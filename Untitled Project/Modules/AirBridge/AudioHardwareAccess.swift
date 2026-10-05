import AppKit
import CoreAudio

struct AirBridgeDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannels: Int
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        default: "hifispeaker"
        }
    }
}

struct AirBridgeProcess: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let isOutputActive: Bool
}

struct AirBridgeHardwareError: LocalizedError, Sendable {
    let operation: String
    let status: OSStatus
    var errorDescription: String? {
        let code = UInt32(bitPattern: status)
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        let detail = bytes.allSatisfy { (32...126).contains($0) } ? String(bytes: bytes, encoding: .ascii)! : String(status)
        return "\(operation) failed (\(detail)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
    }
}

enum AirBridgeError: LocalizedError, Sendable {
    case unsupportedFormat
    case noOutput
    case noTapStream
    case deviceChanged
    case noCallbacks

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This device’s stream format is not supported. AirBridge requires native 32-bit floating-point PCM."
        case .noOutput: "Choose an available audio output."
        case .noTapStream: "Core Audio did not expose the application’s stereo tap stream."
        case .deviceChanged: "The audio device or stream format changed. Normal application audio has been restored. Start the route again."
        case .noCallbacks: "The audio route did not deliver buffers. Normal application audio has been restored. Check audio recording permission and try again while the application is playing."
        }
    }
}

enum AirBridgeHAL {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AirBridgeHardwareError(operation: operation, status: status) }
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var property = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        try check(status, "Reading audio property")
        return value
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Reading audio objects")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!)
        }
        try check(status, "Reading audio objects")
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func formats(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> [(id: AudioStreamID, format: AudioStreamBasicDescription)] {
        try objectIDs(device, kAudioDevicePropertyStreams, scope: scope).map {
            ($0, try scalar($0, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()))
        }
    }

    static func outputDevices() throws -> [AirBridgeDevice] {
        try objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("dev.bezel.airbridge."),
                  let channels = try? formats(id, scope: kAudioDevicePropertyScopeOutput).reduce(0, { $0 + Int($1.format.mChannelsPerFrame) }),
                  channels > 0,
                  (try? scalar(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1 else { return nil }
            return AirBridgeDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Audio output", outputChannels: channels,
                                   transport: (try? scalar(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func audioProcesses() throws -> [AirBridgeProcess] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return try objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard let pid = try? scalar(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0, pid != ownPID else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let bundle = string(object, kAudioProcessPropertyBundleID) ?? app?.bundleIdentifier ?? ""
            let name = app?.localizedName ?? bundle.split(separator: ".").last.map(String.init) ?? "Process \(pid)"
            let running = (try? scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1
            return AirBridgeProcess(id: object, pid: pid, bundleID: bundle, name: name, isOutputActive: running)
        }.sorted {
            if $0.isOutputActive != $1.isOutputActive { return $0.isOutputActive }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func isSupported(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
        format.mChannelsPerFrame > 0 && format.mSampleRate > 0 &&
        format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? format.mChannelsPerFrame : 1)
    }
}
