import AppKit
import Foundation
import Observation
import CoreFoundation

enum MetadataPlayer: String, CaseIterable, Sendable, Identifiable {
    case music = "com.apple.Music", spotify = "com.spotify.client", youtubeMusic = "com.google.Chrome", youtubeMusicBrave = "com.brave.Browser"
    var id: String { rawValue }
    var isYouTubeMusic: Bool { self == .youtubeMusic || self == .youtubeMusicBrave }
    var name: String {
        switch self {
        case .music: "Apple Music"
        case .spotify: "Spotify"
        case .youtubeMusic: "YouTube Music · Chrome"
        case .youtubeMusicBrave: "YouTube Music · Brave"
        }
    }
}

struct PlayerTarget: Sendable, Equatable {
    let player: MetadataPlayer
    let pid: pid_t
    let instance: String
}

enum PlayerCommand: Sendable, Equatable {
    case previous, playPause, next, setVolume(Int), seek(seconds: Double, trackID: String)
    var playbackAction: String? {
        switch self {
        case .previous: "previous"
        case .playPause: "playPause"
        case .next: "next"
        case .setVolume, .seek: nil
        }
    }
}

struct PlayingTrack: Sendable, Equatable {
    let target: PlayerTarget
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let artwork: Data?
    var isPlaying: Bool = true
    var volume: Double? = nil
    var timeline: PlaybackTimeline? = nil
    var label: String { artist.isEmpty ? title : "\(title) · \(artist)" }
    func withPlayback(playing: Bool, volume: Double?) -> Self {
        Self(target: target, trackID: trackID, title: title, artist: artist, album: album, artwork: artwork, isPlaying: playing, volume: volume,
             timeline: timeline.flatMap { PlaybackTimeline(position: $0.elapsed(playing: isPlaying), duration: $0.duration) })
    }
    func withTimeline(_ value: PlaybackTimeline?) -> Self {
        Self(target: target, trackID: trackID, title: title, artist: artist, album: album, artwork: artwork,
             isPlaying: isPlaying, volume: volume, timeline: value)
    }
    func withArtwork(_ data: Data?) -> Self {
        Self(target: target, trackID: trackID, title: title, artist: artist, album: album, artwork: data, isPlaying: isPlaying, volume: volume, timeline: timeline)
    }
}

struct PlayerRefresh: Sendable {
    var tracks: [PlayingTrack] = []
    var errors: [MetadataPlayer: String] = [:]
}

enum PlayerMetadataFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}

/// Converts an Objective-C reply to bounded, Sendable values before it leaves the worker.
struct PlayerPayload: Sendable {
    let target: PlayerTarget
    let playing: Bool
    let unchanged: Bool
    let id: String
    let title: String
    let artist: String
    let album: String
    let artwork: Data?
    let artworkURL: URL?
    let volume: Double?
    let timeline: PlaybackTimeline?

