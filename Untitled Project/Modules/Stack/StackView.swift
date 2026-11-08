import AppKit
import ApplicationServices
import SwiftUI

struct StackView: View {
    @Bindable var service: StackService
    @State private var previewEntry: ClipboardEntry?
    @State private var selectedIDs: Set<UUID> = []
    @State private var isSelecting = false
    @State private var confirmClear = false
    @FocusState private var historyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Everything you copied.").font(.title2.weight(.semibold))
                    Text("Save a few Quick Clips. Choose exactly what to paste.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("History", isOn: $service.isEnabled).toggleStyle(.switch)
            }
            HStack(spacing: 12) {
                Label("\(service.history.count) items", systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isSelecting {
                    Button("Select All") { selectedIDs = Set(service.filteredHistory.map(\.id)) }
                    Button("Delete Selected (\(selectedIDs.count))", systemImage: "trash", role: .destructive) { deleteSelection() }.disabled(selectedIDs.isEmpty)
                }
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle(); selectedIDs.removeAll(); historyFocused = isSelecting
                }.disabled(!isSelecting && service.history.isEmpty)
                Button("Open Clipboard", systemImage: "cursorarrow.rays") { service.showHUD() }
            }.controlSize(.small)
            quickClips
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, images, files, or app", text: $service.searchText).textFieldStyle(.plain)
                if !service.searchText.isEmpty {
                    Button { service.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                }
            }.padding(.horizontal, 15).padding(.vertical, 12).bezelGlass(cornerRadius: 100)
            historyArea.frame(minHeight: 120, maxHeight: .infinity)
                .focusable(isSelecting).focused($historyFocused)
                .onDeleteCommand { if isSelecting { deleteSelection() } }
                .onExitCommand { isSelecting = false; selectedIDs.removeAll() }
            HStack(spacing: 12) {
                Text(service.statusMessage ?? (isSelecting ? "Click clips to select them, then delete them together." : "Clips stay in memory until Bezel quits."))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Delete All", systemImage: "trash", role: .destructive) { confirmClear = true }
                    .disabled(service.history.isEmpty && service.queue.isEmpty).controlSize(.small)
            }
        }.padding(24)
        .sheet(item: $previewEntry) { entry in ClipboardPreview(entry: entry, service: service) }
        .confirmationDialog("Delete all history and Quick Clips?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { service.clearHistory(); selectedIDs.removeAll(); isSelecting = false }
        } message: { Text("Bezel’s saved clips are removed. Your current system clipboard is kept.") }
        .onChange(of: service.history.map(\.id)) { _, ids in selectedIDs.formIntersection(Set(ids)) }
        .onChange(of: service.searchText) { selectedIDs.removeAll() }
    }

    @ViewBuilder private var historyArea: some View {
        if service.filteredHistory.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                Text(service.searchText.isEmpty ? "Your next copy starts here" : "No matching clips").font(.headline)
                Text(service.searchText.isEmpty ? "Text, images, and files stay here for this session." : "Try a different word or app name.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(service.filteredHistory) { entry in
                        ClipboardCard(entry: entry, queuePosition: service.queue.firstIndex(where: { $0.id == entry.id }).map { $0 + 1 },
                                      isSelected: selectedIDs.contains(entry.id), showsSelection: isSelecting,
                                      removeAction: { service.remove(entry) }) {
                            if isSelecting {
                                if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) }
                                else { selectedIDs.insert(entry.id) }
                            } else { previewEntry = entry }
                        }.contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { service.copy(entry) }
                            Button("Add to Quick Clips", systemImage: "text.badge.plus") { service.enqueue(entry) }
                            Button("Delete", systemImage: "trash", role: .destructive) { service.remove(entry) }
                        }
                    }
                }.padding(4)
            }
        }
    }

    private func deleteSelection() { service.remove(selectedIDs); selectedIDs.removeAll() }

    private var quickClips: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick Clips · \(service.queue.count)").font(.headline)
                Text("⇧⌘C adds a selection · ⇧⌘V lets you choose a clip").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !service.queue.isEmpty { Button("Clear") { service.clearQueue() }.buttonStyle(.borderless) }
            Button("Choose to Paste", systemImage: "list.bullet.rectangle") { service.showPastePicker() }
        }.padding(18).bezelSurface(cornerRadius: 22, tint: .accentColor)
    }
}

