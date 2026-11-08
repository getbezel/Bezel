import SwiftUI
import Intents
import UniformTypeIdentifiers

struct IslandView: View {
    @Bindable var service: ApertureService
    @Namespace private var island
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if service.state == .focus {
                    Image(systemName: "moon.fill").foregroundStyle(.indigo.opacity(0.9))
                    Spacer(minLength: service.notchWidth)
                    Text(service.timeLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                } else if service.state == .nowPlaying && !service.isPlayerExpanded {
                    if let artwork = service.mediaArtwork {
                        Image(nsImage: artwork).resizable().scaledToFill().frame(width: 24, height: 24).clipShape(Circle()).accessibilityHidden(true)
                    } else {
                        Image(systemName: "waveform.circle.fill").foregroundStyle(.orange).font(.system(size: 23))
                    }
                    Spacer(minLength: service.notchWidth)
                    AudioMeter(bands: service.mediaBands)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: service.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { if !service.isPlayerExpanded { service.expandPlayer() } }
            .accessibilityAction(named: Text("Open player")) { service.expandPlayer() }

            switch service.state {
            case .idle: EmptyView()
            case .clipboard(let preview):
                HStack(spacing: 10) {
                    if let data = service.clipboardThumbnail, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "checkmark.square.fill").foregroundStyle(.green)
                    }
                    MarqueeText(text: preview).frame(height: 30)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 18).frame(height: 56).transition(.opacity.combined(with: .move(edge: .top)))
            case .systemFocus(let active):
                HStack(spacing: 12) {
                    Image(systemName: active ? "moon.fill" : "moon").font(.title3).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(active ? "Focus on" : "Focus off").font(.callout.weight(.semibold))
                        Text(active ? "Notifications silenced" : "Notifications resumed").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                }.padding(.horizontal, 20).frame(height: 56).transition(.opacity.combined(with: .move(edge: .top)))
            case .track(let title):
                HStack(spacing: 12) {
                    if let artwork = service.mediaArtwork {
                        Image(nsImage: artwork).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else { Image(systemName: "music.note").foregroundStyle(.orange) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Now Playing").font(.caption2).foregroundStyle(.white.opacity(0.6))
                        Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20).frame(height: 56)
                    .contentShape(Rectangle()).onTapGesture { service.expandPlayer() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { service.expandPlayer() }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .focus:
                if service.isHovered {
                    Text("One thing at a time.").font(.caption).foregroundStyle(.white.opacity(0.6)).frame(height: 32)
                }
            case .nowPlaying:
                if service.isPlayerExpanded {
                    ExpandedNotchPlayer(service: service)
                        .frame(height: 264)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if service.isHovered {
                    Button { service.expandPlayer() } label: {
                        HStack(spacing: 10) {
                            Text(service.mediaTitle).font(.caption).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }.padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 42)
                    }.buttonStyle(.plain).help("Open playback controls")
                }
            case .shelf:
                VStack(spacing: 9) {
                    Image(systemName: "tray.and.arrow.down").font(.title2).foregroundStyle(.cyan)
                    Text("Drop into Shelf").font(.system(size: 13, weight: .medium))
                    Text("Ready when you are.").font(.caption).foregroundStyle(.white.opacity(0.5))
                }.frame(maxWidth: .infinity).frame(height: 115)
            }
        }
        .foregroundStyle(.white)
        .frame(width: service.width, height: service.height, alignment: .top)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)
                .fill(.black)
                .matchedGeometryEffect(id: "capsule", in: island)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
        .contentShape(UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20))
        .onGeometryChange(for: CGRect.self) { proxy in proxy.frame(in: .named("ApertureCanvas")) } action: { bounds in
            service.recordVisibleBounds(bounds)
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.88, blendDuration: 0.1)) {
                service.isHovered = hovering
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.plainText], isTargeted: nil) { providers in
            guard service.showsShelf else { return false }
            let accepted = service.acceptDrop?(providers) ?? false
            service.finishDrop()
            if accepted { service.showClipboard("Added to Shelf") }
            return accepted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aperture")
        .frame(width: service.canvasWidth, height: service.canvasHeight, alignment: .top)
        .coordinateSpace(name: "ApertureCanvas")
    }
}

