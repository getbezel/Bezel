import AppKit
import Observation

@MainActor @Observable
final class BezelModel {
    var account = GoogleAccount()
    var dashboard = DashboardLayout(available: BezelModule.allCases.filter { $0 != .overview }.map(\.rawValue))
    static let shared = BezelModel()
    var selection: BezelModule = .overview
    var search = ""
    var stack: StackService
    let airBridge = AirBridgeService()
    let nowPlaying = NowPlayingMetadata()
    let focusStatus = FocusStatusMonitor()
    var aperture = ApertureService()
    let grid = GridService()
    let scope = ScopeService()
    let monolith = MonolithService()
    var shelf = ShelfService()
    var dragWheel = DragWheelService()
    let tether = TetherService()
    let pulse = PulseService()
    let border = BorderService()
    let cleaning = CleaningService()
    let permissions = PermissionCenter()
    let shortcuts = GlobalShortcuts()
    var menuShelf = MenuShelfService()
    let lens: LensService
    @ObservationIgnored private var started = false
    @ObservationIgnored private var activateObserver: NSObjectProtocol?
    @ObservationIgnored private var lastTrackIdentity: String?

    init() {
        let stack = StackService()
        self.stack = stack
        lens = LensService(stack: stack)
    }

    var activeCount: Int {
        [stack.isEnabled, aperture.isEnabled, monolith.isActive, shelf.isEnabled,
         pulse.isActive, border.isEnabled, airBridge.isPlaying, dragWheel.isEnabled, cleaning.isActive].filter { $0 }.count
    }
    func start() {
        guard !started else { return }
        started = true
        permissions.refresh()
        account.start()
        permissions.startMonitoring()
        if menuShelf.manager.isEnabled { menuShelf.manager.start() }
        tether.start()
        airBridge.start()
        if stack.isEnabled { stack.start() }
        if shelf.isEnabled { shelf.start() }
        shelf.suppressDragDrawer = { [weak self] in self?.dragWheel.reservesDrag ?? false }
        dragWheel.onConverted = { [weak self] source, output in
            guard let self else { return "Open Shelf to add these files." }
            shelf.addFiles([source, output])
            if !shelf.isVisible { shelf.show() }
            return shelf.statusMessage
        }
        if dragWheel.isEnabled { dragWheel.start() }
        if aperture.isEnabled { aperture.start() }
        shelf.captureImage = { [weak self] in
            guard let self else { return }
            lens.startImageCapture { [weak self] data in
                self?.shelf.addImageData(data)
                self?.shelf.show()
            }
        }
        focusStatus.onChange = { [weak self] active in self?.aperture.showSystemFocus(active) }
        stack.onCapture = { [weak self] entry in self?.aperture.showClipboard(entry.preview, thumbnail: entry.thumbnailData) }
        aperture.acceptDrop = { [weak self] providers in self?.shelf.acceptDrop(providers) ?? false }
        aperture.openShelf = { [weak self] in self?.shelf.show() }
        aperture.controlPlayback = { [weak self] command in
            let action: PlayerCommand
            switch command {
            case .previous: action = .previous
            case .playPause: action = .playPause
            case .next: action = .next
            }
            return self?.nowPlaying.send(action) ?? false
        }
        aperture.controlVolume = { [weak self] value in
            guard let self else { return false }
            if nowPlaying.selected != nil { return nowPlaying.send(.setVolume(Int((value * 100).rounded()))) }
            guard let route = playbackRoute else { return false }
            route.gain = value
            return true
        }
        aperture.controlSeek = { [weak self] seconds, trackID in
            self?.nowPlaying.send(.seek(seconds: seconds, trackID: trackID)) ?? false
        }
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .clipboard: stack.showHUD()
            case .enqueue: stack.captureSelectionToQueue()
            case .dequeue: stack.showPastePicker()
            case .lens: lens.startCapture()
            case .tileLeft: grid.tile(.leftHalf)
            case .tileRight: grid.tile(.rightHalf)
            }
        }
        if UserDefaults.standard.object(forKey: "shortcuts.enabled") as? Bool ?? true { shortcuts.start() }
        activateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.permissions.refresh(); self?.lens.refreshPermission() }
        }
        synchronizeAperture()
    }
    private var playbackRoute: AirBridgeChannel? {
        airBridge.channels.filter { $0.isRouting && $0.process.bundleID == airBridge.nowPlayingBundleID }
            .max { $0.level < $1.level }
    }

    private func synchronizeAperture() {
        guard started else { return }
        let snapshot = withObservationTracking {
            (enabled: aperture.isEnabled, focusRemaining: monolith.isActive ? monolith.remainingSeconds : 0,
             playing: airBridge.isPlaying, level: airBridge.level, title: airBridge.nowPlayingTitle,
             bands: airBridge.frequencyBands, bundleID: airBridge.nowPlayingBundleID,
             track: nowPlaying.selected, commandPending: nowPlaying.isControlling,
             controlError: nowPlaying.controlError, metadataEnabled: nowPlaying.isEnabled, routeGain: playbackRoute?.gain)
        } onChange: { [weak self] in
            Task { @MainActor in self?.synchronizeAperture() }
        }
        focusStatus.setActive(snapshot.enabled)
        nowPlaying.setActive(snapshot.enabled)
        nowPlaying.prefer(snapshot.playing ? snapshot.bundleID : nil)
        if snapshot.enabled {
            let track = nowPlaying.selected
            aperture.update(focusRemaining: snapshot.focusRemaining, playing: track?.isPlaying ?? snapshot.playing, level: snapshot.level,
                            title: track?.title ?? snapshot.title, bands: snapshot.bands, artwork: track?.artwork,
                            commandPending: nowPlaying.isControlling, controlError: nowPlaying.controlError,
                            available: snapshot.playing || track != nil, artist: track?.artist ?? "", album: track?.album ?? "",
                            playerName: track?.target.player.name ?? snapshot.title,
                            sourceID: track?.target.instance ?? playbackRoute.map { "route:\($0.id)" },
                            volume: track?.volume ?? (track == nil ? snapshot.routeGain : nil),
                            timeline: track?.timeline, trackID: track?.trackID)
            let identity = track.map { "\($0.target.player.rawValue)/\($0.trackID)" }
            if let track, let identity, identity != lastTrackIdentity {
                aperture.showTrackChange(track.label)
            }
            lastTrackIdentity = identity
        }
    }
    func shutdown() async {
        cleaning.stop()
        await dragWheel.shutdown()
        stop()
        await shelf.shutdown()
        await monolith.focusAutomation.shutdown()
        await tether.chargeControl.shutdown()
        await airBridge.shutdown()
    }

    func handle(url: URL) {
        if account.handle(url) { return }
        guard let request = ScopeRequest(url: url) else { return }
        selection = .scope
        NSApp.activate(ignoringOtherApps: true)
        scope.handleFinderRequest(request)
    }
    func stop() {
        cleaning.stop()
        started = false
        if let activateObserver { NotificationCenter.default.removeObserver(activateObserver) }
        activateObserver = nil
        permissions.stopMonitoring()
        shortcuts.stop()
        aperture.stop()
        nowPlaying.stop()
        focusStatus.setActive(false)
        lastTrackIdentity = nil
        stack.stop()
        lens.cancelCapture()
        shelf.stop()
        dragWheel.stop()
        shelf.clear()
        monolith.stop()
        pulse.stop()
        border.stop()
        grid.stop()
        menuShelf.manager.stop()
        tether.stop()
        airBridge.stop()
        scope.stop()
    }
    func status(for module: BezelModule) -> String {
        switch module {
        case .cleaning: cleaning.isActive ? "Cleaning" : "Ready"
        case .overview: ""
        case .stack: stack.isEnabled ? "Listening" : "Paused"
        case .airBridge: airBridge.isPlaying ? "Playing" : "Ready"
        case .aperture: aperture.isEnabled ? "Enabled" : "Off"
        case .grid: permissions.accessibility ? "Ready" : "Set up"
        case .scope: scope.isScanning ? "Scanning" : "On demand"
        case .monolith: monolith.isActive ? "Focusing" : "Ready"
        case .shelf: "\(shelf.count) items"
        case .lens: lens.isBusy ? "Capturing" : (lens.hasScreenRecordingPermission ? "On demand" : "Needs access")
        case .dragWheel: dragWheel.activeCount > 0 ? "Converting \(dragWheel.activeCount)" : (dragWheel.isEnabled ? "Ready" : "Off")
        case .tether: tether.chargePercent.map { "\($0)%" } ?? "No battery"
        case .pulse: pulse.isActive ? "Keeping awake" : "Off"
        case .border: border.isEnabled ? (permissions.accessibility ? "Enabled" : "Needs access") : "Off"
        }
    }
}
