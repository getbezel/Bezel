import SwiftUI

struct AirBridgeView: View {
    @Bindable var service: AirBridgeService
    @State private var showsInactive = false

    private var displayedChannels: [AirBridgeChannel] { showsInactive ? service.channels : service.visibleChannels }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sound, in its place.")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("Send each application to its own speakers or headphones.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    if service.activeRouteCount > 0 || service.channels.contains(where: \.isBusy) {
                        Button("Stop All", systemImage: "stop.circle") { service.stopAllRoutes() }
                            .disabled(service.isStoppingAll)
                    }
                }

                HStack(spacing: 12) {
                    Image(systemName: "waveform.path")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.activeRouteCount == 0 ? "Ready when you are" : "\(service.activeRouteCount) active \(service.activeRouteCount == 1 ? "route" : "routes")")
                            .font(.headline)
                        Text("Start a route to allow system audio recording. Stopping restores the application’s normal audio output.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))

                if let error = service.discoveryError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                HStack {
                    Text("APPLICATION MIXER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show inactive", isOn: $showsInactive).toggleStyle(.checkbox).font(.callout)
                }

                if displayedChannels.isEmpty {
                    ContentUnavailableView("No active audio applications", systemImage: "speaker.slash", description: Text("Play audio in an application to see it here. You can also show inactive applications with an audio connection."))
                        .frame(minHeight: 200)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(displayedChannels) { channel in
                            AirBridgeChannelView(channel: channel, service: service)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Audio stays on your Mac", systemImage: "lock.shield")
                        .font(.callout.weight(.medium))
                    Text("Meters show live routed audio. A second output mirrors the same stereo mix. Bluetooth outputs may have different latency. Protected audio and devices that do not expose a compatible PCM stream cannot be routed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Audio Recording Privacy Settings…") { service.openAudioPrivacySettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }
}

private struct AirBridgeChannelView: View {
    @Bindable var channel: AirBridgeChannel
    let service: AirBridgeService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Group {
                    if let icon = channel.icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
                }
                .scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.process.name).font(.headline)
                    Text(channel.isRouting ? "Routed audio" : channel.process.isOutputActive ? "Active output · System routing" : "Inactive audio connection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if channel.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Updating audio route")
                }
                Button(channel.isRouting ? "Stop Routing" : "Start Routing", systemImage: channel.isRouting ? "stop.fill" : "arrow.triangle.branch") {
                    if channel.isRouting { service.stopRouting(channel) }
                    else { service.startRouting(channel) }
                }
                .disabled(channel.isBusy || service.isStoppingAll || service.isSuspended || (!channel.isRouting && service.devices.isEmpty))
            }

            HStack(spacing: 20) {
                Picker("Output", selection: $channel.primaryOutputID) {
                    if !service.devices.contains(where: { $0.id == channel.primaryOutputID }) { Text("Choose an output").tag(channel.primaryOutputID) }
                    ForEach(service.devices) { device in
                        Label(device.name, systemImage: device.symbol).tag(device.id)
                    }
                }
                Picker("Also play on", selection: $channel.secondaryOutputID) {
                    Text("None").tag(UInt32(0))
                    ForEach(service.devices.filter { $0.id != channel.primaryOutputID }) { device in
                        Label(device.name, systemImage: device.symbol).tag(device.id)
                    }
                }
            }
            .disabled(channel.isRouting || channel.isBusy)
            .onChange(of: channel.primaryOutputID) {
                if channel.secondaryOutputID == channel.primaryOutputID { channel.secondaryOutputID = 0 }
            }

            HStack(spacing: 12) {
                Image(systemName: channel.gain == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Slider(value: $channel.gain, in: 0...1) { Text("\(channel.process.name) volume") }
                    .disabled(!channel.isRouting)
                    .accessibilityValue("\(Int(channel.gain * 100)) percent")
                Text("\(Int(channel.gain * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(channel.level > 0.94 ? Color.orange : Color.accentColor)
                                .frame(width: max(0, proxy.size.width * meterFraction))
                        }
                    }
                    .frame(width: 88, height: 4)
                    Text(channel.isRouting ? channel.decibels : "Not measured")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Audio level")
                .accessibilityValue(channel.isRouting ? channel.decibels : "Not measured")
            }

            if let error = channel.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
    }

    private var meterFraction: Double { channel.level > 0 ? min(1, max(0, (20 * log10(channel.level) + 60) / 60)) : 0 }
}
