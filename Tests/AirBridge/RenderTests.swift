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
    static func main() throws {
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
        print("PASS: stereo, mono and stereo mirroring, planar channels, input exclusion, NaN handling, gain ramps, clipping, bounded buffers, null input, format-change silence, and real stereo FFT frequency bands")
        if !CommandLine.arguments.contains("--skip-hardware") {
            let devices = try AirBridgeHAL.outputDevices()
            let processes = try AirBridgeHAL.audioProcesses()
            print("Read-only CoreAudio discovery: \(devices.count) outputs; \(processes.count) audio processes; \(processes.filter(\.isOutputActive).count) active output streams")
        }
    }
}
