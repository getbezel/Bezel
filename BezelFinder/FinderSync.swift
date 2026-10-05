import AppKit
import FinderSync

final class BezelFinderSync: FIFinderSync {
    override init() {
        super.init()
        // This context-menu-only extension never requests badge updates or traverses folders.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer,
              let url = selectedURL() else { return nil }
        let menu = NSMenu(title: "Bezel")
        let inspect = NSMenuItem(title: "Analyze Storage with Bezel", action: #selector(analyze), keyEquivalent: "")
        inspect.target = self
        menu.addItem(inspect)
        if Self.isArchive(url) {
            let contents = NSMenuItem(title: "Inspect Archive with Bezel", action: #selector(inspectArchive), keyEquivalent: "")
            contents.target = self
            menu.addItem(contents)
            let extract = NSMenuItem(title: "Extract with Bezel…", action: #selector(extract), keyEquivalent: "")
            extract.target = self
            menu.addItem(extract)
        }
        let compress = NSMenuItem(title: "Compress with Bezel…", action: #selector(compress), keyEquivalent: "")
        compress.target = self
        menu.addItem(compress)
        return menu
    }
    private func selectedURL() -> URL? {
        let controller = FIFinderSyncController.default()
        if let selection = controller.selectedItemURLs(), !selection.isEmpty { return selection.count == 1 ? selection[0] : nil }
        return controller.targetedURL()
    }
    private static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".zip", ".rar", ".7z", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz"].contains { name.hasSuffix($0) }
    }
    private func send(_ action: String) {
        guard let url = selectedURL(), url.isFileURL else { return }
        var components = URLComponents()
        components.scheme = "bezel"
        components.host = "scope"
        components.queryItems = [URLQueryItem(name: "action", value: action), URLQueryItem(name: "path", value: url.path)]
        guard let request = components.url else { return }
        NSWorkspace.shared.open(request)
    }
    @objc private func analyze(_ sender: Any?) { send("analyze") }
    @objc private func inspectArchive(_ sender: Any?) { send("inspect") }
    @objc private func extract(_ sender: Any?) { send("extract") }
    @objc private func compress(_ sender: Any?) { send("compress") }
}
