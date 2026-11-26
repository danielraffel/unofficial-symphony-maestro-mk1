import CoreAudio
import Foundation

/// Diagnostics only: one line on standard output for every Core Audio
/// notification about the 8MicPre's input controls, with the value read at
/// that moment. Standard output is what a diagnostics report keeps under
/// "Maestro's own output".
///
/// A DAW sees the same notifications Maestro does. The lines show whether a
/// change made in Maestro is announced at all, on which property, in what
/// order, and what a client reading at that moment would get. They change
/// nothing: the strips still come from the driver's records.
///
/// The value is read inside the listener, on Core Audio's notification thread
/// (not an I/O thread): a read after a hop to the main actor would show only
/// the final value and hide an announcement made before the value changed.
enum MicPreHALLog {
    struct Listener {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
    }

    /// 'nlvl' and the like; hex when a code is not printable.
    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return String(format: "0x%08X", code) }
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
    }

    /// The device announces a great deal; only its input scope is about the
    /// 8MicPre. Everything a watched control object announces is kept.
    static func keeps(objectIsDevice: Bool, scope: AudioObjectPropertyScope) -> Bool {
        !objectIsDevice || scope == kAudioObjectPropertyScopeInput
    }

    /// Four bytes are shown as a number: a float for the two volume
    /// properties, an integer otherwise.
    static func valueText(selector: AudioObjectPropertySelector, bytes: [UInt8]?) -> String {
        guard let bytes else { return "not a number" }
        guard bytes.count == 4 else { return "\(bytes.count) bytes" }
        let raw = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if selector == kAudioDevicePropertyVolumeDecibels || selector == kAudioDevicePropertyVolumeScalar
            || selector == kAudioLevelControlPropertyDecibelValue || selector == kAudioLevelControlPropertyScalarValue {
            return String(format: "%.2f", Float32(bitPattern: raw))
        }
        return String(raw)
    }

    static func line(stamp: String, objectIsDevice: Bool, objectID: AudioObjectID,
                     address: AudioObjectPropertyAddress, value: String) -> String {
        let object = objectIsDevice ? "device" : "control \(objectID)"
        return "[MicPreHAL] \(stamp) \(object) '\(fourCC(address.mSelector))' "
            + "scope '\(fourCC(address.mScope))' element \(address.mElement) = \(value)"
    }

    /// Four-byte values only. Every value wanted here is one, and a larger
    /// one may be an object (a channel name is a CFString) that a raw copy
    /// would take ownership of and never release.
    static func read(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [UInt8]? {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size == 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &bytes) == noErr else { return nil }
        return Array(bytes.prefix(Int(size)))
    }

    /// Watches the device, and each of its line-level (input type) controls
    /// as an object of its own: a control that changes while the device stays
    /// silent about it is a different fault from nothing being announced.
    static func install(device: AudioObjectID) -> [Listener] {
        guard device != kAudioObjectUnknown else { return [] }
        let context = UnsafeMutableRawPointer(bitPattern: UInt(device))
        var listeners: [Listener] = []
        func watch(_ objectID: AudioObjectID) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertySelectorWildcard,
                mScope: kAudioObjectPropertyScopeWildcard,
                mElement: kAudioObjectPropertyElementWildcard)
            if AudioObjectAddPropertyListener(objectID, &address, micPreHALLogChanged, context) == noErr {
                listeners.append(Listener(objectID: objectID, address: address))
            }
        }
        watch(device)
        for control in controls(of: device) {
            func u32(_ selector: AudioObjectPropertySelector) -> UInt32? {
                read(control, AudioObjectPropertyAddress(mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain))
                    .flatMap { $0.count == 4 ? $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } : nil }
            }
            guard u32(kAudioObjectPropertyClass) == kAudioLineLevelControlClassID else { continue }
            watch(control)
            let element = u32(kAudioControlPropertyElement).map(String.init) ?? "?"
            let item = u32(kAudioSelectorControlPropertyCurrentItem).map(String.init) ?? "?"
            print("[MicPreHAL] watching control \(control): input type, element \(element), now \(item)")
        }
        return listeners
    }

    static func remove(_ listeners: [Listener], device: AudioObjectID) {
        let context = UnsafeMutableRawPointer(bitPattern: UInt(device))
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListener(listener.objectID, &address, micPreHALLogChanged, context)
        }
    }

    private static func controls(of device: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyControlList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}

/// The client data is the device's object ID, not a pointer.
private func micPreHALLogChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    let isDevice = UInt(bitPattern: clientData) == UInt(objectID)
    // Most of what the device announces is not kept: no work for those.
    let kept = (0..<Int(numberAddresses)).map { addresses[$0] }
        .filter { MicPreHALLog.keeps(objectIsDevice: isDevice, scope: $0.mScope) }
    guard !kept.isEmpty else { return noErr }
    let stamp = DiagnosticsRecorder.stamp(Date())
    for address in kept {
        let value = MicPreHALLog.valueText(selector: address.mSelector, bytes: MicPreHALLog.read(objectID, address))
        print(MicPreHALLog.line(stamp: stamp, objectIsDevice: isDevice, objectID: objectID,
                                address: address, value: value))
    }
    return noErr
}
