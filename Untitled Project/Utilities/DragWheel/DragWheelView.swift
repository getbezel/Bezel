import SwiftUI
import AppKit

struct DragWheelView: View {
    @Bindable var service: DragWheelService
    @State private var isTargeted = false
    @State private var targetFormat = "png"

    private var targets: [String] { DragWheelService.commonTargets(service.selectedFiles) }
    private func missing(_ target: String) -> String? {
        service.selectedFiles.lazy.compactMap { DWConverter.missingRequirement(for: $0, to: target) }.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 17) {
                    ModuleIcon(module: .dragWheel, size: 58)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A new format. One gesture.").font(.title2.weight(.semibold))
                        Text("Hold \(service.trigger.displayName) while dragging a file, then drop on a format.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enable DragWheel", isOn: $service.isEnabled).labelsHidden().help("Enable DragWheel")
                }
                BezelCard {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.system(size: 35, weight: .light)).foregroundStyle(.mint)
                        Text("Drop files here, or hold \(service.trigger.displayName) in Finder.")
                            .font(.headline).multilineTextAlignment(.center)
                        Text("Choose a format on the wheel. The result saves beside the original, and both files are added to Shelf.")
                            .foregroundStyle(.secondary).font(.callout)
                        Button("Choose Files…") { service.chooseFiles() }
                            .buttonStyle(BezelActionStyle(prominent: true)).disabled(!service.isEnabled)
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(isTargeted ? Color.mint : .clear, lineWidth: 2))
                .dropDestination(for: URL.self) { urls, _ in
                    guard service.isEnabled, !DragWheelService.commonTargets(urls).isEmpty else { return false }
                    service.selectedFiles = urls
                    return true
                } isTargeted: { isTargeted = $0 }

                if let message = service.statusMessage {
                    Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
                }
                if !service.selectedFiles.isEmpty {
                    BezelCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(service.selectedFiles.count == 1 ? service.selectedFiles[0].lastPathComponent : "\(service.selectedFiles.count) selected files")
                                .font(.headline).lineLimit(2)
                            HStack {
                                Picker("Convert to", selection: $targetFormat) {
                                    ForEach(targets, id: \.self) { format in
                                        Text(format.uppercased() + (missing(format).map { " · needs \($0)" } ?? ""))
                                            .tag(format).disabled(missing(format) != nil)
                                    }
                                }.frame(maxWidth: 360)
                                Button("Convert") { service.convert(service.selectedFiles, to: targetFormat) }
                                    .buttonStyle(BezelActionStyle(prominent: true))
                                    .disabled(!service.isEnabled || !targets.contains(targetFormat) || missing(targetFormat) != nil)
                                Button("Clear") { service.selectedFiles = [] }
                            }
                        }
                    }
                }
                BezelCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Trigger key").font(.headline)
                            Spacer()
                            Picker("Trigger key", selection: $service.trigger) {
                                ForEach(DWTriggerKey.presets, id: \.self) { key in Text(key.displayName).tag(key) }
                                if case .key = service.trigger { Text(service.trigger.displayName).tag(service.trigger) }
                            }.labelsHidden().frame(width: 145)
                            Button("Record Key…") { service.recordKey() }.disabled(service.isRecordingKey)
                        }
                        if case .key = service.trigger {
                            Text("Custom keys may require Input Monitoring in System Settings → Privacy & Security. Modifier keys work without it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Toggle("Position the result beside the original icon in Finder", isOn: $service.placeNextToOriginal)
                        Text("Results always save in the same folder without replacing files. Optional icon positioning asks for Finder Automation access and works in icon view.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !service.jobs.isEmpty {
                    HStack {
                        SmallSectionLabel(text: "CONVERSIONS")
                        Spacer()
                        if service.activeCount > 0 {
                            Text("\(service.activeCount) remaining").font(.caption).foregroundStyle(.secondary)
                            Button("Cancel All") { service.cancelAll() }
                        }
                    }
                    BezelCard {
                        VStack(spacing: 12) {
                            ForEach(service.jobs) { job in
                                HStack(spacing: 12) {
                                    if job.state == .converting { ProgressView().controlSize(.small) }
                                    else { Image(systemName: symbol(job.state)).foregroundStyle(tint(job.state)) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(job.source.lastPathComponent + " → " + job.format.uppercased()).lineLimit(1)
                                        Text(job.error ?? job.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(3).textSelection(.enabled)
                                    }
                                    Spacer()
                                    if let output = job.output {
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                                    }
                                }
                            }
                        }
                    }
                }
                HStack {
                    SmallSectionLabel(text: "HELPER TOOLS")
                    Spacer()
                    Button("Refresh") { service.refreshHelpers() }
                }
                BezelCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(DWTool.allCases) { tool in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: service.helperPaths[tool] == nil ? "circle.dashed" : "checkmark.circle.fill")
                                    .foregroundStyle(service.helperPaths[tool] == nil ? Color.secondary : .green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tool.displayName).fontWeight(.medium)
                                    Text(tool.usedFor).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if service.helperPaths[tool] == nil {
                                    Button("Copy Install Command") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(tool.brewInstall, forType: .string)
                                    }.controlSize(.small)
                                } else { Text("Installed").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Text("Basic conversions use macOS tools. Optional helpers unlock additional formats; unavailable choices are labeled on the wheel.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Supported conversions") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(DWFormats.table, id: \.kind) { row in
                            LabeledContent(row.kind.rawValue.capitalized, value: row.to.joined(separator: ", ").uppercased())
                                .font(.caption)
                        }
                        Text("PDF to document formats extracts text; page layouts are not retained. Multi-page image exports produce a folder. Markdown falls back to plain text when Pandoc is missing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }
            }.padding(30).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
        }.onAppear { service.refreshHelpers() }
            .onChange(of: targets, initial: true) { _, values in
                if !values.contains(targetFormat) { targetFormat = values.first(where: { missing($0) == nil }) ?? values.first ?? "" }
            }
    }

    private func symbol(_ state: DWConversionJob.State) -> String {
        switch state {
        case .queued: "clock"
        case .converting: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }
    private func tint(_ state: DWConversionJob.State) -> Color {
        switch state {
        case .completed: .green
        case .failed: .orange
        default: .secondary
        }
    }
}
