import AppKit
import Observation
import ApplicationServices
import CoreGraphics
import ServiceManagement

@MainActor @Observable
final class PermissionCenter {
    private(set) var accessibility = false
    private(set) var screenCapture = false
    private(set) var loginEnabled = false
    var loginError: String?

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenCapture = CGPreflightScreenCaptureAccess()
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
        if !accessibility { openPrivacy("Privacy_Accessibility") }
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
