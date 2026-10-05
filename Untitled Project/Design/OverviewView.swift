import SwiftUI

struct OverviewView: View {
    @Bindable var model: BezelModel
    @Binding var showPermissions: Bool
    private let columns = [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)]
    private var filtered: [BezelModule] {
        BezelModule.allCases.filter {
            $0 != .overview && (model.search.isEmpty || "\($0.title) \($0.subtitle)".localizedCaseInsensitiveContains(model.search))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                hero
                HStack(spacing: 13) {
                    quickControl(title: model.monolith.isActive ? "In your flow" : "A moment of focus",
                                 value: model.monolith.isActive ? timerText : "25 minutes, just for you", symbol: "moon", tint: .purple) {
                        model.monolith.isActive ? model.monolith.stop() : model.monolith.start(minutes: 25)
                    }
                    quickControl(title: "Your temporary shelf", value: "\(model.shelf.count) items at hand", symbol: "tray", tint: .cyan) { model.shelf.show() }
                    quickControl(title: "A little extra energy", value: model.pulse.isActive ? "Your Mac is staying awake" : "Keep awake for an hour", symbol: "cup.and.saucer", tint: .orange) {
                        model.pulse.isActive ? model.pulse.stop() : model.pulse.start(minutes: 60)
                    }
                }
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        SmallSectionLabel(text: model.search.isEmpty ? "YOUR UTILITIES" : "SEARCH RESULTS")
                        Spacer()
                        Text("\(filtered.count) tools. One happy Mac.").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    LazyVGrid(columns: columns, spacing: 13) {
                        ForEach(filtered) { module in
                            Button { model.selection = module } label: {
                                BezelCard {
                                    VStack(alignment: .leading, spacing: 13) {
                                        HStack {
                                            ModuleIcon(module: module)
                                            Spacer()
                                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.quaternary)
                                        }
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack {
                                                Text(module.title).font(.system(size: 14, weight: .semibold))
                                                Spacer(minLength: 4)
                                                Text(model.status(for: module)).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                            }
                                            Text(module.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                                                .lineLimit(2).frame(height: 29, alignment: .top)
                                        }
                                    }
                                }.contentShape(RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain)
                                .help("Open \(module.title)")
                        }
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: model.search).frame(maxWidth: .infinity).padding(30)
                    }
                }
                if !model.permissions.accessibility {
                    HStack(spacing: 13) {
                        Image(systemName: "hand.raised").font(.system(size: 19)).foregroundStyle(.blue)
                            .frame(width: 38, height: 38).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("A few permissions. More possibilities.").font(.system(size: 12, weight: .medium))
                            Text("Choose what Bezel can access. You’re always in control.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Set Up") { showPermissions = true }.controlSize(.small)
                    }.padding(16).background(.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Image(systemName: "lock.shield").font(.system(size: 11))
                    Text("On your Mac. For your Mac. No account required.").font(.system(size: 10))
                    Spacer()
                    Text("BEZEL 1.0").font(.system(size: 9, weight: .medium)).tracking(1.3)
                }.foregroundStyle(.tertiary).padding(.top, 1)
            }.padding(28)
        }
    }
    private var timerText: String {
        String(format: "%02d:%02d remaining", model.monolith.remainingSeconds / 60, model.monolith.remainingSeconds % 60)
    }
    private var hero: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").font(.system(size: 10))
                    Text("LITTLE THINGS, BEAUTIFULLY DONE").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                }.foregroundStyle(.blue.opacity(0.8))
                Text("Less friction.\nMore flow.").font(.system(size: 30, weight: .semibold)).tracking(-0.8).lineSpacing(-2)
                Text("Eleven thoughtful upgrades.\nOne seamless workspace.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            }
            Spacer(minLength: 0)
            WorkspaceIllustration().frame(width: 275, height: 166).accessibilityHidden(true)
        }
        .padding(.horizontal, 27).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 17)
                .fill(LinearGradient(colors: [.blue.opacity(0.09), .cyan.opacity(0.025), .purple.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.blue.opacity(0.07), lineWidth: 1))
    }
    private func quickControl(title: String, value: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(value).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 15).frame(maxWidth: .infinity, minHeight: 64)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.055), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

private struct WorkspaceIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(.blue.opacity(0.065)).frame(width: 240, height: 147).rotationEffect(.degrees(-5)).offset(x: 4, y: 8)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { _ in Circle().fill(.gray.opacity(0.25)).frame(width: 5, height: 5) }
                    Spacer()
                    Capsule().fill(.black.opacity(0.85)).frame(width: 62, height: 12).offset(x: -15, y: -3)
                    Spacer()
                }.padding(9)
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 3).fill(.blue.opacity(0.22)).frame(height: 15)
                        ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 2).fill(.gray.opacity(0.11)).frame(height: 5) }
                        Spacer()
                    }.frame(width: 43).padding(7).frame(maxHeight: .infinity).background(.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(.gray.opacity(0.14)).frame(width: 68, height: 6)
                        HStack(spacing: 6) {
                            miniTile("square.3.layers.3d", color: .blue)
                            miniTile("waveform", color: .orange)
                            miniTile("moon", color: .purple)
                        }
                        HStack(spacing: 6) {
                            miniTile("tray", color: .cyan)
                            miniTile("viewfinder", color: .indigo)
                            miniTile("cup.and.saucer", color: .orange)
                        }
                    }.padding(.trailing, 4)
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }.frame(width: 231, height: 145)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.07), radius: 12, y: 9)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("A little more capable.").font(.system(size: 9, weight: .medium))
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.06), radius: 7, y: 3)
                .offset(x: 32, y: 69)
        }
    }
    private func miniTile(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color)
            .frame(width: 44, height: 34).background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 5))
    }
}
