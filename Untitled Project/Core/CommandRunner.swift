import Foundation
import Darwin

struct CommandOutput: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CommandFailure: LocalizedError {
    case timedOut, outputLimit, failed(String)
    var errorDescription: String? {
        switch self {
        case .timedOut: "The system command took too long to respond."
        case .outputLimit: "The system command exceeded its output limit."
        case .failed(let message): message
        }
    }
}

/// Arguments are passed directly to a known executable; no shell is involved.
enum CommandRunner {
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 15,
                    outputLimit: Int = 64 * 1024) async throws -> CommandOutput {
        let session = CommandSession(executable: executable, arguments: arguments, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                try session.execute(timeout: timeout)
            }.value
        } onCancel: {
            session.cancel(CancellationError())
        }
    }
}

/// The lock serializes launch/cancel/termination and bounds the reader buffers.
/// Nonblocking pipe reads and waitUntilExit run only on dedicated background work.
private final class CommandSession: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let outputLimit: Int
    private var stdout = Data()
    private var stderr = Data()
    private var failure: Error?
    private var didFinish = false

    init(executable: URL, arguments: [String], outputLimit: Int) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        self.outputLimit = max(1, outputLimit)
    }

    func execute(timeout: TimeInterval) throws -> CommandOutput {
        // A descendant may inherit a pipe after the direct command exits. Keep
        // readers interruptible and the deadline alive until both pipes drain.
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw CommandFailure.failed("Could not configure the system command's output pipes.")
            }
        }
        try lock.withLock {
            if let failure { throw failure }
            try process.run()
        }
        let deadline = DispatchWorkItem { [weak self] in self?.cancel(CommandFailure.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.1, timeout), execute: deadline)
        let readers = DispatchGroup()
        for (handle, isError) in [(output.fileHandleForReading, false), (errors.fileHandleForReading, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { try? handle.close(); readers.leave() }
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
                defer { buffer.deallocate() }
                while lock.withLock({ failure == nil }) {
                    var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, 50)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        cancel(CommandFailure.failed("Could not read the system command's output."))
                        break
                    }
                    if ready == 0 { continue }
                    let count = Darwin.read(handle.fileDescriptor, buffer, 4096)
                    if count < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        cancel(CommandFailure.failed("Could not read the system command's output."))
                        break
                    }
                    if count == 0 { break }
                    let overflow = lock.withLock {
                        guard count <= outputLimit - stdout.count - stderr.count else { return true }
                        let bytes = Data(bytes: buffer, count: count)
                        if isError { stderr.append(bytes) } else { stdout.append(bytes) }
                        return false
                    }
                    if overflow { cancel(CommandFailure.outputLimit); break }
                }
            }
        }
        process.waitUntilExit()
        readers.wait()
        deadline.cancel()
        return try lock.withLock {
            didFinish = true
            if let failure { throw failure }
            return CommandOutput(status: process.terminationStatus,
                                 stdout: String(decoding: stdout, as: UTF8.self),
                                 stderr: String(decoding: stderr, as: UTF8.self))
        }
    }

    func cancel(_ error: Error) {
        let needsEscalation = lock.withLock {
            guard !didFinish, failure == nil else { return false }
            failure = error
            guard process.isRunning else { return false }
            process.terminate()
            return true
        }
        guard needsEscalation else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if !self.didFinish, self.process.isRunning { _ = kill(self.process.processIdentifier, SIGKILL) }
            }
        }
    }
}
