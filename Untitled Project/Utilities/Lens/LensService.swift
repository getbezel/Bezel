import AppKit
import Observation
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import Vision

@MainActor
@Observable
final class LensService {
    enum Phase: String {
        case idle = "Ready to capture"
        case capturing = "Freezing the display…"
        case selecting = "Drag to select text"
        case recognizing = "Recognizing text on this Mac…"
        case saving = "Preparing image for Shelf…"
    }

    var phase: Phase = .idle
    var lastResult = ""
    var statusMessage: String?
    var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    var runtimeBuild = RuntimeBuild.current()
    var isBusy: Bool { phase != .idle }
    @ObservationIgnored private let stack: StackService
    @ObservationIgnored private var panel: LensSelectionPanel?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var imageConsumer: (@MainActor (Data) -> Void)?

    init(stack: StackService) { self.stack = stack }

    func refreshPermission() {
        runtimeBuild = .current()
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingPermission() {
        hasScreenRecordingPermission = CGRequestScreenCaptureAccess()
        if !hasScreenRecordingPermission {
            statusMessage = "Allow Bezel under Privacy & Security → Screen & System Audio Recording. macOS may ask you to reopen Bezel."
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func startCapture() { beginCapture(imageConsumer: nil) }

    func startImageCapture(onImage: @escaping @MainActor (Data) -> Void) {
        beginCapture(imageConsumer: onImage)
    }

    private func beginCapture(imageConsumer: (@MainActor (Data) -> Void)?) {
        guard !isBusy else { return }
        refreshPermission()
        guard !runtimeBuild.diskChanged else { statusMessage = runtimeBuild.accessHelp; return }
        // The user's capture action goes through ScreenCaptureKit's own authorization.
        // A stale CoreGraphics preflight must not prevent the framework from trying capture.
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            statusMessage = "No display is available to capture."
            return
        }
        self.imageConsumer = imageConsumer
        let displayID = number.uint32Value
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        let id = UUID()
        requestID = id
        phase = .capturing
        statusMessage = nil
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot: ShareableSnapshot = try await CallbackDeadline.perform(timeout: .seconds(15)) { reply in
                    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                        if let error { reply(.failure(error)) }
                        else if let content { reply(.success(ShareableSnapshot(content: content))) }
                        else { reply(.failure(LensError.displayUnavailable)) }
                    }
                }
                let content = snapshot.content
                guard self.requestID == id, !Task.isCancelled else { return }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw LensError.displayUnavailable
                }
                let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = Int(frame.width * scale)
                configuration.height = Int(frame.height * scale)
                configuration.showsCursor = false
                configuration.captureResolution = .best
                let image: CGImage = try await CallbackDeadline.perform(timeout: .seconds(10)) { reply in
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                        if let error { reply(.failure(error)) }
                        else if let image { reply(.success(image)) }
                        else { reply(.failure(LensError.encodingFailed)) }
                    }
                }
                guard self.requestID == id, !Task.isCancelled else { return }
                self.hasScreenRecordingPermission = true
                self.presentSelection(image: image, frame: frame, requestID: id)
            } catch {
                guard self.requestID == id else { return }
                self.phase = .idle
                self.imageConsumer = nil
                self.refreshPermission()
                let nativeError = error as NSError
                if nativeError.domain == SCStreamErrorDomain && nativeError.code == SCStreamError.Code.userDeclined.rawValue {
                    self.statusMessage = "ScreenCaptureKit denied this running build. \(self.runtimeBuild.accessHelp)"
                } else {
                    self.statusMessage = "Capture failed (\(nativeError.domain), \(nativeError.code)): \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelCapture() {
        requestID = UUID()
        captureTask?.cancel()
        captureTask = nil
        closePanel()
        phase = .idle
        imageConsumer = nil
    }

    func copyResult() {
        guard !lastResult.isEmpty else { return }
        stack.insertText(lastResult, source: "Lens")
        statusMessage = "Copied to Stack and the system clipboard."
    }

    private func presentSelection(image: CGImage, frame: NSRect, requestID: UUID) {
        let panel = LensSelectionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = true
        let selection = LensSelectionView(frame: NSRect(origin: .zero, size: frame.size), image: image, capturingImage: imageConsumer != nil)
        selection.onCancel = { [weak self] in self?.cancelCapture() }
        selection.onSelect = { [weak self] rect in
            guard let self, self.requestID == requestID else { return }
            let ratioX = CGFloat(image.width) / frame.width
            let ratioY = CGFloat(image.height) / frame.height
            let crop = CGRect(x: rect.minX * ratioX, y: (frame.height - rect.maxY) * ratioY, width: rect.width * ratioX, height: rect.height * ratioY).integral
            self.closePanel()
            guard let cropped = image.cropping(to: crop) else {
                self.phase = .idle
                self.imageConsumer = nil
                self.statusMessage = "Select a larger area and try again."
                return
            }
            if let consumer = self.imageConsumer {
                self.saveImage(cropped, requestID: requestID, consumer: consumer)
            } else {
                self.recognize(cropped, requestID: requestID)
            }
        }
        panel.contentView = selection
        self.panel = panel
        phase = .selecting
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(selection)
        panel.invalidateCursorRects(for: selection)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func saveImage(_ image: CGImage, requestID: UUID, consumer: @escaping @MainActor (Data) -> Void) {
        phase = .saving
        captureTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () throws -> Data in
                try Task.checkCancellation()
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                    throw LensError.encodingFailed
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw LensError.encodingFailed }
                try Task.checkCancellation()
                return data as Data
            }
            do {
                let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.requestID == requestID, !Task.isCancelled else { return }
                self.phase = .idle
                self.imageConsumer = nil
                self.statusMessage = "Image captured for Shelf."
                consumer(data)
            } catch {
                guard let self, self.requestID == requestID else { return }
                self.phase = .idle
                self.imageConsumer = nil
                self.statusMessage = "Image capture failed: \(error.localizedDescription)"
            }
        }
    }

    private func recognize(_ image: CGImage, requestID: UUID) {
        phase = .recognizing
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
                try Task.checkCancellation()
                return Self.formattedText(from: request.results ?? [])
            }
            do {
                let text = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard self.requestID == requestID, !Task.isCancelled else { return }
                self.phase = .idle
                if text.isEmpty {
                    self.statusMessage = "No readable text was found. Try a larger or clearer selection."
                } else {
                    self.lastResult = text
                    self.stack.insertText(text, source: "Lens")
                    self.statusMessage = "\(text.count.formatted()) characters copied to Stack and your clipboard."
                }
            } catch {
                guard self.requestID == requestID else { return }
                self.phase = .idle
                self.statusMessage = "Text recognition failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func formattedText(from observations: [VNRecognizedTextObservation]) -> String {
        struct Line {
            let text: String
            let bounds: CGRect
        }
        let lines = observations.compactMap { observation -> Line? in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Line(text: text, bounds: observation.boundingBox)
        }.sorted { $0.bounds.midY > $1.bounds.midY }
        var rows: [[Line]] = []
        for line in lines {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.bounds.midY - line.bounds.midY) < min(anchor.bounds.height, line.bounds.height) * 0.45 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            row.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum LensError: LocalizedError {
    case displayUnavailable, encodingFailed
    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "The selected display disconnected before capture."
        case .encodingFailed: "The selected image could not be saved."
        }
    }
}

