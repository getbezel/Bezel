import AppKit
import ApplicationServices

/// The app and its input focus are captured before the picker can become key.
@MainActor
struct ClipboardTarget {
    let application: NSRunningApplication
    private let window: AXUIElement?
    private let input: AXUIElement?

    init(application: NSRunningApplication) {
        self.application = application
        let app = AXUIElementCreateApplication(application.processIdentifier)
        window = Self.element(app, attribute: kAXFocusedWindowAttribute)
        input = Self.element(app, attribute: kAXFocusedUIElementAttribute)
    }

    private static func element(_ app: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func restoreFocus() {
        application.activate(options: [])
        if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        if let input {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(input, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue {
                AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    var isActive: Bool {
        !application.isTerminated && application.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }
}

@MainActor
enum ClipboardCommandExecutor {
    struct Environment {
        var isTrusted: () -> Bool
        var heldModifiers: () -> CGEventFlags
        var restoreFocus: () -> Void
        var isTargetActive: () -> Bool
        var deliver: ([CGEvent]) -> Bool
    }

    enum Failure: LocalizedError {
        case permission, modifiersHeld, focus, delivery
        var errorDescription: String? {
            switch self {
            case .permission: "macOS is blocking keyboard commands for this copy of Bezel. Check Keyboard Commands in Bezel Settings."
            case .modifiersHeld: "Release the shortcut keys, then try again."
            case .focus: "The original app could not regain focus. Click its text box and try again."
            case .delivery: "macOS could not deliver the clipboard command. Your saved clips are unchanged."
            }
        }
    }

    static func events(for key: CGKeyCode) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return [down, up]
    }

    static func execute(key: CGKeyCode, environment: Environment, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        guard environment.isTrusted() else { throw Failure.permission }
        let modifiersDeadline = clock.now.advanced(by: timeout)
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        while !environment.heldModifiers().intersection(modifiers).isEmpty {
            try Task.checkCancellation()
            guard clock.now < modifiersDeadline else { throw Failure.modifiersHeld }
            try await Task.sleep(for: .milliseconds(15))
        }
        try Task.checkCancellation()
        environment.restoreFocus()
        let focusDeadline = clock.now.advanced(by: timeout)
        while !environment.isTargetActive() {
            try Task.checkCancellation()
            guard clock.now < focusDeadline else { throw Failure.focus }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Let AppKit finish returning keyboard focus after hiding a nonactivating panel.
        try await Task.sleep(for: .milliseconds(60))
        guard environment.isTrusted() else { throw Failure.permission }
        guard environment.isTargetActive() else { throw Failure.focus }
        guard let events = events(for: key), environment.deliver(events) else { throw Failure.delivery }
    }
}
