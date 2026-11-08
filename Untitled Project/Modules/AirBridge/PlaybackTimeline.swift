import Foundation

/// Player samples arrive every two seconds; project between samples using a
/// monotonic clock so the expanded scrubber moves without extra Apple events.
struct PlaybackTimeline: Sendable, Equatable {
    let position: Double
    let duration: Double
    let sampledAt: ContinuousClock.Instant

    init?(position: Double, duration: Double, sampledAt: ContinuousClock.Instant = .now) {
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0, duration <= 604800 else { return nil }
        self.position = min(position, duration)
        self.duration = duration
        self.sampledAt = sampledAt
    }
    func elapsed(playing: Bool, now: ContinuousClock.Instant = .now) -> Double {
        let delta = sampledAt.duration(to: now).components
        let seconds = Double(delta.seconds) + Double(delta.attoseconds) / 1e18
        return min(duration, max(0, position + (playing ? max(0, seconds) : 0)))
    }
    static func label(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(min(604800, max(0, seconds)))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
