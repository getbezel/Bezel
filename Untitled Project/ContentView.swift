import SwiftUI

struct ContentView: View {
    @Bindable var model: BezelModel
    @State private var showPermissions = false
    @State private var showSignIn = false
    @State private var presentedSignIn = false
    private let categories = ["CAPTURE & COLLECT", "WORK & FOCUS", "SYSTEM"]

    private var navigationSelection: Binding<BezelModule?> {
        Binding(get: { model.selection }, set: { if let value = $0 { model.selection = value } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: navigationSelection) {
                Label { Text("Overview") } icon: { Image(systemName: BezelModule.overview.symbol) }
                    .tag(BezelModule.overview)
                ForEach(categories, id: \.self) { category in
                    let modules = BezelModule.allCases.filter { $0.category == category && matches($0) }
                    if !modules.isEmpty {
                        Section(category.localizedCapitalized) {
                            ForEach(modules) { module in
                                HStack(spacing: 10) {
                                    ModuleIcon(module: module, size: 26)
                                    Text(module.title)
                                    Spacer(minLength: 0)
                                    if module == .stack, !model.stack.history.isEmpty {
                                        Text("\(model.stack.history.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 3).tag(module)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationTitle("Bezel")
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
            .searchable(text: $model.search, placement: .sidebar, prompt: "Find a utility")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(model.activeCount > 0 ? Color.green : .secondary).frame(width: 6, height: 6)
                    Text("\(model.activeCount) active").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
                }.padding(.horizontal, 14).padding(.vertical, 11)
                .bezelGlass(cornerRadius: 100).padding(.horizontal, 12).padding(.bottom, 12)
            }
        } detail: {
            // A finite viewport keeps a page's ideal size from resizing or displacing the window.
            GeometryReader { viewport in
                moduleContent
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                    .clipped()
            }
            .background(BezelBackdrop(tint: model.selection.tint))
            .scrollContentBackground(.hidden)
            .buttonStyle(BezelActionStyle())
            .navigationTitle(model.selection.title)
            .navigationSubtitle(model.selection.subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showPermissions = true } label: { Label("Permissions and Setup", systemImage: "slider.horizontal.3") }
                        .help("Permissions and setup")
                }
                if let shortcut = model.selection.shortcut {
                    ToolbarItem(placement: .status) {
                        Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showPermissions) { PermissionSheet(permissions: model.permissions) }
        .sheet(isPresented: $showSignIn) { BezelSignInPrompt(account: model.account) }
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

    private func matches(_ module: BezelModule) -> Bool {
        model.search.isEmpty || "\(module.title) \(module.subtitle)".localizedCaseInsensitiveContains(model.search)
    }

    @ViewBuilder private var moduleContent: some View {
        switch model.selection {
        case .overview: OverviewView(model: model, showPermissions: $showPermissions)
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
