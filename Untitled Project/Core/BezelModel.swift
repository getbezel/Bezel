import AppKit
import Observation

@MainActor @Observable
final class BezelModel {
    static let shared = BezelModel()
    var selection: BezelModule = .overview
    var search = ""
    var stack: StackService
    let airBridge = AirBridgeService()
    let nowPlaying = NowPlayingMetadata()
    var aperture = ApertureService()
    let grid = GridService()
    let scope = ScopeService()
    let monolith = MonolithService()
    var shelf = ShelfService()
    let tether = TetherService()
    let pulse = PulseService()
    let border = BorderService()
    let permissions = PermissionCenter()
    let shortcuts = GlobalShortcuts()
    var menuShelf = MenuShelfService()
    let lens: LensService
    @ObservationIgnored private var started = false
    @ObservationIgnored private var activateObserver: NSObjectProtocol?

    init() {
        let stack = StackService()
        self.stack = stack
        lens = LensService(stack: stack)
    }

    var activeCount: Int {
        [stack.isEnabled, aperture.isEnabled, monolith.isActive, shelf.isEnabled,
         pulse.isActive, border.isEnabled, airBridge.isPlaying].filter { $0 }.count
    }
    func start() {
        guard !started else { return }
        started = true
        permissions.refresh()
        if menuShelf.manager.isEnabled { menuShelf.manager.start() }
        tether.start()
        airBridge.start()
        if stack.isEnabled { stack.start() }
        if shelf.isEnabled { shelf.start() }
        if aperture.isEnabled { aperture.start() }
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
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .clipboard: stack.showHUD()
            case .enqueue: stack.captureSelectionToQueue()
            case .dequeue: stack.pasteNext()
            case .lens: lens.startCapture()
            case .tileLeft: grid.tile(.leftHalf)
            case .tileRight: grid.tile(.rightHalf)
            }
        }
        if UserDefaults.standard.object(forKey: "shortcuts.enabled") as? Bool ?? true { shortcuts.start() }
        activateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.permissions.refresh() }
        }
        synchronizeAperture()
    }
    private func synchronizeAperture() {
        guard started else { return }
        let snapshot = withObservationTracking {
            (enabled: aperture.isEnabled, focusRemaining: monolith.isActive ? monolith.remainingSeconds : 0,
             playing: airBridge.isPlaying, level: airBridge.level, title: airBridge.nowPlayingTitle,
             bands: airBridge.frequencyBands, bundleID: airBridge.nowPlayingBundleID,
             track: nowPlaying.selected, commandPending: nowPlaying.isControlling,
             controlError: nowPlaying.controlError, metadataEnabled: nowPlaying.isEnabled)
        } onChange: { [weak self] in
            Task { @MainActor in self?.synchronizeAperture() }
        }
        nowPlaying.setActive(snapshot.enabled)
        nowPlaying.prefer(snapshot.playing ? snapshot.bundleID : nil)
        if snapshot.enabled {
            let track = nowPlaying.selected
            aperture.update(focusRemaining: snapshot.focusRemaining, playing: snapshot.playing || track != nil, level: snapshot.level,
                            title: track?.label ?? snapshot.title, bands: snapshot.bands, artwork: track?.artwork,
                            commandPending: nowPlaying.isControlling, controlError: nowPlaying.controlError)
        }
    }
    func shutdown() async {
        stop()
        await monolith.focusAutomation.shutdown()
        await tether.chargeControl.shutdown()
        await airBridge.shutdown()
    }

    func handle(url: URL) {
        guard let request = ScopeRequest(url: url) else { return }
        selection = .scope
        NSApp.activate(ignoringOtherApps: true)
        scope.handleFinderRequest(request)
    }
    func stop() {
        started = false
        if let activateObserver { NotificationCenter.default.removeObserver(activateObserver) }
        activateObserver = nil
        shortcuts.stop()
        aperture.stop()
        nowPlaying.stop()
        stack.stop()
        lens.cancelCapture()
        shelf.stop()
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
        case .overview: ""
        case .stack: stack.isEnabled ? "Listening" : "Paused"
        case .airBridge: airBridge.isPlaying ? "Playing" : "Ready"
        case .aperture: aperture.isEnabled ? "Enabled" : "Off"
        case .grid: permissions.accessibility ? "Ready" : "Set up"
        case .scope: scope.isScanning ? "Scanning" : "On demand"
        case .monolith: monolith.isActive ? "Focusing" : "Ready"
        case .shelf: "\(shelf.count) items"
        case .lens: "On demand"
        case .tether: tether.chargePercent.map { "\($0)%" } ?? "No battery"
        case .pulse: pulse.isActive ? "Keeping awake" : "Off"
        case .border: border.isEnabled ? "Enabled" : "Off"
        }
    }
}
