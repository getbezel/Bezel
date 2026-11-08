import Foundation
import CoreAudio

@main struct AudioChecks {
    static func withBuffers(_ channels: [Int], _ values: [[Float]], _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void) {
        let bytes = MemoryLayout<AudioBufferList>.size + max(0, channels.count - 1) * MemoryLayout<AudioBuffer>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        list.pointee.mNumberBuffers = UInt32(channels.count)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var allocated: [UnsafeMutablePointer<Float>] = []
        for index in channels.indices {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: values[index].count)
            pointer.initialize(from: values[index], count: values[index].count)
            allocated.append(pointer)
            buffers[index] = AudioBuffer(mNumberChannels: UInt32(channels[index]), mDataByteSize: UInt32(values[index].count * 4), mData: pointer)
        }
        body(list)
        for pointer in allocated { pointer.deallocate() }
        raw.deallocate()
    }
    static func output(_ list: UnsafeMutablePointer<AudioBufferList>, buffer: Int = 0) -> [Float] {
        let value = UnsafeMutableAudioBufferListPointer(list)[buffer]
        return Array(UnsafeBufferPointer(start: value.mData!.assumingMemoryBound(to: Float.self), count: Int(value.mDataByteSize) / 4))
    }
    static func main() async throws {
        let stereo = AirBridgeDevice(id: 1, uid: "test", name: "Test", outputChannels: 2, transport: 0)
        let mono = AirBridgeDevice(id: 2, uid: "mono", name: "Mono", outputChannels: 1, transport: 0)
        let state = AirBridgeRenderState(gain: 1, inputChannelOffset: 1, expectedInputChannels: 3, outputDevices: [stereo, mono])
        withBuffers([1, 2], [[0.9, 0.9], [0.25, -0.5, 0.5, -0.25]]) { input in
            withBuffers([2, 1], [[8, 8, 8, 8], [8, 8]]) { out in
                state.render(input: input, output: out)
                precondition(output(out) == [0.25, -0.5, 0.5, -0.25], "Stereo mapping ignores hardware input")
                precondition(output(out, buffer: 1) == [-0.125, 0.125], "Mono output mixes stereo")
                precondition(state.peak == 0.5, "Measured peak")
            }
        }
        let planar = AirBridgeRenderState(gain: 1, inputChannelOffset: 0, expectedInputChannels: 2, outputDevices: [stereo])
        withBuffers([1, 1], [[0.5, Float.nan], [-0.5, 0.25]]) { input in
            withBuffers([1, 1], [[8, 8], [8, 8]]) { out in
                planar.render(input: input, output: out)
                precondition(output(out) == [0.5, 0], "Planar input and NaN handling")
                precondition(output(out, buffer: 1) == [-0.5, 0.25], "Planar right output")
            }
        }
        let ramp = AirBridgeRenderState(gain: 1, inputChannelOffset: 0, expectedInputChannels: 2, outputDevices: [stereo])
        ramp.setGain(0)
        withBuffers([2], [[1, 1, 1, 1]]) { input in
            withBuffers([2], [[8, 8, 8, 8]]) { out in
                ramp.render(input: input, output: out)
                precondition(output(out) == [0.5, 0.5, 0, 0], "Smooth volume ramp")
            }
            withBuffers([1], [[8, 8]]) { out in
                ramp.render(input: input, output: out)
                precondition(output(out) == [0, 0], "Changed formats remain silent")
                precondition(ramp.invalidFormat.load(ordering: .relaxed), "Changed format watchdog")
            }
            withBuffers([2], [[8, 8, 8, 8]]) { out in
                ramp.render(input: input, output: out)
                precondition(output(out) == [0, 0, 0, 0], "Format gate stays closed until route is rebuilt")
            }
        }
        let duplicate = AirBridgeRenderState(gain: 1, inputChannelOffset: 0, expectedInputChannels: 2, outputDevices: [stereo, stereo])
        withBuffers([2], [[2, -2, 0.5, -0.5]]) { input in
            withBuffers([2, 2], [[8, 8, 8, 8], [8, 8, 8, 8]]) { out in
                duplicate.render(input: input, output: out)
                precondition(output(out) == [1, -1, 0.5, -0.5], "Output is bounded to full scale")
                precondition(output(out, buffer: 1) == output(out), "Second stereo output mirrors the first")
            }
            withBuffers([2, 2], [[8, 8], [8, 8, 8, 8]]) { out in
                duplicate.render(input: input, output: out)
                precondition(output(out) == [1, -1], "Short output capacity bounds rendering")
                precondition(output(out, buffer: 1) == [1, -1, 0, 0], "Unused output frames stay silent")
            }
            UnsafeMutableAudioBufferListPointer(input)[0].mData = nil
            withBuffers([2, 2], [[8, 8], [8, 8]]) { out in
                duplicate.render(input: input, output: out)
                precondition(output(out) == [0, 0], "Missing tap input stays silent")
                precondition(output(out, buffer: 1) == [0, 0], "Missing input silences both outputs")
                precondition(duplicate.peak == 0, "Missing input resets the meter")
            }
        }
        for (frequency, expectedBand) in [(450.0, 2), (6_000.0, 6)] {
            let spectrum = AudioSpectrum(sampleRate: 48_000)
            for frame in 0..<4_800 {
                let value = Float(sin(Double(frame) * 2 * .pi * frequency / 48_000)) * 0.2
                spectrum.offer(left: value, right: -value)
            }
            let bands = spectrum.bands
            precondition(bands.allSatisfy { $0.isFinite && (0...1).contains($0) }, "Frequency bands stay finite and normalized")
            precondition(bands[expectedBand] == bands.max() && bands[expectedBand] > 0.5, "Frequency bands must follow real input, including anti-phase stereo")
            spectrum.clear()
            precondition(spectrum.bands.allSatisfy { $0 == 0 }, "Spectrum reset clears stale playback")
            for _ in 0..<4_800 { spectrum.offer(left: .nan, right: .infinity) }
            precondition(spectrum.bands.allSatisfy { $0 == 0 }, "Nonfinite input must not generate false frequency activity")
        }
        let appURL = URL(fileURLWithPath: "/Applications/Browser.app")
        precondition(AirBridgeHAL.outerApplicationURL(appURL.appendingPathComponent("Contents/Frameworks/Helper.app/Contents/MacOS/helper"))?.path == appURL.path,
                     "Nested audio helpers must resolve to the outer application")
        let main = AirBridgeProcess(id: 10, pid: 100, bundleID: "test.browser", name: "Browser", isOutputActive: false, applicationURL: appURL, applicationPID: 100)
        let helper = AirBridgeProcess(id: 11, pid: 101, bundleID: "test.browser", name: "Browser", isOutputActive: true, applicationURL: appURL, applicationPID: 100)
        let unrelated = AirBridgeProcess(id: 12, pid: 102, bundleID: "test.browser.helper", name: "helper", isOutputActive: false)
        let grouped = AirBridgeHAL.groupProcesses([helper, main, unrelated])
        precondition(grouped.count == 2 && grouped[0].id == 10 && grouped[0].pid == 100 && grouped[0].isOutputActive,
                     "An active browser helper must activate the stable parent row without merging unknown helpers")
        precondition(grouped[0].captureProcessIDs == [10, 11], "Routing the parent must capture all of its audio helpers")
        print("PASS: nested-helper application identity, stable parent row selection, active-state merging and full application tap membership")
        print("PASS: stereo, mono and stereo mirroring, planar channels, input exclusion, NaN handling, gain ramps, clipping, bounded buffers, null input, format-change silence, and real stereo FFT frequency bands")
        if CommandLine.arguments.contains("--check-active-route") {
            let engine = AirBridgeEngine()
            do {
                let snapshot = try await engine.discover()
                guard let process = snapshot.processes.first(where: \.isOutputActive) else {
                    print("SKIP live route: no app is currently emitting audio")
                    return
                }
                let defaultID = try AirBridgeHAL.scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
                guard let output = snapshot.devices.first(where: { $0.id == defaultID }) else {
                    print("SKIP live route: current output is unavailable")
                    return
                }
                let before = try AirBridgeHAL.formats(output.id, scope: kAudioDevicePropertyScopeOutput).map(\.format.mSampleRate)
                let operation = UUID()
                let state = try await engine.start(processID: process.id, processIDs: process.captureProcessIDs,
                                                   outputs: [output], gain: 1, operationID: operation)
                try await Task.sleep(for: .seconds(1))
                let callbacks = state.callbackCount.load(ordering: .relaxed)
                let inputPeak = Float(bitPattern: state.inputPeakBits.load(ordering: .relaxed))
                let peak = state.peak
                let valid = !state.invalidFormat.load(ordering: .relaxed)
                let failures = await engine.validate(processes: snapshot.processes)
                await engine.stop(processID: process.id, operationID: operation)
                let after = try AirBridgeHAL.formats(output.id, scope: kAudioDevicePropertyScopeOutput).map(\.format.mSampleRate)
                precondition(callbacks > 0 && valid && failures.isEmpty, "The current output must deliver healthy live buffers")
                precondition(before == after, "Routing must not change the physical output's stream rate")
                if inputPeak > 0.00001 { precondition(abs(inputPeak - peak) < 0.0001, "Unity routing must preserve the live peak") }
                print("PASS live route: \(process.name), \(process.captureProcessIDs.count) audio processes, \(output.name), \(callbacks) callbacks, input peak \(inputPeak), output peak \(peak); original audio restored, device rates unchanged")
            } catch {
                await engine.stopAll()
                throw error
            }
        }
        if !CommandLine.arguments.contains("--skip-hardware") {
            let devices = try AirBridgeHAL.outputDevices()
            let processes = try AirBridgeHAL.audioProcesses()
            print("Read-only CoreAudio discovery: \(devices.count) outputs; \(processes.count) audio processes; \(processes.filter(\.isOutputActive).count) active output streams")
        }
    }
}
