import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import FinderSync

struct ScopeNode: Identifiable, Sendable {
    let url: URL
    let name: String
    let allocatedBytes: Int64
    let fileCount: Int
    let skippedCount: Int
    let isDirectory: Bool
    let children: [ScopeNode]
    var id: URL { url }
}

private final class ScopeDetailBudget: @unchecked Sendable {
    // All mutable state is protected by the lock. Workers retain a bounded display tree,
    // while continuing to count every accessible file in their allocation totals.
    private let lock = NSLock()
    private var count = 0
    func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < 20_000 else { return false }
        count += 1
        return true
    }
}

private enum ScopeScanner {
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]

    static func scan(_ url: URL) async throws -> ScopeNode {
        let budget = ScopeDetailBudget()
        let values = try url.resourceValues(forKeys: keys)
        guard values.isDirectory == true else { return try walk(url, depth: 0, budget: budget) }
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        var iterator = urls.makeIterator()
        var nodes: [ScopeNode] = []
        var total: Int64 = 0
        var count = 0
        var skipped = 0
        try await withThrowingTaskGroup(of: ScopeNode.self) { group in
            for _ in 0..<min(6, urls.count) {
                if let next = iterator.next() { group.addTask { try walk(next, depth: 1, budget: budget) } }
            }
            while let node = try await group.next() {
                try Task.checkCancellation()
                total += node.allocatedBytes
                count += node.fileCount
                skipped += node.skippedCount
                nodes.append(node)
                if nodes.count > 160 { nodes.sort { $0.allocatedBytes > $1.allocatedBytes }; nodes = Array(nodes.prefix(80)) }
                if let next = iterator.next() { group.addTask { try walk(next, depth: 1, budget: budget) } }
            }
        }
        return ScopeNode(url: url, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                         allocatedBytes: total, fileCount: count, skippedCount: skipped, isDirectory: true,
                         children: Array(nodes.sorted { $0.allocatedBytes > $1.allocatedBytes }.prefix(80)))
    }

    private static func walk(_ url: URL, depth: Int, budget: ScopeDetailBudget) throws -> ScopeNode {
        try Task.checkCancellation()
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: keys) }
        catch { return ScopeNode(url: url, name: url.lastPathComponent, allocatedBytes: 0, fileCount: 0, skippedCount: 1, isDirectory: false, children: []) }
        if values.isSymbolicLink == true {
            return ScopeNode(url: url, name: url.lastPathComponent, allocatedBytes: 0, fileCount: 0, skippedCount: 1, isDirectory: false, children: [])
        }
        let isDirectory = values.isDirectory == true
        guard isDirectory, depth < 128 else {
            return ScopeNode(url: url, name: url.lastPathComponent,
                             allocatedBytes: isDirectory ? 0 : Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0),
                             fileCount: isDirectory ? 0 : 1, skippedCount: isDirectory ? 1 : 0, isDirectory: isDirectory, children: [])
        }
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)) }
        catch { return ScopeNode(url: url, name: url.lastPathComponent, allocatedBytes: 0, fileCount: 0, skippedCount: 1, isDirectory: true, children: []) }
        var total: Int64 = 0
        var count = 0
        var skipped = 0
        var children: [ScopeNode] = []
        for child in urls {
            let node = try walk(child, depth: depth + 1, budget: budget)
            total += node.allocatedBytes
            count += node.fileCount
            skipped += node.skippedCount
            if depth < 6, budget.reserve() {
                children.append(node)
                if children.count > 160 { children.sort { $0.allocatedBytes > $1.allocatedBytes }; children = Array(children.prefix(80)) }
            }
        }
        return ScopeNode(url: url, name: url.lastPathComponent, allocatedBytes: total, fileCount: count,
                         skippedCount: skipped, isDirectory: true, children: Array(children.sorted { $0.allocatedBytes > $1.allocatedBytes }.prefix(80)))
    }
}