private struct ExpandedNotchPlayer: View {
    @Bindable var service: ApertureService
    @State private var volume = 0.5
    @State private var editingVolume = false
    @State private var volumeSourceID: String?
    @State private var seekPosition = 0.0
    @State private var editingSeek = false
    @State private var seekSourceID: String?
    @State private var seekTrackID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 14) {
                Group {
                    if let artwork = service.mediaArtwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08))
                            .overlay { Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.white.opacity(0.55)) }
                    }
                }.frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Album artwork")
                VStack(alignment: .leading, spacing: 5) {
                    Text(service.mediaTitle).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    if !service.mediaArtist.isEmpty {
                        Text(service.mediaArtist).font(.callout).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                    Text(service.mediaAlbum.isEmpty ? service.mediaPlayerName : service.mediaAlbum)
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack {
                    Button { service.collapsePlayer() } label: {
                        Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)).frame(width: 26, height: 26)
                            .background(.white.opacity(0.08), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Collapse player").help("Collapse player")
                    Spacer(minLength: 0)
                }.frame(height: 76)
            }
            timeline
            HStack(spacing: 30) {
                transport(.previous, symbol: "backward.end.fill", label: "Previous track")
                Button { service.sendMediaKey(.playPause) } label: {
                    Image(systemName: service.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(.black)
                        .frame(width: 44, height: 44).background(.white, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel(service.isPlaying ? "Pause" : "Play")
                    .help(service.isPlaying ? "Pause" : "Play")
                transport(.next, symbol: "forward.end.fill", label: "Next track")
            }.disabled(service.isMediaCommandPending)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.white.opacity(0.5))
                Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                    editingVolume = editing
                    if editing { volumeSourceID = service.mediaSourceID }
                    else { service.setMediaVolume(volume, sourceID: volumeSourceID); volumeSourceID = nil }
                }).tint(.white).controlSize(.small)
                    .disabled(service.mediaVolume == nil || service.isMediaCommandPending)
                    .accessibilityLabel("\(service.mediaPlayerName) volume")
                    .accessibilityValue(service.mediaVolume == nil ? "Unavailable" : "\(Int(volume * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        guard service.mediaVolume != nil, !service.isMediaCommandPending else { return }
                        switch direction {
                        case .increment: volume = min(1, volume + 0.05)
                        case .decrement: volume = max(0, volume - 0.05)
                        @unknown default: return
                        }
                        service.setMediaVolume(volume, sourceID: service.mediaSourceID)
                    }
                    .help(service.mediaVolume == nil ? "This source does not expose volume control" : "\(service.mediaPlayerName) volume")
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Text(service.statusMessage ?? service.mediaControlError ?? service.mediaPlayerName)
                .font(.caption2).foregroundStyle(service.statusMessage != nil || service.mediaControlError != nil ? .orange : .white.opacity(0.4))
                .lineLimit(1).frame(height: 12)
        }
        .padding(.horizontal, 20).padding(.bottom, 14)
        .onAppear { volume = service.mediaVolume ?? 0.5 }
        .onChange(of: service.mediaVolume) { _, value in if !editingVolume { volume = value ?? 0.5 } }
        .onChange(of: service.mediaSourceID) { _, _ in
            editingVolume = false; volumeSourceID = nil; volume = service.mediaVolume ?? 0.5
            resetSeek()
        }
        .onChange(of: service.mediaTrackID) { _, _ in resetSeek() }
    }

    @ViewBuilder private var timeline: some View {
        if let trackTimeline = service.mediaTimeline {
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 0.25, paused: !service.isPlaying || editingSeek)) { _ in
                let shown = editingSeek ? min(trackTimeline.duration, seekPosition) : trackTimeline.elapsed(playing: service.isPlaying)
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { shown }, set: { seekPosition = $0 }), in: 0...trackTimeline.duration,
                           onEditingChanged: { editing in
                        if editing {
                            seekPosition = trackTimeline.elapsed(playing: service.isPlaying)
                            seekSourceID = service.mediaSourceID
                            seekTrackID = service.mediaTrackID
                            editingSeek = true
                        } else {
                            let source = seekSourceID, track = seekTrackID
                            editingSeek = false; seekSourceID = nil; seekTrackID = nil
                            service.seekMedia(to: seekPosition, sourceID: source, trackID: track)
                        }
                    })
                    .tint(.white).controlSize(.small)
                    .disabled(service.isMediaCommandPending)
                    .accessibilityLabel("Track position")
                    .accessibilityValue("\(PlaybackTimeline.label(shown)) of \(PlaybackTimeline.label(trackTimeline.duration))")
                    .accessibilityAdjustableAction { direction in
                        guard !service.isMediaCommandPending else { return }
                        let current = trackTimeline.elapsed(playing: service.isPlaying)
                        let target: Double
                        switch direction {
                        case .increment: target = min(trackTimeline.duration, current + 5)
                        case .decrement: target = max(0, current - 5)
                        @unknown default: return
                        }
                        service.seekMedia(to: target, sourceID: service.mediaSourceID, trackID: service.mediaTrackID)
                    }
                    .help("Drag to seek in the current track")
                    HStack {
                        Text(PlaybackTimeline.label(shown))
                        Spacer()
                        Text("−" + PlaybackTimeline.label(max(0, trackTimeline.duration - shown)))
                    }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                }.frame(height: 40)
            }
        } else {
            Text("Timeline unavailable for this source")
                .font(.caption2).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity).frame(height: 40)
        }
    }
    private func resetSeek() {
        editingSeek = false; seekSourceID = nil; seekTrackID = nil
        seekPosition = service.mediaTimeline?.elapsed(playing: service.isPlaying) ?? 0
    }

    private func transport(_ command: ApertureService.MediaCommand, symbol: String, label: String) -> some View {
        Button { service.sendMediaKey(command) } label: {
            Image(systemName: symbol).font(.system(size: 19)).frame(width: 40, height: 40)
                .contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}

struct AudioMeter: View {
    let bands: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<7) { index in
                Capsule().fill(.orange)
                    .frame(width: 2, height: max(3, CGFloat(bands.indices.contains(index) ? bands[index] : 0) * 26))
            }
        }.frame(width: 28, height: 26)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: bands)
            .accessibilityLabel("Audio frequency spectrum")
    }
}

