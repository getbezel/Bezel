import AppKit
import ApplicationServices
import Observation
import SwiftUI

@MainActor @Observable
final class BorderService {
    private(set) var isEnabled = false
    var lastError: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var outline: BorderOutlineView?
    @ObservationIgnored private var colorObserver: NSObjectProtocol?
    @ObservationIgnored private var previousFrame: CGRect?

    func setEnabled(_ enabled: Bool) { if enabled { start() } else { stop() } }

    func start() {
        guard !isEnabled else { return }
        guard AccessibilityAccess.canControlWindows else {
            lastError = "Enable Accessibility access in System Settings to track the focused window."
            return
        }
        lastError = nil
        isEnabled = true
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let outline = BorderOutlineView(frame: .zero)
        panel.contentView = outline
        self.outline = outline
        self.panel = panel
        colorObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.outline?.needsDisplay = true }
        }
        update()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) }
        colorObserver = nil
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        outline = nil
        previousFrame = nil
        isEnabled = false
    }

    private func update() {
        guard let panel, let window = FocusedWindowAccess.current() else {
            panel?.orderOut(nil)
            previousFrame = nil
            return
        }
        let frame = FocusedWindowAccess.appKitFrame(window.frame).insetBy(dx: -1, dy: -1)
        if previousFrame != frame {
            panel.setFrame(frame, display: true)
            outline?.needsDisplay = true
            previousFrame = frame
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

@MainActor private final class BorderOutlineView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: pixel / 2, dy: pixel / 2), xRadius: 9, yRadius: 9)
        path.lineWidth = pixel
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

struct BorderView: View {
    @Bindable var service: BorderService
    var body: some View {
        Form {
            Section {
                Toggle("Highlight the active window", isOn: Binding(get: { service.isEnabled }, set: service.setEnabled))
                Text("A one-pixel accent outline follows keyboard focus across displays and Spaces. The outline passes all clicks through to your apps.")
                    .foregroundStyle(.secondary)
                HStack {
                    RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor, lineWidth: 1).background(.quaternary, in: RoundedRectangle(cornerRadius: 9)).frame(width: 160, height: 100)
                        .overlay(Image(systemName: "cursorarrow").font(.title).foregroundStyle(.secondary))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Right where you are.").font(.headline)
                        Text("Uses your macOS accent color.").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 20)
            }
            if let error = service.lastError { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
        }.formStyle(.grouped).navigationTitle("Border")
    }
}
