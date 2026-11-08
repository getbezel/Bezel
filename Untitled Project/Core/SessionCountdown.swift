import Foundation

/// Measures elapsed time independently of calendar or network-clock adjustments.
/// ContinuousClock also accounts for time spent asleep, so expiry is reflected on wake.
struct SessionCountdown: Sendable {
    private let startedAt: ContinuousClock.Instant
    private let totalSeconds: Int

    init(seconds: Int, now: ContinuousClock.Instant = .now) {
        startedAt = now
        totalSeconds = max(0, seconds)
    }

    func remainingSeconds(at now: ContinuousClock.Instant = .now) -> Int {
        let elapsed = startedAt.duration(to: now)
        guard elapsed > .zero else { return totalSeconds }
        guard elapsed < .seconds(totalSeconds) else { return 0 }
        // Rounding elapsed time down keeps the last fraction of a second visible.
        return totalSeconds - Int(elapsed.components.seconds)
    }
}
