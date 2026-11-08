import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Immutable channel configuration plus lock-free control/meter values shared with the HAL.
/// `smoothedGain` is accessed only by this route’s serial realtime IO callback.
final class AirBridgeRenderState: @unchecked Sendable {
    let gainBits: Atomic<UInt32>
    let peakBits = Atomic<UInt32>(0)
    let callbackCount = Atomic<UInt64>(0)
    let invalidFormat = Atomic<Bool>(false)
    let lastInputFrameCount = Atomic<UInt32>(0)
    let lastOutputFrameCount = Atomic<UInt32>(0)
    let inputPeakBits = Atomic<UInt32>(0)
    let inputChannelOffset: Int
    let expectedInputChannels: Int
    let outputChannelCount: Int
    let outputMap: UnsafeMutablePointer<Int8>
    let spectrum: AudioSpectrum
    private var smoothedGain: Float

    init(gain: Float, inputChannelOffset: Int, expectedInputChannels: Int, outputDevices: [AirBridgeDevice], sampleRate: Double = 48_000) {
        spectrum = AudioSpectrum(sampleRate: sampleRate)
        gainBits = Atomic(gain.bitPattern)
        smoothedGain = gain
        self.inputChannelOffset = inputChannelOffset
        self.expectedInputChannels = expectedInputChannels
        outputChannelCount = outputDevices.reduce(0) { $0 + $1.outputChannels }
        outputMap = .allocate(capacity: max(1, outputChannelCount))
        outputMap.initialize(repeating: -1, count: max(1, outputChannelCount))
        var offset = 0
        for device in outputDevices {
            outputMap[offset] = device.outputChannels == 1 ? 2 : 0
            if device.outputChannels > 1 { outputMap[offset + 1] = 1 }
            offset += device.outputChannels
        }
    }

    deinit { outputMap.deallocate() }

    func setGain(_ value: Double) { gainBits.store(Float(min(1, max(0, value))).bitPattern, ordering: .relaxed) }
    var peak: Float { Float(bitPattern: peakBits.load(ordering: .relaxed)) }

    /// No heap allocations, locks, actor hops, HAL property access, or logging on this thread.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var inputChannels = 0
        var outputChannels = 0
        for buffer in inputs { inputChannels += Int(buffer.mNumberChannels) }
        for buffer in outputs {
            outputChannels += Int(buffer.mNumberChannels)
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard !invalidFormat.load(ordering: .relaxed) else {
            peakBits.store(0, ordering: .relaxed)
            spectrum.clear()
            return
        }
        guard inputChannels == expectedInputChannels, outputChannels == outputChannelCount else {
            invalidFormat.store(true, ordering: .relaxed)
            peakBits.store(0, ordering: .relaxed)
            spectrum.clear()
            return
        }

        var left: UnsafePointer<Float>?
        var right: UnsafePointer<Float>?
        var leftStride = 1
        var rightStride = 1
        var frames = Int.max
        var channelOffset = 0
        for buffer in inputs {
            let count = Int(buffer.mNumberChannels)
            if count > 0, let data = buffer.mData {
                let base = data.assumingMemoryBound(to: Float.self)
                if (channelOffset..<(channelOffset + count)).contains(inputChannelOffset) {
                    left = UnsafePointer(base.advanced(by: inputChannelOffset - channelOffset))
                    leftStride = count
                    frames = min(frames, Int(buffer.mDataByteSize) / (4 * count))
                }
                if (channelOffset..<(channelOffset + count)).contains(inputChannelOffset + 1) {
                    right = UnsafePointer(base.advanced(by: inputChannelOffset + 1 - channelOffset))
                    rightStride = count
                    frames = min(frames, Int(buffer.mDataByteSize) / (4 * count))
                }
            }
            channelOffset += count
        }
        callbackCount.wrappingAdd(1, ordering: .relaxed)
        guard let left, let right, frames > 0, frames != Int.max else {
            peakBits.store(0, ordering: .relaxed)
            spectrum.clear()
            return
        }
        lastInputFrameCount.store(UInt32(clamping: frames), ordering: .relaxed)
        if let buffer = outputs.first(where: { $0.mNumberChannels > 0 && $0.mData != nil }) {
            lastOutputFrameCount.store(buffer.mDataByteSize / (4 * buffer.mNumberChannels), ordering: .relaxed)
        }
        for buffer in outputs where buffer.mNumberChannels > 0 && buffer.mData != nil {
            frames = min(frames, Int(buffer.mDataByteSize) / (4 * Int(buffer.mNumberChannels)))
        }
        guard frames > 0 else { peakBits.store(0, ordering: .relaxed); spectrum.clear(); return }
        let targetGain = Float(bitPattern: gainBits.load(ordering: .relaxed))
        let startingGain = smoothedGain
        let gainStep = (targetGain - startingGain) / Float(frames)
        var analysisGain = startingGain
        var inputPeak: Float = 0
        for frame in 0..<frames {
            analysisGain += gainStep
            let l = left[frame * leftStride]
            let r = right[frame * rightStride]
            if l.isFinite { inputPeak = max(inputPeak, abs(l)) }; if r.isFinite { inputPeak = max(inputPeak, abs(r)) }
            spectrum.offer(left: l.isFinite ? min(1, max(-1, l * analysisGain)) : 0,
                           right: r.isFinite ? min(1, max(-1, r * analysisGain)) : 0)
        }
        inputPeakBits.store(inputPeak.bitPattern, ordering: .relaxed)
        var peak: Float = 0
        var outputOffset = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            if let data = buffer.mData, channels > 0 {
                let samples = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels {
                    let source = outputMap[outputOffset + channel]
                    guard source >= 0 else { continue }
                    var gain = startingGain
                    for frame in 0..<frames {
                        gain += gainStep
                        let raw: Float
                        if source == 0 { raw = left[frame * leftStride] }
                        else if source == 1 { raw = right[frame * rightStride] }
                        else { raw = (left[frame * leftStride] + right[frame * rightStride]) * 0.5 }
                        let value = raw.isFinite ? min(1, max(-1, raw * gain)) : 0
                        samples[frame * channels + channel] = value
                        peak = max(peak, abs(value))
                    }
                }
            }
            outputOffset += channels
        }
        smoothedGain = targetGain
        peakBits.store(peak.bitPattern, ordering: .relaxed)
    }
}

