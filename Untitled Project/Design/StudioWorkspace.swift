import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

private enum DeskItem: Identifiable {
    case clip(ClipboardEntry)
    case shelf(ShelfItem)

    var id: UUID {
        switch self { case .clip(let entry): entry.id; case .shelf(let item): item.id }
    }
    var date: Date {
        switch self { case .clip(let entry): entry.capturedAt; case .shelf(let item): item.addedAt }
    }
    var title: String {
        switch self { case .clip(let entry): entry.title; case .shelf(let item): item.title }
    }
    var symbol: String {
        switch self {
        case .clip(let entry): entry.kind.symbol
        case .shelf(let item): if case .file = item.content { "doc" } else { "text.alignleft" }
        }
    }
    var source: String {
        switch self { case .clip(let entry): "Stack · " + entry.sourceName; case .shelf: "Shelf" }
    }
}

struct StudioWorkspace: View {
    let model: BezelModel
    @Binding var selection: UUID?
    @State private var targeted = false
    @FocusState private var listFocused: Bool

    private var items: [DeskItem] {
        (model.stack.history.map(DeskItem.clip) + model.shelf.items.map(DeskItem.shelf)).sorted { $0.date > $1.date }
    }

    var body: some View {
        let entries = items
        let selected = entries.first { $0.id == selection } ?? entries.first
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Workspace").font(.system(size: 29, weight: .medium)).tracking(-1)
                Spacer()
                Button("Open Shelf", systemImage: "tray") { model.shelf.show() }
            }
            if let selected {
                HStack(alignment: .top, spacing: 14) {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(entries) { item in
                                Button {
                                    selection = item.id
                                    listFocused = true
                                } label: {
                                    HStack {
                                        Image(systemName: item.symbol).foregroundStyle(StudioColor.blue).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title).font(.callout).lineLimit(1)
                                            Text(item.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(9).background(item.id == selected.id ? StudioColor.blue.opacity(0.16) : .clear,
                                                            in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityAddTraits(item.id == selected.id ? .isSelected : [])
                            }
                        }
                    }
                    .frame(width: 195)
                    .focusable()
                    .focused($listFocused)
                    .onDeleteCommand { delete(selected) }
                    Divider()
                    inspector(selected).id(selected.id)
                }
            } else {
                ContentUnavailableView {
                    Label("Your workspace is empty", systemImage: "tray")
                } description: {
                    Text("Copy something to Stack or drop a file here to keep it on Shelf.")
                } actions: {
                    Button("Add Clipboard to Shelf") { model.shelf.pasteClipboard() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).studioSurface()
            }
            if let message = model.shelf.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? StudioColor.blue : .clear, lineWidth: 2).allowsHitTesting(false))
            .onDrop(of: [UTType.fileURL, .image, .plainText], isTargeted: $targeted, perform: model.shelf.acceptDrop)
    }

    private func delete(_ item: DeskItem) {
        let entries = items
        guard let index = entries.firstIndex(where: { $0.id == item.id }) else { return }
        selection = entries.dropFirst(index + 1).first?.id ?? entries.prefix(index).last?.id
        switch item {
        case .clip(let entry): model.stack.remove(entry)
        case .shelf(let shelfItem): model.shelf.remove(shelfItem)
        }
        listFocused = true
    }

    @ViewBuilder private func inspector(_ item: DeskItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                switch item {
                case .clip(let entry):
                    if let data = entry.thumbnailData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().padding()
                    } else { textPreview(entry.preview) }
                case .shelf(let shelfItem):
                    switch shelfItem.content {
                    case .file(let url): WorkspaceFilePreview(url: url)
                    case .text(let value): textPreview(value)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).studioSurface()
            Text(item.title).font(.headline).lineLimit(2)
            HStack {
                Text(item.source).lineLimit(1)
                Spacer()
                Text(item.date, style: .time)
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                switch item {
                case .clip(let entry):
                    Button("Copy", systemImage: "doc.on.doc") { model.stack.copy(entry) }
                    Button("Keep on Shelf", systemImage: "tray.and.arrow.down") {
                        Task { await model.stack.keepOnShelf(entry, shelf: model.shelf) }
                    }.disabled(entry.kind == .binary)
                case .shelf(let shelfItem):
                    Button("Copy", systemImage: "doc.on.doc") { model.shelf.copy(shelfItem) }
                    if case .file = shelfItem.content {
                        Button("Quick Look", systemImage: "eye") { model.shelf.preview(shelfItem) }
                        Button("Show in Finder") { model.shelf.reveal(shelfItem) }
                    }
                }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive) { delete(item) }
                    .help("Delete the selected Workspace item (⌫)")
            }.controlSize(.small)
        }
    }

    private func textPreview(_ value: String) -> some View {
        ScrollView {
            Text(value).font(.system(size: 15)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
        }
    }
}

private struct WorkspaceFilePreview: View {
    let url: URL
    @State private var thumbnail: NSImage?
    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable().scaledToFit().padding()
            .accessibilityLabel(url.lastPathComponent)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 620, height: 420),
                                                          scale: 1, representationTypes: .all)
                let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                if !Task.isCancelled { thumbnail = result?.nsImage }
            }
    }
}