@MainActor
private final class LensSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class LensSelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private let image: NSImage
    private var startPoint: NSPoint?
    private var selectedRect: NSRect?
    private let prompt: String

    init(frame: NSRect, image: CGImage, capturingImage: Bool) {
        prompt = capturingImage ? "Drag to capture an image · Esc to cancel" : "Drag to capture text · Esc to cancel"
        self.image = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        setAccessibilityLabel(prompt)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectedRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectedRect = NSRect(x: min(startPoint.x, point.x), y: min(startPoint.y, point.y), width: abs(point.x - startPoint.x), height: abs(point.y - startPoint.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selectedRect, selectedRect.width >= 4, selectedRect.height >= 4 else {
            startPoint = nil
            self.selectedRect = nil
            needsDisplay = true
            return
        }
        onSelect?(selectedRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        if let selectedRect {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selectedRect).addClip()
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selectedRect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (prompt as NSString).size(withAttributes: attributes)
        let promptRect = NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - 96, width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: promptRect.insetBy(dx: -18, dy: -12), xRadius: 20, yRadius: 20).fill()
        (prompt as NSString).draw(in: promptRect, withAttributes: attributes)
    }
}

/// ScreenCaptureKit delivers an immutable snapshot with read-only display/app arrays.
private struct ShareableSnapshot: @unchecked Sendable {
    let content: SCShareableContent
}
