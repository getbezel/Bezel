import AppKit
import CoreAudio
import Observation

@MainActor @Observable
final class AirBridgeChannel: Identifiable {
    let id: AudioObjectID
    let icon: NSImage?
    var process: AirBridgeProcess
    var primaryOutputID: AudioDeviceID = 0
    var secondaryOutputID: AudioDeviceID = 0
    var gain: Double = 1 {
        didSet { renderState?.setGain(gain) }
    }
    var level: Double = 0
    var isRouting = false
    var isBusy = false
    var error: String?
    @ObservationIgnored var renderState: AirBridgeRenderState?
    @ObservationIgnored var operationID = UUID()

    init(process: AirBridgeProcess, defaultOutputID: AudioDeviceID) {
        self.id = process.id
        icon = NSRunningApplication(processIdentifier: process.pid)?.icon
        self.process = process
        primaryOutputID = defaultOutputID
    }

    var decibels: String { level > 0.00001 ? String(format: "%.0f dBFS", 20 * log10(level)) : "−∞ dBFS" }
}

@MainActor @Observable
final class AirBridgeService {
    private(set) var devices: [AirBridgeDevice] = []
    private(set) var channels: [AirBridgeChannel] = []
    private(set) var isPlaying = false
    private(set) var level: Double = 0
    private(set) var frequencyBands = Array(repeating: 0.0, count: 7)
    private(set) var nowPlayingTitle = "No routed audio"
    private(set) var nowPlayingBundleID: String?
    private(set) var discoveryError: String?
    private(set) var isSuspended = false
    private(set) var isStoppingAll = false
    @ObservationIgnored private let engine = AirBridgeEngine()
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var shutdownID = UUID()

    var activeRouteCount: Int { channels.filter(\.isRouting).count }
    var visibleChannels: [AirBridgeChannel] {
        channels.filter { $0.process.isOutputActive || $0.isRouting || $0.isBusy || $0.error != nil }
    }

    /// Discovery does not request permission or capture audio. Routing starts only from a user action.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSuspended = true
                    self?.cancelAllRoutes(message: "Routing stopped when your Mac went to sleep. Start the route again after waking.")
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isSuspended = false }
            }
        ]
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            }
        }
    }

    func stop() {
        isStarted = false
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
        isSuspended = false
        discoveryTask?.cancel()
        discoveryTask = nil
        cancelAllRoutes(message: nil)
    }

    /// Wait for CoreAudio teardown before the application exits.
    func shutdown() async {
        stop()
        await engine.stopAll()
    }

    private func cancelAllRoutes(message: String?) {
        let shutdown = UUID()
        shutdownID = shutdown
        isStoppingAll = true
        meterTask?.cancel()
        meterTask = nil
        for channel in channels {
            if let message, channel.isRouting || channel.isBusy { channel.error = message }
            channel.operationID = UUID()
            channel.renderState = nil
            channel.isRouting = false
            channel.isBusy = false
            channel.level = 0
        }
        isPlaying = false
        level = 0
        frequencyBands = Array(repeating: 0, count: 7)
        nowPlayingTitle = "No routed audio"
        nowPlayingBundleID = nil
        let engine = engine
        Task { [weak self] in
            await engine.stopAll()
            guard self?.shutdownID == shutdown else { return }
            self?.isStoppingAll = false
        }
    }

    func startRouting(_ channel: AirBridgeChannel) {
        guard isStarted, !isSuspended, !isStoppingAll, !channel.isBusy, !channel.isRouting else { return }
        guard let primary = devices.first(where: { $0.id == channel.primaryOutputID }) else {
            channel.error = AirBridgeError.noOutput.localizedDescription
            return
        }
        var targets = [primary]
        if channel.secondaryOutputID != 0, channel.secondaryOutputID != primary.id,
           let secondary = devices.first(where: { $0.id == channel.secondaryOutputID }) { targets.append(secondary) }
        channel.isBusy = true
        channel.error = nil
        let operation = UUID()
        channel.operationID = operation
        let engine = engine
        Task { [weak self, weak channel] in
            guard let channel, channel.operationID == operation, self?.isStarted == true, self?.isSuspended == false else { return }
            do {
                let state = try await engine.start(processID: channel.id, outputs: targets, gain: channel.gain, operationID: operation)
                guard channel.operationID == operation, self?.isStarted == true else {
                    await engine.stop(processID: channel.id, operationID: operation)
                    return
                }
                channel.renderState = state
                channel.isRouting = true
                channel.isBusy = false
                self?.startMeteringIfNeeded()
            } catch {
                guard channel.operationID == operation else { return }
                channel.error = error.localizedDescription
                channel.isBusy = false
                channel.isRouting = false
            }
        }
    }

    func stopRouting(_ channel: AirBridgeChannel) {
        guard !channel.isBusy else { return }
        let routeOperation = channel.operationID
        let stopOperation = UUID()
        channel.operationID = stopOperation
        channel.isBusy = true
        let engine = engine
        Task { [weak self, weak channel] in
            guard let channel else { return }
            await engine.stop(processID: channel.id, operationID: routeOperation)
            guard channel.operationID == stopOperation else { return }
            channel.renderState = nil
            channel.isRouting = false
            channel.isBusy = false
            channel.level = 0
            self?.updateMeters()
        }
    }

    func stopAllRoutes() {
        cancelAllRoutes(message: nil)
    }

    private func refresh() async {
        guard !isSuspended else { return }
        do {
            let snapshot = try await engine.discover()
            guard isStarted, !Task.isCancelled else { return }
            devices = snapshot.devices
            discoveryError = nil
            let defaultOutput = (try? AirBridgeHAL.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))) ?? devices.first?.id ?? 0
            let existing = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
            channels = snapshot.processes.map { process in
                if let channel = existing[process.id], channel.process.pid == process.pid {
                    channel.process = process
                    if !channel.isRouting && !channel.isBusy && !devices.contains(where: { $0.id == channel.primaryOutputID }) { channel.primaryOutputID = defaultOutput }
                    return channel
                }
                return AirBridgeChannel(process: process, defaultOutputID: defaultOutput)
            }
            let failures = await engine.validate(processIDs: Set(snapshot.processes.map(\.id)))
            guard isStarted, !Task.isCancelled else { return }
            for channel in channels {
                if let failure = failures[channel.id], channel.operationID == failure.operationID {
                    channel.renderState = nil
                    channel.isRouting = false
                    channel.isBusy = false
                    channel.error = failure.message
                    channel.level = 0
                }
            }
            updateMeters()
        } catch {
            discoveryError = error.localizedDescription
        }
    }

    private func startMeteringIfNeeded() {
        guard meterTask == nil else { return }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateMeters()
                guard self?.activeRouteCount ?? 0 > 0 else { self?.meterTask = nil; return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    private func updateMeters() {
        var highest: AirBridgeChannel?
        for channel in channels {
            let actual = Double(channel.renderState?.peak ?? 0)
            channel.level = channel.isRouting ? max(actual, channel.level * 0.65) : 0
            if channel.isRouting, channel.level > (highest?.level ?? 0) { highest = channel }
        }
        level = highest?.level ?? 0
        isPlaying = level > 0.001
        frequencyBands = isPlaying ? highest?.renderState?.spectrum.bands ?? Array(repeating: 0, count: 7) : Array(repeating: 0, count: 7)
        nowPlayingTitle = highest?.process.name ?? "No routed audio"
        nowPlayingBundleID = isPlaying ? highest?.process.bundleID : nil
    }

    func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}
