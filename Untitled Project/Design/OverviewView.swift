import SwiftUI

struct OverviewView: View {
    @Bindable var model: BezelModel
    @Binding var showPermissions: Bool
    @State private var targetedModule: BezelModule?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 16)]
    private var filtered: [BezelModule] {
        model.dashboard.order.ids.compactMap(BezelModule.init(rawValue:)).filter {
            $0 != .overview && (model.search.isEmpty || "\($0.title) \($0.subtitle)".localizedCaseInsensitiveContains(model.search))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                hero
                BezelGlassGroup(spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 16) {
                        quickControl(title: model.monolith.isActive ? "In your flow" : "A moment of focus",
                                     value: model.monolith.isActive ? timerText : "25 minutes, just for you", symbol: "moon", tint: .purple) {
                            model.monolith.isActive ? model.monolith.stop() : model.monolith.start(minutes: 25)
                        }
                        quickControl(title: "Your temporary shelf", value: "\(model.shelf.count) items at hand", symbol: "tray", tint: .cyan) { model.shelf.show() }
                        quickControl(title: "A little extra energy", value: model.pulse.isActive ? "Your Mac is staying awake" : "Keep awake for an hour", symbol: "cup.and.saucer", tint: .orange) {
                            model.pulse.isActive ? model.pulse.stop() : model.pulse.start(minutes: 60)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        SmallSectionLabel(text: model.search.isEmpty ? "YOUR UTILITIES" : "SEARCH RESULTS")
                        Spacer()
                        Menu {
                            Text("Drag a card onto another to move it.")
                            Button("Reset Layout", systemImage: "arrow.counterclockwise") {
                                rearrange { model.dashboard.reset() }
                            }.disabled(model.dashboard.isDefault)
                        } label: {
                            Label("Arrange", systemImage: "slider.horizontal.3")
                                .font(.caption)
                        }.menuStyle(.borderlessButton).fixedSize()
                        .help("Rearrange utility cards, or reset their order")
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { module in
                            UtilityCard(module: module, status: model.status(for: module), targeted: targetedModule == module) { model.selection = module }
                                .draggable(DashboardModuleTransfer(id: module.rawValue)) {
                                    HStack(spacing: 10) {
                                        ModuleIcon(module: module, size: 28)
                                        Text(module.title).font(.callout.weight(.medium))
                                    }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                                }
                                .dropDestination(for: DashboardModuleTransfer.self) { items, _ in
                                    targetedModule = nil
                                    guard items.count == 1, let source = items.first?.id,
                                          model.dashboard.order.ids.contains(source), source != module.rawValue else { return false }
                                    rearrange { model.dashboard.move(source, onto: module.rawValue) }
                                    return true
                                } isTargeted: { targeted in
                                    if targeted { targetedModule = module }
                                    else if targetedModule == module { targetedModule = nil }
                                }
                                .contextMenu {
                                    Button("Open \(module.title)") { model.selection = module }
                                    Divider()
                                    Button("Move Earlier", systemImage: "arrow.up") { move(module, by: -1) }
                                        .disabled(model.dashboard.order.ids.first == module.rawValue)
                                    Button("Move Later", systemImage: "arrow.down") { move(module, by: 1) }
                                        .disabled(model.dashboard.order.ids.last == module.rawValue)
                                }
                                .accessibilityAction(named: "Move earlier") { move(module, by: -1) }
                                .accessibilityAction(named: "Move later") { move(module, by: 1) }
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
                            Text("A few permissions. More possibilities.").font(.callout.weight(.medium))
                            Text("Choose what Bezel can access. You’re always in control.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Set Up") { showPermissions = true }.controlSize(.small)
                    }.padding(16).background(.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Spacer()
                    Text("Bezel 1.0").font(.caption)
                }.foregroundStyle(.tertiary).padding(.top, 1)
            }.padding(28)
                .frame(maxWidth: 1140, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
    private func rearrange(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { action() }
    }
    private func move(_ module: BezelModule, by delta: Int) {
        rearrange { model.dashboard.nudge(module.rawValue, by: delta) }
    }
    private var timerText: String {
        String(format: "%02d:%02d remaining", model.monolith.remainingSeconds / 60, model.monolith.remainingSeconds % 60)
    }
    private var hero: some View {
        WelcomeHeader(account: model.account, activeCount: model.activeCount)
    }
    private func quickControl(title: String, value: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 15).frame(maxWidth: .infinity, minHeight: 76)
                .modifier(DashboardCardSurface(tint: tint))
        }.buttonStyle(DashboardCardPressStyle())
    }
}

private struct UtilityCard: View {
    let module: BezelModule
    let status: String
    var targeted = false
    let action: () -> Void
    @State private var hovered = false
    @State private var iconPulse = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ModuleIcon(module: module, size: 40)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : iconPulse)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(status).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Image(systemName: "hand.draw").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .opacity(hovered || targeted ? 1 : 0).accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(module.title).font(.headline)
                    Text(module.subtitle).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).frame(height: 36, alignment: .top)
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(DashboardCardSurface(tint: module.tint, targeted: targeted))
        }
        .buttonStyle(DashboardCardPressStyle())
        .onHover { value in hovered = value; if value { iconPulse += 1 } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        .help("Open \(module.title). Drag to rearrange; right-click for more options.")
    }
}
