import AppKit
import ApplicationServices

/// AX notifications drive focus and geometry changes. A lightweight fallback
/// handles apps that omit notifications, without redrawing a stationary window.
@MainActor
final class FocusWindowTracker {
    var onChange: ((CGRect?, Bool) -> Void)?
    private var observer: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedWindow: AXUIElement?
    private var activationToken: NSObjectProtocol?
    private var spacesToken: NSObjectProtocol?
    private var screensToken: NSObjectProtocol?
    private var timer: Timer?
    private var scheduled: Task<Void, Never>?
    private var active = false
    private var globalDragMonitor: Any?
    private var localDragMonitor: Any?
    private var previous: CGRect?

    func start() {
        guard !active else { return }
        active = true
        let center = NSWorkspace.shared.notificationCenter
        activationToken = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        spacesToken = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        screensToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.previous = nil; self?.sample(animated: false) }
        }
        attach()
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(animated: false) }
        }
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated { self?.schedule(animated: false) }
            return event
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        active = false
        scheduled?.cancel(); scheduled = nil
        timer?.invalidate(); timer = nil
        let center = NSWorkspace.shared.notificationCenter
        if let activationToken { center.removeObserver(activationToken) }
        if let spacesToken { center.removeObserver(spacesToken) }
        if let screensToken { NotificationCenter.default.removeObserver(screensToken) }
        activationToken = nil; spacesToken = nil; screensToken = nil
        detach()
        previous = nil
        if let globalDragMonitor { NSEvent.removeMonitor(globalDragMonitor) }
        if let localDragMonitor { NSEvent.removeMonitor(localDragMonitor) }
        globalDragMonitor = nil; localDragMonitor = nil
    }

    private func tick() {
        guard active else { return }
        sample(animated: false)
    }

    private func attach() {
        guard active else { return }
        detach()
        guard let app = NSWorkspace.shared.frontmostApplication else { publish(nil, animated: false); return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.025)
        observedApplication = element
        var nativeObserver: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            // This observer's source is registered exclusively on the main run loop.
            MainActor.assumeIsolated {
                let tracker = Unmanaged<FocusWindowTracker>.fromOpaque(context).takeUnretainedValue()
                let focus = notification as String == kAXFocusedWindowChangedNotification || notification as String == kAXMainWindowChangedNotification
                tracker.schedule(animated: focus)
            }
        }, &nativeObserver)
        if result == .success, let nativeObserver {
            observer = nativeObserver
            for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                AXObserverAddNotification(nativeObserver, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(nativeObserver), .commonModes)
        }
        sample(animated: true)
        // Activation can precede the app publishing its focused window.
        schedule(animated: true)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedWindow = nil
        observedApplication = nil
    }

    private func schedule(animated: Bool) {
        guard active, scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            guard let self, active else { return }
            scheduled = nil
            sample(animated: animated && NSEvent.pressedMouseButtons & 1 == 0)
        }
    }

    private func sample(animated: Bool) {
        guard active, let application = observedApplication else { return }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            publish(nil, animated: false)
            return
        }
        let window = unsafeDowncast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.025)
        if observedWindow.map({ CFEqual($0, window) }) != true {
            if let observer, let old = observedWindow {
                for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                    AXObserverRemoveNotification(observer, old, name as CFString)
                }
            }
            observedWindow = window
            if let observer {
                for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                    AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                }
            }
        }
        guard let frame = FocusedWindowAccess.frame(of: window), frame.width > 1, frame.height > 1 else {
            publish(nil, animated: false)
            return
        }
        publish(FocusedWindowAccess.appKitFrame(frame).insetBy(dx: -1, dy: -1), animated: animated)
    }

    private func publish(_ frame: CGRect?, animated: Bool) {
        guard frame != previous else { return }
        previous = frame
        onChange?(frame, animated)
    }
}
