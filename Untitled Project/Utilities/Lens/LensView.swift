import SwiftUI
import AppKit

struct LensView: View {
    @Bindable var service: LensService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    ModuleIcon(module: .lens, size: 56)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Text, wherever you see it.").font(.title2.weight(.semibold))
                        Text("Select part of your display. Lens recognizes the text locally and copies it straight to Stack.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Button { service.startCapture() } label: { Label("Capture Text", systemImage: "text.viewfinder") }
                        .buttonStyle(BezelActionStyle(prominent: true)).controlSize(.large).disabled(service.isBusy)
                    Text("⇧⌘2").font(.callout.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if service.isBusy {
                        ProgressView().controlSize(.small)
                        Text(service.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { service.cancelCapture() }
                    }
                }
                if let message = service.statusMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(15).bezelSurface(cornerRadius: 18)
                }
                if !service.hasScreenRecordingPermission || service.runtimeBuild.diskChanged {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Screen Recording permission", systemImage: "lock.shield").font(.headline)
                            Text("Allow Bezel to read pixels on your display. Recognition stays on this Mac.")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("Allow Screen Recording") { service.requestScreenRecordingPermission() }
                                Button("Open System Settings") { service.openPrivacySettings() }
                                Button("Refresh Access") { service.refreshPermission() }
                            }
                            Text(service.runtimeBuild.accessHelp).font(.caption).foregroundStyle(.secondary)
                            Text(service.runtimeBuild.appPath).font(.caption.monospaced()).textSelection(.enabled)
                            HStack {
                                Button("Show This App in Finder") { service.runtimeBuild.showInFinder() }
                                Button("Quit Bezel") { NSApp.terminate(nil) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
                if service.lastResult.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.viewfinder").font(.system(size: 46, weight: .light)).foregroundStyle(.tint)
                        Text("Select. Recognize. Copy.").font(.title3.weight(.semibold))
                        Text("Screenshots, presentations, video frames, and images.\nDrag a selection to capture only the text you need.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 56)
                    .bezelSurface(cornerRadius: 26, tint: .indigo)
                } else {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Label("Last capture", systemImage: "text.alignleft").font(.headline)
                                Spacer()
                                Button("Copy Again", systemImage: "doc.on.doc") { service.copyResult() }
                            }
                            Text(service.lastResult).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(12)
                    }
                }
                if service.statusMessage == nil && !service.isBusy {
                    Label(service.phase.rawValue, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { service.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in service.refreshPermission() }
    }
}
