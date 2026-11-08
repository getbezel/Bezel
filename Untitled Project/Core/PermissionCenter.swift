import AppKit
import Observation
import ApplicationServices
import CoreGraphics
import ServiceManagement

@MainActor @Observable
final class PermissionCenter {
    private(set) var accessibility = false
    private(set) var keyboardEvents = false
    private(set) var accessibilityDiagnostic = "Checking access…"
    @ObservationIgnored private var accessTimer: Timer?
    private(set) var screenCapture = false
    private(set) var loginEnabled = false
    var loginError: String?
    private(set) var runtimeBuild = RuntimeBuild.current()

    func refresh() {
        runtimeBuild = .current()
        refreshAccessibility(verify: true)
        screenCapture = CGPreflightScreenCaptureAccess()
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    func refreshAccessibility(verify: Bool = false) {
        let status = AccessibilityAccess.current(verify: verify)
        accessibility = status.windowAccess
        keyboardEvents = status.keyboardEvents
        accessibilityDiagnostic = status.diagnostic
        if verify {
            // Local, content-free support report from the actual app process.
            let report: [String: Any] = [
                "appPath": Bundle.main.bundleURL.path,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "reportedTrusted": status.reportedTrusted,
                "verifiedWindowAccess": status.verifiedWindowAccess,
                "windowAccess": status.windowAccess,
                "probeError": status.probeError.map { Int($0.rawValue) } ?? 0,
                "keyboardEvents": status.keyboardEvents,
                "checkedAt": ISO8601DateFormatter().string(from: Date())
            ]
            if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Bezel", isDirectory: true),
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent("AccessStatus.json"), options: .atomic)
            }
        }
    }
    func startMonitoring() {
        guard accessTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAccessibility() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        accessTimer = timer
    }
    func stopMonitoring() { accessTimer?.invalidate(); accessTimer = nil }
    func requestAccessibility() {
        AccessibilityAccess.request()
        refreshAccessibility(verify: true)
        if !accessibility { openPrivacy("Privacy_Accessibility") }
    }
    func requestKeyboardEvents() {
        AccessibilityAccess.requestKeyboardEvents()
        refreshAccessibility(verify: true)
        if !keyboardEvents { openPrivacy("Privacy_Accessibility") }
    }
    func requestScreenCapture() {
        screenCapture = CGRequestScreenCaptureAccess()
        if !screenCapture { openPrivacy("Privacy_ScreenCapture") }
    }
    func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        refresh()
    }
}
