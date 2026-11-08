import Foundation

private actor WorkflowLog {
    var names: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    let gatedName: String?
    let failingName: String?
    init(gated: String? = nil, failing: String? = nil) { gatedName = gated; failingName = failing }
    func run(_ name: String) async throws {
        names.append(name)
        if name == gatedName { await withCheckedContinuation { gate = $0 } }
        if name == failingName { throw CommandFailure.failed("Fixture workflow failed") }
    }
    func release() { gate?.resume(); gate = nil }
    func snapshot() -> [String] { names }
}

@main struct AutomationTests {
    @MainActor private static var preferenceDomains: [String] = []
    static func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    @MainActor static func defaults() -> UserDefaults {
        let name = "Bezel.Tests.\(UUID().uuidString)"
        preferenceDomains.append(name)
        let value = UserDefaults(suiteName: name)!
        value.set(true, forKey: "focus.automation")
        value.set("On", forKey: "focus.on")
        value.set("Off", forKey: "focus.off")
        return value
    }

    @MainActor static func main() async throws {
        defer { for name in preferenceDomains { UserDefaults.standard.removePersistentDomain(forName: name) } }
        let literal = "$(should-not-execute) `nor-this` ; & |"
        let output = try await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal])
        require(output.status == 0 && output.stdout == literal, "Command arguments must remain literal")
        do {
            _ = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.1)
            fatalError("Command timeout was not enforced")
        } catch CommandFailure.timedOut {}
        let cancelled = Task { try await CommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled command completed") } catch is CancellationError {}
        do {
            _ = try await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["bounded output"], outputLimit: 1024)
            fatalError("Output budget was not enforced")
        } catch CommandFailure.outputLimit {}

        require(CommandLine.arguments.count == 2, "Pass the compiled command fixture path")
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let streams = try await CommandRunner.run(fixture, arguments: ["normal"])
        require(streams.status == 7 && streams.stdout == "stdout fixture\n" && streams.stderr == "stderr fixture\n", "Both streams and the command exit status must survive pipe draining")
        for mode in ["inherited", "ignore-term"] {
            let started = ContinuousClock.now
            do {
                _ = try await CommandRunner.run(fixture, arguments: [mode], timeout: 0.1)
                fatalError("The \(mode) fixture did not enforce its deadline")
            } catch CommandFailure.timedOut {}
            require(started.duration(to: .now) < .seconds(2), "The \(mode) fixture exceeded bounded shutdown")
        }
        let inheritedCancellation = Task { try await CommandRunner.run(fixture, arguments: ["inherited"]) }
        try await Task.sleep(for: .milliseconds(50))
        inheritedCancellation.cancel()
        do { _ = try await inheritedCancellation.value; fatalError("Inherited-pipe cancellation completed successfully") } catch is CancellationError {}

        let racingLog = WorkflowLog(gated: "On")
        let racing = FocusAutomation(defaults: defaults()) { try await racingLog.run($0) }
        racing.setSessionActive(true)
        try await waitUntil { await !racingLog.snapshot().isEmpty }
        racing.setSessionActive(false)
        racing.offShortcut = "Changed After Start"
        await racingLog.release()
        await racing.shutdown()
        require(await racingLog.snapshot() == ["On", "Off"], "A late On must be compensated using the captured Off")
        require(!racing.isRunning && !racing.needsRecovery, "Successful cleanup must finish the worker")

        let failedLog = WorkflowLog(failing: "On")
        let failed = FocusAutomation(defaults: defaults()) { try await failedLog.run($0) }
        failed.setSessionActive(true)
        try await waitUntil { await failedLog.snapshot().count == 2 && !failed.isRunning }
        require(await failedLog.snapshot() == ["On", "Off"], "Indeterminate On failures must run compensation")
        require(failed.lastError != nil, "A starting workflow failure must remain visible after cleanup")

        let pendingDefaults = defaults()
        let endingLog = WorkflowLog(failing: "Off")
        let ending = FocusAutomation(defaults: pendingDefaults) { try await endingLog.run($0) }
        ending.setSessionActive(true)
        try await waitUntil { await !endingLog.snapshot().isEmpty }
        await ending.shutdown()
        require(ending.needsRecovery && pendingDefaults.string(forKey: "focus.pendingOff") == "Off", "Failed cleanup must persist a recovery action")
        let recoveryLog = WorkflowLog()
        let recovered = FocusAutomation(defaults: pendingDefaults) { try await recoveryLog.run($0) }
        require(recovered.needsRecovery, "An interrupted session must expose recovery on launch")
        recovered.recover()
        await recovered.shutdown()
        require(await recoveryLog.snapshot() == ["Off"] && !recovered.needsRecovery, "Recovery must only run the captured ending workflow")
        require(pendingDefaults.object(forKey: "focus.pendingOff") == nil, "Successful recovery must clear its persisted action")

        for pair in [FocusShortcutPair(on: "-h", off: "Off"), FocusShortcutPair(on: "On\nOther", off: "Off"), FocusShortcutPair(on: "Same", off: "Same")] {
            require(!pair.isValid, "Invalid workflow configuration accepted")
        }
        let allowed = MenuVisibilityPolicy.allowedBundles(running: ["com.apple.controlcenter", "test.hidden", "test.visible", "test.visible"], hidden: ["test.hidden", "com.apple.controlcenter"], own: "test.bezel")
        require(allowed == ["com.apple.controlcenter", "test.bezel", "test.visible"], "Menu collapse must preserve Bezel and system icons")
        let valid = CommandOutput(status: 0, stdout: #"{"version":1,"supported":true,"enabled":true,"limit":80}"#, stderr: "")
        require(try ChargeControlSnapshot.decode(valid).limit == 80, "Charge response must decode exact limit")
        for json in [#"{"version":2,"supported":true,"enabled":true,"limit":80}"#, #"{"version":1,"supported":true,"enabled":true,"limit":79}"#, #"{"version":1,"supported":true,"limit":80}"#, #"{"version":1,"supported":true,"enabled":true}"#] {
            var rejected = false
            do { _ = try ChargeControlSnapshot.decode(CommandOutput(status: 0, stdout: json, stderr: "")) } catch { rejected = true }
            require(rejected, "Malformed charge response accepted")
        }
        let chargeLog = WorkflowLog(gated: "limit80")
        let control = NativeChargeControl { action in try await chargeLog.run(action.rawValue); return valid }
        control.refresh()
        try await waitUntil { !control.isBusy }
        control.perform(.limit80)
        try await waitUntil { await chargeLog.snapshot().count == 2 }
        control.perform(.topoff100)
        control.stop()
        require(control.isBusy, "Normal shutdown must not interrupt a requested battery write")
        await chargeLog.release()
        await control.shutdown()
        require(await chargeLog.snapshot() == ["status", "limit80"], "Concurrent battery writes must be serialized")
        require(control.limit == 80 && !control.isBusy, "Battery state must come from the verified helper response")
        print("Automation checks passed: literal process arguments, both output streams, inherited-pipe deadlines/cancellation, forced termination, output bounds, Focus start/stop races, compensation and recovery, menu visibility policy, and charge-response validation/serialization.")
    }

    @MainActor private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            require(ContinuousClock.now < deadline, "An asynchronous fixture did not reach its expected state within three seconds")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
