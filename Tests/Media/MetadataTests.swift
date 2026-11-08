import Foundation

private actor FixtureReader: PlayerReading {
    var reads = 0
    var commands: [PlayerCommand] = []
    var gate: CheckedContinuation<PlayerRefresh, Never>?
    var result: PlayerRefresh
    let gated: Bool
    init(result: PlayerRefresh, gated: Bool = false) { self.result = result; self.gated = gated }
    func read(_ targets: [PlayerTarget], spotifyArtwork: Bool, youtubeArtwork: Bool) async throws -> PlayerRefresh {
        reads += 1
        if gated { return await withCheckedContinuation { gate = $0 } }
        return result
    }
    func control(_ target: PlayerTarget, command: PlayerCommand) async -> String? {
        commands.append(command)
        result.tracks = result.tracks.map { track in
            guard track.target == target else { return track }
            switch command {
            case .playPause: return track.withPlayback(playing: !track.isPlaying, volume: track.volume)
            case .setVolume(let percent): return track.withPlayback(playing: track.isPlaying, volume: Double(percent) / 100)
            case .seek(let seconds, _): return track.withTimeline(track.timeline.flatMap { PlaybackTimeline(position: seconds, duration: $0.duration) })
            default: return track
            }
        }
        return nil
    }
    func clear() {}
    func release() { gate?.resume(returning: result); gate = nil }
    func state() -> (reads: Int, commands: [PlayerCommand]) { (reads, commands) }
}

