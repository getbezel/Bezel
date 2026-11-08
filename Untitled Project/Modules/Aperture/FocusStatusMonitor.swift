import AppKit
import Intents
import Observation

/// Unknown/shared-off states establish no transition and never mean Focus is off.
struct FocusChangeTracker: Sendable {
    private var previous: Bool?
    mutating func observe(_ value: Bool?) -> Bool? {
        guard let value else { previous = nil; return nil }
        defer { previous = value }
        guard let previous, previous != value else { return nil }
        return value
    }
    mutating func reset() { previous = nil }
}

@MainActor @Observable
final class FocusStatusMonitor {
    var isEnabled = UserDefaults.standard.object(forKey: "aperture.focusStatus") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "aperture.focusStatus")
            if active && isEnabled { start() } else { stop() }
        }
    }
    private(set) var authorization = INFocusStatusAuthorizationStatus.notDetermined
    private(set) var isFocused: Bool?
    private(set) var isRequesting = false
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private var tracker = FocusChangeTracker()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var statusDescription: String {
        switch authorization {
        case .notDetermined: "Allow Focus status to show changes from Control Center."
        case .denied: "Focus access is denied. Review Focus sharing in System Settings."
        case .restricted: "macOS does not allow this app to read Focus status."
        case .authorized:
            if let isFocused { isFocused ? "Focus is on. Notifications are silenced." : "Focus is off." }
            else { "Focus status is not being shared with Bezel." }
        @unknown default: "Focus status is unavailable."
        }
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value && isEnabled { start() } else { stop() }
    }

    func requestAccess() {
        guard !isRequesting else { return }
        isRequesting = true
        INFocusStatusCenter.default.requestAuthorization { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRequesting = false
                self.refresh(announceInitial: self.active && self.isEnabled)
            }
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        tracker.reset()
    }

    private func refresh(announceInitial: Bool = false) {
        let center = INFocusStatusCenter.default
        authorization = center.authorizationStatus
        let value = authorization == .authorized ? center.focusStatus.isFocused : nil
        isFocused = value
        let transition = tracker.observe(value)
        if let transition { onChange?(transition) }
        else if announceInitial, let value { onChange?(value) }
    }
}
