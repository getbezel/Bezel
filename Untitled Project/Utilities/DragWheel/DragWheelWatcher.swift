import AppKit

/// A fresh drag pasteboard change is required; holding Shift on a click cannot
/// reuse an old file drag. One wheel is presented per mouse session.
struct DWDragSession: Sendable {
    private var baseline: Int?
    private var pressed = false
    private var fired = false

    mutating func update(down: Bool, changeCount: Int, trigger: Bool) -> Bool {
        if !down {
            baseline = changeCount; pressed = false; fired = false
            return false
        }
        if !pressed { pressed = true }
        guard let baseline, baseline != changeCount, trigger, !fired else { return false }
        fired = true
        return true
    }

    mutating func reset(changeCount: Int) {
        baseline = changeCount; pressed = false; fired = false
    }
}

@MainActor final class DWDragWatcher {
    var isTriggerHeld: () -> Bool = { false }
    var onTrigger: ((NSPoint, [URL]) -> Void)?
    var onMouseUp: (() -> Void)?
    private let pasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var session = DWDragSession()
    private var wasDown = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func start() {
        guard timer == nil else { return }
        session.reset(changeCount: pasteboard.changeCount)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseEvent(event) }
            return event
        }
        schedule(active: false)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        wasDown = false
        session.reset(changeCount: pasteboard.changeCount)
    }

    private func mouseEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            // Keep the last idle baseline: Finder may already have populated
            // the drag pasteboard before the asynchronous mouse monitor runs.
            _ = session.update(down: true, changeCount: pasteboard.changeCount, trigger: false)
            wasDown = true
            schedule(active: true)
        } else { released() }
    }

    private func schedule(active: Bool) {
        timer?.invalidate()
        let timer = Timer(timeInterval: active ? 1.0 / 30 : 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = active ? 0.005 : 0.03
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func released() {
        if wasDown { onMouseUp?() }
        wasDown = false
        _ = session.update(down: false, changeCount: pasteboard.changeCount, trigger: false)
        schedule(active: false)
    }

    private func tick() {
        let down = (NSEvent.pressedMouseButtons & 1) != 0
        if !down {
            if wasDown { released() }
            else { _ = session.update(down: false, changeCount: pasteboard.changeCount, trigger: false) }
            return
        }
        if !wasDown { wasDown = true; schedule(active: true) }
        guard session.update(down: true, changeCount: pasteboard.changeCount, trigger: isTriggerHeld()) else { return }
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !files.isEmpty else { return }
        onTrigger?(NSEvent.mouseLocation, files)
    }
}
