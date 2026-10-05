import SwiftUI
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
                } else if service.state == .nowPlaying {
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
                }.padding(.horizontal, 18).frame(height: 48)
            case .focus:
                if service.isHovered {
                    Text("One thing at a time.").font(.caption).foregroundStyle(.white.opacity(0.6)).frame(height: 32)
                }
            case .nowPlaying:
                if service.isHovered {
                    VStack(spacing: 10) {
                        Text(service.statusMessage ?? service.mediaControlError ?? service.mediaTitle).font(.caption).lineLimit(1).help(service.mediaTitle)
                        HStack(spacing: 25) {
                            Button { service.sendMediaKey(.previous) } label: { Image(systemName: "backward.end.fill") }
                                .help("Previous track")
                            Button { service.sendMediaKey(.playPause) } label: { Image(systemName: "playpause.fill") }
                                .help("Play or pause")
                            Button { service.sendMediaKey(.next) } label: { Image(systemName: "forward.end.fill") }
                                .help("Next track")
                        }.buttonStyle(.plain).disabled(service.isMediaCommandPending)
                    }.frame(height: 65)
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
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.72, blendDuration: 0)) {
                service.isHovered = hovering
            }
        }
        .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: nil) { providers in
            let accepted = service.acceptDrop?(providers) ?? false
            service.finishDrop()
            if accepted { service.showClipboard("Added to Shelf") }
            return accepted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aperture")
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
                    Section("Moments") {
                        Label("Copied items appear for 1.2 seconds", systemImage: "doc.on.clipboard")
                        Label("Focus sessions keep the timer in view", systemImage: "timer")
                        Label("Routed audio displays seven live frequency bands", systemImage: "waveform")
                        Label("Drag files to the top edge to reveal Shelf", systemImage: "tray.and.arrow.down")
                    }
                }.formStyle(.grouped).scrollDisabled(true).frame(height: 360)
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
                        Text("Connect a running player to allow track details and playback controls. Apple Music artwork is read locally. Spotify covers are downloaded from Spotify’s image servers only when enabled. Other players show their app name and routed audio levels.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Automation Settings…") { metadata.openAutomationSettings() }
                    }.padding(8)
                }
                Button("Preview a clipboard moment") { service.preview() }.buttonStyle(.borderedProminent)
            }.padding(28)
        }
    }
}
