import AppKit
import ApplicationServices
import Observation
import SwiftUI

@MainActor
@Observable
final class StackService {
    var isEnabled = UserDefaults.standard.object(forKey: "stack.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "stack.enabled")
            isEnabled ? start() : stop()
        }
    }
    var history: [ClipboardEntry] = []
    var queue: [ClipboardEntry] = []
    var searchText = ""
    var statusMessage: String?
    var memoryBytes = 0
    var isPasting = false
    @ObservationIgnored var onCapture: ((ClipboardEntry) -> Void)?

    @ObservationIgnored private let store = ClipboardStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var latestRevision = 0
    @ObservationIgnored private var pendingQueueDeadline: Date?
    @ObservationIgnored private var previousApplication: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var hud: StackPanel?
    @ObservationIgnored private var outsideMonitor: Any?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var commandGeneration = UUID()

    var filteredHistory: [ClipboardEntry] {
        guard !searchText.isEmpty else { return history }
        return history.filter {
            $0.preview.localizedCaseInsensitiveContains(searchText)
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.sourceName.localizedCaseInsensitiveContains(searchText)
                || $0.kind.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    func start() {
        guard isEnabled, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        rememberExternalApplication()
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rememberExternalApplication() }
            }
        }
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        commandGeneration = UUID()
        commandTask?.cancel()
        commandTask = nil
        isPasting = false
        timer?.invalidate()
        timer = nil
        pendingQueueDeadline = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        hideHUD()
    }

    func captureSelectionToQueue() {
        guard isEnabled else { statusMessage = "Turn on Stack to collect a sequence."; return }
        guard queue.count < 50 else { statusMessage = "The sequence is full. Paste or clear an item first."; return }
        guard AXIsProcessTrusted() else {
            statusMessage = "Allow Bezel in Privacy & Security → Accessibility to copy and paste with shortcuts."
            return
        }
        guard pendingQueueDeadline == nil, commandTask == nil, !isPasting else { return }
        rememberExternalApplication()
        hideHUD()
        let target = destinationApplication()
        guard let target, !target.isTerminated else { statusMessage = "Select text or a file in another app first."; return }
        pendingQueueDeadline = Date().addingTimeInterval(2)
        let commandID = UUID()
        commandGeneration = commandID
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.commandGeneration == commandID { self.commandTask = nil } }
            if !target.isActive {
                target.activate(options: [])
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, self.commandGeneration == commandID else { return }
            guard target.isActive else {
                self.pendingQueueDeadline = nil
                self.statusMessage = "The source app could not become active. Try the shortcut in that app."
                return
            }
            if !self.postCommandKey(8) {
                self.pendingQueueDeadline = nil
                self.statusMessage = "macOS could not deliver the Copy command."
                return
            }
            // A sequential copy checks promptly, without raising the background poll rate.
            while let deadline = self.pendingQueueDeadline, Date() <= deadline {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, self.commandGeneration == commandID else { return }
                self.pollClipboard()
            }
            self.pollClipboard()
        }
    }

    func pasteNext() {
        guard !isPasting, commandTask == nil, pendingQueueDeadline == nil else { return }
        guard !queue.isEmpty else { statusMessage = "The sequence is empty. Add items with ⇧⌘C."; return }
        guard AXIsProcessTrusted() else {
            statusMessage = "Allow Bezel in Privacy & Security → Accessibility to paste into another app."
            return
        }
        let target = destinationApplication()
        guard let target, !target.isTerminated else { statusMessage = "Choose a destination app before pasting."; return }
        isPasting = true
        hideHUD()
        let commandID = UUID()
        commandGeneration = commandID
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.commandGeneration == commandID {
                    self.isPasting = false
                    self.commandTask = nil
                }
            }
            guard let payload = await self.store.firstQueued(), !Task.isCancelled else { return }
            if !target.isActive {
                target.activate(options: [])
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled, self.commandGeneration == commandID else { return }
            guard target.isActive else {
                self.statusMessage = "The destination app could not become active. Your sequence is unchanged."
                return
            }
            guard self.writeToPasteboard(payload) else { return }
            if self.postCommandKey(9) {
                self.apply(await self.store.consumeFirst(expectedID: payload.entry.id))
                self.statusMessage = "Pasted “\(payload.entry.title.prefix(42))”."
            } else {
                self.statusMessage = "macOS could not deliver Paste. The item is still in your sequence."
            }
        }
    }

    func copy(_ entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self, let payload = await self.store.payload(for: entry.id) else { return }
            if self.writeToPasteboard(payload) { self.statusMessage = "Copied to the clipboard." }
        }
    }

    func enqueue(_ entry: ClipboardEntry) {
        guard queue.count < 50 else { statusMessage = "The sequence holds up to 50 items."; return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apply(await self.store.enqueue(entry.id))
        }
    }

    func remove(_ entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apply(await self.store.remove(entry.id))
        }
    }

    func clearQueue() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apply(await self.store.clearQueue())
        }
    }

    func clearHistory() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apply(await self.store.clear())
            self.statusMessage = nil
        }
    }

    /// Explicit imports (for example Lens) work even when background monitoring is paused.
    func insertText(_ text: String, source: String = "Lens", enqueue: Bool = false) {
        guard !text.isEmpty else { return }
        let data = Data(text.utf8)
        guard data.count <= ClipboardStore.maximumItemBytes else { statusMessage = "Text exceeds Stack’s 24 MB item limit."; return }
        let entry = ClipboardEntry(
            id: UUID(), kind: .text, title: String(text.prefix(120)), preview: String(text.prefix(32_768)),
            detail: "\(text.count.formatted()) characters", sourceName: source,
            sourceBundleIdentifier: Bundle.main.bundleIdentifier, capturedAt: .now,
            thumbnailData: nil, byteCount: data.count
        )
        let payload = ClipboardPayload(entry: entry, items: [[ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: data)]])
        guard writeToPasteboard(payload) else { return }
        record(payload, enqueue: enqueue)
    }

    func showHUD() {
        if let hud, hud.isVisible { hideHUD(); return }
        rememberExternalApplication()
        if hud == nil {
            let panel = StackPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled], backing: .buffered, defer: false)
            panel.title = "Stack"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: StackHUD(service: self))
            hud = panel
        }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main, let hud else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(660, visible.width), height: min(470, visible.height))
        let origin = NSPoint(x: min(max(point.x - 40, visible.minX), visible.maxX - size.width), y: min(max(point.y - size.height - 12, visible.minY), visible.maxY - size.height))
        hud.setFrame(NSRect(origin: origin, size: size), display: true)
        hud.orderFrontRegardless()
        hud.makeKey()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideHUD() }
        }
    }

    func hideHUD() {
        hud?.orderOut(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
    }

    private func rememberExternalApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = app
        }
    }

    private func destinationApplication() -> NSRunningApplication? {
        rememberExternalApplication()
        return previousApplication
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            if let deadline = pendingQueueDeadline, Date() > deadline {
                pendingQueueDeadline = nil
                statusMessage = "Nothing was copied. Select copyable content and try ⇧⌘C again."
            }
            return
        }
        lastChangeCount = pasteboard.changeCount
        let enqueue = pendingQueueDeadline.map { $0 >= Date() } ?? false
        pendingQueueDeadline = nil
        guard let payload = readPayload(pasteboard) else { return }
        record(payload, enqueue: enqueue)
    }

    private func record(_ payload: ClipboardPayload, enqueue: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.apply(await self.store.record(payload, enqueue: enqueue))
            self.onCapture?(payload.entry)
        }
    }

    private func apply(_ snapshot: ClipboardSnapshot) {
        guard snapshot.revision >= latestRevision else { return }
        latestRevision = snapshot.revision
        history = snapshot.history
        queue = snapshot.queue
        memoryBytes = snapshot.byteCount
    }

    private func readPayload(_ pasteboard: NSPasteboard) -> ClipboardPayload? {
        let blockedTypes: Set<String> = [
            "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
            "com.agilebits.onepassword", "com.typeit4me.clipping", "de.petermaurer.TransientPasteboardType"
        ]
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        let types = Set((pasteboard.types ?? []).map(\.rawValue) + pasteboardItems.flatMap { $0.types.map(\.rawValue) })
        guard types.isDisjoint(with: blockedTypes) else { return nil }
        var byteCount = 0
        var items: [[ClipboardRepresentation]] = []
        for item in pasteboardItems {
            var representations: [ClipboardRepresentation] = []
            for type in item.types {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                byteCount += data.count
                guard byteCount <= ClipboardStore.maximumItemBytes else {
                    statusMessage = "Skipped a clipboard item larger than 24 MB."
                    return nil
                }
                representations.append(ClipboardRepresentation(type: type.rawValue, data: data))
            }
            if !representations.isEmpty { items.append(representations) }
        }
        guard !items.isEmpty else { return nil }
        let app = NSWorkspace.shared.frontmostApplication
        let source = app?.localizedName ?? "Unknown app"
        var kind = ClipboardKind.binary
        var title = "Clipboard data"
        var preview = ""
        var detail = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .memory)
        var thumbnailData: Data?
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            kind = .files
            title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            preview = urls.map(\.lastPathComponent).joined(separator: "\n")
            detail = urls.count == 1 ? urls[0].deletingLastPathComponent().path : "\(urls.count) file references"
        } else if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
                  let image = ClipboardImage.preview(data: imageData) {
            kind = .image
            title = "Copied image"
            detail = "\(image.width) × \(image.height) pixels"
            preview = detail
            thumbnailData = image.thumbnail
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            kind = types.contains(NSPasteboard.PasteboardType.rtf.rawValue) ? .richText : .text
            title = String(text.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
            preview = String(text.prefix(32_768))
            detail = "\(text.count.formatted()) characters"
        } else if let rtf = pasteboard.data(forType: .rtf), let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            kind = .richText
            title = String(attributed.string.prefix(120))
            preview = String(attributed.string.prefix(32_768))
            detail = "\(attributed.length.formatted()) characters"
        } else if let representation = items.first?.first {
            title = representation.type
            preview = representation.data.prefix(256).enumerated().map { offset, byte in
                String(format: "%02X", byte) + ((offset + 1) % 16 == 0 ? "\n" : " ")
            }.joined()
        }
        let entry = ClipboardEntry(id: UUID(), kind: kind, title: title.isEmpty ? kind.rawValue : title, preview: preview, detail: detail, sourceName: source, sourceBundleIdentifier: app?.bundleIdentifier, capturedAt: .now, thumbnailData: thumbnailData, byteCount: byteCount)
        return ClipboardPayload(entry: entry, items: items)
    }

    @discardableResult
    private func writeToPasteboard(_ payload: ClipboardPayload) -> Bool {
        let items = payload.items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations { item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) }
            return item
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.writeObjects(items)
        lastChangeCount = pasteboard.changeCount
        if !success { statusMessage = "The clipboard could not be updated. Please try again." }
        return success
    }

    @discardableResult
    private func postCommandKey(_ keyCode: CGKeyCode) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
private final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
