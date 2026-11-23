import SwiftUI

struct OverviewView: View {
    @Bindable var model: BezelModel
    @Binding var showPermissions: Bool
    let inspect: (UUID?) -> Void
    @State private var targetedModule: BezelModule?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = [GridItem(.adaptive(minimum: 182), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WelcomeHeader(account: model.account)
                StudioDesk(model: model, inspect: inspect)
                Text("Quick actions").font(.headline)
                HStack(spacing: 8) {
                    Button("Capture text", systemImage: "viewfinder") {
                        model.selection = .lens
                        model.lens.startCapture()
                    }.buttonStyle(BezelActionStyle(prominent: true))
                    Button("Open Shelf", systemImage: "tray") { model.shelf.show() }
                    Button(model.monolith.isActive ? "End focus" : "Start focus", systemImage: "moon") {
                        if model.monolith.isActive { model.monolith.stop() }
                        else {
                            model.monolith.start()
                            if !model.monolith.isActive { model.selection = .monolith }
                        }
                    }
                    Button(model.pulse.isActive ? "End keep awake" : "Keep awake", systemImage: "cup.and.saucer") {
                        if model.pulse.isActive { model.pulse.stop() } else { model.pulse.start(minutes: 60) }
                        if model.pulse.lastError != nil { model.selection = .pulse }
                    }.help("Toggle a one-hour keep-awake session")
                }
                Divider()
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("Your utilities").font(.headline)
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
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.dashboard.order.ids.compactMap(BezelModule.init(rawValue:))) { module in
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
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    ModuleIcon(module: module, size: 28)
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
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .studioSurface()
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(StudioColor.blue.opacity(targeted ? 0.75 : hovered ? 0.3 : 0)).allowsHitTesting(false))
        }
        .buttonStyle(DashboardCardPressStyle())
        .onHover { value in hovered = value; if value { iconPulse += 1 } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        .help("Open \(module.title). Drag to rearrange; right-click for more options.")
    }
}
