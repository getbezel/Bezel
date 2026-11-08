import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Bindable var service: ShelfService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    ModuleIcon(module: .shelf, size: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A little room between apps.").font(.title2.weight(.semibold))
                        Text("Keep images, files, and text within reach, across every Space.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Edge activation", isOn: $service.isEnabled).toggleStyle(.switch)
                }
                HStack {
                    Button("Show Shelf", systemImage: "rectangle.on.rectangle") { service.show() }
                        .buttonStyle(BezelActionStyle(prominent: true))
                    Button("Add Clipboard", systemImage: "doc.on.clipboard") { service.pasteClipboard() }
                    Button("Capture Image", systemImage: "camera.viewfinder") { service.captureImage?() }
                    Spacer()
                    Text("\(service.count) of 50").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                ShelfDropContainer(service: service) {
                    ScrollView {
                        if service.items.isEmpty {
                            ShelfEmptyState()
                                .frame(maxWidth: .infinity, minHeight: 260)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(service.items) { item in ShelfItemRow(item: item, service: service) }
                            }.padding(12)
                        }
                    }
                    .background(service.isDropTargeted ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(service.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }
                .frame(height: 310)
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Floating Shelf").font(.headline)
                            Spacer()
                            ShelfSizeMenu(service: service)
                            Button("Reset Position") { service.resetPosition() }
                        }
                        HStack {
                            Text("Width").frame(width: 48, alignment: .leading)
                            Slider(value: $service.drawerWidth, in: 280...640, step: 10)
                            Text("\(Int(service.drawerWidth)) pt").monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                        HStack {
                            Text("Height").frame(width: 48, alignment: .leading)
                            Slider(value: $service.drawerHeight, in: 240...720, step: 10)
                            Text("\(Int(service.drawerHeight)) pt").monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                        Text("Drag the Shelf header to move it, or its bottom-right corner to resize. Your layout is remembered.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                HStack(alignment: .top) {
                    Text(service.statusMessage ?? "Original files stay in place. Captures are temporary PNG files; export them before clearing Shelf.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Shelf") { service.clear() }.disabled(service.items.isEmpty)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct ShelfDrawer: View {
    @Bindable var service: ShelfService

    var body: some View {
        ShelfDropContainer(service: service) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Label("Shelf", systemImage: "tray.fill").font(.headline)
                        .overlay { ShelfMoveHandle() }
                        .help("Drag to move Shelf")
                    Text("\(service.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    ShelfMoveHandle().frame(maxWidth: .infinity, minHeight: 24)
                    ShelfSizeMenu(service: service).labelStyle(.iconOnly)
                    Button { service.hide() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Hide Shelf")
                }
                HStack(spacing: 8) {
                    Button("Clipboard", systemImage: "doc.on.clipboard") { service.pasteClipboard() }
                    Button("Capture", systemImage: "camera.viewfinder") { service.captureImage?() }
                    Spacer(minLength: 0)
                }.controlSize(.small)
                if service.items.isEmpty {
                    ShelfEmptyState().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(service.items) { item in ShelfItemRow(item: item, service: service) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text(service.statusMessage ?? (service.isDropTargeted ? "Release to add to Shelf" : "Drag an item to another app"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    if !service.items.isEmpty { Button("Clear") { service.clear() }.buttonStyle(.borderless).controlSize(.small) }
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { service.resizeDrawer(by: $0.translation, finished: false) }
                            .onEnded { service.resizeDrawer(by: $0.translation, finished: true) })
                        .help("Drag to resize Shelf")
                        .accessibilityLabel("Resize Shelf; size controls are in the menu")
                }
            }
            .padding(16)
            .bezelGlass(cornerRadius: 28)
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(service.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: service.isDropTargeted ? 2 : 1))
            .padding(2)
            .buttonStyle(BezelActionStyle())
        }
    }
}

private struct ShelfSizeMenu: View {
    let service: ShelfService
    var body: some View {
        Menu {
            Button("Compact") { service.setSize(width: 320, height: 300) }
            Button("Comfortable") { service.setSize(width: 380, height: 400) }
            Button("Roomy") { service.setSize(width: 520, height: 560) }
        } label: { Label("Size", systemImage: "arrow.up.left.and.arrow.down.right") }
        .menuStyle(.borderlessButton).fixedSize().help("Shelf size")
    }
}

private struct ShelfEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 36, weight: .light)).foregroundStyle(.tint)
            Text("Drop something here").font(.headline)
            Text("Files, images, and text.\nReady whenever you are.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(20)
    }
}

private struct ShelfItemRow: View {
    let item: ShelfItem
    let service: ShelfService
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    switch item.content {
                    case .file(let url): Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                    case .text: Image(systemName: "text.alignleft").font(.title2).foregroundStyle(.tint)
                    }
                }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onDrag { service.itemProvider(for: item) }
            .onTapGesture(count: 2) { service.preview(item) }
            if case .file = item.content {
                Button { service.preview(item) } label: { Image(systemName: "eye") }
                    .buttonStyle(.plain).help("Quick Look").accessibilityLabel("Preview \(item.title)")
            }
            Button { service.remove(item) } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove from Shelf").accessibilityLabel("Remove \(item.title) from Shelf")
        }
        .padding(12).bezelSurface(cornerRadius: 16)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { service.copy(item) }
            if case .file = item.content {
                Button("Quick Look", systemImage: "eye") { service.preview(item) }
                Button("Show in Finder", systemImage: "folder") { service.reveal(item) }
            }
            Button("Remove from Shelf", systemImage: "xmark") { service.remove(item) }
        }
        .help(item.subtitle)
        .task(id: item.id) {
            guard case .file(let url) = item.content else { return }
            let worker = Task.detached(priority: .utility) { () -> CGImage? in
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160
                ] as CFDictionary)
            }
            let image = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let image else { return }
            thumbnail = NSImage(cgImage: image, size: .zero)
        }
    }
}

/// Receives a real AppKit drag on the header without stealing drags from stored assets.
private struct ShelfMoveHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> ShelfMoveNSView { ShelfMoveNSView() }
    func updateNSView(_ view: ShelfMoveNSView, context: Context) {}
}

private final class ShelfMoveNSView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private struct ShelfDropContainer<Content: View>: NSViewRepresentable {
    let service: ShelfService
    @ViewBuilder let content: () -> Content
    func makeNSView(context: Context) -> ShelfDropNSView<Content> { ShelfDropNSView(service: service, content: content()) }
    func updateNSView(_ view: ShelfDropNSView<Content>, context: Context) { view.hostingView.rootView = content() }
}

@MainActor
private final class ShelfDropNSView<Content: View>: NSView {
    let hostingView: NSHostingView<Content>
    private let service: ShelfService
    private static var types: [NSPasteboard.PasteboardType] { [.fileURL, .png, .tiff, .string] }

    init(service: ShelfService, content: Content) {
        self.service = service
        hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        super.init(frame: .zero)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor), hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor), hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForDraggedTypes(Self.types)
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard service.count < 50, sender.draggingPasteboard.availableType(from: Self.types) != nil else { return [] }
        service.isDropTargeted = true
        return .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { service.isDropTargeted ? .copy : [] }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { service.isDropTargeted = false }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { service.count < 50 }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        service.isDropTargeted = false
        return service.acceptPasteboard(sender.draggingPasteboard)
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) { service.isDropTargeted = false }
}
