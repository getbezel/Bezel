import SwiftUI
import AppKit

struct CleaningView: View {
    @Bindable var service: CleaningService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "keyboard").font(.system(size: 30, weight: .light)).foregroundStyle(.mint)
                    Text("A clean slate.").font(.system(size: 30, weight: .medium))
                    Text("Wipe your keyboard, trackpad, and displays without accidental typing or clicks. Cleaning mode covers every connected display in black.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Start Cleaning Mode", systemImage: "sparkles") { service.start() }
                            .buttonStyle(BezelActionStyle(prominent: true)).controlSize(.large)
                            .disabled(service.isActive)
                        Spacer()
                        Picker("Automatic exit", selection: $service.durationMinutes) {
                            ForEach([1, 2, 3, 5], id: \.self) { Text("\($0) minutes").tag($0) }
                        }.fixedSize().disabled(service.isActive)
                    }
                }.padding(26).frame(maxWidth: .infinity, alignment: .leading).bezelSurface(cornerRadius: 22)
                VStack(alignment: .leading, spacing: 20) {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hold Escape to finish").font(.callout.weight(.medium))
                            Text("Hold the Esc key for two seconds. A progress ring shows when input will return.").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "escape").frame(width: 26) }
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("An automatic way out").font(.callout.weight(.medium))
                            Text("The shield ends after your chosen duration. ⌘⌥Esc exits immediately and keeps macOS Force Quit available.").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "timer").frame(width: 26) }
                    Text("Accessibility access is required. Power, Touch ID, and other hardware controls remain managed by macOS. Cleaning mode also ends on sleep or a system session change.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).bezelSurface(cornerRadius: 22)
                if let failure = service.lastFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                } else if let status = service.lastStatus {
                    Label(status, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Cleaning")
        .alert("Cleaning mode", isPresented: Binding(
            get: { service.lastError != nil }, set: { if !$0 { service.lastError = nil } }
        )) {
            Button("Accessibility Settings…") {
                openSettings("Privacy_Accessibility")
            }
            Button("Input Monitoring Settings…") {
                openSettings("Privacy_ListenEvent")
            }
            Button("OK", role: .cancel) { service.lastError = nil }
        } message: { Text(service.lastError ?? "") }
    }
    private func openSettings(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") {
            NSWorkspace.shared.open(url)
        }
    }
}
