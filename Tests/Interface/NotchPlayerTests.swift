import Foundation
import AppKit
import SwiftUI

@main struct NotchPlayerTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    @MainActor static func main() async {
        let domain = "Bezel.Notch.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "aperture.enabled")
        let service = ApertureService(defaults: defaults)
        defer { service.stop(); defaults.removePersistentDomain(forName: domain) }
        service.update(focusRemaining: 0, playing: true, level: 0, title: "Track", bands: [],
                       available: true, artist: "Artist", playerName: "Spotify", sourceID: "spotify-instance", volume: 0.6)
        require(service.height == service.notchHeight, "Collapsed music must align with the menu bar without extra bottom padding")
        service.isHovered = true
        require(service.height > service.notchHeight, "Hovering may still reveal playback details")
        service.isHovered = false
        service.showTrackChange("Track · Artist")
        require(service.state == .track("Track · Artist"), "Track moments must still appear before expansion")
        let momentHeight = service.height
        service.expandPlayer()
        require(service.state == .nowPlaying && service.isPlayerExpanded && service.height > momentHeight,
                "Clicking a track moment must enter a larger controllable player")
        require(service.canvasHeight >= service.height && service.canvasWidth >= service.width,
                "The native canvas must contain all expanded controls")
        service.isHovered = true; service.isHovered = false
        require(service.isPlayerExpanded, "Moving from the notch to its controls must not collapse the player")
        service.showTrackChange("Next track")
        require(service.isPlayerExpanded && service.state == .nowPlaying, "Next track must preserve open controls")
        service.update(focusRemaining: 120, playing: false, level: 0, title: "Track", bands: [],
                       available: true, sourceID: "spotify-instance", volume: 0.6)
        require(service.isPlayerExpanded && !service.isPlaying && service.hasMedia && service.state == .nowPlaying,
                "Pausing must preserve the expanded player and Play control, even during focus")
        service.collapsePlayer()
        require(service.height == service.notchHeight, "The compact focus timer must align with the menu bar")
        require(!service.isPlayerExpanded && service.state == .focus, "Closing playback must restore a running focus timer")
        service.update(focusRemaining: 0, playing: false, level: 0, title: "Track", bands: [],
                       available: true, sourceID: "spotify-instance", volume: 0.6)
        require(service.state == .nowPlaying, "A paused source must remain available to click and resume")
        var volumes: [Double] = []
        service.controlVolume = { value in volumes.append(value); return true }
        service.setMediaVolume(0.37, sourceID: "spotify-instance")
        require(volumes == [0.37] && service.mediaVolume == 0.37, "Volume commit must reach the source and update the display")
        service.setMediaVolume(.nan, sourceID: "spotify-instance")
        service.setMediaVolume(0.5, sourceID: "old-instance")
        require(volumes == [0.37], "Nonfinite values and stale player drags must not control another source")
        service.setMediaVolume(2, sourceID: "spotify-instance")
        require(volumes == [0.37, 1], "Slider output must be bounded")
        service.update(focusRemaining: 0, playing: false, level: 0, title: "Track", bands: [],
                       commandPending: true, available: true, sourceID: "spotify-instance", volume: 0.6)
        require(service.mediaVolume == 1, "A stale poll must not snap volume backward while its command is pending")
        var seeks: [(Double, String)] = []
        service.controlSeek = { value, id in seeks.append((value, id)); return true }
        service.update(focusRemaining: 0, playing: true, level: 0, title: "Track", bands: [], available: true,
                       sourceID: "spotify-instance", timeline: PlaybackTimeline(position: 20, duration: 180), trackID: "track-one")
        service.seekMedia(to: 65, sourceID: "spotify-instance", trackID: "track-one")
        require(seeks.count == 1 && seeks[0].0 == 65 && service.mediaTimeline?.position == 65, "A valid scrub must route to the selected track")
        service.seekMedia(to: 50, sourceID: "old-source", trackID: "track-one")
        service.seekMedia(to: 50, sourceID: "spotify-instance", trackID: "old-track")
        service.seekMedia(to: .nan, sourceID: "spotify-instance", trackID: "track-one")
        require(seeks.count == 1, "Stale source/track drags and invalid values must not seek")
        service.update(focusRemaining: 0, playing: true, level: 0, title: "Track", bands: [], commandPending: true,
                       available: true, sourceID: "spotify-instance", timeline: PlaybackTimeline(position: 20, duration: 180), trackID: "track-one")
        require(service.mediaTimeline?.position == 65, "A pending seek must not be overwritten by a stale poll")
        service.seekMedia(to: 80, sourceID: "spotify-instance", trackID: "track-one")
        require(seeks.count == 1, "A pending command cannot silently accept another seek")
        service.expandPlayer()
        service.update(focusRemaining: 0, playing: false, level: 0, title: "No playback", bands: [], available: false)
        require(!service.isPlayerExpanded && service.state == .idle, "Closing or losing the player must release its panel state")
        service.expandPlayer()
        require(!service.isPlayerExpanded, "An unavailable player must not expose fabricated controls")
        require(service.showsClipboard && service.showsMusic && service.showsFocusTimer && service.showsShelf,
                "Existing users retain all moment types by default")
        service.update(focusRemaining: 120, playing: true, level: 0, title: "Track", bands: [], available: true)
        service.showClipboard("Copied")
        service.showsClipboard = false
        require(service.state == .focus, "Disabling clipboard immediately dismisses its visible moment")
        service.showClipboard("Hidden")
        require(service.state == .focus, "Disabled clipboard cannot interrupt other moments")
        service.showsFocusTimer = false
        require(service.state == .nowPlaying, "Hiding the timer reveals enabled playback")
        service.expandPlayer()
        service.showsMusic = false
        require(service.state == .idle && !service.isPlayerExpanded, "Disabling music closes expanded playback")
        service.showTrackChange("Hidden")
        service.expandPlayer()
        service.update(focusRemaining: 120, playing: true, level: 1, title: "Still hidden", bands: [], available: true)
        require(service.state == .idle && !service.isPlayerExpanded, "Polling and clicks cannot restore disabled music")
        service.showsMusic = true
        require(service.state == .nowPlaying, "Re-enabling music restores the current source")
        service.showsShelf = false
        let restored = ApertureService(defaults: defaults)
        require(!restored.showsClipboard && restored.showsMusic && !restored.showsFocusTimer && !restored.showsShelf,
                "Each moment choice persists independently")
        restored.stop()
        if let path = ProcessInfo.processInfo.environment["BEZEL_NOTCH_PREVIEW_PATH"] {
            _ = NSApplication.shared
            service.update(focusRemaining: 0, playing: false, level: 0, title: "A little room to listen", bands: [],
                           available: true, artist: "Bezel", album: "Preview", playerName: "Music", sourceID: "preview", volume: 0.5,
                           timeline: PlaybackTimeline(position: 45, duration: 210), trackID: "preview-track")
            service.expandPlayer()
            let host = NSHostingView(rootView: IslandView(service: service))
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: service.canvasWidth, height: service.canvasHeight)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            try? await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            window.orderOut(nil)
        }
        print("Notch player checks passed: moment-to-player click transition, bounds, hover persistence, track switching, pause/resume availability, focus restoration, source-bound volume, stale drag/poll protection, finite bounds, source loss, independent moment preferences, immediate dismissal, disabled-music suppression and preference persistence.")
    }
}
