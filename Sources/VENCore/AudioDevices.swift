import CoreAudio
import Foundation

public let venDeviceUID = "VENEnhancedMic_UID"
/// Custom driver property: how many apps other than VEN are recording from the virtual mic.
public let venClientCountSelector: AudioObjectPropertySelector = 0x7663_6E74 // 'vcnt'

public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let transport: UInt32
    public let sampleRate: Double

    public var isVEN: Bool { uid == venDeviceUID }
    public var isVirtual: Bool {
        transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
    }
}

public enum AudioDevices {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var addr = address(selector, scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result)
        return err == noErr ? result : value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDevice(
                id: id,
                uid: uid,
                name: string(id, kAudioObjectPropertyName) ?? "Unknown",
                inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                transport: get(id, kAudioDevicePropertyTransportType, default: UInt32(0)),
                sampleRate: get(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
            )
        }
    }

    /// Microphones the app can use as a source (never the VEN device itself).
    public static func inputs() -> [AudioDevice] {
        all().filter { $0.inputChannels > 0 && !$0.isVEN }
    }

    public static func venDevice() -> AudioDevice? {
        all().first { $0.isVEN }
    }

    public static func defaultOutput() -> AudioDeviceID {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
    }

    public static func defaultInput() -> AudioDeviceID {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(0))
    }

    /// The best physical mic: an external USB/Thunderbolt mic beats the built-in one; virtual
    /// devices and Bluetooth (low-quality headset profile) come last.
    public static func automaticInput() -> AudioDevice? {
        let candidates = inputs()
        func rank(_ d: AudioDevice) -> Int {
            if d.isVirtual { return 0 }
            switch d.transport {
            case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire,
                 kAudioDeviceTransportTypePCI:
                return 5
            case kAudioDeviceTransportTypeBuiltIn: return 3
            case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return 2
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 1
            default: return 2
            }
        }
        let fallback = candidates.first { $0.id == defaultInput() && !$0.isVirtual }
        return candidates.max { rank($0) < rank($1) } ?? fallback
    }

    /// Number of apps other than VEN currently recording from the virtual mic.
    public static func venClientCount(_ device: AudioDeviceID) -> Int {
        var addr = address(venClientCountSelector)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let value else { return 0 }
        return (value.takeRetainedValue() as? NSNumber)?.intValue ?? 0
    }

    public static func setBufferSize(_ device: AudioDeviceID, frames: UInt32) {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Calls `handler` on the main queue when `selector` changes on `object`. Returns a token for `removeListener`.
    @discardableResult
    public static func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                   handler: @escaping () -> Void) -> ListenerToken {
        var addr = address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block)
        return ListenerToken(object: object, address: addr, block: block)
    }

    public static func removeListener(_ token: ListenerToken) {
        var addr = token.address
        AudioObjectRemovePropertyListenerBlock(token.object, &addr, DispatchQueue.main, token.block)
    }

    public struct ListenerToken {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
}