/// The second background poll fails late, after a control and its refresh have succeeded.
private actor StalePollReader: PlayerReading {
    var reads = 0
    var pending: CheckedContinuation<PlayerRefresh, Error>?
    var track: PlayingTrack
    init(track: PlayingTrack) { self.track = track }
    func read(_ targets: [PlayerTarget], spotifyArtwork: Bool, youtubeArtwork: Bool) async throws -> PlayerRefresh {
        reads += 1
        if reads == 2 { return try await withCheckedThrowingContinuation { pending = $0 } }
        return PlayerRefresh(tracks: [track])
    }
    func control(_ target: PlayerTarget, command: PlayerCommand) async -> String? {
        track = track.withPlayback(playing: false, volume: 0.37)
        return nil
    }
    func clear() {}
    func waiting() -> Bool { pending != nil }
    func failStalePoll() {
        pending?.resume(throwing: PlayerMetadataFailure.message("Late poll failure")); pending = nil
    }
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
        let paused = track.withPlayback(playing: false, volume: 0.25)
        require(PlayingTrackSelection.choose([paused, other], preferredBundle: nil, frontmostBundle: nil, previous: music) == other, "Paused metadata must not displace a playing source")
        require(PlayingTrackSelection.choose([paused], preferredBundle: nil, frontmostBundle: nil, previous: music) == paused, "Pausing must preserve a source to resume")
        require(paused.withArtwork(Data([1])).isPlaying == false && paused.withArtwork(nil).volume == 0.25, "Artwork updates must retain paused state and volume")
        let youtube = PlayerTarget(player: .youtubeMusic, pid: 789, instance: "Chrome instance")
        let browserTrack = PlayingTrack(target: youtube, trackID: "tab|video|title|artist", title: "Browser song", artist: "Artist", album: "", artwork: nil)
        require(PlayingTrackSelection.choose([track, browserTrack], preferredBundle: "com.google.Chrome", frontmostBundle: nil, previous: music) == browserTrack,
                "A routed browser must select its own YouTube Music track")
        let brave = PlayerTarget(player: .youtubeMusicBrave, pid: 790, instance: "Brave instance")
        let braveTrack = PlayingTrack(target: brave, trackID: browserTrack.trackID, title: "Brave song", artist: "Artist", album: "", artwork: nil)
        require(brave.player.isYouTubeMusic && youtube.player.isYouTubeMusic && !music.player.isYouTubeMusic,
                "Browser metadata routing must include Brave and preserve native player routing")
        require(PlayingTrackSelection.choose([browserTrack, braveTrack], preferredBundle: "com.brave.Browser", frontmostBundle: "com.google.Chrome", previous: youtube) == braveTrack,
                "Brave routing must select Brave, even if Chrome has the same tab/song ID")
        require(PlayingTrackSelection.choose([browserTrack, braveTrack], preferredBundle: nil, frontmostBundle: "com.brave.Browser", previous: youtube) == braveTrack,
                "The foreground Brave player must select its own controls")
        let bravePreferences = preferences(enabled: true)
        bravePreferences.set([MetadataPlayer.youtubeMusic.rawValue, MetadataPlayer.youtubeMusicBrave.rawValue], forKey: "media.players")
        let restoredBrowsers = NowPlayingMetadata(defaults: bravePreferences, reader: FixtureReader(result: PlayerRefresh()), targets: { [] })
        require(restoredBrowsers.connected == [.youtubeMusic, .youtubeMusicBrave], "Chrome and Brave connections persist independently")
        let cover = "https://lh3.googleusercontent.com/image/valid"
        require(try PlayerPayload.decode(["playing": true, "artworkURL": cover, "position": 10, "duration": 100], target: youtube).artworkURL != nil,
                "YouTube Music covers and timing must pass through the browser source")
        require(try PlayerPayload.decode(["playing": true, "artworkURL": cover], target: spotify).artworkURL == nil,
                "Spotify cannot acquire a browser-only artwork URL")
        for url in ["https://i.ytimg.com/image/valid", cover, "https://lh3.google.com/image/valid"] {
            require(YouTubeArtwork.allows(URL(string: url)!), "YouTube image host rejected")
        }
        for url in ["http://i.ytimg.com/image", "https://i.ytimg.com.evil.test/image", "https://user@lh3.googleusercontent.com/image", "https://lh3.google.com:8443/image", "https://music.youtube.com/image"] {
            require(!YouTubeArtwork.allows(URL(string: url)!), "An unrelated browser artwork URL must be rejected")
        }
        let pausedReply = try PlayerPayload.decode(["playing": false, "id": "M", "unchanged": true, "volume": 37], target: music)
        require(!pausedReply.playing && pausedReply.volume == 0.37, "Paused cached replies must update actual player volume")
        for badVolume in [Double.nan, Double.infinity, -1.0, 101.0] {
            require(try PlayerPayload.decode(["playing": true, "volume": badVolume], target: music).volume == nil, "Invalid volume must be unavailable")
        }
        require(try PlayerPayload.decode(["playing": true, "volume": true], target: music).volume == nil, "Boolean volume must be rejected")
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
        require(try await SpotifyArtwork.load(URL(string: cover)!, session: session, policy: YouTubeArtwork.allows) != nil,
                "Browser artwork must use the same bounded image loader")
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
        require(live.send(.playPause), "Pause must use the connected source")
        try await waitUntil { live.selected?.isPlaying == false && !live.isControlling }
        require(live.selected?.target == music && live.send(.setVolume(37)), "A paused source must remain controllable")
        try await waitUntil { live.selected?.volume == 0.37 && !live.isControlling }
        require(!live.send(.setVolume(-1)) && !live.send(.setVolume(101)), "Invalid volume must not reach a source")
        require(live.send(.playPause), "Paused tracks must be resumable")
        try await waitUntil { live.selected?.isPlaying == true && !live.isControlling }
        live.prefer("com.apple.Safari")
        require(live.selected == nil && !live.send(.next), "Unrelated routed playback must not send a player-specific command")
        live.stop()

        let anchor = ContinuousClock.now
        let clock = PlaybackTimeline(position: 30, duration: 180, sampledAt: anchor)!
        require(clock.elapsed(playing: true, now: anchor.advanced(by: .seconds(5))) == 35, "Timeline must project playback between polls")
        require(clock.elapsed(playing: false, now: anchor.advanced(by: .seconds(5))) == 30, "A paused timeline must remain fixed")
        require(clock.elapsed(playing: true, now: anchor.advanced(by: .seconds(999))) == 180, "Projection must stop at the track end")
        require(PlaybackTimeline(position: .nan, duration: 100) == nil && PlaybackTimeline(position: 0, duration: 0) == nil,
                "Invalid/live durations must not fabricate a seek bar")
        require(PlaybackTimeline.label(3661) == "1:01:01" && PlaybackTimeline.label(.infinity) == "0:00", "Time labels must handle long and invalid values")
        let timedReply = try PlayerPayload.decode(["playing": true, "position": 42.5, "duration": 180], target: music)
        require(timedReply.timeline?.position == 42.5 && timedReply.timeline?.duration == 180, "Actual position and duration must survive decoding")
        require(try PlayerPayload.decode(["playing": true, "position": true, "duration": 180], target: music).timeline == nil,
                "Boolean playback positions must not be treated as seconds")
        let seekReader = FixtureReader(result: PlayerRefresh(tracks: [track.withTimeline(clock)]))
        let seeking = NowPlayingMetadata(defaults: preferences(enabled: true), reader: seekReader, targets: { [music] }, foreground: { nil }, authorize: { _ in 0 })
        seeking.setActive(true)
        try await waitUntil { seeking.selected?.timeline != nil }
        require(!seeking.send(.seek(seconds: .nan, trackID: "M")) && !seeking.send(.seek(seconds: 181, trackID: "M")), "Invalid seek positions must be rejected")
        require(!seeking.send(.seek(seconds: 60, trackID: "old-track")), "A stale track must not receive a seek")
        require(seeking.send(.seek(seconds: 60, trackID: "M")), "A seekable connected track must accept a seek")
        try await waitUntil { seeking.selected?.timeline?.position == 60 && !seeking.isControlling }
        require(await seekReader.state().commands == [.seek(seconds: 60, trackID: "M")], "Only a validated seek may reach the source")
        seeking.stop()

        let staleReader = StalePollReader(track: track)
        let stale = NowPlayingMetadata(defaults: preferences(enabled: true), reader: staleReader, targets: { [music] }, foreground: { nil }, authorize: { _ in 0 })
        stale.setActive(true)
        try await waitUntil { let waiting = await staleReader.waiting(); return stale.selected != nil && waiting }
        require(stale.send(.playPause), "A pending poll must not block controls")
        try await waitUntil { stale.selected?.isPlaying == false && stale.selected?.volume == 0.37 && !stale.isControlling }
        await staleReader.failStalePoll()
        try await Task.sleep(for: .milliseconds(30))
        require(stale.selected?.isPlaying == false && stale.selected?.volume == 0.37, "A stale poll error must not erase a successful command refresh")
        stale.stop()

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
        require(BezelSetPlayerVolume(MetadataPlayer.spotify.rawValue, 0, -1) == "Volume must be between 0 and 100.", "Invalid volume must be rejected before permissions or events")
        require(BezelSetPlayerVolume(MetadataPlayer.spotify.rawValue, 0, 50) != nil, "Volume must never launch a missing player")
        require(BezelSeekPlayer(MetadataPlayer.music.rawValue, 0, "M", .nan) != nil, "Native invalid seeks are rejected before permissions")
        require(BezelSeekPlayer(MetadataPlayer.spotify.rawValue, 0, "S", 10) != nil, "Seeking cannot launch a closed player")
        require(BezelReadYouTubeMusic(MetadataPlayer.youtubeMusicBrave.rawValue, 0, nil)["error"] != nil, "Brave reads must never launch a browser")
        require(BezelControlYouTubeMusic(MetadataPlayer.youtubeMusicBrave.rawValue, 0, "tab|id", "next", 0) != nil, "Brave controls must not target an absent browser")
        require(BezelReadYouTubeMusic(MetadataPlayer.music.rawValue, 0, nil)["error"] as? String == "Choose a supported YouTube Music browser.", "Browser automation must reject native-player and unrelated bundle IDs")
        require(BezelReadYouTubeMusic(MetadataPlayer.youtubeMusic.rawValue, 0, nil)["error"] != nil, "Browser reads must not launch Chrome")
        require(BezelControlYouTubeMusic(MetadataPlayer.youtubeMusic.rawValue, 0, "tab|id", "unknown", 0) == "Unknown playback action.", "Browser controls reject unknown actions before automation")
        require(BezelControlYouTubeMusic(MetadataPlayer.youtubeMusic.rawValue, 0, "tab|id", "volume", 101) != nil, "Browser volume must be bounded")
        require(BezelSeekYouTubeMusic(MetadataPlayer.youtubeMusic.rawValue, 0, "tab|id", .nan) != nil, "Browser seeks reject nonfinite input")
        require(BezelReadPlayer(MetadataPlayer.music.rawValue, 0, nil)["error"] != nil, "Non-running players must not launch or receive an event")
        print("Media checks passed: bounded/typed metadata, route/player matching, artwork decode/HTTP/byte limits/CDN policy/request cancellation, opt-in reads, source-specific controls, stop cancellation, late-consent rejection, paused-source retention/resume, actual volume normalization/source commands, post-command refresh, and native target/action/volume rejection without player or network access.")
    }

    @MainActor static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            require(ContinuousClock.now < deadline, "A metadata fixture missed its bounded deadline")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
