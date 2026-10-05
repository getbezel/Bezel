import AppKit
import SwiftUI

struct StackView: View {
    @Bindable var service: StackService
    @State private var selectedEntry: ClipboardEntry?
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Everything you copied.").font(.title2.weight(.semibold))
                    Text("Collect a sequence, then paste it in order.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Clipboard history", isOn: $service.isEnabled).toggleStyle(.switch)
            }
            HStack(spacing: 14) {
                Label("\(service.history.count) of 50 items", systemImage: "square.stack.3d.up")
                Label(ByteCountFormatter.string(fromByteCount: Int64(service.memoryBytes), countStyle: .memory), systemImage: "memorychip")
                Spacer()
                Button("Open at Pointer", systemImage: "cursorarrow.rays") { service.showHUD() }
            }
            .font(.caption).foregroundStyle(.secondary)
            sequenceStrip
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, files, or source app", text: $service.searchText).textFieldStyle(.plain)
                if !service.searchText.isEmpty { Button { service.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }
            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            if service.filteredHistory.isEmpty {
                ContentUnavailableView(service.searchText.isEmpty ? "Your next copy starts here" : "No matching items", systemImage: "doc.on.clipboard", description: Text(service.searchText.isEmpty ? "Text, images, and files stay in memory for this session. Apps’ concealed and temporary clipboard items are skipped." : "Try a different word or app name."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(service.filteredHistory) { entry in
                            ClipboardCard(entry: entry, queuePosition: service.queue.firstIndex(where: { $0.id == entry.id }).map { $0 + 1 }) {
                                selectedEntry = entry
                            }
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { service.copy(entry) }
                                Button("Add to Sequence", systemImage: "text.badge.plus") { service.enqueue(entry) }
                                Divider()
                                Button("Remove", systemImage: "trash", role: .destructive) { service.remove(entry) }
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(minHeight: 200)
            }
            HStack {
                Text(service.statusMessage ?? "History stays on this Mac and is cleared when Bezel quits.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Clear History", role: .destructive) { confirmClear = true }.disabled(service.history.isEmpty && service.queue.isEmpty)
            }
        }
        .padding(24)
        .sheet(item: $selectedEntry) { entry in ClipboardPreview(entry: entry, service: service) }
        .confirmationDialog("Clear clipboard history and the paste sequence?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { service.clearHistory() }
        } message: { Text("This removes Bezel’s in-memory copies. Your current system clipboard is kept.") }
    }

    private var sequenceStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Paste sequence", systemImage: "list.number").font(.headline)
                Text("\(service.queue.count)").font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                Spacer()
                if !service.queue.isEmpty {
                    Button("Clear") { service.clearQueue() }.buttonStyle(.borderless)
                    Button("Paste Next") { service.pasteNext() }.disabled(service.isPasting)
                }
            }
            if let next = service.queue.first {
                Label(next.title, systemImage: next.kind.symbol).lineLimit(1).font(.callout)
            } else {
                Text("⇧⌘C collects a selection · ⇧⌘V pastes the oldest item").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ClipboardCard: View {
    let entry: ClipboardEntry
    let queuePosition: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: entry.kind.symbol).foregroundStyle(.tint)
                    Text(entry.kind.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    if let queuePosition { Text("\(queuePosition)").font(.caption2.monospacedDigit()).padding(5).background(Color.accentColor.opacity(0.12), in: Circle()) }
                }
                if let data = entry.thumbnailData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 68)
                } else {
                    Text(entry.preview).font(entry.kind == .binary ? .system(.caption, design: .monospaced) : .callout)
                        .lineLimit(4).frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68, alignment: .topLeading)
                }
                Divider()
                HStack(spacing: 5) {
                    if let icon = ClipboardAppIcons.icon(for: entry.sourceBundleIdentifier) {
                        Image(nsImage: icon).resizable().frame(width: 13, height: 13).accessibilityHidden(true)
                    }
                    Text(entry.sourceName).lineLimit(1)
                    Spacer()
                    Text(entry.capturedAt, style: .time)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.kind.rawValue), \(entry.title), copied from \(entry.sourceName)")
        .help(entry.detail)
    }
}

private struct ClipboardPreview: View {
    let entry: ClipboardEntry
    let service: StackService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(entry.kind.rawValue, systemImage: entry.kind.symbol).font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(entry.sourceName) · \(entry.detail)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                if let data = entry.thumbnailData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 260)
                }
                Text(entry.preview).font(entry.kind == .binary ? .system(.body, design: .monospaced) : .body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, maxHeight: 360)
            HStack {
                Text(entry.capturedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add to Sequence", systemImage: "text.badge.plus") { service.enqueue(entry); dismiss() }
                Button("Copy", systemImage: "doc.on.doc") { service.copy(entry); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22).frame(width: 540)
    }
}

struct StackHUD: View {
    @Bindable var service: StackService
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                Text("Stack").font(.headline)
                Text("\(service.history.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !service.queue.isEmpty { Button("Paste next · \(service.queue.count)") { service.pasteNext() } }
                Button { service.hideHUD() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Close Stack")
            }
            TextField("Search clipboard", text: $service.searchText).textFieldStyle(.roundedBorder).focused($searchFocused)
            if service.filteredHistory.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "doc.on.clipboard", description: Text("Copy text, an image, or a file to begin."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 10) {
                        ForEach(service.filteredHistory) { entry in
                            ClipboardCard(entry: entry, queuePosition: nil) { service.copy(entry); service.hideHUD() }
                                .contextMenu { Button("Add to Sequence") { service.enqueue(entry) } }
                        }
                    }
                    .padding(2)
                }
            }
            HStack { Text("Click to copy · Right-click to queue"); Spacer(); Text("Esc to close") }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16).background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onExitCommand { service.hideHUD() }
    }
}

@MainActor private enum ClipboardAppIcons {
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
    static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        let key = bundleIdentifier as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}