@MainActor @Observable
final class ScopeService {
    private(set) var root: ScopeNode?
    private(set) var selection: ScopeNode?
    private(set) var isScanning = false
    private(set) var isArchiving = false
    private(set) var navigation: [ScopeNode] = []
    var lastError: String?
    var archiveStatus: String?
    private(set) var inspectedArchive: URL?
    private(set) var inspection: SafeArchive.Inspection?
    private(set) var isInspecting = false
    private(set) var inspectionError: String?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var archiveTask: Task<Void, Never>?
    @ObservationIgnored private var scanID = UUID()
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionID = UUID()

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.scan(url: url) }
        }
    }

    func scan(url: URL) {
        scanTask?.cancel()
        scanID = UUID()
        let id = scanID
        isScanning = true
        lastError = nil
        scanTask = Task { [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let worker = Task.detached(priority: .utility) { try await ScopeScanner.scan(url) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.scanID == id else { return }
                self.root = result
                self.selection = result
                self.navigation = []
                self.isScanning = false
            } catch {
                guard let self, self.scanID == id else { return }
                self.isScanning = false
                if !(error is CancellationError) { self.lastError = error.localizedDescription }
            }
        }
    }

    func cancel() { scanTask?.cancel(); scanID = UUID(); isScanning = false }
    func stop() { cancel(); archiveTask?.cancel(); dismissInspection() }
    func navigate(to node: ScopeNode) {
        guard node.isDirectory else { NSWorkspace.shared.activateFileViewerSelecting([node.url]); return }
        if node.children.isEmpty, node.fileCount > 0 { scan(url: node.url); return }
        if let selection { navigation.append(selection) }
        selection = node
    }
    func goBack() { if let previous = navigation.popLast() { selection = previous } }
    func revealSelection() { if let selection { NSWorkspace.shared.activateFileViewerSelecting([selection.url]) } }

    func handleFinderRequest(_ request: ScopeRequest) {
        guard FileManager.default.fileExists(atPath: request.file.path) else {
            lastError = "The selected item is no longer available."
            return
        }
        switch request.action {
        case .analyze: scan(url: request.file)
        case .inspect: inspectArchive(request.file)
        case .extract: chooseExtractionDestination(for: request.file)
        case .compress: chooseCompressionDestination(for: request.file)
        }
    }

    func chooseArchive(inspect: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = inspect ? "Inspect" : "Extract"
        panel.message = "Choose a ZIP, RAR, 7z, TAR, or compressed TAR archive."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if inspect { self?.inspectArchive(url) }
                else { self?.chooseExtractionDestination(for: url) }
            }
        }
    }

    func inspectArchive(_ source: URL) {
        dismissInspection()
        let id = UUID()
        inspectionID = id
        inspectedArchive = source
        isInspecting = true
        inspectionTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { try SafeArchive.inspect(source) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, inspectionID == id else { return }
                inspection = result
            } catch {
                guard let self, !Task.isCancelled, inspectionID == id else { return }
                inspectionError = error.localizedDescription
            }
            guard let self, inspectionID == id else { return }
            isInspecting = false
            inspectionTask = nil
        }
    }

    func dismissInspection() {
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionID = UUID()
        inspectedArchive = nil
        inspection = nil
        isInspecting = false
        inspectionError = nil
    }

    func chooseExtractionDestination(for archive: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = "Bezel creates a new folder and never overwrites existing files."
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in self?.extractArchive(at: archive, to: destination) }
        }
    }

    func extractArchive(at archive: URL, to destination: URL) {
        guard !isArchiving else { return }
        isArchiving = true
        lastError = nil
        archiveStatus = "Extracting \(archive.lastPathComponent)…"
        archiveTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { try SafeArchive.extract(archive, into: destination) }
            do {
                let output = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                self?.archiveStatus = "Extracted to \(output.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                self?.archiveStatus = nil
                if !(error is CancellationError) { self?.lastError = error.localizedDescription }
            }
            self?.isArchiving = false
        }
    }

    func compressSelection() {
        guard let selection, !isArchiving else { return }
        chooseCompressionDestination(for: selection.url)
    }

    private func chooseCompressionDestination(for source: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = source.lastPathComponent + ".zip"
        panel.prompt = "Compress"
        panel.begin { [weak self] response in
            guard response == .OK, let output = panel.url else { return }
            Task { @MainActor in self?.compress(source, to: output) }
        }
    }

    private func compress(_ source: URL, to destination: URL) {
        guard !isArchiving else { return }
        isArchiving = true
        lastError = nil
        archiveStatus = "Compressing \(source.lastPathComponent)…"
        archiveTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { try SafeArchive.compress(source, to: destination) }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                self?.archiveStatus = "Created \(destination.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self?.archiveStatus = nil
                if !(error is CancellationError) { self?.lastError = error.localizedDescription }
            }
            self?.isArchiving = false
        }
    }
}

