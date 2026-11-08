import SwiftUI
import AppKit

struct BezelSettingsView: View {
    @Bindable var model: BezelModel
    var body: some View {
        TabView {
            Form {
                Section("Startup") {
                    Toggle("Launch Bezel at login", isOn: Binding(get: { model.permissions.loginEnabled }, set: { model.permissions.setLoginEnabled($0) }))
                    if let error = model.permissions.loginError { Text(error).foregroundStyle(.red).font(.caption) }
                    Text("Bezel continues in the menu bar when you close its window.").foregroundStyle(.secondary)
                }
                Section("Background utilities") {
                    Toggle("Clipboard history", isOn: $model.stack.isEnabled)
                    Toggle("File shelf at screen edges", isOn: $model.shelf.isEnabled)
                    Toggle("DragWheel file conversions", isOn: $model.dragWheel.isEnabled)
                    Toggle("Aperture overlay", isOn: $model.aperture.isEnabled)
                }
                Section("Menu icons") { MenuBarManagerControls(manager: model.menuShelf.manager) }
                Section {
                    ForEach(BezelModule.allCases.filter { $0 != .overview }) { module in
                        Toggle(module.title, isOn: Binding(get: { model.menuShelf.pinned.contains(module) }, set: { _ in model.menuShelf.togglePin(module) }))
                    }
                } header: { Text("Menu bar shelf") } footer: {
                    Text("Pin Bezel utilities in the menu bar popover. The separate chevron manages other apps’ menu icons.")
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            PermissionDetails(permissions: model.permissions)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            Form {
                Section {
                    Toggle("Enable global shortcuts", isOn: Binding(get: { model.shortcuts.isEnabled }, set: { enabled in
                        UserDefaults.standard.set(enabled, forKey: "shortcuts.enabled")
                        enabled ? model.shortcuts.start() : model.shortcuts.stop()
                    }))
                }
                Section("Capture & collect") {
                    LabeledContent("Open Stack", value: "⌥⌘V")
                    LabeledContent("Copy selection to Quick Clips", value: "⇧⌘C")
                    LabeledContent("Choose a clip to paste", value: "⇧⌘V")
                    LabeledContent("Capture text with Lens", value: "⇧⌘2")
                }
                Section {
                    LabeledContent("Left half", value: "⌃⌥←")
                    LabeledContent("Right half", value: "⌃⌥→")
                } header: { Text("Arrange windows") } footer: { Text("Window actions and pasting require Accessibility access. Shortcuts apply across apps while Bezel is running.") }
                if !model.shortcuts.failures.isEmpty {
                    Section("Unavailable shortcuts") {
                        ForEach(model.shortcuts.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Shortcuts", systemImage: "keyboard") }
            BezelLegalView().tabItem { Label("About & Legal", systemImage: "info.circle") }
        }.frame(width: 580, height: 560).padding(12)
            .scrollContentBackground(.hidden).background(BezelBackdrop())
            .buttonStyle(BezelActionStyle())
            .onAppear { model.permissions.refresh() }
    }
}

struct PermissionSheet: View {
    @Bindable var permissions: PermissionCenter
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Make yourself at home.").font(.title2.weight(.semibold))
                    Text("Enable only the access you need.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Close setup")
            }.padding(25)
            PermissionDetails(permissions: permissions)
            HStack {
                Button("Refresh") { permissions.refresh() }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(BezelActionStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }.padding(22)
        }.frame(width: 600, height: 560)
            .scrollContentBackground(.hidden).background(BezelBackdrop())
            .buttonStyle(BezelActionStyle()).onAppear { permissions.refresh() }
    }
}

private struct PermissionDetails: View {
    @Bindable var permissions: PermissionCenter
    var body: some View {
        Form {
            Section {
                permissionRow(title: "Accessibility", detail: "Tile windows, highlight the active window, and dim the background.", symbol: "figure.arms.open", granted: permissions.accessibility) { permissions.requestAccessibility() }
                permissionRow(title: "Keyboard Commands", detail: "Copy selections and paste Quick Clips into another app. macOS checks this separately from window access.", symbol: "keyboard", granted: permissions.keyboardEvents) { permissions.requestKeyboardEvents() }
                Text(permissions.accessibilityDiagnostic).font(.caption).foregroundStyle(.secondary)
                Button("Check Access") { permissions.refresh() }
                permissionRow(title: "Screen Recording", detail: "Capture a region when you invoke Lens. Text recognition runs locally with Apple Vision.", symbol: "viewfinder", granted: permissions.screenCapture) { permissions.requestScreenCapture() }
            } footer: {
                Text("The button opens macOS settings; it cannot grant access itself. Bezel checks access automatically when you return.")
            }
            Section("This running app") {
                Text(permissions.runtimeBuild.appPath).font(.caption.monospaced()).textSelection(.enabled)
                Text(permissions.runtimeBuild.accessHelp).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Show This App in Finder") { permissions.runtimeBuild.showInFinder() }
                    Button("Quit Bezel") { NSApp.terminate(nil) }
                }
            }
            Section("Audio access") {
                Label("AirBridge asks when you start your first route.", systemImage: "waveform")
                Text("Select an emitting app and an output device, then choose Start Routing. Permission is managed by macOS under Screen & System Audio Recording.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Player connections") {
                Text("Connect Apple Music, Spotify or YouTube Music in Chrome or Brave in Aperture to allow current-track details and playback controls through macOS Automation. These connections are optional. Spotify and YouTube Music artwork is downloaded only when its respective option is enabled. Browser connections read page content only from music.youtube.com and needs Allow JavaScript from Apple Events.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your data stays here") {
                Text("Clipboard history is held in memory, limited to 50 entries and 64 MB. Marked passwords and concealed or transient clipboard types are skipped. Quitting Bezel clears its history. Unmarked sensitive text may still be captured; pause Stack when needed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Shelf holds references to files. Removing an item from Shelf does not delete the original file.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func permissionRow(title: String, detail: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.blue).frame(width: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if granted { Label("Allowed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            else { Button("Open Settings…", action: action).controlSize(.small) }
        }.padding(.vertical, 7)
    }
}
