import SwiftUI

struct NotchReadingView: View {
    let service: ApertureService
    private var reader: NotchTeleprompter { service.reader }

    var body: some View {
        VStack(spacing: 4) {
            if reader.script.lines.indices.contains(reader.line) {
                let lines = reader.script.lines
                Text(lines[reader.line].text)
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityLabel("Current line: \(lines[reader.line].text)")
                Text(reader.line + 1 < lines.count ? lines[reader.line + 1].text : " ")
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.60))
            }
            HStack(spacing: 12) {
                Menu {
                    Section("Scrolling") {
                        ForEach(NotchTeleprompter.Mode.allCases, id: \.self) { mode in
                            Button {
                                reader.choose(mode)
                            } label: {
                                if reader.mode == mode { Label(mode.rawValue, systemImage: "checkmark") }
                                else { Text(mode.rawValue) }
                            }
                        }
                    }
                    if reader.mode == .timed {
                        Section("Words per minute") {
                            ForEach([90, 120, 150, 180, 210, 240], id: \.self) { rate in
                                Button {
                                    reader.setSpeed(rate)
                                } label: {
                                    if reader.speed == rate { Label("\(rate)", systemImage: "checkmark") }
                                    else { Text("\(rate)") }
                                }
                            }
                        }
                    }
                } label: {
                    Label(reader.mode == .timed ? "\(reader.speed) WPM" : "Voice",
                          systemImage: reader.mode == .timed ? "metronome" : "mic")
                }.menuStyle(.borderlessButton).fixedSize().help("Scrolling mode and speed")
                Spacer(minLength: 4)
                control("chevron.up", "Previous line (↑)") { reader.step(-1) }.disabled(reader.line == 0)
                control(reader.playing ? "pause.fill" : "play.fill",
                        reader.finished ? "Read again (Space)" : (reader.playing ? "Pause (Space)" : "Resume (Space)")) {
                    reader.toggle()
                }
                control("chevron.down", "Next line (↓)") { reader.step(1) }
                    .disabled(reader.line + 1 >= reader.script.lines.count)
                Spacer(minLength: 4)
                Text("\(reader.line + 1) / \(reader.script.lines.count)").monospacedDigit().foregroundStyle(.secondary)
                control("xmark", "Close teleprompter (Esc)") { service.finishReading() }
            }.font(.caption).padding(.top, 3)
            if let message = reader.message {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2).help(message)
            } else if reader.preparing {
                Text("Connecting to microphone…").font(.caption2).foregroundStyle(.secondary)
            } else if reader.finished {
                Text("End of script").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.65)
        .padding(.horizontal, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func control(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 25, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}

struct ScriptComposer: View {
    let service: ApertureService
    @State private var expanded = false
    @State private var draft = ""

    var body: some View {
        GroupBox {
            DisclosureGroup("Notch teleprompter", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste a script below, or choose Read at Notch on a text item in Workspace.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $draft)
                        .font(.body).frame(minHeight: 75, maxHeight: 150).padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                        .accessibilityLabel("Teleprompter script")
                    HStack {
                        Button("Read at Notch", systemImage: "play.fill") { service.readAtNotch(draft) }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if service.reader.active {
                            Button("Close teleprompter") { service.finishReading() }
                        }
                    }
                    Text("Click the reader for keyboard controls. Space pauses, ↑ and ↓ step a line, and Esc closes. Choose Follow my voice in the speed menu for on-device speech tracking.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.padding(6)
        }
    }
}
