import AppKit
import ApplicationServices
import Observation
import SwiftUI

enum ClipboardCollection: String, CaseIterable, Identifiable {
    case history = "History", quickClips = "Quick Clips"
    var id: Self { self }
}

enum StackHUDMode: Equatable { case history, quickClips, paste }

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
    var hudCollection: ClipboardCollection = .history
    var hudSelectionID: UUID?
    private(set) var hudIsPasteMode = false
    private(set) var isHUDVisible = false
    @ObservationIgnored var onCapture: ((ClipboardEntry) -> Void)?

    @ObservationIgnored private let store = ClipboardStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var latestRevision = 0
    @ObservationIgnored private var pendingQueueDeadline: Date?
    @ObservationIgnored private var previousApplication: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var hud: StackPanel?
    @ObservationIgnored private var pickerTarget: ClipboardTarget?
    @ObservationIgnored private var outsideMonitor: Any?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var commandGeneration = UUID()
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var dataGeneration = UUID()

    var filteredHistory: [ClipboardEntry] { filtered(history) }
    var hudEntries: [ClipboardEntry] { filtered(hudCollection == .history ? history : queue) }

    private func filtered(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
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
        guard isEnabled else { statusMessage = "Turn on Stack to collect Quick Clips."; showHUD(mode: .quickClips, toggle: false); return }
        guard queue.count < 50 else { statusMessage = "Quick Clips is full. Paste or remove an item first."; showHUD(mode: .quickClips, toggle: false); return }
        guard AccessibilityAccess.canSendKeyboardEvents else {
            statusMessage = "macOS is blocking keyboard commands for this copy of Bezel. Check Keyboard Commands in Bezel Settings. You can still add your current clipboard."
            showHUD(mode: .quickClips, toggle: false)
            return
        }
        guard pendingQueueDeadline == nil, commandTask == nil, !isPasting else { return }
        rememberExternalApplication()
        hideHUD()
        let application = destinationApplication()
        guard let application, !application.isTerminated else { statusMessage = "Select text or a file in another app first."; showHUD(mode: .quickClips, toggle: false); return }
        let target = ClipboardTarget(application: application)
        let commandID = UUID()
        commandGeneration = commandID
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.commandGeneration == commandID {
                    self.commandTask = nil
                    self.showHUD(mode: .quickClips, toggle: false)
                }
            }
            do { try await self.deliverCommand(8, to: target, prepare: {
                self.lastChangeCount = NSPasteboard.general.changeCount
                return true
            }) } catch {
                if !Task.isCancelled { self.statusMessage = error.localizedDescription }
                self.pendingQueueDeadline = nil
                return
            }
            guard !Task.isCancelled, self.commandGeneration == commandID else { return }
            self.pendingQueueDeadline = Date().addingTimeInterval(2)
            // A sequential copy checks promptly, without raising the background poll rate.
            while let deadline = self.pendingQueueDeadline, Date() <= deadline {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, self.commandGeneration == commandID else { return }
                self.pollClipboard()
            }
            self.pollClipboard()
            await self.mutationTask?.value
        }
    }

    func showPastePicker() {
        showHUD(mode: .paste, toggle: false)
    }

    func pasteNext() {
        guard let entry = queue.first else { statusMessage = "Quick Clips is empty. Add a selection with ⇧⌘C."; return }
        paste(entry, fromQuickClips: true)
    }

    func paste(_ entry: ClipboardEntry, fromQuickClips: Bool) {
        guard !isPasting, commandTask == nil, pendingQueueDeadline == nil else { return }
        guard AccessibilityAccess.canSendKeyboardEvents else {
            statusMessage = "macOS is blocking keyboard commands for this copy of Bezel. Check Keyboard Commands in Bezel Settings, or use Copy and paste manually."
            return
        }
        let target = pickerTarget ?? destinationApplication().map { ClipboardTarget(application: $0) }
        guard let target, !target.application.isTerminated else { statusMessage = "Choose a destination text box before opening the picker."; return }
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
            let payload: ClipboardPayload?
            if fromQuickClips { payload = await self.store.queuedPayload(for: entry.id) }
            else { payload = await self.store.payload(for: entry.id) }
            guard !Task.isCancelled, self.commandGeneration == commandID else { return }
            guard let payload else {
                self.statusMessage = "That clip is no longer saved. Choose another clip."
                self.showHUD(mode: .paste, toggle: false)
                return
            }
            do {
                try await self.deliverCommand(9, to: target, prepare: {
                    self.writeToPasteboard(payload)
                })
                guard !Task.isCancelled, self.commandGeneration == commandID else { return }
                if fromQuickClips { self.apply(await self.store.consumeQueued(expectedID: payload.entry.id)) }
                self.statusMessage = "Paste sent to \(target.application.localizedName ?? "your app")."
            } catch {
                guard !Task.isCancelled, self.commandGeneration == commandID else { return }
                self.statusMessage = error.localizedDescription
                self.showHUD(mode: .paste, toggle: false)
            }
        }
    }

    func addCurrentClipboardToQueue() {
        guard queue.count < 50 else { statusMessage = "Quick Clips holds up to 50 items."; return }
        let pasteboard = NSPasteboard.general
        guard let payload = readPayload(pasteboard) else { statusMessage = "There is no supported clipboard item to add."; return }
        lastChangeCount = pasteboard.changeCount
        record(payload, enqueue: true)
    }

    func openAccessibilitySettings() {
        AccessibilityAccess.request()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func copy(_ entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self, let payload = await self.store.payload(for: entry.id) else { return }
            if self.writeToPasteboard(payload) { self.statusMessage = "Copied to the clipboard." }
        }
    }

    func enqueue(_ entry: ClipboardEntry) {
        guard queue.count < 50 else { statusMessage = "Quick Clips holds up to 50 items."; return }
        mutate { await $0.enqueue(entry.id) }
    }

    func remove(_ entry: ClipboardEntry) { remove(Set([entry.id])) }

    func remove(_ ids: Set<UUID>) {
        cancelClipboardCommand()
        mutate { await $0.remove(ids) }
    }

    func clearQueue() {
        cancelClipboardCommand()
        mutate { await $0.clearQueue() }
    }

    func clearHistory() {
        cancelClipboardCommand()
        dataGeneration = UUID()
        mutate({ await $0.clear() }) { [weak self] _ in self?.statusMessage = nil }
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

    func showHUD(mode: StackHUDMode = .history, toggle: Bool = true) {
        if toggle, let hud, hud.isVisible { hideHUD(); return }
        if mode != .history { searchText = "" }
        hudIsPasteMode = mode == .paste
        hudCollection = mode == .history || (mode == .paste && queue.isEmpty) ? .history : .quickClips
        hudSelectionID = mode == .quickClips ? queue.last?.id : hudEntries.first?.id
        if let hud, hud.isVisible { hud.makeKey(); return }
        rememberExternalApplication()
        pickerTarget = destinationApplication().map { ClipboardTarget(application: $0) }
        if hud == nil {
            let panel = StackPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled], backing: .buffered, defer: false)
            panel.title = "Stack"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            let hostingView = NSHostingView(rootView: StackHUD(service: self))
            hostingView.sizingOptions = []
            panel.contentView = hostingView
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
        isHUDVisible = true
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideHUD() }
        }
    }

    func hideHUD() {
        hud?.orderOut(nil)
        isHUDVisible = false
        pickerTarget = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
    }

    private func cancelClipboardCommand() {
        commandGeneration = UUID()
        commandTask?.cancel()
        commandTask = nil
        pendingQueueDeadline = nil
        isPasting = false
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
        let generation = dataGeneration
        mutate({ await $0.record(payload, enqueue: enqueue) }) { [weak self] snapshot in
            guard let self, self.dataGeneration == generation else { return }
            let retained = snapshot.history.contains { $0.id == payload.entry.id } || snapshot.queue.contains { $0.id == payload.entry.id }
            guard retained else { self.statusMessage = "Stack's memory is full. Remove a few Quick Clips to make room."; return }
            if enqueue {
                self.hudSelectionID = payload.entry.id
                self.statusMessage = snapshot.queue.contains { $0.id == payload.entry.id } ? "Added to Quick Clips." : "Quick Clips is full; saved to history instead."
            }
            self.onCapture?(payload.entry)
        }
    }

    /// Preserve UI request order across actor hops, so Clear cannot be overtaken by an earlier capture.
    private func mutate(_ operation: @escaping @Sendable (ClipboardStore) async -> ClipboardSnapshot,
                        onApplied: (@MainActor (ClipboardSnapshot) -> Void)? = nil) {
        let previous = mutationTask
        mutationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let snapshot = await operation(self.store)
            self.apply(snapshot)
            onApplied?(snapshot)
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

    private func deliverCommand(_ key: CGKeyCode, to target: ClipboardTarget, prepare: @escaping () -> Bool) async throws {
        try await ClipboardCommandExecutor.execute(key: key, environment: .init(
            isTrusted: { AccessibilityAccess.canSendKeyboardEvents },
            heldModifiers: { CGEventSource.flagsState(.combinedSessionState) },
            restoreFocus: { target.restoreFocus() },
            isTargetActive: { target.isActive },
            deliver: { events in
                guard prepare() else { return false }
                for event in events { event.postToPid(target.application.processIdentifier) }
                return true
            }
        ))
    }

}

@MainActor
private final class StackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
