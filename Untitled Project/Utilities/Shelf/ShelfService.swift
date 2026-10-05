import AppKit
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
final class ShelfService {
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
    @ObservationIgnored private var panel: ShelfPanel?
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
        for url in urls where url.isFileURL {
            guard items.count < 50 else { statusMessage = "Shelf holds up to 50 items. Remove an item to make room."; break }
            let normalized = url.standardizedFileURL
            guard !items.contains(where: {
                if case .file(let existing) = $0.content { return existing == normalized }
                return false
            }) else { continue }
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
        if case .file(let url) = item.content, scopedURLs.remove(url) != nil { url.stopAccessingSecurityScopedResource() }
    }

    func clear() {
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        items.removeAll()
        statusMessage = nil
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
        for provider in providers {
            guard items.count + pendingLoads < 50 else { statusMessage = "Shelf holds up to 50 items."; break }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                pendingLoads += 1
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, error in
                    let errorDescription = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.pendingLoads -= 1
                        if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                            self.addFiles([url])
                        } else {
                            self.statusMessage = errorDescription ?? "The dropped file could not be read."
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                pendingLoads += 1
                provider.loadObject(ofClass: NSString.self) { [weak self] object, error in
                    let value = (object as? NSString).map { String($0) }
                    let errorDescription = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self else { return }
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
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            addText(text)
            return true
        }
        return false
    }

    private func checkDragAtEdge() {
        guard isEnabled, !isVisible, Date().timeIntervalSince(lastDragCheck) >= 0.1 else { return }
        lastDragCheck = .now
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != lastDragChangeCount, pasteboard.availableType(from: [.fileURL, .string]) != nil else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return }
        let frame = screen.frame
        let edgeDistance = min(pointer.x - frame.minX, frame.maxX - pointer.x, pointer.y - frame.minY, frame.maxY - pointer.y)
        if edgeDistance <= 22 { show(on: screen, near: pointer) }
    }

    private func show(on screen: NSScreen, near pointer: NSPoint) {
        if panel == nil {
            let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: ShelfDrawer(service: self))
            self.panel = panel
        }
        guard let panel else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(340, visible.width), height: min(360, visible.height))
        let leftEdge = pointer.x < screen.frame.midX
        let destination = NSRect(x: leftEdge ? visible.minX : visible.maxX - size.width, y: min(max(pointer.y - size.height / 2, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
        if !isVisible {
            panel.setFrame(destination.offsetBy(dx: leftEdge ? -80 : 80, dy: 0), display: false)
        }
        panel.orderFrontRegardless()
        isVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().setFrame(destination, display: true)
        }
    }
}

@MainActor
private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
