import SwiftUI

enum StudioColor {
    static let canvas = Color(red: 0.077, green: 0.082, blue: 0.092)
    static let rail = Color(red: 0.062, green: 0.067, blue: 0.077)
    static let tile = Color(red: 0.098, green: 0.104, blue: 0.116)
    static let blue = Color(red: 0.27, green: 0.55, blue: 1)
}

extension View {
    func studioSurface(radius: CGFloat = 8) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(StudioColor.tile, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false))
    }
}

struct StudioGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            configuration.content.padding(12).frame(maxWidth: .infinity, alignment: .leading).studioSurface()
        }
    }
}

struct StudioSessionBar: View {
    let model: BezelModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if model.monolith.isActive { model.monolith.stop() }
                else {
                    model.monolith.start()
                    if !model.monolith.isActive { model.selection = .monolith }
                }
            } label: {
                let remaining = model.monolith.isActive ? model.monolith.remainingSeconds : model.monolith.durationMinutes * 60
                HStack(spacing: 8) {
                    Image(systemName: model.monolith.isActive ? "stop.circle.fill" : "circle.dotted")
                        .foregroundStyle(StudioColor.blue)
                    Text("Focus")
                    Text(String(format: "%02d:%02d", remaining / 60, remaining % 60))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }.help(model.monolith.isActive ? "End focus session" : "Start a \(model.monolith.durationMinutes)-minute focus session")
            Spacer()
            let player = model.nowPlaying
            let track = player.selected
            Button { model.selection = .aperture } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(StudioColor.blue)
                    if let error = player.controlError ?? model.aperture.statusMessage, track != nil || model.airBridge.isPlaying {
                        Text(error).foregroundStyle(.orange).lineLimit(1).help(error)
                    } else if let track {
                        Text(track.title).fontWeight(.medium).lineLimit(1)
                        Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(model.airBridge.isPlaying ? model.airBridge.nowPlayingTitle : "No media playing")
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.help("Open Aperture and manage connected players")
            transport(.previous, "backward.end.fill", "Previous track")
            let isPlaying = track?.isPlaying ?? model.airBridge.isPlaying
            transport(.playPause, isPlaying ? "pause.fill" : "play.fill", isPlaying ? "Pause" : "Play")
            transport(.next, "forward.end.fill", "Next track")
        }.font(.system(size: 12)).buttonStyle(.plain)
            .padding(.horizontal, 22).frame(height: 44).background(StudioColor.rail)
    }

    private func transport(_ command: ApertureService.MediaCommand, _ symbol: String, _ label: String) -> some View {
        Button { model.aperture.sendMediaKey(command) } label: {
            Image(systemName: symbol).frame(width: 22, height: 28)
        }.accessibilityLabel(label).help(label)
            .disabled((model.nowPlaying.selected == nil && !model.airBridge.isPlaying) || model.nowPlaying.isControlling)
    }
}

struct StudioSearch: View {
    let navigate: (BezelModule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    private var matches: [BezelModule] {
        ([.overview, .workspace] + BezelModule.utilities).filter {
            query.isEmpty || "\($0.title) \($0.subtitle)".localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioColor.blue)
                TextField("Search utilities and pages", text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if matches.indices.contains(index) { navigate(matches[index]) } }
                    .onKeyPress(.downArrow) { index = min(max(0, matches.count - 1), index + 1); return .handled }
                    .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
                Button("Esc") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(15)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        if matches.isEmpty { Text("No matching utilities").foregroundStyle(.secondary).padding() }
                        ForEach(Array(matches.enumerated()), id: \.element.id) { offset, module in
                            Button { navigate(module) } label: {
                                HStack {
                                    Image(systemName: module.symbol).foregroundStyle(StudioColor.blue).frame(width: 21)
                                    Text(module.title)
                                    Spacer()
                                    Text(module.category.localizedCapitalized).font(.caption).foregroundStyle(.secondary)
                                }.padding(.horizontal, 12).frame(height: 32)
                                    .background(index == offset ? StudioColor.blue.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }.id(module.id)
                        }
                    }.padding(6)
                }
                .onChange(of: index) { _, i in
                    if matches.indices.contains(i) { proxy.scrollTo(matches[i].id) }
                }
            }
        }.buttonStyle(.plain).frame(width: 435, height: 325).background(StudioColor.canvas)
            .onChange(of: query) { index = 0 }
            .onAppear { focused = true }
    }
}
