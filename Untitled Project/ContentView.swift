import SwiftUI

struct ContentView: View {
    @Bindable var model: BezelModel
    @State private var showPermissions = false
    private let categories = ["CAPTURE & COLLECT", "WORK & FOCUS", "SYSTEM"]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11).fill(.primary).frame(width: 37, height: 37)
                        RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor)).frame(width: 24, height: 18)
                        Capsule().fill(.primary).frame(width: 13, height: 6).offset(y: -7)
                    }.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bezel").font(.system(size: 23, weight: .semibold, design: .rounded))
                        Text("A LITTLE MORE MAC").font(.system(size: 8, weight: .medium)).tracking(1.7).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 23)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Find a utility", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).help("Clear search")
                    }
                }.padding(9).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 15).padding(.bottom, 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        sidebarRow(.overview)
                        ForEach(categories, id: \.self) { category in
                            let modules = BezelModule.allCases.filter { $0.category == category && matches($0) }
                            if !modules.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    SmallSectionLabel(text: category).padding(.leading, 13).padding(.bottom, 4)
                                    ForEach(modules) { sidebarRow($0) }
                                }
                            }
                        }
                    }.padding(.horizontal, 10)
                }
                VStack(spacing: 13) {
                    Divider()
                    HStack(spacing: 7) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("\(model.activeCount) utilities active").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        SettingsLink { Image(systemName: "gearshape").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings")
                    }
                    Text("Made for the way you Mac.").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(20)
            }
            .frame(minWidth: 230, maxWidth: 230)
            .navigationSplitViewColumnWidth(230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.selection.title).font(.system(size: 27, weight: .semibold))
                        Text(model.selection.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let shortcut = model.selection.shortcut {
                        Text(shortcut).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .padding(7).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Button { showPermissions = true } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 30, height: 30)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help("Permissions and setup")
                }.padding(.horizontal, 30).padding(.top, 34).padding(.bottom, 24)
                Divider().opacity(0.5)
                moduleContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $showPermissions) { PermissionSheet(permissions: model.permissions) }
    }

    private func matches(_ module: BezelModule) -> Bool {
        model.search.isEmpty || "\(module.title) \(module.subtitle)".localizedCaseInsensitiveContains(model.search)
    }
    private func sidebarRow(_ module: BezelModule) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { model.selection = module }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: module.symbol).font(.system(size: 15)).frame(width: 20)
                    .foregroundStyle(model.selection == module ? Color.accentColor : .secondary)
                Text(module.title).font(.system(size: 13, weight: model.selection == module ? .semibold : .regular))
                Spacer()
                if module == .stack && !model.stack.history.isEmpty {
                    Text("\(model.stack.history.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                if model.selection == module {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3, height: 14)
                }
            }.padding(.horizontal, 12).frame(height: 34)
                .background(model.selection == module ? Color.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(model.selection == module ? .isSelected : [])
    }
    @ViewBuilder private var moduleContent: some View {
        switch model.selection {
        case .overview: OverviewView(model: model, showPermissions: $showPermissions)
        case .stack: StackView(service: model.stack)
        case .airBridge: AirBridgeView(service: model.airBridge)
        case .aperture: ApertureView(service: model.aperture, metadata: model.nowPlaying)
        case .grid: GridView(service: model.grid, menuManager: model.menuShelf.manager)
        case .scope: ScopeView(service: model.scope)
        case .monolith: MonolithView(service: model.monolith)
        case .shelf: ShelfView(service: model.shelf)
        case .lens: LensView(service: model.lens)
        case .tether: TetherView(service: model.tether)
        case .pulse: PulseView(service: model.pulse)
        case .border: BorderView(service: model.border)
        }
    }
}
