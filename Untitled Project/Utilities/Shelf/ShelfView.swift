import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Bindable var service: ShelfService

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A little room between apps.").font(.title2.weight(.semibold))
                    Text("Park files and text here, then drag them out when you’re ready.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Edge activation", isOn: $service.isEnabled).toggleStyle(.switch)
            }
            HStack {
                Label("\(service.count) of 50 items", systemImage: "tray")
                Spacer()
                Button("Show Floating Shelf", systemImage: "rectangle.on.rectangle") { service.show() }
            }
            .font(.callout)
            ShelfDropContainer(service: service) {
                VStack(spacing: 12) {
                    if service.items.isEmpty {
                        ContentUnavailableView("Drop something here", systemImage: "tray.and.arrow.down", description: Text("Drag a file or selected text to any display edge to reveal the floating shelf across Spaces."))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(service.items) { item in ShelfItemRow(item: item, service: service) }
                            }
                            .padding(12)
                        }
                        .frame(minHeight: 260)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(service.isDropTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(service.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            .frame(minHeight: 270)
            HStack {
                Text(service.statusMessage ?? "Shelf holds references to your original files. Nothing is moved or uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Shelf") { service.clear() }.disabled(service.items.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

struct ShelfDrawer: View {
    @Bindable var service: ShelfService

    var body: some View {
        ShelfDropContainer(service: service) {
            VStack(spacing: 12) {
                HStack {
                    Label("Shelf", systemImage: "tray.fill").font(.headline)
                    Text("\(service.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { service.hide() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Hide Shelf")
                }
                if service.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
                        Text("Drop files or text").font(.headline)
                        Text("A temporary home, across Spaces.").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(service.items) { item in ShelfItemRow(item: item, service: service) }
                        }
                    }
                }
                HStack {
                    Text(service.isDropTargeted ? "Release to add to Shelf" : "Drag an item to another app").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if !service.items.isEmpty { Button("Clear") { service.clear() }.font(.caption).buttonStyle(.borderless) }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(service.isDropTargeted ? Color.accentColor : Color.white.opacity(0.2), lineWidth: service.isDropTargeted ? 2 : 1))
            .padding(2)
        }
    }
}

private struct ShelfItemRow: View {
    let item: ShelfItem
    let service: ShelfService

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item.content {
                case .file(let url): Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                case .text: Image(systemName: "text.alignleft").font(.title2).foregroundStyle(.tint)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button { service.remove(item) } label: { Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel("Remove \(item.title) from Shelf")
        }
        .padding(10).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onDrag { service.itemProvider(for: item) }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { service.copy(item) }
            if case .file = item.content { Button("Show in Finder", systemImage: "folder") { service.reveal(item) } }
            Button("Remove from Shelf", systemImage: "xmark") { service.remove(item) }
        }
        .help(item.subtitle)
    }
}

private struct ShelfDropContainer<Content: View>: NSViewRepresentable {
    let service: ShelfService
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ShelfDropNSView<Content> {
        ShelfDropNSView(service: service, content: content())
    }

    func updateNSView(_ view: ShelfDropNSView<Content>, context: Context) { view.hostingView.rootView = content() }
}

@MainActor
private final class ShelfDropNSView<Content: View>: NSView {
    let hostingView: NSHostingView<Content>
    private let service: ShelfService

    init(service: ShelfService, content: Content) {
        self.service = service
        hostingView = NSHostingView(rootView: content)
        super.init(frame: .zero)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor), hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor), hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard service.count < 50, sender.draggingPasteboard.availableType(from: [.fileURL, .string]) != nil else { return [] }
        service.isDropTargeted = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        service.isDropTargeted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { service.isDropTargeted = false }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { service.count < 50 }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        service.isDropTargeted = false
        return service.acceptPasteboard(sender.draggingPasteboard)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) { service.isDropTargeted = false }
}
