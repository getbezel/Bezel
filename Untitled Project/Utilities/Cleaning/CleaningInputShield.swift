import Foundation
import CoreGraphics
import Carbon

/// Input filtering must keep running while AppKit/SwiftUI builds or redraws windows.
/// Only the tap's private run loop handles events; the UI polls a content-free snapshot.
final class CleaningInputShield: @unchecked Sendable {
    enum EndReason { case escape, timeout, forceQuit, interrupted, secureInput }
    struct Snapshot {
        let active: Bool
        let progress: Double
        let remaining: Int
        let reason: EndReason?
    }
    enum Failure: LocalizedError {
        case unavailable, keyboardDenied, workerUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: "macOS couldn’t enable input blocking. Review Bezel’s Accessibility and Input Monitoring access, then try again."
            case .keyboardDenied: "macOS didn’t allow keyboard blocking. Review Bezel’s Accessibility access before starting Cleaning mode."
            case .workerUnavailable: "The input shield couldn’t start its event handler. Please try again."
            }
        }
    }
    private let lock = NSLock()
    private var session: CleaningSession?
    private var reason: EndReason?
    private var stopped = false
    private var prepared = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?
    private var thread: Thread?

    /// Creates a disabled filter. No user input is suppressed until arm is called.
    func prepare() throws {
        guard lock.withLock({
            if prepared || stopped { return false }
            prepared = true
            return true
        }) else { throw Failure.unavailable }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
            .tabletPointer, .tabletProximity]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let shield = Unmanaged<CleaningInputShield>.fromOpaque(context).takeUnretainedValue()
                return shield.handle(type, event: event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw Failure.unavailable }
        CGEvent.tapEnable(tap: tap, enable: false)
        guard Self.hasKeyboardFilter() else { CFMachPortInvalidate(tap); throw Failure.keyboardDenied }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); throw Failure.workerUnavailable
        }
        let ready = DispatchSemaphore(value: 0)
        lock.withLock { self.tap = tap; self.source = source }
        // Retains self until the run loop ends, keeping the callback context alive.
        let worker = Thread { [self] in run(ready: ready) }
        worker.name = "Bezel Cleaning Input"
        worker.qualityOfService = .userInteractive
        lock.withLock { thread = worker }
        worker.start()
        guard ready.wait(timeout: .now() + 1) == .success else { stop(); throw Failure.workerUnavailable }
    }

    @discardableResult func arm(duration: TimeInterval) -> Bool {
        let port = lock.withLock { () -> CFMachPort? in
            guard !stopped, loop != nil, let tap else { return nil }
            return tap
        }
        guard let port else { return false }
        return activate(duration: duration) {
            CGEvent.tapEnable(tap: port, enable: true)
            return CGEvent.tapIsEnabled(tap: port)
        }
    }

    /// Serialize enabling with stop and publish the session only after the filter
    /// is enabled. Otherwise the worker can mistake startup for tap interruption.
    /// The closure is synchronous and must not reenter this shield.
    @discardableResult func activate(duration: TimeInterval, enableFilter: () -> Bool) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            guard enableFilter() else { session = nil; reason = .interrupted; return false }
            session = CleaningSession(now: ProcessInfo.processInfo.systemUptime, duration: duration)
            reason = nil
            return true
        }
    }

    func snapshot() -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            Snapshot(active: session != nil, progress: session?.progress(now: now) ?? 0,
                     remaining: session?.remaining(now: now) ?? 0, reason: reason)
        }
    }

    func stop() {
        let resources = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            stopped = true
            session = nil
            return (tap, loop)
        }
        if let port = resources.0 { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop = resources.1 { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
    }

    private func run(ready: DispatchSemaphore) {
        guard let source = lock.withLock({ self.source }) else { ready.signal(); return }
        let current = CFRunLoopGetCurrent()!
        lock.withLock { loop = current }
        CFRunLoopAddSource(current, source, .commonModes)
        ready.signal()
        defer {
            CFRunLoopRemoveSource(current, source, .commonModes)
            lock.withLock { loop = nil; thread = nil; tap = nil; self.source = nil }
        }
        // A finite run interval also handles stop racing with run-loop startup.
        while !lock.withLock({ stopped }) {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            guard snapshot().active else { continue }
            if IsSecureEventInputEnabled() { finish(.secureInput); continue }
            let port = lock.withLock { tap }
            guard let port, CGEvent.tapIsEnabled(tap: port) else { finish(.interrupted); continue }
            let exit = lock.withLock { session?.exit(now: ProcessInfo.processInfo.systemUptime) }
            if let exit { finish(exit == .escape ? .escape : .timeout) }
        }
    }

    private func finish(_ value: EndReason) {
        let port = lock.withLock { () -> CFMachPort? in
            guard session != nil else { return nil }
            session = nil; reason = value
            return tap
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            finish(.interrupted); return false
        }
        guard snapshot().active else { return false }
        if type == .keyDown || type == .keyUp,
           event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            if type == .keyDown, event.flags.contains(.maskCommand), event.flags.contains(.maskAlternate) {
                finish(.forceQuit); return false
            }
            lock.withLock {
                if type == .keyDown {
                    session?.escapeDown(now: ProcessInfo.processInfo.systemUptime,
                                        repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                } else { session?.escapeUp() }
            }
        }
        // No characters, pointer coordinates or clipboard contents are retained.
        return true
    }

    private static func hasKeyboardFilter() -> Bool {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0, count <= 4096 else { return false }
        var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var returned: UInt32 = 0
        let result = entries.withUnsafeMutableBufferPointer { CGGetEventTapList(count, $0.baseAddress, &returned) }
        guard result == .success else { return false }
        let required = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        return entries.prefix(Int(min(returned, count))).contains {
            $0.tappingProcess == ProcessInfo.processInfo.processIdentifier && $0.tapPoint == .cgSessionEventTap &&
            $0.options == .defaultTap && $0.eventsOfInterest & required == required
        }
    }
}