private let airBridgeIOProc: AudioDeviceIOProc = { _, _, input, _, output, _, context in
    guard let context else { return noErr }
    Unmanaged<AirBridgeRenderState>.fromOpaque(context).takeUnretainedValue().render(input: input, output: output)
    return noErr
}

private final class AirBridgeRoute {
    let operationID: UUID
    let processID: AudioObjectID
    private var processIDs: Set<AudioObjectID>
    let outputs: [AirBridgeDevice]
    let renderState: AirBridgeRenderState
    let inputFormats: [AudioStreamBasicDescription]
    let outputFormats: [AudioStreamBasicDescription]
    let clockRate: Double
    private var tapID: AudioObjectID
    private let tapDescription: CATapDescription
    private var aggregateID: AudioObjectID
    private var ioProc: AudioDeviceIOProcID?
    private let formatListener: AudioObjectPropertyListenerBlock
    private var listenedProperties: [(AudioObjectID, AudioObjectPropertyAddress)]
    private var lastCallbackCount: UInt64 = 0
    private var lastCallbackProgress = ContinuousClock.now

    init(processID: AudioObjectID, processIDs: [AudioObjectID], outputs: [AirBridgeDevice], gain: Float, operationID: UUID) throws {
        guard !outputs.isEmpty, outputs.count <= 2 else { throw AirBridgeError.noOutput }
        self.operationID = operationID
        self.processID = processID
        self.processIDs = Set(processIDs)
        self.outputs = outputs
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.name = "Bezel application audio"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap: AudioObjectID = 0
        try AirBridgeHAL.check(AudioHardwareCreateProcessTap(description, &tap), "Creating application audio tap")
        var aggregate: AudioObjectID = 0
        var createdProc: AudioDeviceIOProcID?
        var acquiredState: AirBridgeRenderState?
        // The C callback has an unretained context. Keep it alive through failure cleanup,
        // including a partially successful AudioDeviceStart.
        defer { withExtendedLifetime(acquiredState) {} }
        var listener: AudioObjectPropertyListenerBlock?
        var registeredProperties: [(AudioObjectID, AudioObjectPropertyAddress)] = []
        do {
            let tapFormat = try AirBridgeHAL.scalar(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard AirBridgeHAL.isSupported(tapFormat), tapFormat.mChannelsPerFrame == 2 else { throw AirBridgeError.unsupportedFormat }
            guard let tapUID = AirBridgeHAL.string(tap, kAudioTapPropertyUID) else { throw AirBridgeError.noTapStream }
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Bezel AirBridge",
                kAudioAggregateDeviceUIDKey: "dev.bezel.airbridge.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputs[0].uid,
                // Starting must never wait for an application to produce its first sample.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: outputs.enumerated().map { index, device in
                    [kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: index != 0,
                     kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality] as [String: Any]
                },
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true,
                                                     kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality]]
            ]
            try AirBridgeHAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Creating private audio route")
            let inputs = try AirBridgeHAL.formats(aggregate, scope: kAudioDevicePropertyScopeInput)
            let outputStreams = try AirBridgeHAL.formats(aggregate, scope: kAudioDevicePropertyScopeOutput)
            guard let lastInput = inputs.last, lastInput.format.mChannelsPerFrame == 2,
                  AirBridgeHAL.isSupported(lastInput.format), !outputStreams.isEmpty else { throw AirBridgeError.noTapStream }
            guard outputStreams.allSatisfy({ AirBridgeHAL.isSupported($0.format) }),
                  outputStreams.reduce(0, { $0 + Int($1.format.mChannelsPerFrame) }) == outputs.reduce(0, { $0 + $1.outputChannels }),
                  outputs.reduce(0, { $0 + $1.outputChannels }) <= 128 else { throw AirBridgeError.unsupportedFormat }
            // Every IOProc buffer runs on the aggregate's master clock. CoreAudio
            // converts tap/secondary-device rates through drift compensation;
            // stream ASBDs can still report their original 48/44.1 kHz rates.
            let rate = try AirBridgeHAL.scalar(aggregate, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
            guard rate.isFinite, rate > 0 else { throw AirBridgeError.unsupportedFormat }
            let inputChannels = inputs.reduce(0) { $0 + Int($1.format.mChannelsPerFrame) }
            let state = AirBridgeRenderState(gain: gain, inputChannelOffset: inputChannels - 2, expectedInputChannels: inputChannels, outputDevices: outputs, sampleRate: rate)
            acquiredState = state
            try AirBridgeHAL.check(AudioDeviceCreateIOProcID(aggregate, airBridgeIOProc, Unmanaged.passUnretained(state).toOpaque(), &createdProc), "Creating audio playback callback")
            guard let createdProc else { throw AirBridgeError.noCallbacks }
            // Hardware input streams are never read. Only the final process-tap stream is enabled.
            // This also avoids activating the microphone on duplex headsets and USB interfaces.
            let usageSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + max(0, inputs.count - 1) * MemoryLayout<UInt32>.size
            let usage = UnsafeMutableRawPointer.allocate(byteCount: usageSize, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
            defer { usage.deallocate() }
            usage.initializeMemory(as: UInt8.self, repeating: 0, count: usageSize)
            let header = usage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
            header.pointee.mIOProc = unsafeBitCast(createdProc, to: UnsafeMutableRawPointer.self)
            header.pointee.mNumberStreams = UInt32(inputs.count)
            let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
            usage.advanced(by: flagsOffset).assumingMemoryBound(to: UInt32.self)[inputs.count - 1] = 1
            var property = AirBridgeHAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioDevicePropertyScopeInput)
            try AirBridgeHAL.check(AudioObjectSetPropertyData(aggregate, &property, 0, nil, UInt32(usageSize), usage), "Disabling hardware microphone streams")
            try AirBridgeHAL.check(AudioDeviceStart(aggregate, createdProc), "Starting application audio route")
            // A format change closes the realtime gate immediately. The actor then dismantles
            // the route on its next health check, restoring the original application output.
            let onFormatChanged: AudioObjectPropertyListenerBlock = { _, _ in
                state.invalidFormat.store(true, ordering: .relaxed)
            }
            listener = onFormatChanged
            let watched = (inputs + outputStreams).map { ($0.id, kAudioStreamPropertyVirtualFormat) } +
                outputs.map { ($0.id, kAudioDevicePropertyDeviceIsAlive) } + [(aggregate, kAudioDevicePropertyNominalSampleRate)]
            for (object, selector) in watched {
                var watchedProperty = AirBridgeHAL.address(selector)
                try AirBridgeHAL.check(AudioObjectAddPropertyListenerBlock(object, &watchedProperty, nil, onFormatChanged), "Monitoring audio stream format")
                registeredProperties.append((object, watchedProperty))
            }
            clockRate = rate
            renderState = state
            inputFormats = inputs.map(\.format)
            outputFormats = outputStreams.map(\.format)
            tapID = tap
            tapDescription = description
            aggregateID = aggregate
            ioProc = createdProc
            formatListener = onFormatChanged
            listenedProperties = registeredProperties
        } catch {
            Self.restoreOriginalAudio(tap: tap, description: description)
            if let listener {
                for (object, var property) in registeredProperties { AudioObjectRemovePropertyListenerBlock(object, &property, nil, listener) }
            }
            if let createdProc {
                AudioDeviceStop(aggregate, createdProc)
                AudioDeviceDestroyIOProcID(aggregate, createdProc)
            }
            if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    func stop() {
        for (object, var property) in listenedProperties { AudioObjectRemovePropertyListenerBlock(object, &property, nil, formatListener) }
        listenedProperties.removeAll()
        if let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            // Explicitly unmute as well as using mutedWhenTapped. Even if a disconnected
            // device refuses to stop cleanly, the original process must keep its audio.
            Self.restoreOriginalAudio(tap: tapID, description: tapDescription)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            self.ioProc = nil
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }

    private static func restoreOriginalAudio(tap: AudioObjectID, description: CATapDescription) {
        guard tap != 0 else { return }
        description.muteBehavior = .unmuted
        var value = description
        var address = AirBridgeHAL.address(kAudioTapPropertyDescription)
        _ = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
    }

    deinit { stop() }

    func updateProcesses(_ ids: [AudioObjectID]) throws {
        let updated = Set(ids)
        guard updated != processIDs else { return }
        guard !updated.isEmpty else { throw AirBridgeError.deviceChanged }
        tapDescription.processes = updated.sorted()
        var value = tapDescription
        var property = AirBridgeHAL.address(kAudioTapPropertyDescription)
        try AirBridgeHAL.check(withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(tapID, &property, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }, "Updating application audio processes")
        processIDs = updated
    }

    func checkHealth() throws {
        guard !renderState.invalidFormat.load(ordering: .relaxed) else { throw AirBridgeError.deviceChanged }
        let callbacks = renderState.callbackCount.load(ordering: .relaxed)
        if callbacks != lastCallbackCount {
            lastCallbackCount = callbacks
            lastCallbackProgress = .now
        } else if lastCallbackProgress.duration(to: .now) > .seconds(8) {
            throw AirBridgeError.noCallbacks
        }
        for output in outputs {
            guard (try? AirBridgeHAL.scalar(output.id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1,
                  AirBridgeHAL.string(output.id, kAudioDevicePropertyDeviceUID) == output.uid else { throw AirBridgeError.deviceChanged }
        }
        guard try AirBridgeHAL.scalar(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) == clockRate else { throw AirBridgeError.deviceChanged }
        let newInputs = try AirBridgeHAL.formats(aggregateID, scope: kAudioDevicePropertyScopeInput).map(\.format)
        let newOutputs = try AirBridgeHAL.formats(aggregateID, scope: kAudioDevicePropertyScopeOutput).map(\.format)
        func matches(_ a: [AudioStreamBasicDescription], _ b: [AudioStreamBasicDescription]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy {
                $0.mSampleRate == $1.mSampleRate && $0.mFormatID == $1.mFormatID && $0.mFormatFlags == $1.mFormatFlags &&
                $0.mChannelsPerFrame == $1.mChannelsPerFrame && $0.mBytesPerFrame == $1.mBytesPerFrame && $0.mBitsPerChannel == $1.mBitsPerChannel
            }
        }
        guard matches(inputFormats, newInputs), matches(outputFormats, newOutputs) else { throw AirBridgeError.deviceChanged }
    }
}

actor AirBridgeEngine {
    private var routes: [AudioObjectID: AirBridgeRoute] = [:]

    func discover() throws -> (devices: [AirBridgeDevice], processes: [AirBridgeProcess]) {
        (try AirBridgeHAL.outputDevices(), try AirBridgeHAL.audioProcesses())
    }

    func start(processID: AudioObjectID, processIDs: [AudioObjectID]? = nil, outputs: [AirBridgeDevice], gain: Double, operationID: UUID) throws -> AirBridgeRenderState {
        routes.removeValue(forKey: processID)?.stop()
        let route = try AirBridgeRoute(processID: processID, processIDs: processIDs ?? [processID], outputs: outputs, gain: Float(gain), operationID: operationID)
        routes[processID] = route
        return route.renderState
    }

    func stop(processID: AudioObjectID, operationID: UUID) {
        guard routes[processID]?.operationID == operationID else { return }
        routes.removeValue(forKey: processID)?.stop()
    }
    func stopAll() { for route in routes.values { route.stop() }; routes.removeAll() }

    func validate(processes: [AirBridgeProcess]) -> [AudioObjectID: AirBridgeRouteFailure] {
        let members = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0.captureProcessIDs) })
        var failures: [AudioObjectID: AirBridgeRouteFailure] = [:]
        for (id, route) in routes {
            do {
                guard let ids = members[id] else { throw AirBridgeError.deviceChanged }
                try route.updateProcesses(ids)
                try route.checkHealth()
            } catch { failures[id] = AirBridgeRouteFailure(operationID: route.operationID, message: error.localizedDescription) }
        }
        for id in failures.keys { routes.removeValue(forKey: id)?.stop() }
        return failures
    }
}

struct AirBridgeRouteFailure: Sendable {
    let operationID: UUID
    let message: String
}
