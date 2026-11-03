import CoreAudio
import Foundation

/// Owns one HAL nominal-rate listener. Keep it alive while consuming `rates`,
/// then call `stop()` (or release it) to remove the exact registered block.
/// Registration precedes the initial read so a rate change cannot be missed
/// between the first snapshot and subscribing. No hardware writes are made.
public final class NominalSampleRateObservation {
    public let rates: AsyncStream<Double?>
    private let deviceID: AudioDeviceID
    private let queue = DispatchQueue(label: "com.danielraffel.maestro.nominal-rate")
    private let listener: AudioObjectPropertyListenerBlock
    private let continuation: AsyncStream<Double?>.Continuation
    private var isListening = true

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    public init(deviceID: AudioDeviceID) throws {
        self.deviceID = deviceID
        let pair = AsyncStream<Double?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        rates = pair.stream
        continuation = pair.continuation
        let continuation = pair.continuation
        listener = { _, _ in
            continuation.yield(CoreAudioDeviceConnection.nominalSampleRate(of: deviceID))
        }
        var address = Self.address
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener)
        guard status == noErr else {
            isListening = false
            continuation.finish()
            throw DeviceConnectionError.transportError("Nominal sample-rate listener OSStatus \(status)")
        }
        // Serialize the snapshot with callbacks so an older initial read cannot
        // overwrite a newer notification.
        queue.async {
            continuation.yield(CoreAudioDeviceConnection.nominalSampleRate(of: deviceID))
        }
    }

    /// Call on the owning task, not from the CoreAudio callback.
    public func stop() {
        guard isListening else { return }
        isListening = false
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
        continuation.finish()
    }

    deinit { stop() }
}
