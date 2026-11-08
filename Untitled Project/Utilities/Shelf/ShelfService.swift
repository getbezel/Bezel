import AppKit
import QuartzCore
import QuickLookUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Sendable {
    enum Content: Sendable {
        case file(URL)
        case text(String)
    }

    let id = UUID()
    let content: Content
    let addedAt = Date()

    var title: String {
        switch content {
        case .file(let url): url.lastPathComponent
        case .text(let text): String(text.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var subtitle: String {
        switch content {
        case .file(let url): url.deletingLastPathComponent().path
        case .text(let text): "\(text.count.formatted()) characters"
        }
    }
}

@MainActor
@Observable
final class ShelfService: NSObject, NSWindowDelegate {
    var isEnabled = UserDefaults.standard.object(forKey: "shelf.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "shelf.enabled")
            isEnabled ? start() : stop()
        }
    }
    var items: [ShelfItem] = []
    var isDropTargeted = false
    var statusMessage: String?
    var isVisible = false
    var count: Int { items.count }
    var previewURL: URL?
    var drawerWidth = UserDefaults.standard.object(forKey: "shelf.width") as? Double ?? 380 {
        didSet { UserDefaults.standard.set(drawerWidth, forKey: "shelf.width"); applySize() }
    }
    var drawerHeight = UserDefaults.standard.object(forKey: "shelf.height") as? Double ?? 400 {
        didSet { UserDefaults.standard.set(drawerHeight, forKey: "shelf.height"); applySize() }
    }
    @ObservationIgnored var captureImage: (() -> Void)?
    @ObservationIgnored var suppressDragDrawer: (() -> Bool)?
    @ObservationIgnored private let imageStore = ShelfImageStore()
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var imageTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var ownedImages: Set<URL> = []
    @ObservationIgnored private var settingFrame = false
    @ObservationIgnored private var resizeStart: NSRect?
    @ObservationIgnored private var panel: ShelfPanel?
    @ObservationIgnored private var previewWindow: NSWindow?
    @ObservationIgnored private var dragMonitor: Any?
    @ObservationIgnored private var localDragMonitor: Any?
    @ObservationIgnored private var lastDragCheck = Date.distantPast
    @ObservationIgnored private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    @ObservationIgnored private var scopedURLs: Set<URL> = []
    @ObservationIgnored private var pendingLoads = 0

    func start() {
        guard isEnabled, dragMonitor == nil else { return }
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseUp { self?.lastDragChangeCount = NSPasteboard(name: .drag).changeCount }
                else { self?.checkDragAtEdge() }
            }
        }
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseUp { self?.lastDragChangeCount = NSPasteboard(name: .drag).changeCount }
                else { self?.checkDragAtEdge() }
            }
            return event
        }
    }

    func stop() {
        closePreview()
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor); self.dragMonitor = nil }
        if let localDragMonitor { NSEvent.removeMonitor(localDragMonitor); self.localDragMonitor = nil }
        hide()
    }

    func show() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        show(on: screen, near: pointer)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        isDropTargeted = false
    }

    func addFiles(_ urls: [URL]) {
        statusMessage = nil
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            guard !items.contains(where: {
                if case .file(let existing) = $0.content { return existing == normalized }
                return false
            }) else { continue }
            guard items.count < 50 else { statusMessage = "Shelf holds up to 50 items. Remove an item to make room."; break }
            if normalized.startAccessingSecurityScopedResource() { scopedURLs.insert(normalized) }
            items.append(ShelfItem(content: .file(normalized)))
            statusMessage = nil
        }
    }

    func addText(_ text: String) {
        guard !text.isEmpty else { return }
        guard items.count < 50 else { statusMessage = "Shelf holds up to 50 items."; return }
        guard text.utf8.count <= 1_024 * 1_024 else { statusMessage = "Text drops are limited to 1 MB each."; return }
        items.append(ShelfItem(content: .text(text)))
        statusMessage = nil
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        if case .file(let url) = item.content {
            if previewURL == url { closePreview() }
            if scopedURLs.remove(url) != nil { url.stopAccessingSecurityScopedResource() }
            if ownedImages.remove(url) != nil { Task { await imageStore.remove(url) } }
        }
    }

    func clear() {
        loadGeneration = UUID()
        for task in imageTasks.values { task.cancel() }
        imageTasks.removeAll()
        pendingLoads = 0
        closePreview()
        let images = ownedImages
        ownedImages.removeAll()
        // Delete only this batch: a later paste may already be creating a new image.
        Task { for url in images { await imageStore.remove(url) } }
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        items.removeAll()
        statusMessage = nil
    }

    func preview(_ item: ShelfItem) {
        guard case .file(let url) = item.content else { return }
        closePreview()
        guard let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 720, height: 520), style: .normal) else {
            statusMessage = "This file could not be previewed."
            return
        }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        window.delegate = self
        view.autoresizingMask = [.width, .height]
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        window.contentView = view
        window.center()
        previewWindow = window
        previewURL = url
        window.makeKeyAndOrderFront(nil)
    }

    private func closePreview(closeWindow: Bool = true) {
        let window = previewWindow
        previewWindow = nil
        previewURL = nil
        if let view = window?.contentView as? QLPreviewView { view.close() }
        window?.contentView = nil
        if closeWindow { window?.close() }
    }

    func shutdown() async {
        clear()
        await imageStore.clear()
    }

    func pasteClipboard() {
        if !acceptPasteboard(.general) { statusMessage = "Copy a file, image, or text, then add it to Shelf." }
    }

    func addImageData(_ data: Data) {
        guard items.count + pendingLoads < 50 else { statusMessage = "Shelf holds up to 50 items."; return }
        let generation = loadGeneration
        let id = UUID()
        pendingLoads += 1
        statusMessage = "Preparing image…"
        imageTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await imageStore.createImage(data)
                guard generation == loadGeneration, !Task.isCancelled else {
                    await imageStore.remove(url)
                    return
                }
                ownedImages.insert(url)
                addFiles([url])
                if !items.contains(where: { if case .file(let file) = $0.content { return file == url }; return false }) {
                    ownedImages.remove(url)
                    await imageStore.remove(url)
                }
            } catch {
                if generation == loadGeneration, !Task.isCancelled { statusMessage = error.localizedDescription }
            }
            guard generation == loadGeneration else { return }
            pendingLoads -= 1
            imageTasks[id] = nil
        }
    }

    func setSize(width: Double, height: Double) {
        drawerWidth = min(max(width, 280), 640)
        drawerHeight = min(max(height, 240), 720)
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "shelf.frame")
        if isVisible { hide(); show() }
    }

    func resizeDrawer(by translation: CGSize, finished: Bool) {
        guard let panel, let screen = panel.screen else { return }
        let start = resizeStart ?? panel.frame
        resizeStart = start
        let size = CGSize(width: min(max(start.width + translation.width, 280), 640),
                          height: min(max(start.height + translation.height, 240), 720))
        let frame = ShelfPlacement.constrained(CGRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height), to: screen.visibleFrame.insetBy(dx: 8, dy: 8))
        settingFrame = true
        panel.setFrame(frame, display: true)
        settingFrame = false
        if finished { resizeStart = nil; rememberFrame() }
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel { rememberFrame() }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel { rememberFrame() }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === previewWindow { closePreview(closeWindow: false) }
    }

    private func rememberFrame() {
        guard !settingFrame, isVisible, let panel else { return }
        settingFrame = true
        drawerWidth = panel.frame.width
        drawerHeight = panel.frame.height
        settingFrame = false
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "shelf.frame")
    }

    private func applySize() {
        guard !settingFrame, let panel, let screen = panel.screen else { return }
        let frame = ShelfPlacement.constrained(CGRect(x: panel.frame.minX, y: panel.frame.maxY - drawerHeight, width: drawerWidth, height: drawerHeight), to: screen.visibleFrame.insetBy(dx: 8, dy: 8))
        settingFrame = true
        panel.setFrame(frame, display: true)
        settingFrame = false
        rememberFrame()
    }

    func reveal(_ item: ShelfItem) {
        guard case .file(let url) = item.content else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success: Bool
        switch item.content {
        case .file(let url): success = pasteboard.writeObjects([url as NSURL])
        case .text(let text): success = pasteboard.setString(text, forType: .string)
        }
        statusMessage = success ? "Copied to the clipboard." : "The clipboard could not be updated."
    }

    func itemProvider(for item: ShelfItem) -> NSItemProvider {
        switch item.content {
        case .file(let url): NSItemProvider(object: url as NSURL)
        case .text(let text): NSItemProvider(object: text as NSString)
        }
    }

    /// Shared by the floating drawer and Aperture's drop zone.
    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        let generation = loadGeneration
        for provider in providers {
            guard items.count + pendingLoads < 50 else { statusMessage = "Shelf holds up to 50 items."; break }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                pendingLoads += 1
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, error in
                    let errorDescription = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        self.pendingLoads -= 1
                        if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                            self.addFiles([url])
                        } else {
                            self.statusMessage = errorDescription ?? "The dropped file could not be read."
                        }
                    }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                accepted = true
                pendingLoads += 1
                provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, error in
                    let message = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        self.pendingLoads -= 1
                        if let data { self.addImageData(data) }
                        else { self.statusMessage = message ?? "The dropped image could not be read." }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                pendingLoads += 1
                provider.loadObject(ofClass: NSString.self) { [weak self] object, error in
                    let value = (object as? NSString).map { String($0) }
                    let errorDescription = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        self.pendingLoads -= 1
                        if let value { self.addText(value) }
                        else { self.statusMessage = errorDescription ?? "The dropped text could not be read." }
                    }
                }
            }
        }
        return accepted
    }

    @discardableResult
    func acceptPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            addFiles(files)
            return true
        }
        if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
            addImageData(data)
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            addText(text)
            return true
        }
        return false
    }

    private func checkDragAtEdge() {
        guard suppressDragDrawer?() != true else { return }
        guard isEnabled, !isVisible, Date().timeIntervalSince(lastDragCheck) >= 0.1 else { return }
        lastDragCheck = .now
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != lastDragChangeCount, pasteboard.availableType(from: [.fileURL, .png, .tiff, .string]) != nil else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return }
        let frame = screen.frame
        let edgeDistance = min(pointer.x - frame.minX, frame.maxX - pointer.x, pointer.y - frame.minY, frame.maxY - pointer.y)
        if edgeDistance <= 22 { show(on: screen, near: pointer) }
    }

    private func show(on screen: NSScreen, near pointer: NSPoint) {
        if panel == nil {
            let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = false
            panel.minSize = NSSize(width: 280, height: 240)
            panel.maxSize = NSSize(width: 640, height: 720)
            panel.delegate = self
            let hosting = NSHostingView(rootView: ShelfDrawer(service: self))
            hosting.sizingOptions = []
            panel.contentView = hosting
            self.panel = panel
        }
        guard let panel else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(drawerWidth, visible.width), height: min(drawerHeight, visible.height))
        let leftEdge = pointer.x < screen.frame.midX
        var destination = NSRect(x: leftEdge ? visible.minX : visible.maxX - size.width, y: min(max(pointer.y - size.height / 2, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
        if let saved = UserDefaults.standard.string(forKey: "shelf.frame") {
            let previous = NSRectFromString(saved)
            if screen.frame.contains(NSPoint(x: previous.midX, y: previous.midY)) {
                destination = ShelfPlacement.constrained(NSRect(origin: previous.origin, size: size), to: visible)
            }
        }
        settingFrame = true
        if !isVisible {
            panel.setFrame(destination.offsetBy(dx: leftEdge ? -80 : 80, dy: 0), display: false)
        }
        panel.orderFrontRegardless()
        isVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(destination, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.settingFrame = false; self?.rememberFrame() }
        }
    }
}

@MainActor
private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
