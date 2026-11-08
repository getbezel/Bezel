import AppKit
import SwiftUI
import Observation
import ApplicationServices
import IOKit.hidsystem
import UniformTypeIdentifiers

/// Transient states take precedence over long-lived focus and playback states.
enum IslandState: Equatable {
    case idle, clipboard(String), focus, nowPlaying, shelf, systemFocus(Bool), track(String)
}

@MainActor @Observable
final class ApertureService {
    @ObservationIgnored private let defaults: UserDefaults
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "aperture.enabled")
            isEnabled ? start() : stop()
        }
    }
    var showOnExternalDisplay: Bool {
        didSet {
            defaults.set(showOnExternalDisplay, forKey: "aperture.external")
            reposition()
        }
    }
    var showsClipboard: Bool {
        didSet {
            defaults.set(showsClipboard, forKey: "aperture.moments.clipboard")
            refreshMomentPreferences()
        }
    }
    var showsMusic: Bool {
        didSet {
            defaults.set(showsMusic, forKey: "aperture.moments.music")
            refreshMomentPreferences()
        }
    }
    var showsFocusTimer: Bool {
        didSet {
            defaults.set(showsFocusTimer, forKey: "aperture.moments.focusTimer")
            refreshMomentPreferences()
        }
    }
    var showsShelf: Bool {
        didSet {
            defaults.set(showsShelf, forKey: "aperture.moments.shelf")
            refreshMomentPreferences()
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
    private(set) var mediaArtist = ""
    private(set) var mediaAlbum = ""
    private(set) var mediaPlayerName = "Audio"
    private(set) var mediaSourceID: String?
    private(set) var mediaVolume: Double?
    private(set) var mediaTimeline: PlaybackTimeline?
    private(set) var mediaTrackID: String?
    private(set) var hasMedia = false
    private(set) var isPlayerExpanded = false
    private(set) var isMediaCommandPending = false
    private(set) var mediaControlError: String?
    private(set) var isPlaying = false
    private(set) var notchWidth: CGFloat = 180
    private(set) var notchHeight: CGFloat = NSStatusBar.system.thickness
    var statusMessage: String?
    var notificationDuration: Double {
        didSet {
            let bounded = min(6, max(1.6, notificationDuration.isFinite ? notificationDuration : 2.8))
            if notificationDuration != bounded { notificationDuration = bounded }
            defaults.set(bounded, forKey: "aperture.momentDuration")
        }
    }
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            if isHovered { dismissTask?.cancel() }
            else if isTransient { scheduleDismissal() }
        }
    }
    var canvasWidth: CGFloat { max(notchWidth + 300, 520) }
    var canvasHeight: CGFloat { notchHeight + 290 }
    private var isTransient: Bool {
        switch state { case .clipboard, .systemFocus, .track: true; default: false }
    }
    @ObservationIgnored var acceptDrop: (([NSItemProvider]) -> Bool)?
    @ObservationIgnored var openShelf: (() -> Void)?
    @ObservationIgnored var controlVolume: ((Double) -> Bool)?
    @ObservationIgnored var controlSeek: ((Double, String) -> Bool)?
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
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var localMouseMonitor: Any?
    @ObservationIgnored private var visibleBounds = CGRect.zero

    var width: CGFloat {
        switch state {
        case .idle: notchWidth
        case .clipboard, .systemFocus, .track: max(notchWidth + 180, 370)
        case .focus: max(notchWidth + 170, 350)
        case .nowPlaying: isPlayerExpanded ? max(notchWidth + 180, 420) : max(notchWidth + 160, 350)
        case .shelf: max(notchWidth + 170, 360)
        }
    }
    var height: CGFloat {
        switch state {
        case .idle: notchHeight
        case .clipboard, .systemFocus, .track: notchHeight + 56
        case .focus: notchHeight + (isHovered ? 32 : 0)
        case .nowPlaying: notchHeight + (isPlayerExpanded ? 264 : (isHovered ? 42 : 0))
        case .shelf: notchHeight + 115
        }
    }
    var timeLabel: String { String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "aperture.enabled")
        showOnExternalDisplay = defaults.bool(forKey: "aperture.external")
        showsClipboard = defaults.object(forKey: "aperture.moments.clipboard") as? Bool ?? true
        showsMusic = defaults.object(forKey: "aperture.moments.music") as? Bool ?? true
        showsFocusTimer = defaults.object(forKey: "aperture.moments.focusTimer") as? Bool ?? true
        showsShelf = defaults.object(forKey: "aperture.moments.shelf") as? Bool ?? true
        let duration = defaults.object(forKey: "aperture.momentDuration") as? Double ?? 2.8
        notificationDuration = duration.isFinite ? min(6, max(1.6, duration)) : 2.8
    }

    func expandPlayer() {
        guard isEnabled, showsMusic, hasMedia else { return }
        dismissTask?.cancel()
        statusMessage = nil
        animatePlayer { isPlayerExpanded = true; state = .nowPlaying }
    }

    func collapsePlayer() {
        guard isPlayerExpanded else { return }
        animatePlayer { isPlayerExpanded = false }
        restorePersistentState()
    }

    func setMediaVolume(_ value: Double, sourceID: String?) {
        guard value.isFinite, sourceID != nil, sourceID == mediaSourceID, mediaVolume != nil else { return }
        statusMessage = nil
        let bounded = min(1, max(0, value))
        if controlVolume?(bounded) == true { mediaVolume = bounded }
        else { statusMessage = "Volume is unavailable for this output." }
    }

    func seekMedia(to seconds: Double, sourceID: String?, trackID: String?) {
        guard seconds.isFinite, let sourceID, sourceID == mediaSourceID,
              let trackID, trackID == mediaTrackID, let timeline = mediaTimeline,
              !isMediaCommandPending else { return }
        let bounded = min(timeline.duration, max(0, seconds))
        statusMessage = nil
        if controlSeek?(bounded, trackID) == true {
            mediaTimeline = PlaybackTimeline(position: bounded, duration: timeline.duration)
        } else { statusMessage = "Seeking is unavailable for this source right now." }
    }

    private func animatePlayer(_ changes: () -> Void) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil :
            .spring(response: 0.35, dampingFraction: 0.82)) { changes() }
    }

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
        let hostingView = NSHostingView(rootView: IslandView(service: self))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.ignoresMouseEvents = true
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
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown || event.type == .rightMouseDown { self?.dismissPlayerIfOutside() }
                else { self?.updatePointerInteraction() }
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown || event.type == .rightMouseDown { self?.dismissPlayerIfOutside() }
                else { self?.updatePointerInteraction() }
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
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
        localDragMonitor = nil
        displayObserver = nil
        dragMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        state = .idle
        isPlayerExpanded = false
        isHovered = false
        visibleBounds = .zero
    }

    func showClipboard(_ text: String, thumbnail: Data? = nil) {
        guard isEnabled, showsClipboard else { return }
        dismissTask?.cancel()
        clipboardThumbnail = thumbnail
        transition(to: .clipboard(String(text.prefix(60))))
        scheduleDismissal()
    }

    func showSystemFocus(_ active: Bool) {
        guard isEnabled else { return }
        dismissTask?.cancel()
        transition(to: .systemFocus(active))
        scheduleDismissal()
    }

    func showTrackChange(_ title: String) {
        guard isEnabled, showsMusic, !isPlayerExpanded else { return }
        dismissTask?.cancel()
        transition(to: .track(String(title.prefix(100))))
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        guard !isHovered else { return }
        let duration = min(6, max(1.6, notificationDuration))
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.restorePersistentState()
        }
    }

    func update(focusRemaining: Int, playing: Bool, level: Double, title: String, bands: [Double],
                artwork: Data? = nil, commandPending: Bool = false, controlError: String? = nil,
                available: Bool? = nil, artist: String = "", album: String = "", playerName: String = "Audio",
                sourceID: String? = nil, volume: Double? = nil,
                timeline: PlaybackTimeline? = nil, trackID: String? = nil) {
        hasMedia = available ?? playing
        if !hasMedia, isPlayerExpanded { animatePlayer { isPlayerExpanded = false } }
        mediaArtist = artist; mediaAlbum = album; mediaPlayerName = playerName; mediaSourceID = sourceID
        if !commandPending || trackID != mediaTrackID {
            mediaTimeline = timeline
            mediaTrackID = trackID
        }
        if !commandPending { mediaVolume = volume.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } }
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
        if isTransient { return }
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
        guard AccessibilityAccess.canSendKeyboardEvents else {
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
        guard showsShelf, let screen else { return }
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

    private func refreshMomentPreferences() {
        if !showsMusic, isPlayerExpanded { animatePlayer { isPlayerExpanded = false } }
        let hidden: Bool
        switch state {
        case .clipboard: hidden = !showsClipboard
        case .track, .nowPlaying: hidden = !showsMusic
        case .focus: hidden = !showsFocusTimer
        case .shelf: hidden = !showsShelf
        default: hidden = false
        }
        if !showsClipboard { clipboardThumbnail = nil }
        if !showsShelf { dragExitTask?.cancel() }
        if hidden {
            dismissTask?.cancel()
            restorePersistentState()
        } else if !isTransient && state != .shelf {
            restorePersistentState()
        }
    }

    private func restorePersistentState() {
        transition(to: showsMusic && isPlayerExpanded && hasMedia ? .nowPlaying :
            (showsFocusTimer && remainingSeconds > 0 ? .focus : (showsMusic && hasMedia ? .nowPlaying : .idle)))
    }
    private func transition(to next: IslandState) {
        guard state != next else { return }
        let contracting = next == .idle || (isTransient && (next == .focus || next == .nowPlaying))
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil :
            (contracting ? .easeInOut(duration: 0.34) : .spring(response: 0.44, dampingFraction: 0.88, blendDuration: 0.1))
        withAnimation(animation) { state = next }
        // The native canvas stays large enough for both the entering and retiring content.
    }
    private func reposition() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? (showOnExternalDisplay ? NSScreen.main : nil)
        hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        guard let screen else { panel?.orderOut(nil); return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchCenterX = (right.minX + left.maxX) / 2
            notchWidth = max(1, right.minX - left.maxX)
            notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        } else {
            notchCenterX = screen.frame.midX
            notchWidth = 180
            notchHeight = NSStatusBar.system.thickness
        }
        resize()
        panel?.orderFrontRegardless()
    }
    private func resize() {
        guard let screen, let panel else { return }
        let frame = NSRect(x: notchCenterX - canvasWidth / 2, y: screen.frame.maxY - canvasHeight, width: canvasWidth, height: canvasHeight)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        updatePointerInteraction()
    }

    func recordVisibleBounds(_ bounds: CGRect) {
        visibleBounds = bounds
        updateMouseAcceptance()
    }

    private var screenHitFrame: CGRect? {
        guard let panel else { return nil }
        let rect = visibleBounds.isEmpty ? CGRect(x: (canvasWidth - width) / 2, y: 0, width: width, height: height) : visibleBounds
        return CGRect(x: panel.frame.minX + rect.minX, y: panel.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func dismissPlayerIfOutside() {
        guard isPlayerExpanded, let frame = screenHitFrame, !frame.contains(NSEvent.mouseLocation) else { return }
        collapsePlayer()
    }

    private func updateMouseAcceptance() {
        guard let panel, let hitFrame = screenHitFrame else { return }
        let ignores = !hitFrame.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    private func updatePointerInteraction() {
        updateMouseAcceptance()
        guard let panel else { return }
        let hovering = !panel.ignoresMouseEvents && NSEvent.pressedMouseButtons == 0
        guard isHovered != hovering else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.88)) {
            isHovered = hovering
        }
    }

}

final class AperturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
