import Foundation
import Observation

struct FocusShortcutPair: Equatable, Sendable {
    let on: String
    let off: String
    var isValid: Bool { Self.valid(on) && Self.valid(off) && on != off }
    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && !value.hasPrefix("-") &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Serializes On/Off workflows so a late On can never overtake an End Session.
/// Each session captures its Off shortcut, even if settings change mid-session.
@MainActor @Observable
final class FocusAutomation {
    typealias Runner = @Sendable (String) async throws -> Void
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "focus.automation")
            if !isEnabled { setSessionActive(false) }
        }
    }
    var onShortcut: String { didSet { defaults.set(onShortcut, forKey: "focus.on") } }
    var offShortcut: String { didSet { defaults.set(offShortcut, forKey: "focus.off") } }
    private(set) var isRunning = false
    private(set) var status = "Notifications follow your macOS Focus settings."
    private(set) var lastError: String?
    private(set) var needsRecovery = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let run: Runner
    @ObservationIgnored private var requested: FocusShortcutPair?
    @ObservationIgnored private var applied: FocusShortcutPair?
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, runner: @escaping Runner = FocusAutomation.runShortcut) {
        self.defaults = defaults
        run = runner
        isEnabled = defaults.bool(forKey: "focus.automation")
        onShortcut = defaults.string(forKey: "focus.on") ?? "Bezel Focus On"
        offShortcut = defaults.string(forKey: "focus.off") ?? "Bezel Focus Off"
        if let recovery = defaults.string(forKey: "focus.pendingOff") {
            applied = FocusShortcutPair(on: "Recovery", off: recovery)
            needsRecovery = true
            status = "A previous Focus session needs its ending shortcut."
        }
    }

    func setSessionActive(_ active: Bool) {
        if active && isEnabled {
            let pair = FocusShortcutPair(on: onShortcut.trimmingCharacters(in: .whitespaces),
                                         off: offShortcut.trimmingCharacters(in: .whitespaces))
            guard pair.isValid else {
                lastError = "Choose two different shortcut names or identifiers without line breaks."
                return
            }
            requested = pair
        } else { requested = nil }
        beginWorker()
    }

    func recover() { requested = nil; beginWorker() }

    func shutdown() async {
        requested = nil
        beginWorker()
        await worker?.value
    }

    private func beginWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.reconcile() }
    }

    private func reconcile() async {
        isRunning = true
        defer { isRunning = false; worker = nil }
        var startingFailure: String?
        while applied != requested {
            if let previous = applied {
                status = "Running the ending Focus shortcut…"
                do {
                    try await run(previous.off)
                    applied = nil
                    needsRecovery = false
                    defaults.removeObject(forKey: "focus.pendingOff")
                    status = "Ending Focus shortcut finished."
                    lastError = startingFailure
                } catch {
                    needsRecovery = true
                    requested = nil
                    lastError = "The ending shortcut failed: \(error.localizedDescription)"
                    status = "Run the ending shortcut to restore notifications."
                    return
                }
            } else if let next = requested {
                // A timeout can occur after the workflow changed Focus, so always
                // retain the compensation before starting and run it on failure.
                applied = next
                defaults.set(next.off, forKey: "focus.pendingOff")
                status = "Running the starting Focus shortcut…"
                do {
                    try await run(next.on)
                    lastError = nil
                    status = "Starting Focus shortcut finished."
                } catch {
                    startingFailure = "The starting shortcut failed: \(error.localizedDescription)"
                    lastError = startingFailure
                    if requested == next { requested = nil }
                }
            }
        }
    }

    nonisolated static func runShortcut(_ name: String) async throws {
        let result = try await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["run", name])
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandFailure.failed(detail.isEmpty ? "Shortcuts returned exit status \(result.status)." : String(detail.prefix(500)))
        }
    }
}
