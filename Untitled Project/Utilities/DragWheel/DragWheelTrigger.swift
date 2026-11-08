// Adapted from the user-provided DragWheel source archive (revision 9fc8867).
import AppKit
import CoreGraphics

enum DWTriggerKey: Hashable, Sendable {
    case shift, option, control, command, fn
    case key(code: UInt16, name: String)

    static let presets: [DWTriggerKey] = [.shift, .option, .control, .command, .fn]

    var displayName: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        case .fn: return "fn"
        case .key(_, let name): return name
        }
    }

    @MainActor var isHeld: Bool {
        let flags = NSEvent.modifierFlags
        switch self {
        case .shift: return flags.contains(.shift)
        case .option: return flags.contains(.option)
        case .control: return flags.contains(.control)
        case .command: return flags.contains(.command)
        case .fn: return flags.contains(.function)
        case .key(let code, _): return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
    }

    static var current: DWTriggerKey {
        get {
            let d = UserDefaults.standard
            switch d.string(forKey: "dragWheel.trigger") ?? "shift" {
            case "option": return .option
            case "control": return .control
            case "command": return .command
            case "fn": return .fn
            case "key":
                return .key(code: UInt16(clamping: d.integer(forKey: "dragWheel.triggerKeyCode")),
                            name: d.string(forKey: "dragWheel.triggerKeyName") ?? "Key")
            default: return .shift
            }
        }
        set {
            let d = UserDefaults.standard
            switch newValue {
            case .shift: d.set("shift", forKey: "dragWheel.trigger")
            case .option: d.set("option", forKey: "dragWheel.trigger")
            case .control: d.set("control", forKey: "dragWheel.trigger")
            case .command: d.set("command", forKey: "dragWheel.trigger")
            case .fn: d.set("fn", forKey: "dragWheel.trigger")
            case .key(let code, let name):
                d.set("key", forKey: "dragWheel.trigger")
                d.set(Int(code), forKey: "dragWheel.triggerKeyCode")
                d.set(name, forKey: "dragWheel.triggerKeyName")
            }
        }
    }
}

/// Small window that captures the next key / modifier the user presses.
@MainActor final class DWKeyRecorder: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var monitor: Any?
    private var completion: ((DWTriggerKey?) -> Void)?

    private static let names: [UInt16: String] = [
        49: "Space", 48: "Tab", 36: "Return", 51: "Delete", 50: "`",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    func begin(completion: @escaping (DWTriggerKey?) -> Void) {
        finish(nil)
        self.completion = completion

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Set Trigger Key"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let label = NSTextField(wrappingLabelWithString:
            "Press the key you want to hold while dragging.\nModifiers (⇧ ⌥ ⌃ ⌘ fn) work best. Esc cancels.")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 25, width: 300, height: 70)
        panel.contentView?.addSubview(label)
        panel.center()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { finish(nil); return }   // Esc
            let name = Self.names[event.keyCode]
                ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces)
                ?? "Key \(event.keyCode)"
            finish(.key(code: event.keyCode, name: name.isEmpty ? "Key \(event.keyCode)" : name))
            return
        }
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.shift) { finish(.shift) }
        else if f.contains(.option) { finish(.option) }
        else if f.contains(.control) { finish(.control) }
        else if f.contains(.command) { finish(.command) }
        else if f.contains(.function) { finish(.fn) }
    }

    func finish(_ key: DWTriggerKey?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let done = completion
        completion = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        done?(key)
    }

    func windowWillClose(_ notification: Notification) {
        if completion != nil { finish(nil) }
    }
}