struct ScopeView: View {
    @Bindable var service: ScopeService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Make room for what matters.").font(.title2)
                        Text("See what is taking up space, one folder at a time.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Folder…", systemImage: "folder") { service.chooseDirectory() }.disabled(service.isScanning)
                }
                if service.isScanning {
                    HStack { ProgressView().controlSize(.small); Text("Measuring allocated file sizes…"); Spacer(); Button("Cancel") { service.cancel() } }
                }
                if let node = service.selection {
                    HStack {
                        Button { service.goBack() } label: { Image(systemName: "chevron.left") }.disabled(service.navigation.isEmpty).help("Enclosing folder")
                        VStack(alignment: .leading) {
                            Text(node.name).font(.headline)
                            Text(node.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Reveal in Finder", systemImage: "arrow.up.right.square") { service.revealSelection() }
                    }
                    HStack(spacing: 30) {
                        ScopeSunburst(node: node, navigate: service.navigate).frame(width: 300, height: 300)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(ByteCountFormatter.string(fromByteCount: node.allocatedBytes, countStyle: .file)).font(.system(size: 38, weight: .light, design: .rounded))
                            Text("Allocated across \(node.fileCount.formatted()) files").foregroundStyle(.secondary)
                            if node.skippedCount > 0 { Text("\(node.skippedCount.formatted()) inaccessible paths or symbolic links skipped").font(.caption).foregroundStyle(.orange) }
                            Text("Click a ring or folder to explore.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                            Button { service.navigate(to: child) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: child.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(ScopeSunburst.color(index))
                                    Text(child.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: child.allocatedBytes, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
                                    Image(systemName: child.isDirectory ? "chevron.right" : "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(.vertical, 10).padding(.horizontal, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }.background(.background, in: RoundedRectangle(cornerRadius: 12))
                    Text("Shows the 80 largest entries per folder, up to six levels, with 20,000 detailed entries per scan. Drill into a folder to refresh its detail. File allocation is an estimate: APFS clones and hard links may share blocks. Protected folders require access in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !service.isScanning {
                    ContentUnavailableView("Your storage, in perspective", systemImage: "chart.pie", description: Text("Choose a folder to build an interactive storage map. Everything is analyzed on your Mac."))
                        .frame(minHeight: 290)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Archives").font(.headline)
                        Text("Extract ZIP, RAR, 7z, and TAR with macOS libarchive. Encrypted archives may be unsupported.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Inspect…") { service.chooseArchive(inspect: true) }
                    Button("Extract…") { service.chooseArchive() }.disabled(service.isArchiving)
                    Button("Compress Folder…") { service.compressSelection() }.disabled(service.selection == nil || service.isArchiving)
                }
                HStack {
                    Label("Finder actions", systemImage: "contextualmenu.and.cursorarrow")
                    Spacer()
                    Button("Enable Finder Extension…") { FIFinderSyncController.showExtensionManagementInterface() }
                }
                Text("Enable Bezel Finder Actions in macOS Extensions to analyze, inspect, compress, or extract an item from Finder’s context menu.").font(.caption).foregroundStyle(.secondary)
                if let status = service.archiveStatus { HStack { if service.isArchiving { ProgressView().controlSize(.small) }; Text(status).foregroundStyle(.secondary) } }
                if let error = service.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.padding(28)
        }.navigationTitle("Scope")
            .sheet(isPresented: Binding(get: { service.inspectedArchive != nil }, set: { if !$0 { service.dismissInspection() } })) {
                ArchiveInspectionView(service: service)
            }
    }
}

private struct ScopeSunburst: View {
    struct Arc: Identifiable {
        let node: ScopeNode
        let start: Double
        let end: Double
        let depth: Int
        let index: Int
        var id: String { node.id.path + ":\(depth)" }
    }
    let node: ScopeNode
    let navigate: (ScopeNode) -> Void
    static func color(_ index: Int) -> Color { Color(hue: Double(index % 11) / 11, saturation: 0.58, brightness: 0.85) }
    private var arcs: [Arc] {
        var result: [Arc] = []
        func add(_ parent: ScopeNode, start: Double, end: Double, depth: Int, base: Int?) {
            guard depth < 3, parent.allocatedBytes > 0 else { return }
            var cursor = start
            for (index, child) in parent.children.enumerated() where child.allocatedBytes > 0 {
                let width = (end - start) * Double(child.allocatedBytes) / Double(parent.allocatedBytes)
                if width > 0.001 {
                    result.append(Arc(node: child, start: cursor, end: cursor + width, depth: depth, index: base ?? index))
                    add(child, start: cursor, end: cursor + width, depth: depth + 1, base: base ?? index)
                }
                cursor += width
            }
        }
        add(node, start: 0, end: 2 * .pi, depth: 0, base: nil)
        return result
    }
    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Circle().stroke(.quaternary, lineWidth: radius * 0.6).padding(radius * 0.3)
                ForEach(arcs) { arc in
                    let inner = radius * 0.28 + CGFloat(arc.depth) * radius * 0.235
                    let outer = inner + radius * 0.22
                    Path { path in
                        path.addArc(center: center, radius: outer, startAngle: .radians(arc.start - .pi / 2), endAngle: .radians(arc.end - .pi / 2), clockwise: false)
                        path.addArc(center: center, radius: inner, startAngle: .radians(arc.end - .pi / 2), endAngle: .radians(arc.start - .pi / 2), clockwise: true)
                        path.closeSubpath()
                    }.fill(Self.color(arc.index).opacity(1 - Double(arc.depth) * 0.16))
                        .onTapGesture { navigate(arc.node) }
                        .help("\(arc.node.name) · \(ByteCountFormatter.string(fromByteCount: arc.node.allocatedBytes, countStyle: .file))")
                        .accessibilityLabel("\(arc.node.name), \(ByteCountFormatter.string(fromByteCount: arc.node.allocatedBytes, countStyle: .file))")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { navigate(arc.node) }
                }
                Image(systemName: "internaldrive").font(.system(size: 26)).foregroundStyle(.secondary)
            }
        }
    }
}
