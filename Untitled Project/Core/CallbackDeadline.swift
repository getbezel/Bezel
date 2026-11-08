import Foundation

/// Resolves a framework callback once, even if it arrives after cancellation or a timeout.
enum CallbackDeadline {
    struct Timeout: LocalizedError {
        var errorDescription: String? { "macOS did not finish the capture request. Quit and reopen Bezel after granting Screen Recording, then try again." }
    }

    @MainActor static func perform<Value: Sendable>(timeout: Duration, start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) async throws -> Value {
        let gate = CallbackGate<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else { gate.resolve(.failure(CancellationError())); return }
                let deadline = Task.detached {
                    do { try await Task.sleep(for: timeout); gate.resolve(.failure(Timeout())) }
                    catch { /* A delivered result cancels the deadline. */ }
                }
                gate.setDeadline(deadline)
                start { gate.resolve($0) }
            }
        } onCancel: { gate.resolve(.failure(CancellationError())) }
    }
}

private final class CallbackGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var deadline: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        let completed = result
        if completed == nil { self.continuation = continuation }
        lock.unlock()
        if let completed { continuation.resume(with: completed) }
    }

    func setDeadline(_ task: Task<Void, Never>) {
        lock.lock()
        let complete = result != nil
        if !complete { deadline = task }
        lock.unlock()
        if complete { task.cancel() }
    }

    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let deadline = self.deadline
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        continuation?.resume(with: result)
    }
}
