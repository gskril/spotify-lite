import CoreAudio
import Foundation

struct SpotifydAudioOutputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let outputChannels: Int
    let isDefault: Bool
    let isBuiltIn: Bool
}

enum SpotifydAudioOutput {
    static func availableDevices() -> [SpotifydAudioOutputDevice] {
        let defaultID = defaultOutputDeviceID()
        return allDeviceIDs().compactMap { id in
            let channels = outputChannelCount(for: id)
            guard channels > 0, let name = deviceName(for: id), !name.isEmpty else { return nil }
            return SpotifydAudioOutputDevice(
                id: id,
                name: name,
                outputChannels: channels,
                isDefault: id == defaultID,
                isBuiltIn: transportType(for: id) == kAudioDeviceTransportTypeBuiltIn
            )
        }
        .sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// PortAudio in spotifyd 0.4.2 opens a two-channel stream. A mono default
    /// device (commonly a Bluetooth hands-free profile) otherwise crashes it.
    static func recommendedDeviceName(from devices: [SpotifydAudioOutputDevice] = availableDevices()) -> String? {
        if let defaultDevice = devices.first(where: \.isDefault), defaultDevice.outputChannels >= 2 {
            return nil
        }
        return devices.first(where: { $0.isBuiltIn && $0.outputChannels >= 2 })?.name
            ?? devices.first(where: { $0.outputChannels >= 2 })?.name
    }

    static func statusDescription(from devices: [SpotifydAudioOutputDevice] = availableDevices()) -> String {
        if let fallback = recommendedDeviceName(from: devices) {
            return "\(fallback) (safe stereo fallback)"
        }
        return devices.first(where: \.isDefault)?.name ?? "System default"
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func deviceName(for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeUnretainedValue() as String?
    }

    private static func transportType(for id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func outputChannelCount(for id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
