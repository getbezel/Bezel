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
    var dimming: Double = UserDefaults.standard.object(forKey: "monolith.dimming") as? Double ?? 0.55 {
        didSet {
            let clamped = min(0.85, max(0.20, dimming))
            if dimming != clamped { dimming = clamped }
            UserDefaults.standard.set(clamped, forKey: "monolith.dimming")
            updateOpacity()
        }
    }
    @ObservationIgnored private var countdown: SessionCountdown?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panels: [NSPanel] = []
    @ObservationIgnored private var lastFrame: CGRect?
    @ObservationIgnored private var displaySignature: [CGRect] = []
    @ObservationIgnored private let tracker = FocusWindowTracker()

    func start(minutes: Int = 25) {
        guard AccessibilityAccess.canControlWindows else {
            lastError = "macOS is blocking window access for this copy of Bezel. If Bezel is already enabled in Accessibility settings, remove the old entry and add the app shown in Bezel Settings → Privacy → Show This App in Finder."
            return
        }
        stop()
        lastError = nil
        remainingSeconds = max(1, min(minutes, 240)) * 60
        countdown = SessionCountdown(seconds: remainingSeconds)
        isActive = true
        focusAutomation.setSessionActive(true)
        tracker.onChange = { [weak self] frame, animated in self?.render(frame: frame, animated: animated) }
        tracker.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        timer.tolerance = 0.1
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
        tracker.stop()
        let oldPanels = panels
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            oldPanels.forEach { $0.orderOut(nil) }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                oldPanels.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: {
                MainActor.assumeIsolated { oldPanels.forEach { $0.orderOut(nil) } }
            }
        }
        panels.removeAll()
        lastFrame = nil
        displaySignature = []
    }

    private func update() {
        guard isActive, let countdown else { return }
        let seconds = countdown.remainingSeconds()
        if remainingSeconds != seconds { remainingSeconds = seconds }
        if remainingSeconds == 0 { stop(); return }
    }

    private func render(frame: CGRect?, animated: Bool) {
        guard isActive else { return }
        guard let frame else {
            panels.forEach { $0.orderOut(nil) }
            lastFrame = nil
            return
        }
        lastFrame = frame
        let screens = NSScreen.screens
        let displays = screens.map(\.visibleFrame)
        if displays != displaySignature {
            panels.forEach { $0.orderOut(nil) }
            panels.removeAll()
            displaySignature = displays
            for area in displays {
                let panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.isReleasedWhenClosed = false
                panel.contentView = FocusBackdropView(frame: CGRect(origin: .zero, size: area.size))
                panels.append(panel)
            }
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (panel, area) in zip(panels, displays) {
            guard let backdrop = panel.contentView as? FocusBackdropView else { continue }
            backdrop.update(window: FocusDimmingGeometry.localWindow(frame, in: area), animated: animated, reduceMotion: reduceMotion)
            if !panel.isVisible {
                panel.alphaValue = reduceMotion ? dimming : 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduceMotion ? 0 : 0.25
                    panel.animator().alphaValue = dimming
                }
            }
        }
    }

    private func updateOpacity() {
        guard isActive else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            panels.forEach { $0.animator().alphaValue = dimming }
        }
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
                    }.buttonStyle(BezelActionStyle(prominent: true)).controlSize(.large)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            Section("Session") {
                Stepper("Duration: \(minutes) minutes", value: $minutes, in: 5...240, step: 5).disabled(service.isActive)
                LabeledContent("Background dimming", value: "\(Int(service.dimming * 100))%")
                Slider(value: $service.dimming, in: 0.20...0.85, step: 0.05) {
                    Text("Background dimming")
                } minimumValueLabel: { Image(systemName: "sun.max") } maximumValueLabel: { Image(systemName: "moon.fill") }
                Text("A soft shade keeps your active window clear. Adjust it while you work; the menu bar and Dock stay visible.").font(.caption).foregroundStyle(.secondary)
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
        .alert("Couldn’t begin focus", isPresented: Binding(
            get: { service.lastError != nil },
            set: { if !$0 { service.lastError = nil } }
        )) {
            if !AccessibilityAccess.canControlWindows {
                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) { service.lastError = nil }
        } message: {
            Text(service.lastError ?? "")
        }
    }
    private var clock: String { String(format: "%02d:%02d", service.remainingSeconds / 60, service.remainingSeconds % 60) }
}
