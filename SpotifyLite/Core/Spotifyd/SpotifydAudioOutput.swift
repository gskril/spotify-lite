import CoreAudio
import Foundation

private final class CoreAudioDefaultOutputObserver: @unchecked Sendable {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.spotifylite.default-audio-output")
    private var continuation: AsyncStream<Void>.Continuation?
    private var isInstalled = false
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.emitChange()
    }

    func start(_ continuation: AsyncStream<Void>.Continuation) {
        let shouldInstall = lock.withLock {
            self.continuation = continuation
            guard !isInstalled else { return false }
            isInstalled = true
            return true
        }
        guard shouldInstall else { return }

        var address = Self.address
        let status = AudioObjectAddPropertyListenerBlock(
            Self.systemObject,
            &address,
            queue,
            listener
        )
        guard status == noErr else {
            lock.withLock {
                isInstalled = false
                self.continuation = nil
            }
            continuation.finish()
            return
        }
    }

    func stop() {
        let shouldRemove = lock.withLock {
            continuation = nil
            guard isInstalled else { return false }
            isInstalled = false
            return true
        }
        guard shouldRemove else { return }

        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(
            Self.systemObject,
            &address,
            queue,
            listener
        )
    }

    private func emitChange() {
        let activeContinuation: AsyncStream<Void>.Continuation? = lock.withLock {
            self.continuation
        }
        activeContinuation?.yield(())
    }
}

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

    static func statusDescription(from devices: [SpotifydAudioOutputDevice] = availableDevices()) -> String {
        return devices.first(where: \.isDefault)?.name ?? "System default"
    }

    static func defaultDeviceChanges() -> AsyncStream<Void> {
        let observer = CoreAudioDefaultOutputObserver()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { _ in observer.stop() }
            observer.start(continuation)
        }
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