    static func decode(_ reply: [String: Any], target: PlayerTarget) throws -> Self {
        if let error = reply["error"] as? String { throw PlayerMetadataFailure.message(clean(error)) }
        guard let playing = reply["playing"] as? NSNumber,
              CFGetTypeID(playing) == CFBooleanGetTypeID() else {
            throw PlayerMetadataFailure.message("The player returned an invalid playback state.")
        }
        func field(_ key: String) -> String { clean(reply[key] as? String ?? "") }
        let data = reply["artwork"] as? Data
        let rawURL = (reply["artworkURL"] as? String).flatMap(URL.init(string:))
        let rawVolume = reply["volume"] as? NSNumber
        let volume = rawVolume.flatMap { value -> Double? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  (0...100).contains(value.doubleValue) else { return nil }
            return value.doubleValue / 100
        }
        func number(_ key: String) -> Double? {
            guard let value = reply[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        let timeline = number("position").flatMap { position in
            number("duration").flatMap { PlaybackTimeline(position: position, duration: $0) }
        }
        return Self(target: target, playing: playing.boolValue, unchanged: (reply["unchanged"] as? Bool) == true,
                    id: field("id"), title: field("title"), artist: field("artist"), album: field("album"),
                    artwork: data.flatMap { $0.count <= SpotifyArtwork.maximumBytes ? $0 : nil },
                    artworkURL: rawURL.flatMap { (target.player.isYouTubeMusic ? YouTubeArtwork.allows($0) : SpotifyArtwork.allows($0)) ? $0 : nil }, volume: volume, timeline: timeline)
    }

    static func clean(_ text: String) -> String {
        String(text.unicodeScalars.prefix(512).map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PlayingTrackSelection {
    static func choose(_ tracks: [PlayingTrack], preferredBundle: String?, frontmostBundle: String?, previous: PlayerTarget?) -> PlayingTrack? {
        // A routed Safari/Chrome stream must never acquire an unrelated Music cover.
        if let preferredBundle { return tracks.first { $0.target.player.rawValue == preferredBundle } }
        let playing = tracks.filter(\.isPlaying)
        if let frontmostBundle, let track = playing.first(where: { $0.target.player.rawValue == frontmostBundle }) { return track }
        if let previous, let track = playing.first(where: { $0.target == previous }) { return track }
        if let track = playing.first { return track }
        if let frontmostBundle, let track = tracks.first(where: { $0.target.player.rawValue == frontmostBundle }) { return track }
        if let previous, let track = tracks.first(where: { $0.target == previous }) { return track }
        return tracks.first
    }
}

/// Spotify's scripting dictionary exposes a CDN URL rather than image bytes.
enum SpotifyArtwork {
    static let maximumBytes = 4 * 1024 * 1024
    static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "i.scdn.co" &&
        (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func load(_ url: URL, session: URLSession, policy: @Sendable (URL) -> Bool = SpotifyArtwork.allows) async throws -> Data? {
        guard policy(url) else { return nil }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        let requestTask = bytes.task
        defer { requestTask.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url.map(policy) == true, response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= Int64(maximumBytes) else { return nil }
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(max(0, min(maximumBytes, Int(response.expectedContentLength))))
            var chunk: [UInt8] = []
            chunk.reserveCapacity(16 * 1024)
            for try await byte in bytes {
                guard data.count + chunk.count < maximumBytes else { throw PlayerMetadataFailure.message("The album artwork exceeds the image limit.") }
                chunk.append(byte)
                if chunk.count == 16 * 1024 {
                    try Task.checkCancellation()
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            data.append(contentsOf: chunk)
            return ClipboardImage.preview(data: data)?.thumbnail
        } onCancel: { requestTask.cancel() }
    }
}

enum YouTubeArtwork {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "i.ytimg.com" || host == "lh3.googleusercontent.com" || host == "lh3.google.com"
    }
}

private final class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map { SpotifyArtwork.allows($0) || YouTubeArtwork.allows($0) } == true ? request : nil)
    }
}

protocol PlayerReading: Sendable {
    func read(_ targets: [PlayerTarget], spotifyArtwork: Bool, youtubeArtwork: Bool) async throws -> PlayerRefresh
    func control(_ target: PlayerTarget, command: PlayerCommand) async -> String?
    func clear() async
}

actor NativePlayerReader: PlayerReading {
    private struct Cached {
        let track: PlayingTrack
        let artworkURL: URL?
        let refreshed: ContinuousClock.Instant
    }
    private var cache: [MetadataPlayer: Cached] = [:]
    private let session: URLSession
    private var epoch = UUID()
    private var artworkTask: (id: UUID, task: Task<Data?, Error>)?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration, delegate: ArtworkRedirectPolicy(), delegateQueue: nil)
    }

    func clear() { epoch = UUID(); cache.removeAll(); artworkTask?.task.cancel(); artworkTask = nil }

    func read(_ targets: [PlayerTarget], spotifyArtwork: Bool, youtubeArtwork: Bool) async throws -> PlayerRefresh {
        let generation = epoch
        cache = cache.filter { player, cached in targets.contains { $0.player == player && $0 == cached.track.target } }
        var result = PlayerRefresh()
        for target in targets {
            try Task.checkCancellation()
            let old = cache[target.player]
            let previous = old.flatMap { $0.refreshed.duration(to: .now) < .seconds(30) ? $0.track.trackID : nil }
            do {
                let reply = target.player.isYouTubeMusic ? BezelReadYouTubeMusic(target.player.rawValue, target.pid, previous) : BezelReadPlayer(target.player.rawValue, target.pid, previous)
                let payload = try PlayerPayload.decode(reply, target: target)
                let downloadsArtwork = target.player == .spotify ? spotifyArtwork : (target.player.isYouTubeMusic && youtubeArtwork)
                try Task.checkCancellation()
                guard payload.playing || !payload.id.isEmpty || !payload.title.isEmpty else { continue }
                if payload.unchanged {
                    guard let old, old.track.trackID == payload.id else { throw PlayerMetadataFailure.message("The player's track changed while reading metadata.") }
                    let refreshed = old.track.withPlayback(playing: payload.playing, volume: payload.volume).withTimeline(payload.timeline)
                    cache[target.player] = Cached(track: refreshed, artworkURL: old.artworkURL, refreshed: old.refreshed)
                    result.tracks.append(target.player != .music && !downloadsArtwork ? refreshed.withArtwork(nil) : refreshed)
                    continue
                }
                var art: Data?
                if target.player == .music, let data = payload.artwork { art = ClipboardImage.preview(data: data)?.thumbnail }
                if downloadsArtwork, let url = payload.artworkURL {
                    if old?.artworkURL == url, let existing = old?.track.artwork { art = existing }
                    else {
                        let id = UUID()
                        let youtube = target.player.isYouTubeMusic
                        let task = Task { try await SpotifyArtwork.load(url, session: session, policy: { youtube ? YouTubeArtwork.allows($0) : SpotifyArtwork.allows($0) }) }
                        artworkTask = (id, task)
                        art = try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                        if artworkTask?.id == id { artworkTask = nil }
                    }
                }
                try Task.checkCancellation()
                guard epoch == generation else { throw CancellationError() }
                let title = payload.title.isEmpty ? target.player.name : payload.title
                let identity = payload.id.isEmpty ? [title, payload.artist, payload.album].joined(separator: "\u{1f}") : payload.id
                let track = PlayingTrack(target: target, trackID: identity, title: title, artist: payload.artist, album: payload.album, artwork: art, isPlaying: payload.playing, volume: payload.volume, timeline: payload.timeline)
                cache[target.player] = Cached(track: track, artworkURL: payload.artworkURL, refreshed: .now)
                result.tracks.append(track)
            } catch is CancellationError { throw CancellationError() }
            catch { result.errors[target.player] = error.localizedDescription }
        }
        return result
    }

    func control(_ target: PlayerTarget, command: PlayerCommand) -> String? {
        guard !Task.isCancelled else { return nil }
        if target.player.isYouTubeMusic {
            guard let cached = cache[target.player]?.track, cached.target == target else { return "The YouTube Music tab is no longer available." }
            if case .seek(let seconds, let trackID) = command {
                guard cached.trackID == trackID, let timeline = cached.timeline,
                      seconds.isFinite, (0...timeline.duration).contains(seconds) else { return "The track changed or has no seekable timeline." }
                return BezelSeekYouTubeMusic(target.player.rawValue, target.pid, trackID, seconds)
            }
            if case .setVolume(let percent) = command {
                guard (0...100).contains(percent) else { return "Volume must be between 0 and 100." }
                return BezelControlYouTubeMusic(target.player.rawValue, target.pid, cached.trackID, "volume", percent)
            }
            guard let action = command.playbackAction else { return "Unknown playback action." }
            return BezelControlYouTubeMusic(target.player.rawValue, target.pid, cached.trackID, action, 0)
        }
        if case .seek(let seconds, let trackID) = command {
            guard let cached = cache[target.player]?.track, cached.target == target,
                  cached.trackID == trackID, let timeline = cached.timeline,
                  seconds.isFinite, (0...timeline.duration).contains(seconds) else { return "The track changed or has no seekable timeline." }
            return BezelSeekPlayer(target.player.rawValue, target.pid, trackID, seconds)
        }
        if case .setVolume(let percent) = command {
            return BezelSetPlayerVolume(target.player.rawValue, target.pid, percent)
        }
        guard let action = command.playbackAction else { return "Unknown playback action." }
        return BezelControlPlayer(target.player.rawValue, target.pid, action)
    }
}

@MainActor @Observable
final class NowPlayingMetadata {
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "media.metadata")
            if !isEnabled { cancelConnection() }
            reconcile()
        }
    }
    var downloadsSpotifyArtwork: Bool {
        didSet {
            defaults.set(downloadsSpotifyArtwork, forKey: "media.spotifyArtwork")
            stopPolling()
            reconcile()
        }
    }
    var downloadsYouTubeArtwork: Bool {
        didSet {
            defaults.set(downloadsYouTubeArtwork, forKey: "media.youtubeArtwork")
            stopPolling()
            reconcile()
        }
    }
    private(set) var connected: Set<MetadataPlayer>
    private(set) var selected: PlayingTrack?
    private(set) var playerErrors: [MetadataPlayer: String] = [:]
    private(set) var connecting: MetadataPlayer?
    private(set) var isControlling = false
    private(set) var controlError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reader: any PlayerReading
    @ObservationIgnored private let targets: @MainActor () -> [PlayerTarget]
    @ObservationIgnored private let foreground: @MainActor () -> String?
    @ObservationIgnored private let authorize: @Sendable (PlayerTarget) async -> Int32
    @ObservationIgnored private var active = false
    @ObservationIgnored private var preferredBundle: String?
    @ObservationIgnored private var tracks: [PlayingTrack] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var connection: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var loopID = UUID()
    @ObservationIgnored private var connectionID = UUID()
    @ObservationIgnored private var commandID = UUID()

    init(defaults: UserDefaults = .standard, reader: any PlayerReading = NativePlayerReader(),
         targets: @escaping @MainActor () -> [PlayerTarget] = NowPlayingMetadata.runningPlayers,
         foreground: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         authorize: @escaping @Sendable (PlayerTarget) async -> Int32 = NowPlayingMetadata.requestAccess) {
        self.defaults = defaults; self.reader = reader; self.targets = targets; self.foreground = foreground; self.authorize = authorize
        isEnabled = defaults.bool(forKey: "media.metadata")
        downloadsSpotifyArtwork = defaults.object(forKey: "media.spotifyArtwork") as? Bool ?? true
        downloadsYouTubeArtwork = defaults.bool(forKey: "media.youtubeArtwork")
        connected = Set((defaults.stringArray(forKey: "media.players") ?? []).compactMap(MetadataPlayer.init(rawValue:)))
    }

    func setActive(_ value: Bool) { guard active != value else { return }; active = value; reconcile() }
    func prefer(_ bundle: String?) { guard preferredBundle != bundle else { return }; preferredBundle = bundle; selectTrack() }

    func connect(_ player: MetadataPlayer) {
        guard connecting == nil else { return }
        guard let target = targets().first(where: { $0.player == player }) else {
            playerErrors[player] = "Open \(player.name) before connecting it."
            return
        }
        connecting = player
        playerErrors[player] = nil
        let id = UUID(); connectionID = id
        connection = Task { [weak self, authorize] in
            let status = await authorize(target)
            guard let self, !Task.isCancelled, connectionID == id else { return }
            connecting = nil; connection = nil
            if status == 0 {
                connected.insert(player)
                defaults.set(connected.map(\.rawValue).sorted(), forKey: "media.players")
                isEnabled = true
                stopPolling(); reconcile()
            } else { playerErrors[player] = "Automation access was not granted. Review this player in Privacy & Security → Automation." }
        }
    }

    func disconnect(_ player: MetadataPlayer) {
        if connecting == player { connectionID = UUID(); connection?.cancel(); connection = nil; connecting = nil }
        connected.remove(player)
        defaults.set(connected.map(\.rawValue).sorted(), forKey: "media.players")
        playerErrors[player] = nil
        stopPolling(); reconcile()
    }

    @discardableResult func send(_ command: PlayerCommand) -> Bool {
        if case .setVolume(let percent) = command, !(0...100).contains(percent) { return false }
        if case .seek(let seconds, let trackID) = command {
            guard let selected, selected.trackID == trackID, let timeline = selected.timeline,
                  seconds.isFinite, (0...timeline.duration).contains(seconds), !isControlling else { return false }
        }
        guard let target = selected?.target, connected.contains(target.player), isEnabled, active else { return false }
        guard !isControlling else { return true }
        isControlling = true; controlError = nil
        let id = UUID(); commandID = id
        controlTask = Task { [weak self, reader] in
            let error = await reader.control(target, command: command)
            guard let self, !Task.isCancelled, commandID == id else { return }
            if error == nil {
                let result = try? await reader.read([target], spotifyArtwork: downloadsSpotifyArtwork, youtubeArtwork: downloadsYouTubeArtwork)
                guard !Task.isCancelled, commandID == id else { return }
                if let result, result.errors[target.player] == nil {
                    tracks.removeAll { $0.target == target }
                    tracks.append(contentsOf: result.tracks)
                    selectTrack()
                }
            }
            isControlling = false; controlTask = nil; controlError = error
        }
        return true
    }

    func stop() {
        active = false
        cancelConnection(); commandID = UUID()
        controlTask?.cancel(); controlTask = nil; isControlling = false
        stopPolling()
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }

    private func reconcile() {
        guard active, isEnabled, !connected.isEmpty else { stopPolling(); return }
        guard loop == nil else { return }
        let id = UUID(); loopID = id
        loop = Task { [weak self, reader] in
            guard let self, loopID == id else { return }
            await reader.clear()
            while !Task.isCancelled {
                guard loopID == id else { return }
                let requested = targets().filter { connected.contains($0.player) }
                let refreshCommandID = commandID
                do {
                    let result = try await reader.read(requested, spotifyArtwork: downloadsSpotifyArtwork, youtubeArtwork: downloadsYouTubeArtwork)
                    guard !Task.isCancelled, loopID == id else { return }
                    if !isControlling, commandID == refreshCommandID {
                        tracks = result.tracks
                        playerErrors = result.errors
                        selectTrack()
                    }
                } catch is CancellationError { return }
                catch {
                    guard loopID == id else { return }
                    if !isControlling, commandID == refreshCommandID { tracks = []; selected = nil }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func stopPolling() {
        loopID = UUID(); loop?.cancel(); loop = nil
        tracks = []; selected = nil
        commandID = UUID(); controlTask?.cancel(); controlTask = nil; isControlling = false
        let reader = reader
        let id = loopID
        Task { [weak self] in
            guard self?.loopID == id, self?.loop == nil else { return }
            await reader.clear()
        }
    }

    private func selectTrack() {
        let value = PlayingTrackSelection.choose(tracks, preferredBundle: preferredBundle, frontmostBundle: foreground(), previous: selected?.target)
        if selected?.target != value?.target {
            commandID = UUID(); controlTask?.cancel(); controlTask = nil; isControlling = false; controlError = nil
        }
        if selected != value { selected = value }
    }

    private func cancelConnection() {
        connectionID = UUID(); connection?.cancel(); connection = nil; connecting = nil
    }

    static func runningPlayers() -> [PlayerTarget] {
        MetadataPlayer.allCases.compactMap { player in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first, !app.isTerminated else { return nil }
            return PlayerTarget(player: player, pid: app.processIdentifier, instance: "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)")
        }
    }

    nonisolated static func requestAccess(_ target: PlayerTarget) async -> Int32 {
        await Task.detached(priority: .userInitiated) { BezelPlayerPermission(target.player.rawValue, target.pid, true) }.value
    }
}
