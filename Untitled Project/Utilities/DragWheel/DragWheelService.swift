import AppKit
import Observation

struct DWConversionJob: Identifiable, Sendable {
    enum State: String, Sendable { case queued, converting, completed, failed, cancelled }
    let id: UUID
    let source: URL
    let format: String
    var state: State = .queued
    var output: URL?
    var error: String?
}

@MainActor @Observable final class DragWheelService {
    var isEnabled = UserDefaults.standard.object(forKey: "dragWheel.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "dragWheel.enabled")
            isEnabled ? start() : stop()
        }
    }
    var trigger = DWTriggerKey.current {
        didSet { DWTriggerKey.current = trigger }
    }
    var placeNextToOriginal = UserDefaults.standard.object(forKey: "dragWheel.placeNextToOriginal") as? Bool ?? false {
        didSet { UserDefaults.standard.set(placeNextToOriginal, forKey: "dragWheel.placeNextToOriginal") }
    }
    private(set) var jobs: [DWConversionJob] = []
    private(set) var helperPaths: [DWTool: String] = [:]
    var statusMessage: String?
    var selectedFiles: [URL] = []
    var isRecordingKey = false
    var activeCount: Int { jobs.filter { $0.state == .queued || $0.state == .converting }.count }
    var isWheelVisible: Bool { radial?.isVisible ?? false }
    var reservesDrag: Bool { isEnabled && (trigger.isHeld || isWheelVisible) }

    @ObservationIgnored var onConverted: ((URL, URL) -> String?)?

    @ObservationIgnored private let watcher = DWDragWatcher()
    @ObservationIgnored private var radial: DWRadialMenuController?
    @ObservationIgnored private let recorder = DWKeyRecorder()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var started = false

    init(placeNextToOriginal: Bool? = nil) {
        if let placeNextToOriginal { self.placeNextToOriginal = placeNextToOriginal }
        refreshHelpers()
    }

    func start() {
        guard isEnabled, !started else { return }
        started = true
        watcher.isTriggerHeld = { [weak self] in self?.trigger.isHeld ?? false }
        watcher.onTrigger = { [weak self] point, files in self?.presentWheel(at: point, files: files) }
        watcher.onMouseUp = { [weak self] in self?.radial?.hideAfterDrop() }
        watcher.start()
    }

    func stop() {
        started = false
        watcher.stop()
        radial?.hide()
        recorder.finish(nil)
        cancelAll()
    }

    func shutdown() async {
        let task = worker
        stop()
        await task?.value
    }

    func refreshHelpers() {
        helperPaths = Dictionary(uniqueKeysWithValues: DWTool.allCases.compactMap { tool in
            tool.path.map { (tool, $0) }
        })
    }

    func recordKey() {
        isRecordingKey = true
        recorder.begin { [weak self] value in
            guard let self else { return }
            if let value { trigger = value }
            isRecordingKey = false
        }
    }

    static func commonTargets(_ files: [URL]) -> [String] {
        guard !files.isEmpty, files.count <= 50, files.allSatisfy({ $0.isFileURL && DWFormats.classify($0) != nil }) else { return [] }
        var targets = DWFormats.targets(for: files[0])
        for file in files.dropFirst() {
            let available = Set(DWFormats.targets(for: file))
            targets.removeAll { !available.contains($0) }
            if targets.isEmpty { break }
        }
        return targets
    }

    func presentWheel(at point: NSPoint, files: [URL]) {
        guard isEnabled else { return }
        let targets = Self.commonTargets(files)
        guard !targets.isEmpty else {
            statusMessage = "Select up to 50 supported files with a common output format."
            return
        }
        refreshHelpers()
        if radial == nil {
            radial = DWRadialMenuController()
            radial?.onChoose = { [weak self] format, urls in self?.convert(urls, to: format) }
        }
        let items = targets.map { target in
            let missing = files.lazy.compactMap { DWConverter.missingRequirement(for: $0, to: target) }.first
            return DWMenuItem(format: target, enabled: missing == nil, note: missing.map { "needs \($0)" })
        }
        radial?.show(at: point, files: files, items: items,
                     sourceLabel: files.count == 1 ? (DWFormats.classify(files[0])?.format ?? "") : "\(files.count) files")
    }

    func convert(_ files: [URL], to format: String) {
        guard !files.isEmpty, files.count <= 50, activeCount + files.count <= 50,
              Self.commonTargets(files).contains(format) else {
            statusMessage = "Choose a common output format for up to 50 files."
            return
        }
        for file in files {
            if let missing = DWConverter.missingRequirement(for: file, to: format) {
                statusMessage = "\(missing) is needed for this conversion. See Helper Tools below."
                return
            }
        }
        while jobs.count + files.count > 50, let index = jobs.firstIndex(where: { $0.state != .queued && $0.state != .converting }) {
            jobs.remove(at: index)
        }
        jobs += files.map { DWConversionJob(id: UUID(), source: $0, format: format) }
        statusMessage = nil
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        guard jobs.contains(where: { $0.state == .queued }) else { return }
        let token = generation
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled, let job = await self?.nextJob(token: token) {
                do {
                    let output = try await DWConverter.convert(job.source, to: job.format)
                    await self?.finish(job.id, output: output, error: nil, token: token)
                } catch {
                    await self?.finish(job.id, output: nil, error: error, token: token)
                }
            }
            await self?.workerFinished(token: token)
        }
    }

    private func nextJob(token: UUID) -> DWConversionJob? {
        guard token == generation, let index = jobs.firstIndex(where: { $0.state == .queued }) else { return nil }
        jobs[index].state = .converting
        return jobs[index]
    }

    private func finish(_ id: UUID, output: URL?, error: Error?, token: UUID) {
        guard token == generation, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].output = output
        jobs[index].error = error?.localizedDescription
        jobs[index].state = output != nil ? .completed : (error is CancellationError ? .cancelled : .failed)
        if let output {
            statusMessage = "Saved \(output.lastPathComponent) beside the original."
            if placeNextToOriginal { DWFinderPlacement.place(output, nextTo: jobs[index].source) }
            if let onConverted {
                if let warning = onConverted(jobs[index].source, output) {
                    statusMessage = "Saved beside the original. \(warning)"
                } else {
                    statusMessage = "Saved beside the original. Both files are in Shelf."
                }
            }
        } else if let error { statusMessage = error is CancellationError ? "Conversion cancelled." : error.localizedDescription }
    }

    private func workerFinished(token: UUID) {
        if token == generation {
            worker = nil
            startWorkerIfNeeded()
        }
    }

    func cancelAll() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        for index in jobs.indices where jobs[index].state == .queued || jobs[index].state == .converting {
            jobs[index].state = .cancelled
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                self?.selectedFiles = panel.urls
                if Self.commonTargets(panel.urls).isEmpty {
                    self?.statusMessage = "These files have no common conversion format."
                }
            }
        }
    }
}
