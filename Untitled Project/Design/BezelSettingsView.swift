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
                    LabeledContent("Copy to sequential queue", value: "⇧⌘C")
                    LabeledContent("Paste next from queue", value: "⇧⌘V")
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
        }.frame(width: 580, height: 560).padding(12)
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
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(22)
        }.frame(width: 600, height: 560).onAppear { permissions.refresh() }
    }
}

private struct PermissionDetails: View {
    @Bindable var permissions: PermissionCenter
    var body: some View {
        Form {
            Section {
                permissionRow(title: "Accessibility", detail: "Tile windows, highlight the active window, dim the background, and paste from Stack.", symbol: "figure.arms.open", granted: permissions.accessibility) { permissions.requestAccessibility() }
                permissionRow(title: "Screen Recording", detail: "Capture a region when you invoke Lens. Text recognition runs locally with Apple Vision.", symbol: "viewfinder", granted: permissions.screenCapture) { permissions.requestScreenCapture() }
            } footer: {
                Text("After changing permissions in System Settings, return to Bezel and refresh. macOS may ask you to restart the app.")
            }
            Section("Audio access") {
                Label("AirBridge asks when you start your first route.", systemImage: "waveform")
                Text("Select an emitting app and an output device, then choose Start Routing. Permission is managed by macOS under Screen & System Audio Recording.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Player connections") {
                Text("Connect Apple Music or Spotify in Aperture to allow current-track details and playback controls through macOS Automation. These connections are optional. Spotify album artwork is downloaded from Spotify’s image servers only when you enable it.")
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
            else { Button("Enable", action: action).controlSize(.small) }
        }.padding(.vertical, 7)
    }
}
