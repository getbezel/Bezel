import Foundation

private actor FixtureReader: PlayerReading {
    var reads = 0
    var commands: [PlayerCommand] = []
    var gate: CheckedContinuation<PlayerRefresh, Never>?
    let result: PlayerRefresh
    let gated: Bool
    init(result: PlayerRefresh, gated: Bool = false) { self.result = result; self.gated = gated }
    func read(_ targets: [PlayerTarget], spotifyArtwork: Bool) async throws -> PlayerRefresh {
        reads += 1
        if gated { return await withCheckedContinuation { gate = $0 } }
        return result
    }
    func control(_ target: PlayerTarget, command: PlayerCommand) async -> String? { commands.append(command); return nil }
    func clear() {}
    func release() { gate?.resume(returning: result); gate = nil }
    func state() -> (reads: Int, commands: [PlayerCommand]) { (reads, commands) }
}

private actor AuthorizationGate {
    var gate: CheckedContinuation<Int32, Never>?
    func request(_ target: PlayerTarget) async -> Int32 { await withCheckedContinuation { gate = $0 } }
    func isWaiting() -> Bool { gate != nil }
    func release() { gate?.resume(returning: 0); gate = nil }
}

@main struct MetadataTests {
    @MainActor private static var domains: [String] = []
    static func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    @MainActor static func preferences(enabled: Bool) -> UserDefaults {
        let domain = "Bezel.Media.Tests.\(UUID().uuidString)"; domains.append(domain)
        let values = UserDefaults(suiteName: domain)!
        values.set(enabled, forKey: "media.metadata")
        values.set([MetadataPlayer.music.rawValue], forKey: "media.players")
        return values
    }
    @MainActor static func main() async throws {
        defer { for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) } }
        let music = PlayerTarget(player: .music, pid: 123, instance: "first launch")
        let spotify = PlayerTarget(player: .spotify, pid: 456, instance: "second launch")
        let track = PlayingTrack(target: music, trackID: "M", title: "Music title", artist: "Artist", album: "Album", artwork: nil)
        let other = PlayingTrack(target: spotify, trackID: "S", title: "Spotify title", artist: "", album: "", artwork: nil)
        require(PlayingTrackSelection.choose([track, other], preferredBundle: "com.apple.Safari", frontmostBundle: nil, previous: nil) == nil, "An unrelated routed app must not acquire another player's artwork")
        require(PlayingTrackSelection.choose([track, other], preferredBundle: MetadataPlayer.spotify.rawValue, frontmostBundle: MetadataPlayer.music.rawValue, previous: music) == other, "Routing identity must take priority over frontmost metadata")
        require(PlayingTrackSelection.choose([track, other], preferredBundle: nil, frontmostBundle: MetadataPlayer.spotify.rawValue, previous: music) == other, "An explicitly foreground player must win")
        require(PlayingTrackSelection.choose([track, other], preferredBundle: nil, frontmostBundle: "com.bezel.utility", previous: spotify) == other, "Opening Bezel must not switch the selected player")
        let payload = try PlayerPayload.decode(["playing": true, "id": "M", "title": "Title\nwith controls", "artist": String(repeating: "x", count: 1000)], target: music)
        require(payload.title == "Title with controls" && payload.artist.count == 512, "Player strings must be bounded and single line")
        require(PlayerPayload.clean("a" + String(repeating: "\u{0301}", count: 10_000)).utf8.count <= 2048, "A single large grapheme must not bypass the text bound")
        for value in [["playing": "true"], ["playing": 2], ["title": "No state"]] as [[String: Any]] {
            var rejected = false
            do { _ = try PlayerPayload.decode(value, target: music) } catch { rejected = true }
            require(rejected, "Invalid player state accepted")
        }
        let oversized = try PlayerPayload.decode(["playing": true, "artwork": Data(count: SpotifyArtwork.maximumBytes + 1)], target: music)
        require(oversized.artwork == nil, "Oversized artwork must be discarded before decode")
        for url in ["http://i.scdn.co/image/id", "https://i.scdn.co.evil.test/id", "https://user:password@i.scdn.co/id", "https://i.scdn.co:8443/id", "file:///tmp/art.png"] {
            require(!SpotifyArtwork.allows(URL(string: url)!), "Untrusted artwork destination accepted")
        }
        require(SpotifyArtwork.allows(URL(string: "https://i.scdn.co/image/id")!), "Spotify image CDN was rejected")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        require(try await SpotifyArtwork.load(URL(string: "https://i.scdn.co/image/valid")!, session: session) != nil, "A valid image response must produce a downsampled thumbnail")
        for suffix in ["oversized", "html", "forbidden"] {
            require(try await SpotifyArtwork.load(URL(string: "https://i.scdn.co/image/\(suffix)")!, session: session) == nil, "Invalid image response accepted: \(suffix)")
        }
        do {
            _ = try await SpotifyArtwork.load(URL(string: "https://i.scdn.co/image/chunked")!, session: session)
            fatalError("A chunked response bypassed the byte limit")
        } catch PlayerMetadataFailure.message {}
        let stopCount = ArtworkFixture.stoppedCount
        let cancelledImage = Task { try await SpotifyArtwork.load(URL(string: "https://i.scdn.co/image/slow")!, session: session) }
        try await Task.sleep(for: .milliseconds(30))
        cancelledImage.cancel()
        do { _ = try await cancelledImage.value; fatalError("An incomplete image request ignored cancellation") } catch {}
        try await waitUntil { ArtworkFixture.stoppedCount > stopCount }

        let result = PlayerRefresh(tracks: [track], errors: [:])
        let disabledReader = FixtureReader(result: result)
        let disabled = NowPlayingMetadata(defaults: preferences(enabled: false), reader: disabledReader, targets: { [music] }, foreground: { nil }, authorize: { _ in 0 })
        disabled.setActive(true)
        try await Task.sleep(for: .milliseconds(30))
        require(await disabledReader.state().reads == 0, "Disabled metadata must never read a player")
        disabled.stop()

        let reader = FixtureReader(result: result)
        let live = NowPlayingMetadata(defaults: preferences(enabled: true), reader: reader, targets: { [music] }, foreground: { nil }, authorize: { _ in 0 })
        live.setActive(true)
        try await waitUntil { live.selected == track }
        require(live.send(.next), "Connected metadata must route controls to its own player")
        try await waitUntil { await reader.state().commands == [.next] && !live.isControlling }
        live.prefer("com.apple.Safari")
        require(live.selected == nil && !live.send(.next), "Unrelated routed playback must not send a player-specific command")
        live.stop()

        let gatedReader = FixtureReader(result: result, gated: true)
        let stopped = NowPlayingMetadata(defaults: preferences(enabled: true), reader: gatedReader, targets: { [music] }, foreground: { nil }, authorize: { _ in 0 })
        stopped.setActive(true)
        try await waitUntil { await gatedReader.state().reads == 1 }
        stopped.stop()
        await gatedReader.release()
        try await Task.sleep(for: .milliseconds(30))
        require(stopped.selected == nil, "A late metadata reply must not resurrect the notch after stop")

        let authorization = AuthorizationGate()
        let cancelledConnect = NowPlayingMetadata(defaults: preferences(enabled: false), reader: reader, targets: { [music] }, foreground: { nil }, authorize: { await authorization.request($0) })
        cancelledConnect.connect(.music)
        try await waitUntil { await authorization.isWaiting() }
        cancelledConnect.isEnabled = false
        await authorization.release()
        try await Task.sleep(for: .milliseconds(30))
        require(!cancelledConnect.isEnabled && cancelledConnect.connecting == nil, "Late consent must not override a user's disable action")
        cancelledConnect.stop()

        require(BezelPlayerPermission("test.unrecognized", 0, true) != 0, "Unsupported targets must be rejected before consent")
        require(BezelControlPlayer(MetadataPlayer.music.rawValue, 0, "unknown") == "Unknown playback action.", "Unknown actions must be rejected before sending an event")
        require(BezelReadPlayer(MetadataPlayer.music.rawValue, 0, nil)["error"] != nil, "Non-running players must not launch or receive an event")
        print("Media checks passed: bounded/typed metadata, route/player matching, artwork decode/HTTP/byte limits/CDN policy/request cancellation, opt-in reads, source-specific controls, stop cancellation, late-consent rejection, and native target/action rejection without player or network access.")
    }

    @MainActor static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            require(ContinuousClock.now < deadline, "A metadata fixture missed its bounded deadline")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
