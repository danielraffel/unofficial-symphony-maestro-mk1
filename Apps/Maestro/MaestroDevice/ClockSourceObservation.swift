import CoreAudio
import Foundation

/// Owns one HAL clock-source listener: Core Audio pushes an event whenever the
/// device's clock source changes, whoever changed it (Maestro, Audio MIDI
/// Setup, a DAW, or the driver itself). Nothing is polled and no hardware is
/// touched. Keep it alive while consuming `changes`, then call `stop()` (or
/// release it). Registration precedes the first event, so a change cannot be
/// missed between the first read and subscribing; the first event is that read.
public final class ClockSourceObservation {
    public let changes: AsyncStream<Void>
    private let deviceID: AudioDeviceID
    private let queue = DispatchQueue(label: "com.danielraffel.maestro.clock-source")
    private let listener: AudioObjectPropertyListenerBlock
    private let continuation: AsyncStream<Void>.Continuation
    private var isListening = true

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyClockSource,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    public init(deviceID: AudioDeviceID) throws {
        self.deviceID = deviceID
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = pair.stream
        continuation = pair.continuation
        let continuation = pair.continuation
        listener = { _, _ in continuation.yield(()) }
        var address = Self.address
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener)
        guard status == noErr else {
            isListening = false
            continuation.finish()
            throw DeviceConnectionError.transportError("Clock-source listener OSStatus \(status)")
        }
        queue.async { continuation.yield(()) }
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
