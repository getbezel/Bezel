import Foundation
import Observation

struct ChargeControlSnapshot: Decodable, Equatable, Sendable {
    let version: Int
    let supported: Bool
    let enabled: Bool?
    let limit: Int?
    let error: String?

    static func decode(_ output: CommandOutput) throws -> Self {
        guard let data = output.stdout.data(using: .utf8) else { throw CommandFailure.failed("The battery controller returned invalid text.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.limit == nil || (80...100).contains(value.limit!) else {
            throw CommandFailure.failed("The battery controller returned an incompatible response.")
        }
        guard output.status == 0 else { throw CommandFailure.failed(value.error ?? "The battery control request failed.") }
        guard !value.supported || (value.enabled != nil && (value.enabled != true || value.limit != nil)) else { throw CommandFailure.failed("The battery controller did not report its state.") }
        return value
    }
}

@MainActor @Observable
final class NativeChargeControl {
    enum Action: String, Sendable { case status, limit80, topoff100, removeLimit }
    typealias Runner = @Sendable (Action) async throws -> CommandOutput
    private(set) var supported = false
    private(set) var isEnabled = false
    private(set) var limit: Int?
    private(set) var isBusy = false
    private(set) var didCheck = false
    private(set) var topOffRequested = false
    private(set) var lastError: String?
    @ObservationIgnored private let run: Runner
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeAction: Action?

    init(runner: @escaping Runner = NativeChargeControl.runAgent) { run = runner }

    func refresh() { perform(.status) }

    func perform(_ action: Action) {
        guard !isBusy, action == .status || supported else { return }
        isBusy = true
        activeAction = action
        task = Task { [weak self, run] in
            do {
                let value = try ChargeControlSnapshot.decode(await run(action))
                guard let self, !Task.isCancelled else { return }
                supported = value.supported
                isEnabled = value.enabled ?? false
                limit = value.limit
                didCheck = true
                lastError = value.error
                if action == .topoff100 { topOffRequested = true }
                if action == .limit80 || action == .removeLimit { topOffRequested = false }
            } catch {
                guard let self, !Task.isCancelled else { return }
                lastError = error.localizedDescription
                if action == .status { supported = false; didCheck = true }
            }
            self?.isBusy = false
            self?.task = nil
            self?.activeAction = nil
        }
    }

    func clearTopOffStatus() { topOffRequested = false }

    func stop() {
        // Let an explicitly requested write finish during normal termination.
        // Only read-only work may be cancelled without a partial transaction.
        guard activeAction == .status else { return }
        task?.cancel()
        task = nil
        activeAction = nil
        isBusy = false
    }

    func shutdown() async { stop(); await task?.value }

    nonisolated static func runAgent(_ action: Action) async throws -> CommandOutput {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BezelChargeAgent")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CommandFailure.failed("The bundled battery controller is missing. Rebuild Bezel to install it.")
        }
        return try await CommandRunner.run(executable, arguments: [action.rawValue], timeout: 8, outputLimit: 8192)
    }
}
