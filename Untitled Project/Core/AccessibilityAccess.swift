import AppKit
import ApplicationServices
import CoreGraphics

/// Keep window access separate from permission to send keyboard commands.
@MainActor
enum AccessibilityAccess {
    struct Snapshot: Equatable {
        let reportedTrusted: Bool
        let verifiedWindowAccess: Bool
        let probeError: AXError?
        let keyboardEvents: Bool

        var windowAccess: Bool {
            verifiedWindowAccess || (reportedTrusted && probeError != .apiDisabled)
        }
        var diagnostic: String {
            if windowAccess && keyboardEvents { return "Window access and keyboard commands are available." }
            if windowAccess { return "Window access works. macOS is still blocking keyboard commands used by Quick Clips." }
            if keyboardEvents { return "Keyboard commands are available. Window access has not been confirmed." }
            if probeError == .cannotComplete { return "The window-access check did not receive a response. Try Check Access again." }
            return "macOS is denying access to this running copy of Bezel."
        }
    }

    static func current(verify: Bool = false) -> Snapshot {
        let reported = AXIsProcessTrusted()
        var verified = false
        var error: AXError?
        if verify || !reported {
            // Read only an external application's window list. No text, titles, or
            // window contents are retained, and no focus or permission is changed.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let front = NSWorkspace.shared.frontmostApplication
            let target = front?.processIdentifier != ownPID ? front : NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
            if let target, target.processIdentifier != ownPID {
                let application = AXUIElementCreateApplication(target.processIdentifier)
                AXUIElementSetMessagingTimeout(application, 0.15)
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
                error = result
                verified = result == .success && value.map { CFGetTypeID($0) == CFArrayGetTypeID() } == true
            }
        }
        return Snapshot(reportedTrusted: reported, verifiedWindowAccess: verified, probeError: error, keyboardEvents: CGPreflightPostEventAccess())
    }

    static var canControlWindows: Bool { current().windowAccess }
    static var canSendKeyboardEvents: Bool { CGPreflightPostEventAccess() }

    static func request() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestKeyboardEvents() {
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
    }
}