private struct ClipboardCard: View {
    let entry: ClipboardEntry
    let queuePosition: Int?
    var isSelected = false
    var showsSelection = false
    var removeAction: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        if showsSelection {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        } else { Image(systemName: entry.kind.symbol).foregroundStyle(.tint) }
                        Text(entry.kind.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        if let queuePosition { Text("\(queuePosition)").font(.caption2.monospacedDigit()).foregroundStyle(.tint) }
                        if removeAction != nil { Color.clear.frame(width: 18, height: 16) }
                    }
                    if let data = entry.thumbnailData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 72)
                    } else {
                        Text(entry.preview).font(entry.kind == .binary ? .system(.caption, design: .monospaced) : .callout)
                            .lineLimit(4).frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .topLeading)
                    }
                    Divider()
                    HStack(spacing: 5) {
                        if let icon = ClipboardAppIcons.icon(for: entry.sourceBundleIdentifier) {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14).accessibilityHidden(true)
                        }
                        Text(entry.sourceName).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(entry.capturedAt, style: .time)
                    }.font(.caption2).foregroundStyle(.secondary)
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .bezelSurface(cornerRadius: 18, tint: isSelected ? .accentColor : .clear)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(hovering ? 0.14 : 0.07), lineWidth: isSelected ? 2 : 1))
            }.buttonStyle(.plain)
                .accessibilityLabel("\(entry.kind.rawValue), \(entry.title), copied from \(entry.sourceName)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let removeAction {
                Button(role: .destructive, action: removeAction) { Image(systemName: "trash").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(13).opacity(hovering || showsSelection ? 1 : 0.35)
                    .help("Delete this clip").accessibilityLabel("Delete \(entry.title)")
            }
        }.onHover { hovering = $0 }.help(entry.detail)
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
                Button("Add to Quick Clips", systemImage: "text.badge.plus") { service.enqueue(entry); dismiss() }
                Button("Copy", systemImage: "doc.on.doc") { service.copy(entry); dismiss() }.buttonStyle(BezelActionStyle(prominent: true))
            }
        }
        .padding(22).frame(width: 540)
    }
}

struct StackHUD: View {
    @Bindable var service: StackService
    @FocusState private var searchFocused: Bool
    private var selected: ClipboardEntry? { service.hudEntries.first { $0.id == service.hudSelectionID } }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                Text(service.hudIsPasteMode ? "Choose a clip to paste" : "Stack").font(.headline)
                Spacer()
                Button { service.hideHUD() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Close Stack")
            }
            HStack {
                Picker("Collection", selection: $service.hudCollection) {
                    ForEach(ClipboardCollection.allCases) { collection in Text(collection.rawValue).tag(collection) }
                }.pickerStyle(.segmented).frame(maxWidth: 280)
                Spacer()
                Text("\(service.hudEntries.count) clips").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Add Clipboard", systemImage: "plus") { service.addCurrentClipboardToQueue() }.controlSize(.small)
            }
            TextField("Search clips", text: $service.searchText).textFieldStyle(.plain).focused($searchFocused)
                .padding(.horizontal, 15).padding(.vertical, 11).bezelSurface(cornerRadius: 100)
            if service.hudEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text(service.hudCollection == .quickClips ? "No Quick Clips yet" : "No matching clips").font(.headline)
                    Text("⇧⌘C copies a selection here. Add Clipboard saves what you’ve already copied.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 10) {
                            ForEach(Array(service.hudEntries.enumerated()), id: \.offset) { index, entry in
                                ClipboardCard(entry: entry, queuePosition: service.hudCollection == .quickClips ? index + 1 : nil,
                                              isSelected: service.hudSelectionID == entry.id) {
                                    service.hudSelectionID = entry.id
                                    if service.hudIsPasteMode {
                                        service.paste(entry, fromQuickClips: service.hudCollection == .quickClips)
                                    } else {
                                        service.copy(entry)
                                    }
                                }.id(entry.id)
                            }
                        }.padding(3)
                    }.onChange(of: service.hudSelectionID) { _, id in if let id { reader.scrollTo(id, anchor: .center) } }
                }
            }
            if let message = service.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            }
            HStack(spacing: 10) {
                if !AccessibilityAccess.canSendKeyboardEvents { Button("Accessibility…") { service.openAccessibilitySettings() }.controlSize(.small) }
                Text(service.hudIsPasteMode ? "Click a clip to paste · Esc closes" : "Esc closes").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if service.hudCollection == .history {
                    Button("Add to Quick Clips") { if let selected { service.enqueue(selected) } }.disabled(selected == nil)
                }
                Button("Copy") { if let selected { service.copy(selected); service.hideHUD() } }.disabled(selected == nil)
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let selected { service.paste(selected, fromQuickClips: service.hudCollection == .quickClips) }
                }.buttonStyle(BezelActionStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(selected == nil || service.isPasting)
            }.controlSize(.small)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .bezelGlass(cornerRadius: 28).padding(2)
        .buttonStyle(BezelActionStyle())
        .onAppear { searchFocused = true; chooseFirstIfNeeded() }
        .onChange(of: service.hudCollection) { chooseFirstIfNeeded() }
        .onChange(of: service.hudEntries.map(\.id)) { chooseFirstIfNeeded() }
        .onExitCommand { service.hideHUD() }
    }

    private func chooseFirstIfNeeded() {
        if !service.hudEntries.contains(where: { $0.id == service.hudSelectionID }) { service.hudSelectionID = service.hudEntries.first?.id }
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
