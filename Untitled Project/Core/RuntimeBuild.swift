import AppKit
import Security

struct RuntimeBuild: Sendable {
    let appPath: String
    let isAdHoc: Bool
    let diskChanged: Bool

    static func current() -> Self {
        var code: SecCode?
        var information: CFDictionary?
        var adHoc = false
        var diskChanged = false
        if SecCodeCopySelf([], &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
               SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
               let info = information as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? NSNumber {
                adHoc = flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
            }
            diskChanged = SecCodeCheckValidity(code, [], nil) == errSecCSStaticCodeChanged
        }
        return Self(appPath: Bundle.main.bundleURL.path, isAdHoc: adHoc, diskChanged: diskChanged)
    }

    var accessHelp: String {
        if diskChanged { return "Bezel was rebuilt while this copy was running. Quit Bezel from its menu bar and reopen the app shown below." }
        if appPath.hasPrefix("/Volumes/") || appPath.contains("/AppTranslocation/") {
            return "Install Bezel in Applications, eject its disk image, then launch that installed copy before granting permissions. Each Mac needs its own approval. Use Show This App in Finder to identify this copy."
        }
        if isAdHoc { return "This development build may need new permission after a rebuild. If Bezel is enabled in Settings but still blocked, remove the old Bezel entry, add this exact app again, then quit and reopen Bezel." }
        return "If macOS still blocks access after enabling it, quit Bezel from its menu bar and reopen this app. Closing the window does not quit Bezel."
    }

    @MainActor func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)]) }
}
