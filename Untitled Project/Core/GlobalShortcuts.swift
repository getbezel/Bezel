import AppKit
import Carbon
import Observation

@MainActor @Observable
final class GlobalShortcuts {
    enum Action: UInt32, CaseIterable {
        case clipboard = 1, enqueue, dequeue, lens, tileLeft, tileRight
        var key: UInt32 {
            switch self {
            case .clipboard, .dequeue: 9
            case .enqueue: 8
            case .lens: 19
            case .tileLeft: 123
            case .tileRight: 124
            }
        }
        var modifiers: UInt32 {
            switch self {
            case .clipboard: UInt32(cmdKey | optionKey)
            case .enqueue, .dequeue, .lens: UInt32(cmdKey | shiftKey)
            case .tileLeft, .tileRight: UInt32(controlKey | optionKey)
            }
        }
        var name: String {
            switch self {
            case .clipboard: "Open Stack"
            case .enqueue: "Copy to Quick Clips"
            case .dequeue: "Choose a clip to paste"
            case .lens: "Capture text"
            case .tileLeft: "Tile left"
            case .tileRight: "Tile right"
            }
        }
    }
    private(set) var failures: [String] = []
    private(set) var isEnabled = false
    @ObservationIgnored var onAction: ((Action) -> Void)?
    @ObservationIgnored private var references: [EventHotKeyRef] = []
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    func start() {
        guard !isEnabled else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue().onAction?(action)
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            failures = ["Could not install keyboard shortcuts (\(status))."]
            return
        }
        failures = []
        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x425A454C, id: action.rawValue)
            let result = RegisterEventHotKey(action.key, action.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { references.append(reference) }
            else { failures.append("\(action.name) is already assigned or unavailable (\(result)).") }
        }
        isEnabled = true
    }
    func stop() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        isEnabled = false
    }
}
