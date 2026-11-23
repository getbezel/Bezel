import SwiftUI

struct ContentView: View {
    @Bindable var model: BezelModel
    @State private var showPermissions = false
    @State private var showSignIn = false
    @State private var presentedSignIn = false
    @State private var showSearch = false
    @State private var hoveredHomeModule: BezelModule?
    @State private var inspectedItem: UUID?
    @State private var collapsedGroups: Set<String> = []
    private let groups = ["CAPTURE & COLLECT", "WORK & FOCUS", "SYSTEM"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 186)
                Divider()
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    GeometryReader { viewport in
                        VStack(alignment: .leading, spacing: 0) {
                            if BezelModule.utilities.contains(model.selection) {
                                Label(model.selection.title, systemImage: model.selection.symbol)
                                    .font(.system(size: 27, weight: .medium)).tracking(-0.8)
                                    .padding(.horizontal, 24).padding(.top, 16)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            moduleContent
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .scrollContentBackground(.hidden)
                                .buttonStyle(BezelActionStyle())
                                .controlSize(.small)
                                .groupBoxStyle(StudioGroupBoxStyle())
                                .environment(\.studioAppearance, true)
                        }
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                        .clipped()
                    }
                }
                .onPreferenceChange(StudioHoverAccent.self) { hoveredHomeModule = $0 }
                .background {
                    StudioHeaderBackdrop(module: model.selection, hovered: hoveredHomeModule, metadata: model.nowPlaying)
                }
            }
            Divider()
            StudioSessionBar(model: model)
        }
        .background(StudioColor.rail)
        .tint(StudioColor.blue)
        .sheet(isPresented: $showPermissions) { PermissionSheet(permissions: model.permissions) }
        .sheet(isPresented: $showSignIn) { BezelSignInPrompt(account: model.account) }
        .sheet(isPresented: $showSearch) {
            StudioSearch { module in
                model.selection = module
                showSearch = false
            }
        }
        .onAppear { model.isStudioVisible = true }
        .onDisappear { model.isStudioVisible = false }
        .task(id: model.account.isSignedIn) {
            model.start()
            if model.account.isSignedIn {
                showSignIn = false
                presentedSignIn = false
            } else { presentSignInIfNeeded() }
        }
        .onChange(of: showPermissions) { _, visible in
            if !visible { presentSignInIfNeeded() }
        }
    }

    private func presentSignInIfNeeded() {
        guard !model.account.isSignedIn, !presentedSignIn, !showPermissions else { return }
        presentedSignIn = true
        showSignIn = true
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("Bezel", systemImage: "rectangle.roundedtop").foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
            Text(model.selection.title).fontWeight(.medium)
            Spacer()
            if let shortcut = model.selection.shortcut {
                Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Button { showSearch = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    Text("Find a utility")
                    Text("⌘ K").font(.caption.monospaced()).foregroundStyle(.secondary)
                }.padding(.horizontal, 9).padding(.vertical, 5).studioSurface(radius: 5)
            }.keyboardShortcut("k").accessibilityLabel("Find a utility")
            Button { showPermissions = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 26, height: 25)
            }.accessibilityLabel("Permissions and Setup").help("Permissions and setup")
        }
        .buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 21).frame(height: 39)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text("Bezel").font(.system(size: 19, weight: .semibold)).tracking(-0.7)
            } icon: { Image(systemName: "square.stack.3d.up.fill").foregroundStyle(StudioColor.blue) }
                .padding(.leading, 16).frame(height: 44)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    navRow(.overview)
                    navRow(.workspace)
                    ForEach(groups, id: \.self) { group in
                        let collapsed = collapsedGroups.contains(group)
                        Button {
                            if collapsed { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
                        } label: {
                            HStack {
                                Text(group.localizedCapitalized)
                                Spacer()
                                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8))
                            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 9).padding(.top, 10).padding(.bottom, 4).contentShape(Rectangle())
                        }
                        if !collapsed {
                            ForEach(BezelModule.utilities.filter { $0.category == group }) { navRow($0) }
                        }
                    }
                }.padding(.horizontal, 8)
            }
            Divider()
            HStack(spacing: 7) {
                Circle().fill(StudioColor.blue).frame(width: 5, height: 5)
                Text("\(model.activeCount) active").font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.accessibilityLabel("Settings").help("Settings")
            }.padding(.horizontal, 16).frame(height: 33)
        }.buttonStyle(.plain)
    }

    private func navRow(_ module: BezelModule) -> some View {
        let selected = model.selection == module
        return Button { model.selection = module } label: {
            HStack(spacing: 10) {
                Image(systemName: module.symbol).frame(width: 17)
                    .foregroundStyle(selected ? StudioColor.blue : .secondary)
                Text(module.title).fontWeight(selected ? .semibold : .regular)
                Spacer()
            }.font(.system(size: 12)).padding(.horizontal, 9).frame(height: 25)
                .background(selected ? StudioColor.blue.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(module.title)
        .accessibilityIdentifier("studio.nav." + module.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var moduleContent: some View {
        switch model.selection {
        case .overview:
            OverviewView(model: model, showPermissions: $showPermissions) { id in
                inspectedItem = id
                model.selection = .workspace
            }
        case .workspace: StudioWorkspace(model: model, selection: $inspectedItem)
        case .stack: StackView(service: model.stack)
        case .airBridge: AirBridgeView(service: model.airBridge)
        case .aperture: ApertureView(service: model.aperture, metadata: model.nowPlaying, focusStatus: model.focusStatus)
        case .grid: GridView(service: model.grid, menuManager: model.menuShelf.manager)
        case .scope: ScopeView(service: model.scope)
        case .monolith: MonolithView(service: model.monolith)
        case .shelf: ShelfView(service: model.shelf)
        case .lens: LensView(service: model.lens)
        case .dragWheel: DragWheelView(service: model.dragWheel)
        case .tether: TetherView(service: model.tether)
        case .pulse: PulseView(service: model.pulse)
        case .border: BorderView(service: model.border)
        case .cleaning: CleaningView(service: model.cleaning)
        }
    }
}
