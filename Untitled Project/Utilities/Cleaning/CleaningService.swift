import AppKit
import Carbon
import CoreGraphics
import Observation
import SwiftUI

@MainActor @Observable
final class CleaningService {
    private(set) var isActive = false
    private(set) var escapeProgress: Double = 0
    private(set) var remainingSeconds = 0
    private(set) var lastStatus: String?
    private(set) var lastFailure: String?
    var lastError: String? {
        didSet { if let lastError { lastFailure = lastError } }
    }
    var durationMinutes: Int = {
        let stored = UserDefaults.standard.integer(forKey: "cleaning.duration")
        return [1, 2, 3, 5].contains(stored) ? stored : 3
    }() {
        didSet {
            if ![1, 2, 3, 5].contains(durationMinutes) { durationMinutes = 3 }
            UserDefaults.standard.set(durationMinutes, forKey: "cleaning.duration")
        }
    }
    @ObservationIgnored private var inputShield: CleaningInputShield?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panels: [NSPanel] = []
    @ObservationIgnored private var hidCursor = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard !isActive else { return }
        lastError = nil
        lastFailure = nil
        lastStatus = nil
        guard AccessibilityAccess.canControlWindows else {
            lastError = "Allow this copy of Bezel under System Settings → Privacy & Security → Accessibility before starting Cleaning mode."
            return
        }
        guard !IsSecureEventInputEnabled() else {
            lastError = "macOS Secure Keyboard Entry is active. Close password prompts or turn off Secure Keyboard Entry in Terminal before starting Cleaning mode."
            return
        }
        let shield = CleaningInputShield()
        do { try shield.prepare() }
        catch { lastError = error.localizedDescription; return }
        inputShield = shield
        remainingSeconds = durationMinutes * 60
        escapeProgress = 0
        isActive = true
        showPanels()
        guard !panels.isEmpty else {
            stop(); lastError = "No display was available. Cleaning mode ended."; return
        }
        guard shield.arm(duration: Double(durationMinutes * 60)) else {
            stop(); lastError = "macOS blocked the input shield. Review Accessibility and Input Monitoring access before trying again."; return
        }
        NSCursor.hide(); hidCursor = true
        observe(NotificationCenter.default, name: NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.showPanels() }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.screensDidSleepNotification) { [weak self] in self?.stop() }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification) { [weak self] in self?.stop() }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.stop() }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        lastStatus = nil
    }

    func stop() {
        // Release the input filter first, before any window or observer cleanup.
        inputShield?.stop()
        inputShield = nil
        timer?.invalidate(); timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        if hidCursor { NSCursor.unhide(); hidCursor = false }
        if isActive { lastStatus = "Cleaning mode ended. Keyboard and pointer input are available." }
        isActive = false; escapeProgress = 0; remainingSeconds = 0
    }

    private func tick() {
        guard isActive, let shield = inputShield else { return }
        let snapshot = shield.snapshot()
        if !snapshot.active {
            stop()
            switch snapshot.reason {
            case .timeout: lastStatus = "Cleaning mode ended at the automatic timeout."
            case .interrupted: lastError = "macOS interrupted input blocking. Cleaning mode ended and input is available. Try again; if it repeats, review Accessibility and Input Monitoring."
            case .secureInput: lastError = "Secure Keyboard Entry became active, so Cleaning mode ended. Close password prompts or disable Terminal’s Secure Keyboard Entry before trying again."
            default: break
            }
            return
        }
        if escapeProgress != snapshot.progress { escapeProgress = snapshot.progress }
        if remainingSeconds != snapshot.remaining { remainingSeconds = snapshot.remaining }
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    private func showPanels() {
        guard isActive else { return }
        panels.forEach { $0.orderOut(nil); $0.close() }; panels.removeAll()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .black; panel.isOpaque = true
            panel.hasShadow = false; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let host = NSHostingView(rootView: CleaningOverlay(service: self))
            host.sizingOptions = []
            panel.contentView = host
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        if panels.isEmpty { stop() }
    }
}

private struct CleaningOverlay: View {
    let service: CleaningService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.45))
            VStack(spacing: 8) {
                Text("Cleaning mode").font(.system(size: 26, weight: .medium))
                Text("Keyboard and pointer input are paused.").font(.callout).foregroundStyle(.white.opacity(0.5))
            }
            ZStack {
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 2)
                Circle().trim(from: 0, to: service.escapeProgress)
                    .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("esc").font(.system(size: 16, weight: .medium, design: .monospaced))
            }.frame(width: 60, height: 60)
                .animation(reduceMotion ? nil : .linear(duration: 0.05), value: service.escapeProgress)
            VStack(spacing: 8) {
                Text("Hold Escape for 2 seconds to finish.").font(.callout)
                Text("Automatic exit in \(service.remainingSeconds / 60):\(String(format: "%02d", service.remainingSeconds % 60))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                Text("⌘⌥Esc exits immediately.").font(.caption).foregroundStyle(.white.opacity(0.4))
            }
        }
        .foregroundStyle(.white.opacity(0.8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.colorScheme, .dark)
    }
}
