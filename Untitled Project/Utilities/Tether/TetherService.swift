import AppKit
import IOKit.ps
import Observation
import SwiftUI

@MainActor @Observable
final class TetherService {
    let chargeControl = NativeChargeControl()
    private(set) var chargePercent: Int?
    private(set) var isCharging = false
    private(set) var isOnACPower = false
    private(set) var minutesRemaining: Int?
    private(set) var batteryName = "Battery"
    private(set) var lastUpdated: Date?
    private(set) var status = "Waiting for battery information"
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        chargeControl.refresh()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil; chargeControl.stop() }

    func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            status = "Battery information is unavailable."
            chargePercent = nil
            return
        }
        for source in sources {
            guard let data = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (data[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = data[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(1, data[kIOPSMaxCapacityKey] as? Int ?? 100)
            chargePercent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            isCharging = data[kIOPSIsChargingKey] as? Bool ?? false
            isOnACPower = data[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if !isOnACPower || chargePercent == 100 { chargeControl.clearTopOffStatus() }
            batteryName = data[kIOPSNameKey] as? String ?? "Internal battery"
            let remaining = data[isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            minutesRemaining = remaining.flatMap { $0 > 0 ? $0 : nil }
            status = isCharging ? "Charging" : isOnACPower ? "Connected to power" : "Using battery"
            lastUpdated = Date()
            return
        }
        chargePercent = nil
        isCharging = false
        isOnACPower = false
        minutesRemaining = nil
        lastUpdated = Date()
        status = "No internal battery detected"
    }

    func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

struct TetherView: View {
    @Bindable var service: TetherService
    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: service.isCharging ? "battery.100percent.bolt" : "battery.100percent")
                        .font(.system(size: 56)).foregroundStyle(service.isCharging ? .green : .primary)
                    Text(service.chargePercent.map { "\($0)%" } ?? "No battery").font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
                    Text(service.status).foregroundStyle(.secondary)
                    if let minutes = service.minutesRemaining {
                        Text("About \(minutes / 60)h \(minutes % 60)m \(service.isCharging ? "until full" : "remaining")").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
                if let date = service.lastUpdated { LabeledContent("Updated", value: date.formatted(date: .omitted, time: .shortened)) }
                Button("Refresh", systemImage: "arrow.clockwise") { service.refresh() }
            }
            Section("Charge management") {
                if service.chargeControl.isBusy { ProgressView("Reading charge settings…") }
                if service.chargeControl.supported {
                    LabeledContent("Charge limit", value: service.chargeControl.isEnabled ? "\(service.chargeControl.limit ?? 80)%" : "100%")
                    HStack {
                        Button("Limit to 80%", systemImage: "battery.75percent") { service.chargeControl.perform(.limit80) }
                            .buttonStyle(.borderedProminent)
                        Button("Top Off to 100%", systemImage: "battery.100percent.bolt") { service.chargeControl.perform(.topoff100) }
                            .disabled(!service.chargeControl.isEnabled)
                        if service.chargeControl.isEnabled {
                            Button("Remove Limit") { service.chargeControl.perform(.removeLimit) }
                        }
                    }.disabled(service.chargeControl.isBusy)
                    if service.chargeControl.topOffRequested {
                        Label("Top-off requested. Your saved limit stays in place.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    Text("The limit persists across sleep, restart, and quitting Bezel. Top Off uses macOS’s temporary override. macOS may occasionally charge to 100% to calibrate its estimate.").font(.caption).foregroundStyle(.secondary)
                    Text("These experimental controls use an isolated native battery interface available on compatible Apple silicon Macs. Charging behavior still needs hardware verification.").font(.caption).foregroundStyle(.secondary)
                } else if service.chargeControl.didCheck {
                    Label("Native charge control is unavailable on this Mac", systemImage: "lock.shield").font(.headline)
                }
                if let error = service.chargeControl.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Button("Refresh Charge Settings", systemImage: "arrow.clockwise") { service.chargeControl.refresh() }.disabled(service.chargeControl.isBusy)
                Button("Open Battery Settings", systemImage: "battery.100percent") { service.openBatterySettings() }
            }
        }.formStyle(.grouped).navigationTitle("Tether").onAppear { service.start() }
    }
}
