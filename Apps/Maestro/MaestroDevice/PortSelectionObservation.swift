import CoreAudio
import Foundation
import MaestroCore

/// EXPERIMENT (64 channels, stage 2): the ThunderBridge port selector as Core
/// Audio publishes it.
///
/// A two-port build of the driver puts the original's "Source" selector on the
/// device as `kAudioDevicePropertyDataSource`, main element, on the input and
/// the output scope; the driver keeps the two in step. This is the property
/// Audio MIDI Setup and Sound settings write, so reading, writing and listening
/// to it here is what keeps Maestro and those two showing the same thing.
/// Elements 1 and 2 of the output scope are the optical-format selectors and
/// are not touched.
public enum PortSelectionProperty {
    static func address(scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The scopes the selector is published on, output first.
    static let scopes: [AudioObjectPropertyScope] = [kAudioObjectPropertyScopeOutput,
                                                     kAudioObjectPropertyScopeInput]

    /// The device's current data-source ID, or nil when the device has no port
    /// selector (every released driver) or the ID is not one of the two entries.
    public static func read(deviceID: AudioDeviceID) -> UInt32? {
        for scope in scopes {
            var address = Self.address(scope: scope)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { continue }
            return PortSelection(dataSourceID: value) == nil ? nil : value
        }
        return nil
    }

    /// Ask the device for a selection, exactly as Audio MIDI Setup does. The
    /// driver sets the other scope itself. Throws when the device has no
    /// selector or refuses the write.
    public static func write(deviceID: AudioDeviceID, selection: PortSelection) throws {
        var lastStatus: OSStatus = kAudioHardwareUnknownPropertyError
        for scope in scopes {
            var address = Self.address(scope: scope)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value = selection.rawValue
            lastStatus = AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                                    UInt32(MemoryLayout<UInt32>.size), &value)
            if lastStatus == noErr { return }
        }
        throw DeviceConnectionError.transportError("Port selection write failed: OSStatus \(lastStatus)")
    }
}

/// Owns the Core Audio listeners for the port selector. Keep it alive while
/// consuming `selections`, then call `stop()` (or release it). Each element is
/// the device's data-source ID at that moment, nil if the selector is not
/// there. The first element is the value at subscription.
///
/// Besides the selector itself it listens to the device's stream configuration:
/// the driver changes the channel count a moment after the selector, and that
/// is when its explanation of a refusal is ready to be read.
public final class PortSelectionObservation {
    public let selections: AsyncStream<UInt32?>
    private let deviceID: AudioDeviceID
    private let queue = DispatchQueue(label: "com.danielraffel.maestro.port-selection")
    private let listener: AudioObjectPropertyListenerBlock
    private let continuation: AsyncStream<UInt32?>.Continuation
    private var addresses: [AudioObjectPropertyAddress] = []

    public init(deviceID: AudioDeviceID) throws {
        self.deviceID = deviceID
        let pair = AsyncStream<UInt32?>.makeStream(bufferingPolicy: .bufferingNewest(4))
        selections = pair.stream
        continuation = pair.continuation
        let continuation = pair.continuation
        listener = { _, _ in
            continuation.yield(PortSelectionProperty.read(deviceID: deviceID))
        }
        var wanted = PortSelectionProperty.scopes.map { PortSelectionProperty.address(scope: $0) }
        wanted.append(AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain))
        for var address in wanted {
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener) == noErr {
                addresses.append(address)
            }
        }
        guard !addresses.isEmpty else {
            continuation.finish()
            throw DeviceConnectionError.transportError("Port selection listener could not be registered")
        }
        // Serialized with the callbacks, so an older first read cannot
        // overwrite a newer notification.
        queue.async {
            continuation.yield(PortSelectionProperty.read(deviceID: deviceID))
        }
    }

    /// Call on the owning task, not from the Core Audio callback.
    public func stop() {
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
        }
        addresses.removeAll()
        continuation.finish()
    }

    deinit { stop() }
}
