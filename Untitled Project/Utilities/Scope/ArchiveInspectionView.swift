import SwiftUI

struct ArchiveInspectionView: View {
    @Bindable var service: ScopeService
    @State private var query = ""
    private var entries: [SafeArchive.EntryInfo] {
        (service.inspection?.entries ?? []).filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.inspectedArchive?.lastPathComponent ?? "Archive").font(.title2).lineLimit(1)
                    Text("Archive contents").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { service.dismissInspection() }.keyboardShortcut(.cancelAction)
            }
            if service.isInspecting {
                ProgressView("Reading archive headers…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = service.inspectionError {
                ContentUnavailableView("Cannot inspect this archive", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                TextField("Filter filenames", text: $query).textFieldStyle(.roundedBorder)
                Table(entries) {
                    TableColumn("Name") { entry in
                        Label(entry.path, systemImage: entry.isDirectory ? "folder" : "doc")
                            .lineLimit(1).truncationMode(.middle).help(entry.path)
                    }.width(min: 260, ideal: 350)
                    TableColumn("Size") { entry in
                        Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).monospacedDigit()
                    }.width(90)
                    TableColumn("Notes") { entry in Text(entry.warning ?? "").font(.caption).foregroundStyle(.orange) }.width(180)
                }
                HStack {
                    Text("\(entries.count.formatted()) \(entries.count == 1 ? "entry" : "entries") shown").foregroundStyle(.secondary)
                    Spacer()
                    Button("Extract…") {
                        guard let archive = service.inspectedArchive else { return }
                        service.dismissInspection()
                        service.chooseExtractionDestination(for: archive)
                    }.disabled(service.isArchiving || service.inspection == nil || service.inspection?.entries.contains(where: { $0.warning != nil }) == true)
                }
                if service.inspection?.isTruncated == true {
                    Text("This listing is partial. Inspection stops after 20,000 headers or before advancing past 512 MB of declared content.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Inspection reads names and sizes without creating files. Extraction accepts regular files and folders only.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 740, height: 510)
    }
}
