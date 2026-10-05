import AppKit
import IOKit.pwr_mgt
import Observation
import SwiftUI
import Darwin

@MainActor @Observable
final class PulseService {
    enum Mode: Equatable { case continuous, countdown, process(pid_t) }
    private(set) var isActive = false
    private(set) var remainingSeconds: Int?
    private(set) var mode: Mode = .continuous
    private(set) var processCPU: Double?
    var keepDisplayAwake = true
    var keepDisksAwake = false
    var lastError: String?
    var status = "Your Mac follows its normal sleep settings."
    @ObservationIgnored private var assertions: [IOPMAssertionID] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var countdown: SessionCountdown?
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var previousSample: (ticks: UInt64, time: TimeInterval)?
    @ObservationIgnored private var idleSamples = 0
    @ObservationIgnored private var watchedProcessStart: UInt64?

    init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    func start() { begin(.continuous, minutes: nil) }
    func start(minutes: Int) { begin(.countdown, minutes: max(1, min(minutes, 1440))) }
    func startWatching(pid: pid_t) {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else {
            lastError = "Enter the process ID of a running task outside Bezel."
            return
        }
        guard sample(pid) != nil else { lastError = "That process is unavailable or has already finished."; return }
        begin(.process(pid), minutes: nil)
    }

    private func begin(_ requestedMode: Mode, minutes: Int?) {
        stop()
        lastError = nil
        var types = keepDisplayAwake
            ? [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep]
            : [kIOPMAssertionTypePreventUserIdleSystemSleep]
        if keepDisksAwake { types.append(kIOPMAssertPreventDiskIdle) }
        for type in types {
            var identifier = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Bezel Pulse active session" as CFString, &identifier)
            guard result == kIOReturnSuccess else {
                stop()
                lastError = "macOS declined the power assertion (\(result))."
                return
            }
            assertions.append(identifier)
        }
        mode = requestedMode
        countdown = minutes.map { SessionCountdown(seconds: $0 * 60, now: now()) }
        remainingSeconds = minutes.map { $0 * 60 }
        isActive = true
        if case .process(let pid) = requestedMode { watchedProcessStart = sample(pid)?.start }
        status = "Keeping \(keepDisplayAwake ? "your Mac and display" : "your Mac") awake."
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for assertion in assertions { IOPMAssertionRelease(assertion) }
        assertions.removeAll()
        isActive = false
        countdown = nil
        remainingSeconds = nil
        previousSample = nil
        processCPU = nil
        watchedProcessStart = nil
        idleSamples = 0
        status = "Your Mac follows its normal sleep settings."
    }

    private func tick() {
        guard isActive else { return }
        if let countdown {
            remainingSeconds = countdown.remainingSeconds(at: now())
            if remainingSeconds == 0 { stop(); status = "Countdown complete. Normal sleep settings restored." }
        }
        if case .process(let pid) = mode {
            guard let value = sample(pid), value.start == watchedProcessStart else {
                stop(); status = "The watched process finished. Normal sleep settings restored."; return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let previousSample {
                let elapsed = now - previousSample.time
                let delta = value.ticks >= previousSample.ticks ? value.ticks - previousSample.ticks : 0
                // proc_taskinfo CPU totals are nanoseconds on macOS.
                let cpu = Double(delta) / max(0.001, elapsed) / 1_000_000_000 * 100
                processCPU = cpu
                idleSamples = cpu < 0.1 ? idleSamples + 1 : 0
                if idleSamples >= 30 {
                    stop(); status = "The watched process was idle for 30 seconds. Normal sleep settings restored."; return
                }
            }
            previousSample = (value.ticks, now)
        }
    }

    private func sample(_ pid: pid_t) -> (ticks: UInt64, start: UInt64)? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
              bsd.pbi_status != UInt32(SZOMB) else { return nil }
        return (info.pti_total_user + info.pti_total_system, bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)
    }
}

struct PulseView: View {
    @Bindable var service: PulseService
    @State private var selectedMode = 0
    @State private var minutes = 60
    @State private var processID = ""
    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: service.isActive ? "cup.and.saucer.fill" : "cup.and.saucer").font(.system(size: 48)).foregroundStyle(service.isActive ? .orange : .secondary)
                    Text(service.isActive ? "Wide awake." : "A little extra energy.").font(.title2)
                    Text(service.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let seconds = service.remainingSeconds { Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)).font(.title).monospacedDigit() }
                    if let cpu = service.processCPU { Text("Process CPU: \(cpu, specifier: "%.1f")%").monospacedDigit().font(.caption) }
                }.frame(maxWidth: .infinity).padding(.vertical, 22)
                Toggle("Keep the display awake", isOn: $service.keepDisplayAwake).disabled(service.isActive)
                Toggle("Keep attached disks awake", isOn: $service.keepDisksAwake).disabled(service.isActive)
                Picker("Mode", selection: $selectedMode) {
                    Text("Until stopped").tag(0)
                    Text("Countdown").tag(1)
                    Text("Watch a process").tag(2)
                }.disabled(service.isActive)
                if selectedMode == 1 { Stepper("Duration: \(minutes) minutes", value: $minutes, in: 5...1440, step: 5).disabled(service.isActive) }
                if selectedMode == 2 {
                    TextField("Process ID", text: $processID).disabled(service.isActive)
                    Text("Releases the sleep assertion when this exact process exits or uses less than 0.1% CPU for 30 seconds. Choose the workload PID, not an idle Terminal shell. Activity Monitor shows process IDs.").font(.caption).foregroundStyle(.secondary)
                }
                Button(service.isActive ? "Let Mac Sleep Normally" : "Keep Awake") {
                    if service.isActive { service.stop() }
                    else if selectedMode == 1 { service.start(minutes: minutes) }
                    else if selectedMode == 2 {
                        if let pid = Int32(processID.trimmingCharacters(in: .whitespaces)) { service.startWatching(pid: pid) }
                        else { service.lastError = "Enter a numeric process ID." }
                    } else { service.start() }
                }.buttonStyle(.borderedProminent)
            } footer: { Text("Closing the lid, choosing Sleep, or a critically low battery can still put your Mac to sleep.") }
            if let error = service.lastError { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
        }.formStyle(.grouped).navigationTitle("Pulse")
    }
}
