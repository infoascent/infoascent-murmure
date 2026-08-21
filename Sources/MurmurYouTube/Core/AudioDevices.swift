import AVFoundation
import CoreAudio
import Foundation

/// The Mac's audio input devices, and which one dictation should use.
///
/// `AVAudioEngine.inputNode` binds to the *system default* input device and offers no way
/// to choose another. That default is frequently not a microphone: aggregate devices built
/// by Loom, BlackHole, Rogue Amoeba tools and the like install themselves as the default so
/// they can capture system audio, and their first channel is usually the silent loopback
/// leg rather than a mic. Dictation then records perfect silence with no error anywhere —
/// the meter simply never moves.
///
/// So the device is selected explicitly, and the choice is persisted by **UID** rather than
/// `AudioDeviceID`: the numeric ID is reassigned on reboot and whenever devices come and go,
/// while the UID is stable for the life of the device.
struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    /// Every device exposing at least one input channel, in system order.
    static func inputs() -> [AudioDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    /// The system default input — what `AVAudioEngine` would have picked on its own.
    static func systemDefaultInput() -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return inputs().first { $0.id == id }
    }

    /// Resolves a persisted UID back to a live device, or nil if it has been unplugged.
    static func device(uid: String) -> AudioDevice? {
        inputs().first { $0.uid == uid }
    }

    /// The device dictation should actually record from: the user's pick when it is still
    /// present, otherwise the system default, otherwise the first input there is.
    static func preferred(uid: String?) -> AudioDevice? {
        if let uid, let match = device(uid: uid) { return match }
        return systemDefaultInput() ?? inputs().first
    }

    /// Points an `AVAudioEngine`'s input node at a specific device.
    ///
    /// Goes through `AUAudioUnit.setDeviceID`, which is the supported way to move an
    /// engine's input. Writing `kAudioOutputUnitProperty_CurrentDevice` on the raw
    /// `AudioUnit` looks equivalent and returns `noErr`, but `AVAudioEngine` has already
    /// configured its graph against the previous device by the time `inputNode` hands that
    /// unit over — so the write is accepted and then ignored, and capture silently carries
    /// on from the old device. The failure is invisible: audio still flows, the level meter
    /// still moves, and only the channel count in the log gives it away.
    ///
    /// Must be called while the engine is stopped, and before the node's format is read —
    /// the format belongs to whichever device is currently attached.
    static func bind(_ engine: AVAudioEngine, to device: AudioDevice) throws {
        let unit = engine.inputNode.auAudioUnit
        guard unit.deviceID != device.id else { return }
        do {
            try unit.setDeviceID(device.id)
        } catch {
            throw AudioDeviceError.selectionFailed(name: device.name, underlying: error)
        }
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids
    }

    /// Total input channels across every stream, which is what distinguishes a microphone
    /// from an output-only device.
    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

enum AudioDeviceError: LocalizedError {
    case selectionFailed(name: String, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .selectionFailed(let name, let underlying):
            return "Couldn't select \(name): \(underlying.localizedDescription)"
        }
    }
}
