import AppKit
import SwiftUI
import Observation
import ApplicationServices
import IOKit.hidsystem
import UniformTypeIdentifiers

/// Transient states take precedence over long-lived focus and playback states.
enum IslandState: Equatable {
    case idle, clipboard(String), focus, nowPlaying, shelf
}

@MainActor @Observable
final class ApertureService {
    var isEnabled = UserDefaults.standard.bool(forKey: "aperture.enabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "aperture.enabled")
            isEnabled ? start() : stop()
        }
    }
    var showOnExternalDisplay = UserDefaults.standard.bool(forKey: "aperture.external") {
        didSet {
            UserDefaults.standard.set(showOnExternalDisplay, forKey: "aperture.external")
            reposition()
        }
    }
    private(set) var state: IslandState = .idle
    private(set) var hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    private(set) var clipboardThumbnail: Data?
    private(set) var remainingSeconds = 0
    private(set) var mediaLevel: Double = 0
    private(set) var mediaBands = Array(repeating: 0.0, count: 7)
    private(set) var mediaTitle = "Audio playback"
    private(set) var mediaArtwork: NSImage?
    private(set) var isMediaCommandPending = false
    private(set) var mediaControlError: String?
    private(set) var isPlaying = false
    private(set) var notchWidth: CGFloat = 180
    private(set) var notchHeight: CGFloat = 32
    var statusMessage: String?
    var isHovered = false { didSet { resize() } }
    @ObservationIgnored var acceptDrop: (([NSItemProvider]) -> Bool)?
    @ObservationIgnored var openShelf: (() -> Void)?
    @ObservationIgnored var controlPlayback: ((MediaCommand) -> Bool)?
    @ObservationIgnored private var artworkData: Data?
    @ObservationIgnored private var panel: AperturePanel?
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var displayObserver: NSObjectProtocol?
    @ObservationIgnored private var dragMonitor: Any?
    @ObservationIgnored private var localDragMonitor: Any?
    @ObservationIgnored private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    @ObservationIgnored private var notchCenterX: CGFloat = 0
    @ObservationIgnored private var dragExitTask: Task<Void, Never>?

    var width: CGFloat {
        switch state {
        case .idle: notchWidth
        case .clipboard: max(notchWidth + 160, 350)
        case .focus: max(notchWidth + 170, 350)
        case .nowPlaying: max(notchWidth + 160, 350)
        case .shelf: max(notchWidth + 170, 360)
        }
    }
    var height: CGFloat {
        switch state {
        case .idle: notchHeight
        case .clipboard: notchHeight + 48
        case .focus: notchHeight + (isHovered ? 32 : 4)
        case .nowPlaying: notchHeight + (isHovered ? 65 : 4)
        case .shelf: notchHeight + 115
        }
    }
    var timeLabel: String { String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60) }

    func start() {
        guard isEnabled, panel == nil else { return }
        let panel = AperturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IslandView(service: self))
        self.panel = panel
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let isRelease = event.type == .leftMouseUp
            Task { @MainActor in
                if isRelease { self?.scheduleDragEnd() }
                else { self?.checkDrag() }
            }
        }
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseUp { self?.scheduleDragEnd() }
                else { self?.checkDrag() }
            }
            return event
        }
        reposition()
    }

    func stop() {
        dismissTask?.cancel()
        dragExitTask?.cancel()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let localDragMonitor { NSEvent.removeMonitor(localDragMonitor) }
        localDragMonitor = nil
        displayObserver = nil
        dragMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        state = .idle
    }

    func showClipboard(_ text: String, thumbnail: Data? = nil) {
        guard isEnabled else { return }
        dismissTask?.cancel()
        clipboardThumbnail = thumbnail
        transition(to: .clipboard(String(text.prefix(60))))
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.restorePersistentState()
        }
    }

    func update(focusRemaining: Int, playing: Bool, level: Double, title: String, bands: [Double],
                artwork: Data? = nil, commandPending: Bool = false, controlError: String? = nil) {
        let seconds = max(0, focusRemaining)
        let amplitude = max(0, min(1, level))
        if remainingSeconds != seconds { remainingSeconds = seconds }
        if isPlaying != playing { isPlaying = playing }
        if mediaLevel != amplitude { mediaLevel = amplitude }
        let spectrum = Array(bands.prefix(7)).map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        if mediaBands != spectrum { mediaBands = spectrum }
        if mediaTitle != title { mediaTitle = title }
        if artworkData != artwork { artworkData = artwork; mediaArtwork = artwork.flatMap(NSImage.init(data:)) }
        if isMediaCommandPending != commandPending { isMediaCommandPending = commandPending }
        if mediaControlError != controlError { mediaControlError = controlError }
        if case .clipboard = state { return }
        if state == .shelf { return }
        restorePersistentState()
    }

    func preview() {
        if !isEnabled { isEnabled = true }
        showClipboard("A little more possibility. A lot more Mac.")
    }

    private func scheduleDragEnd() {
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
        guard state == .shelf else { return }
        dragExitTask?.cancel()
        // Let the native drop destination finish before contracting its hit region.
        dragExitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.finishDrop()
        }
    }

    func finishDrop() {
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
        dragExitTask?.cancel()
        if state == .shelf { restorePersistentState() }
    }

    enum MediaCommand {
        case previous, playPause, next
        var key: Int {
            switch self {
            case .previous: Int(NX_KEYTYPE_PREVIOUS)
            case .playPause: Int(NX_KEYTYPE_PLAY)
            case .next: Int(NX_KEYTYPE_NEXT)
            }
        }
    }
    func sendMediaKey(_ command: MediaCommand) {
        statusMessage = nil
        if controlPlayback?(command) == true { return }
        guard AXIsProcessTrusted() else {
            statusMessage = "Allow Accessibility access to use system media controls."
            return
        }
        let key = command.key
        for flags in [0xA, 0xB] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 8,
                                          data1: (key << 16) | (flags << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func checkDrag() {
        guard let screen else { return }
        let point = NSEvent.mouseLocation
        let hotZone = NSRect(x: notchCenterX - 220, y: screen.frame.maxY - 100, width: 440, height: 100)
        guard hotZone.contains(point), NSPasteboard(name: .drag).changeCount != lastDragChangeCount, NSPasteboard(name: .drag).types?.isEmpty == false else { return }
        dismissTask?.cancel()
        transition(to: .shelf)
        dragExitTask?.cancel()
        dragExitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if NSEvent.pressedMouseButtons == 0 {
                    self?.scheduleDragEnd()
                    return
                }
            }
        }
    }

    private func restorePersistentState() {
        transition(to: remainingSeconds > 0 ? .focus : (isPlaying ? .nowPlaying : .idle))
    }
    private func transition(to next: IslandState) {
        guard state != next else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.72, blendDuration: 0)) { state = next }
        resize()
    }
    private func reposition() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? (showOnExternalDisplay ? NSScreen.main : nil)
        hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        guard let screen else { panel?.orderOut(nil); return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchCenterX = (right.minX + left.maxX) / 2
            notchWidth = max(1, right.minX - left.maxX)
            notchHeight = max(24, screen.safeAreaInsets.top)
        } else {
            notchCenterX = screen.frame.midX
            notchWidth = 180
            notchHeight = 28
        }
        resize()
        panel?.orderFrontRegardless()
    }
    private func resize() {
        guard let screen, let panel else { return }
        let frame = NSRect(x: notchCenterX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

final class AperturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