struct ApertureView: View {
    @Bindable var service: ApertureService
    @Bindable var metadata: NowPlayingMetadata
    @Bindable var focusStatus: FocusStatusMonitor
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 26) {
                    HStack(spacing: 20) {
                        Image(systemName: "moon.fill").foregroundStyle(.indigo)
                        RoundedRectangle(cornerRadius: 8).fill(.black).frame(width: 130, height: 18)
                        Text("25:00").font(.system(.caption, design: .monospaced)).foregroundStyle(.white)
                    }.padding(.horizontal, 20).frame(height: 42)
                        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                    VStack(spacing: 8) {
                        Text("A quieter kind of notification.").font(.title2.weight(.semibold))
                        Text("Your clipboard, focus timer, audio, and file shelf.\nAlways close. Never in the way.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }.frame(maxWidth: .infinity).padding(.bottom, 28)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
                Form {
                    Section {
                        Toggle("Enable Aperture", isOn: $service.isEnabled)
                        Toggle("Show a capsule on displays without a notch", isOn: $service.showOnExternalDisplay)
                        LabeledContent("Display", value: service.hasNotch ? "Camera housing detected" : "No camera housing detected")
                    } footer: {
                        Text("Aperture follows the camera housing using your display’s safe area. The optional capsule is centered at the top of other displays.")
                    }
                    Section {
                        Toggle("Clipboard previews", isOn: $service.showsClipboard)
                        Toggle("Music & playback controls", isOn: $service.showsMusic)
                        Toggle("Focus session timer", isOn: $service.showsFocusTimer)
                        Toggle("Shelf drop zone", isOn: $service.showsShelf)
                    } header: { Text("Show in Aperture") } footer: {
                        Text("Choose what appears in the notch. Turning off a preview keeps its utility running. System Focus notifications can be configured below.")
                    }
                    Section("Moments") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Moment duration") { Text("\(service.notificationDuration, specifier: "%.1f") seconds") }
                            Slider(value: $service.notificationDuration, in: 1.6...6, step: 0.2).accessibilityLabel("Notification duration")
                            Text("Hover a moment to keep it open.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.formStyle(.grouped).scrollDisabled(true).frame(height: 560)
                GroupBox("Focus status") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show system Focus changes", isOn: $focusStatus.isEnabled)
                        Text(focusStatus.statusDescription).font(.callout).foregroundStyle(.secondary)
                        HStack {
                            if focusStatus.authorization != .authorized {
                                Button("Allow Focus Status…") { focusStatus.requestAccess() }.disabled(focusStatus.isRequesting)
                            }
                            Button("Focus Settings…") { focusStatus.openSettings() }
                        }
                        Text("macOS shares whether notifications are silenced, not the name of the active Focus. Sharing and permission must be enabled; unknown status never produces a false ‘Focus off’ notification.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Now Playing") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show track details from connected players", isOn: $metadata.isEnabled)
                        ForEach(MetadataPlayer.allCases) { player in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label(player.name, systemImage: metadata.connected.contains(player) ? "checkmark.circle" : "music.note")
                                    Spacer()
                                    if metadata.connecting == player { ProgressView().controlSize(.small) }
                                    Button(metadata.connected.contains(player) ? "Reconnect…" : "Connect…") { metadata.connect(player) }
                                        .disabled(metadata.connecting != nil).accessibilityLabel("Connect \(player.name)")
                                    if metadata.connected.contains(player) {
                                        Button("Disconnect") { metadata.disconnect(player) }.accessibilityLabel("Disconnect \(player.name)")
                                    }
                                }
                                if let error = metadata.playerErrors[player] { Text(error).font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        Toggle("Download Spotify album artwork", isOn: $metadata.downloadsSpotifyArtwork)
                        Toggle("Download YouTube Music album artwork", isOn: $metadata.downloadsYouTubeArtwork)
                        Text("For YouTube Music, open music.youtube.com in Chrome or Brave and start a song, then connect that browser above. In that browser’s menu bar, enable View → Developer → Allow JavaScript from Apple Events. Page content is read only from YouTube Music; no extension or Google sign-in in Bezel is required.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Click the Now Playing capsule to open artwork, playback controls and volume. Connect a running player to allow track details and playback controls. Apple Music artwork is read locally. Spotify and YouTube Music covers are downloaded from their image servers only when enabled. Other players show their app name and routed audio levels.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Automation Settings…") { metadata.openAutomationSettings() }
                    }.padding(8)
                }
                Button("Preview a clipboard moment") { service.preview() }
                    .buttonStyle(BezelActionStyle(prominent: true)).disabled(!service.showsClipboard)
            }.padding(28)
        }
    }
}
