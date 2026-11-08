import SwiftUI
import AppKit

struct BezelMenuView: View {
    @Bindable var model: BezelModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "rectangle.topthird.inset.filled").font(.title3)
                Text("Bezel").font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                StatusPill(title: "\(model.activeCount) active", color: .green)
            }
            BezelGlassGroup(spacing: 12) {
                HStack(spacing: 9) {
                    menuAction("Clipboard", symbol: "square.3.layers.3d", tint: .blue) { model.stack.showHUD() }
                    menuAction("Capture", symbol: "viewfinder", tint: .indigo) { model.lens.startCapture() }
                    menuAction("Shelf", symbol: "tray", tint: .cyan) { model.shelf.show() }
                }
            }
            Divider()
            Toggle(isOn: Binding(get: { model.monolith.isActive }, set: { $0 ? model.monolith.start(minutes: 25) : model.monolith.stop() })) {
                Label(model.monolith.isActive ? "Focus · \(model.monolith.remainingSeconds / 60)m left" : "Focus for 25 minutes", systemImage: "moon")
            }
            Toggle(isOn: Binding(get: { model.pulse.isActive }, set: { $0 ? model.pulse.start() : model.pulse.stop() })) {
                Label("Keep awake", systemImage: "cup.and.saucer")
            }
            Toggle("Aperture", systemImage: "rectangle.topthird.inset.filled", isOn: $model.aperture.isEnabled)
            Button {
                model.selection = .dragWheel
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.dragWheel.chooseFiles()
            } label: {
                Label(model.dragWheel.activeCount > 0 ? "DragWheel · \(model.dragWheel.activeCount) converting" : "Convert Files…", systemImage: "arrow.triangle.2.circlepath")
            }.disabled(!model.dragWheel.isEnabled)
            Divider()
            DisclosureGroup("Your utility shelf", isExpanded: $model.menuShelf.isExpanded) {
                VStack(spacing: 2) {
                    ForEach(model.menuShelf.pinned) { module in
                        Button {
                            model.selection = module
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                        } label: {
                            HStack {
                                Image(systemName: module.symbol).foregroundStyle(module.tint).frame(width: 18)
                                Text(module.title)
                                Spacer()
                                Text(model.status(for: module)).foregroundStyle(.tertiary).font(.caption)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, 6)
            }
            HStack {
                Button("Open Bezel") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Bezel")
            }.controlSize(.small)
        }.padding(22).frame(width: 350).toggleStyle(.switch).controlSize(.small)
            .background(BezelBackdrop()).buttonStyle(BezelActionStyle())
    }
    private func menuAction(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(tint)
                Text(title).font(.caption.weight(.medium))
            }.frame(maxWidth: .infinity).frame(height: 67)
                .bezelSurface(cornerRadius: 20)
        }.buttonStyle(.plain)
    }
}
