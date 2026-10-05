import AppKit
import ApplicationServices
import Observation
import SwiftUI

@MainActor @Observable
final class MonolithService {
    var focusAutomation = FocusAutomation()
    private(set) var isActive = false
    private(set) var remainingSeconds = 0
    var lastError: String?
    @ObservationIgnored private var countdown: SessionCountdown?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panels: [NSPanel] = []
    @ObservationIgnored private var lastFrame: CGRect?
    @ObservationIgnored private var displaySignature: [CGRect] = []

    func start(minutes: Int = 25) {
        guard AXIsProcessTrusted() else {
            lastError = "Enable Accessibility access in System Settings to keep the active window illuminated."
            return
        }
        stop()
        lastError = nil
        remainingSeconds = max(1, min(minutes, 240)) * 60
        countdown = SessionCountdown(seconds: remainingSeconds)
        isActive = true
        focusAutomation.setSessionActive(true)
        update()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        countdown = nil
        isActive = false
        focusAutomation.setSessionActive(false)
        remainingSeconds = 0
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        lastFrame = nil
        displaySignature = []
    }

    private func update() {
        guard isActive, let countdown else { return }
        let seconds = countdown.remainingSeconds()
        if remainingSeconds != seconds { remainingSeconds = seconds }
        if remainingSeconds == 0 { stop(); return }
        guard let window = FocusedWindowAccess.current() else {
            // Never leave a dark, uncut overlay behind when AX access is unavailable.
            panels.forEach { $0.orderOut(nil) }
            lastFrame = nil
            return
        }
        let frame = FocusedWindowAccess.appKitFrame(window.frame).insetBy(dx: -1, dy: -1)
        let displays = NSScreen.screens.map(\.frame)
        guard frame != lastFrame || displays != displaySignature else { return }
        lastFrame = frame
        displaySignature = displays
        var desired: [CGRect] = []
        for screen in NSScreen.screens {
            let area = screen.frame
            let cutout = area.intersection(frame)
            let pieces: [CGRect]
            if cutout.isNull || cutout.isEmpty { pieces = [area] }
            else {
                pieces = [
                    CGRect(x: area.minX, y: area.minY, width: area.width, height: cutout.minY - area.minY),
                    CGRect(x: area.minX, y: cutout.maxY, width: area.width, height: area.maxY - cutout.maxY),
                    CGRect(x: area.minX, y: cutout.minY, width: cutout.minX - area.minX, height: cutout.height),
                    CGRect(x: cutout.maxX, y: cutout.minY, width: area.maxX - cutout.maxX, height: cutout.height)
                ]
            }
            desired.append(contentsOf: pieces.filter { $0.width > 0 && $0.height > 0 })
        }
        for (index, rect) in desired.enumerated() {
            let panel: NSPanel
            if index < panels.count { panel = panels[index] }
            else {
                panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .black.withAlphaComponent(0.90)
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.isReleasedWhenClosed = false
                panels.append(panel)
            }
            if panel.frame != rect { panel.setFrame(rect, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for panel in panels.dropFirst(desired.count) { panel.orderOut(nil) }
    }

    func openFocusSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

struct MonolithView: View {
    @Bindable var service: MonolithService
    @State private var minutes = 25

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: "moon.circle.fill").font(.system(size: 48)).foregroundStyle(.indigo)
                    Text(service.isActive ? clock : "A little room to focus.").font(service.isActive ? .system(size: 56, weight: .light, design: .rounded) : .title2).monospacedDigit()
                    Text(service.isActive ? "Your active window stays in the light." : "Dim the desktop and settle into one thing.").foregroundStyle(.secondary)
                    Button(service.isActive ? "End Session" : "Begin Focus") {
                        if service.isActive { service.stop() } else { service.start(minutes: minutes) }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            Section("Session") {
                Stepper("Duration: \(minutes) minutes", value: $minutes, in: 5...240, step: 5).disabled(service.isActive)
                LabeledContent("Background dimming", value: "90%")
                Text("Click-through overlays dim everything outside your active window. They do not change other apps’ window opacity.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Run Focus shortcuts with each session", isOn: $service.focusAutomation.isEnabled)
                    .disabled(service.isActive || service.focusAutomation.isRunning)
                if service.focusAutomation.isEnabled {
                    TextField("Starting shortcut", text: $service.focusAutomation.onShortcut)
                    TextField("Ending shortcut", text: $service.focusAutomation.offShortcut)
                    Text("In Shortcuts, create a starting shortcut with Set Focus → Do Not Disturb → On Until Turned Off, and an ending shortcut with Set Focus → Do Not Disturb → Off. Enter their names or identifiers here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Shortcuts", systemImage: "square.stack.3d.up") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                    }
                    Text(service.focusAutomation.status).font(.caption).foregroundStyle(.secondary)
                }
                if service.focusAutomation.needsRecovery {
                    Button("Run Ending Shortcut", systemImage: "arrow.counterclockwise") { service.focusAutomation.recover() }
                        .disabled(service.focusAutomation.isRunning)
                }
                if let error = service.focusAutomation.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Button("Open Focus Settings", systemImage: "moon.fill") { service.openFocusSettings() }
                Text("The chosen workflows run when you begin and end a session, including timer expiry and normal quit. The ending workflow turns off the selected Focus; it does not restore a previously active Focus.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = service.lastError { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
        }.formStyle(.grouped).navigationTitle("Monolith")
    }
    private var clock: String { String(format: "%02d:%02d", service.remainingSeconds / 60, service.remainingSeconds % 60) }
}
