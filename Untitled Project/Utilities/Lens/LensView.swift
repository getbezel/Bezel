import SwiftUI

struct LensView: View {
    @Bindable var service: LensService

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Text, wherever you see it.").font(.title2.weight(.semibold))
                    Text("Select a region of your display. Lens recognizes its text locally and sends it straight to Stack.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Image(systemName: "viewfinder").font(.system(size: 36, weight: .light)).foregroundStyle(.tint)
            }
            HStack(spacing: 12) {
                Button { service.startCapture() } label: {
                    Label("Capture Text", systemImage: "text.viewfinder")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(service.isBusy)
                Text("⇧⌘2").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if service.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { service.cancelCapture() }
                }
            }
            if !service.hasScreenRecordingPermission {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Screen Recording permission").font(.headline)
                        Text("macOS requires permission to read pixels on your display. Captures are processed on your Mac and discarded after recognition.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Allow Screen Recording") { service.requestScreenRecordingPermission() }
                            Button("Open System Settings") { service.openPrivacySettings() }
                        }
                    }
                }
                .padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            if service.lastResult.isEmpty {
                ContentUnavailableView("Select. Recognize. Copy.", systemImage: "text.viewfinder", description: Text("Use Lens for a screenshot, presentation, video frame, or image containing text."))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                HStack {
                    Label("Last capture", systemImage: "text.alignleft").font(.headline)
                    Spacer()
                    Button("Copy Again", systemImage: "doc.on.doc") { service.copyResult() }
                }
                ScrollView {
                    Text(service.lastResult).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                }
                .frame(minHeight: 200).background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            }
            Text(service.statusMessage ?? service.phase.rawValue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}
