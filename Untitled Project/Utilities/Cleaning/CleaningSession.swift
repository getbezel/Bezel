import Foundation

/// Uses monotonic time so a wall-clock/time-zone change cannot extend a lock.
struct CleaningSession {
    enum Exit: String { case escape, timeout }
    static let holdDuration: TimeInterval = 2
    let deadline: TimeInterval
    private(set) var escapeStarted: TimeInterval?

    init(now: TimeInterval, duration: TimeInterval) {
        deadline = now + min(300, max(30, duration))
    }
    mutating func escapeDown(now: TimeInterval, repeated: Bool) {
        if !repeated, escapeStarted == nil { escapeStarted = now }
    }
    mutating func escapeUp() { escapeStarted = nil }
    func progress(now: TimeInterval) -> Double {
        guard let escapeStarted else { return 0 }
        return min(1, max(0, (now - escapeStarted) / Self.holdDuration))
    }
    func remaining(now: TimeInterval) -> Int { Int(max(0, ceil(deadline - now))) }
    func exit(now: TimeInterval) -> Exit? {
        if now >= deadline { return .timeout }
        if progress(now: now) >= 1 { return .escape }
        return nil
    }
}
