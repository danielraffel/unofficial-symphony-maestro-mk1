/// CoreAudio-based DeviceConnection for Apogee Symphony IO MKI.
///
/// Uses two paths:
/// 1. Standard CoreAudio APIs for device discovery (enumerate devices, get names)
/// 2. Direct IPC to the Apogee daemon via UNIX domain socket for custom properties
///
/// The daemon (symphonyIOUSBDaemon) handles all USB communication. We send
/// MaestroLink-framed messages (registration, GetProperty, SetProperty) over
/// the socket at `/var/run/com.apogee.symphonyIOUSBDaemon/Socket`.
///
/// Evidence: `og_source/maestrolink/Software/Messaging/apogeeDriverPlugInMessageTypes/`
/// Evidence: `og_source/maestrolink/Software/Messaging/MessageTX.cpp`
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` — FourCC property codes

import MaestroCore
import Foundation
import CoreAudio
import Accelerate

// MARK: - Software Meter IO Proc (C callback at file scope)

/// Context passed to the CoreAudio IO proc for software metering.
struct SoftwareMeterContext {
    let inputPeaks: UnsafeMutablePointer<Float>
    let outputPeaks: UnsafeMutablePointer<Float>
    let inputCount: UnsafeMutablePointer<Int32>
    let outputCount: UnsafeMutablePointer<Int32>
}

/// CoreAudio IO proc callback for software metering.
/// Runs on the audio render thread — must be realtime-safe (no locks, no alloc, no ObjC).
private func softwareMeterIOProc(
    _ device: AudioDeviceID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let ctx = clientData.assumingMemoryBound(to: SoftwareMeterContext.self).pointee

    // Process input buffers
    let inBufList = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData)
    )
    var inCh: Int = 0
    for buf in inBufList {
        guard let data = buf.mData else { continue }
        let frameCount = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size / Int(max(buf.mNumberChannels, 1))
        let chCount = Int(buf.mNumberChannels)
        let samples = data.assumingMemoryBound(to: Float32.self)

        for ch in 0..<chCount {
            guard inCh + ch < 64 else { break }
            // For interleaved: stride by chCount. For deinterleaved (chCount=1): stride by 1.
            var peak: Float = 0
            if chCount == 1 {
                vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameCount))
            } else {
                // Interleaved: sample at ch, ch+chCount, ch+2*chCount, ...
                vDSP_maxmgv(samples.advanced(by: ch), vDSP_Stride(chCount), &peak, vDSP_Length(frameCount))
            }
            let dB: Float = peak > 1.0e-10 ? 20.0 * log10f(peak) : -Float.infinity
            ctx.inputPeaks[inCh + ch] = dB
        }
        inCh += chCount
    }
    OSAtomicCompareAndSwap32(ctx.inputCount.pointee, Int32(inCh), ctx.inputCount)

    // Process output buffers
    let outBufList = UnsafeMutableAudioBufferListPointer(outputData)
    var outCh: Int = 0
    for buf in outBufList {
        guard let data = buf.mData else { continue }
        let frameCount = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size / Int(max(buf.mNumberChannels, 1))
        let chCount = Int(buf.mNumberChannels)
        let samples = data.assumingMemoryBound(to: Float32.self)

        for ch in 0..<chCount {
            guard outCh + ch < 64 else { break }
            var peak: Float = 0
            if chCount == 1 {
                vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameCount))
            } else {
                vDSP_maxmgv(samples.advanced(by: ch), vDSP_Stride(chCount), &peak, vDSP_Length(frameCount))
            }
            let dB: Float = peak > 1.0e-10 ? 20.0 * log10f(peak) : -Float.infinity
            ctx.outputPeaks[outCh + ch] = dB
        }
        outCh += chCount
    }
    OSAtomicCompareAndSwap32(ctx.outputCount.pointee, Int32(outCh), ctx.outputCount)

    return noErr
}

// MARK: - CoreAudio Device Connection

/// DeviceConnection implementation using daemon IPC for custom properties.
///
/// Standard CoreAudio properties (sample rate, device name) go through
/// AudioObjectGetPropertyData. Custom Apogee properties (gain, mute,
/// meters, routing) go through the daemon UNIX socket.
public final class CoreAudioDeviceConnection: DeviceConnection, @unchecked Sendable {
    public let identifier: USBDeviceIdentifier

    /// The CoreAudio device ID for this Symphony IO.
    private let audioDeviceID: AudioDeviceID

    /// Thread-safe listener storage.
    private let listenerStorage = CoreAudioListenerStorage()

    /// Whether the connection is active.
    private nonisolated(unsafe) var _isConnected: Bool = true

    public var isConnected: Bool { _isConnected }

    /// Daemon socket connection (thread-safe).
    private let daemonSocket: DaemonSocket

    /// Called on the main queue when the daemon socket reconnects after a drop.
    /// P3G-26: wire this in AppState to show reconnection events in the status bar.
    public var onDaemonReconnect: (() -> Void)? {
        get { daemonSocket.onReconnect }
        set { daemonSocket.onReconnect = newValue }
    }

    /// NonCA IDs of IOBoard input streams discovered during daemon connection setup.
    /// Used by InputRoutingView as fallback source IDs when routing reads return no data.
    /// maestroRoute objectID = (0xF << 32) | streamNonCAID (Evidence: mAEstro.h:567-571)
    public var inputRoutingStreamIDs: [UInt32] {
        daemonSocket.inputRoutingStreamIDsCopy()
    }

    /// Source objectIDs captured at startup for each IOBoard output stream's first pair.
    /// Used by OutputRoutingView as fallback row sources when routing reads return no data.
    /// Each entry: (objectID, leftElement) for HW output ch1 of one discovered output stream.
    public var outputRoutingSourceHints: [(objectID: UInt64, leftElement: UInt64)] {
        daemonSocket.outputRoutingSourceHintsCopy()
    }

    /// Total hardware input pairs for the routing matrix column count.
    ///
    /// This is the number of physical hardware input channels / 2 — i.e., how many
    /// hardware input stereo pairs are available as routing SOURCES in the input matrix.
    /// Derived from daemon-discovered input routing stream IDs × 4 pairs per stream.
    ///
    /// IMPORTANT: This is NOT the same as HAL input scope stream pairs. The HAL only
    /// reports USB audio class channels (e.g. 16ch = 8 pairs for Symphony IO MKI in 16ch mode).
    /// But the hardware has more physical inputs (e.g. 32ch = 16 pairs: 24 Line + 8 ADAT)
    /// which are selectable through the routing matrix.
    ///
    /// Evidence: APInputRoutingTabRowViewController.m:164 — (analogInChannels + digitalInChannels)/2
    ///           SymphonyIO.cpp:977-1033 — daemon creates streams with inChans per IOBoard
    public var hardwareInputPairCount: Int {
        daemonSocket.inputRoutingStreamIDsCopy().count * 4
    }

    /// Total input routing pairs = total CoreAudio output channel pairs for this device.
    ///
    /// "Software Input" rows in the routing matrix = channels the computer sends to the device
    /// via USB = output streams from macOS's perspective.
    ///
    /// Formula mirrors the original Maestro 2:
    ///   numberOfSoftwareInputPairs = [busInChannels count] / 2
    /// where busInChannels = all channels of USB-streaming-terminal-type output streams.
    ///
    /// Evidence: APInputRoutingTabRowViewController.m:168 — count/2 formula
    ///           APAudioStreamModel.m:133-143 — mChannelsPerFrame from stream ASBD
    ///           APAudioDeviceModel.m:1251-1265 — busInChannels accumulation
    ///           SymphonyIO.cpp:977-1033 — daemon creates 1 input stream w/ inChans (16 per board)
    ///
    /// Returns 0 when HAL plugin not active; caller falls back to channelCount/2.
    public var inputRoutingPairCount: Int {
        guard let pairs = halStreamPairsByType(scope: kAudioObjectPropertyScopeOutput) else {
            return 0
        }
        return pairs.analog + pairs.digital
    }

    /// Total output routing pairs derived from discovered output streams.
    public var outputRoutingPairCount: Int {
        daemonSocket.outputRoutingSourceHintsCopy().count * 4
    }

    /// Number of hardware mixer buses available for output routing.
    ///
    /// Queries 'AEMI' (0x41454D49) — the mixer ID array — from the CoreAudio device object.
    /// Mixer count = byte length of result array / sizeof(UInt32).
    ///
    /// Evidence: APOutputRoutingTabRowViewController.m:190 — `mixerIDs.length / sizeof(UInt32)`
    /// Evidence: AudioPropertySelector.mixerID = 'AEMI'
    ///
    /// Returns 2 on error (Symphony IO MKI always has 2 mixer buses).
    public var mixerCount: Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: 0x4145_4D49,  // 'AEMI'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(audioDeviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 2 }
        return Int(size) / MemoryLayout<UInt32>.size
    }

    /// Total input channels from discovered meter streams (8 channels per stream).
    /// Use this for sizing inputMeterLevels array — more accurate than identifier.mode.channelCount.
    public var inputMeterChannelCount: Int {
        daemonSocket.inputMeterStreamIDsCopy().count * 8
    }

    /// Total output channels from discovered meter streams.
    public var outputMeterChannelCount: Int {
        daemonSocket.outputMeterStreamIDsCopy().count * 8
    }

    /// Read the available sample rates from the device via standard CoreAudio APIs.
    /// Returns the rates the device actually supports (e.g. {44100, 48000} for 32ch mode).
    public var availableSampleRates: [Double] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(audioDeviceID, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let rangeCount = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: rangeCount)
        guard AudioObjectGetPropertyData(audioDeviceID, &addr, 0, nil, &dataSize, &ranges) == noErr else {
            return []
        }

        // Each range has mMinimum/mMaximum — for discrete rates they're equal.
        // Collect unique rates, sorted ascending.
        var rates: Set<Double> = []
        for range in ranges {
            rates.insert(range.mMinimum)
            if range.mMaximum != range.mMinimum {
                rates.insert(range.mMaximum)
            }
        }
        return rates.sorted()
    }

    /// Read the nominal sample rate via standard CoreAudio APIs.
    /// More reliable than daemon queries for Symphony IO MKI (returns 'who?' for sampleRate).
    public var nominalSampleRate: Double? {
        Self.nominalSampleRate(of: audioDeviceID)
    }

    public func observeNominalSampleRate() throws -> NominalSampleRateObservation {
        try NominalSampleRateObservation(deviceID: audioDeviceID)
    }

    /// The nominal sample rate of any CoreAudio device, by ID.
    ///
    /// Exposed statically so a caller can check a device it has no connection
    /// object for -- specifically the ASP virtual device, which
    /// discoverAllSymphonyIO deliberately excludes, and which now follows the
    /// hardware's rate rather than setting its own.
    public static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr,
              rate > 0 else { return nil }
        return Double(rate)
    }

    /// Find a device by its exact CoreAudio name.
    ///
    /// discoverAllSymphonyIO filters the virtual device out on purpose, so this
    /// is the way to reach it by name.
    public static func findDevice(named name: String) -> AudioDeviceID? {
        guard let ids = enumerateAudioDevices() else { return nil }
        return ids.first { getDeviceName($0) == name }
    }

    /// Read the clock source ID via standard CoreAudio APIs.
    /// Returns 0 if unavailable (device has only one implicit clock source).
    public var clockSourceIndex: UInt32 {
        var src: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyClockSource,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(audioDeviceID, &addr, 0, nil, &size, &src)
        return src
    }

    /// Builds the ABI payload required by CoreAudio's clock-source translation selectors.
    /// The pointed-to storage must outlive the AudioObjectGetPropertyData call.
    internal static func makeClockSourceNameTranslation(
        sourceID: UnsafeMutablePointer<UInt32>,
        output: UnsafeMutablePointer<Unmanaged<CFString>?>
    ) -> AudioValueTranslation {
        AudioValueTranslation(
            mInputData: sourceID,
            mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
            mOutputData: output,
            mOutputDataSize: UInt32(MemoryLayout<CFString?>.size)
        )
    }

    /// Read the clock source display name via standard CoreAudio APIs.
    /// Uses kAudioDevicePropertyClockSourceNameForIDCFString to get the actual
    /// name string for the current clock source ID.
    public var clockSourceName: String {
        let srcID = clockSourceIndex
        if srcID == 0 { return "Internal" }
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyClockSourceNameForIDCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The clock-source name selector is a translation property. CoreAudio requires
        // its property-data payload to be an AudioValueTranslation (input UInt32 ID -> output
        // CFString), rather than a bare output CFString. Passing the wrong ABI can make
        // HALC_ProxyObject dereference invalid translation state for
        // DriverKit devices such as ThunderBridge.
        var sourceID = srcID
        var name: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &sourceID) { sourcePointer in
            withUnsafeMutablePointer(to: &name) { namePointer in
                var translation = Self.makeClockSourceNameTranslation(
                    sourceID: sourcePointer, output: namePointer)
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(audioDeviceID, &nameAddr, 0, nil,
                                                  &translationSize, &translation)
            }
        }
        if status == noErr, let cf = name?.takeRetainedValue() {
            return cf as String
        }
        return "Internal"
    }

    /// Write the nominal sample rate via standard CoreAudio APIs.
    /// More reliable than daemon path for Symphony IO MKI (returns 'who?' via daemon).
    public func setNominalSampleRate(_ rate: Double) throws {
        var value = Float64(rate)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(audioDeviceID, &addr, 0, nil,
                                                UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("AudioObjectSetPropertyData(NominalSampleRate) OSStatus \(status)")
        }
    }

    /// Write the nominal sample rate to any device by ID, ignoring the result.
    ///
    /// This exists to nudge the virtual device. It follows the hardware on its
    /// own, but only from its IO callback -- so with nothing playing through it,
    /// it will not notice until the next playback. Setting the rate on it asks it
    /// the question directly; it validates the request against the hardware's
    /// published rate and accepts a rate that agrees (see
    /// Drivers/AudioServerPlugin/ApogeeDriver.cpp SetNominalSampleRateImpl), so
    /// this cannot talk it into a rate the hardware is not at.
    ///
    /// Discards the status deliberately: the caller verifies by reading back,
    /// which is the only thing that means anything here -- a virtual device that
    /// quantizes reports success and then keeps its old rate.
    public static func nudgeNominalSampleRate(of deviceID: AudioDeviceID, to rate: Double) {
        guard deviceID != kAudioObjectUnknown else { return }
        var value = Float64(rate)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                       UInt32(MemoryLayout<Float64>.size), &value)
    }

    /// Is anything running IO on this device right now? `nil` when the device
    /// will not say.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` counts other processes too,
    /// which is what we want: the question is whether the device's IO callbacks
    /// are firing at all, not whether we are the one driving them.
    ///
    /// The three-state return is not fussiness. libASPL does not serve this
    /// property itself, so for the virtual device it depends on the HAL
    /// synthesizing it -- and if the HAL declines, a Bool would have to guess.
    /// Guessing "not running" is the dangerous direction: it would hand the
    /// reassuring "nothing is broken yet" message to the one case that is a real
    /// fault. So an unanswered query says so, and the caller stays vague instead
    /// of confidently wrong.
    public static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running) == noErr
        else { return nil }
        return running != 0
    }

    /// Another process whose audio is playing out of a device we are about to
    /// re-rate.
    public struct OutputClient: Sendable, Equatable {
        public let pid: pid_t
        /// Executable name, e.g. "Logic Pro". Never a path.
        public let name: String
    }

    /// Processes other than us and the proxy that are running output on `deviceID`.
    ///
    /// This exists because of one specific, very convincing false bug. A DAW
    /// holding the Symphony pins it to the *project* sample rate and writes that
    /// rate back roughly 200 ms after anyone else changes it. Everything before
    /// the write-back succeeds -- the set returns noErr, the front panel shows the
    /// new rate, the virtual device follows -- and then the whole stack follows the
    /// DAW back down. Measured 2026-09-12 with Logic Pro: 5/5 reverts to the
    /// literal constant 48000 regardless of the previous rate, and with Logic
    /// SIGSTOPped the change held indefinitely. Without naming the process, the
    /// only honest thing left to say is "it would not accept that rate", which
    /// points the user at their interface instead of at the app that is actually
    /// holding it.
    ///
    /// The proxy is excluded because its output is ours: it is the Maestro USB
    /// playback path and it follows the rate rather than fighting it.
    public static func otherOutputClients(of deviceID: AudioDeviceID) -> [OutputClient] {
        guard deviceID != kAudioObjectUnknown else { return [] }

        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &listSize) == noErr,
              listSize > 0
        else { return [] }

        let count = Int(listSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil,
                &listSize, &objects) == noErr
        else { return [] }

        let selfPID = getpid()
        var found: [OutputClient] = []

        for object in objects {
            // Running output at all? A process merely configured for this device
            // is not holding the rate.
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                    object, &runningAddr, 0, nil, &runningSize, &running) == noErr,
                  running != 0
            else { continue }

            // On this device? Output scope: an input-only client does not own the
            // output rate.
            var devicesAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyDevices,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var devicesSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                    object, &devicesAddr, 0, nil, &devicesSize) == noErr,
                  devicesSize > 0
            else { continue }
            var devices = [AudioObjectID](
                repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(
                    object, &devicesAddr, 0, nil, &devicesSize, &devices) == noErr,
                  devices.contains(deviceID)
            else { continue }

            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(
                    object, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                  pid > 0, pid != selfPID
            else { continue }

            let name = executableName(of: pid)
            // The proxy's output IS our output.
            if name == "MaestroVolumeProxy" { continue }
            found.append(OutputClient(pid: pid, name: name ?? "PID \(pid)"))
        }
        return found
    }

    /// Processes other than us and the proxy running output on *this* device.
    public var otherOutputClients: [OutputClient] {
        Self.otherOutputClients(of: audioDeviceID)
    }

    /// Executable name for a pid, without AppKit: MaestroDevice must stay
    /// linkable from a non-UI target.
    private static func executableName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }
    /// Set the nominal sample rate and return the rate the device actually
    /// settled on.
    ///
    /// Replaces "set, sleep 200 ms, read". That sleep was a guess at how long
    /// CoreAudio needs, and it raced the proxy's old 48 kHz coercion, so the
    /// value the picker displayed afterwards was genuinely nondeterministic. The
    /// coercion is gone; this removes the guess. Returning the settled rate --
    /// rather than assuming the requested one took -- is what lets the caller say
    /// something true when the device refuses.
    @discardableResult
    public func setNominalSampleRateAndWait(_ rate: Double,
                                           timeoutMilliseconds: Int = 3000) async throws -> Double {
        // Already there: CoreAudio sends no notification and changes nothing, so
        // waiting would just burn the timeout.
        if let current = nominalSampleRate, abs(current - rate) < 1.0 { return current }
        try setNominalSampleRate(rate)
        if let settled = await Self.waitForNominalSampleRate(
            of: audioDeviceID, toReach: rate, timeoutMilliseconds: timeoutMilliseconds) {
            return settled
        }
        return nominalSampleRate ?? rate
    }

    /// Poll a device until it reports `rate`, or the deadline passes.
    ///
    /// A property listener would be the obvious tool, but the thing we most need
    /// to watch is a DIFFERENT device -- the ASP following the hardware -- and a
    /// nominal-rate read is a cheap in-process HAL call, so one polling helper
    /// covers both cases without a listener's lifetime and Sendable problems.
    /// Returns nil if it never got there.
    public static func waitForNominalSampleRate(of deviceID: AudioDeviceID,
                                                toReach rate: Double,
                                                timeoutMilliseconds: Int = 3000) async -> Double? {
        let stepMs = 25
        var waitedMs = 0
        while true {
            if let now = nominalSampleRate(of: deviceID), abs(now - rate) < 1.0 { return now }
            if waitedMs >= timeoutMilliseconds { return nil }
            try? await Task.sleep(for: .milliseconds(stepMs))
            waitedMs += stepMs
        }
    }

    /// Read the actual (measured) sample rate and compare with nominal to determine lock.
    /// Returns true if locked (rates within 0.5%) or if the actual rate is unavailable.
    public var isClockLocked: Bool {
        guard let nominal = nominalSampleRate else { return true }
        var actual: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyActualSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(audioDeviceID, &addr, 0, nil, &size, &actual) == noErr else {
            return true  // assume locked if actual rate unavailable
        }
        return abs(actual - Float64(nominal)) < Float64(nominal) * 0.005
    }

    public init(identifier: USBDeviceIdentifier, audioDeviceID: AudioDeviceID) {
        self.identifier = identifier
        self.audioDeviceID = audioDeviceID
        self.daemonSocket = DaemonSocket()
    }

    deinit {
        // S4: destroy the IO proc first (stops the RT thread), then free the
        // class-lifetime metering buffers and context exactly once.
        stopSoftwareMetering()
        if let ctx = _meterContext {
            ctx.deinitialize(count: 1)
            ctx.deallocate()
        }
        _softwareInputPeaks.deallocate()
        _softwareOutputPeaks.deallocate()
        _softwareInputCount.deallocate()
        _softwareOutputCount.deallocate()
    }

    // MARK: - Device Discovery

    /// Result of discovering a Symphony IO device.
    public struct DiscoveredSymphonyIO {
        public let audioDeviceID: AudioDeviceID
        public let identifier: USBDeviceIdentifier
        public let transportType: TransportType
        public let name: String
    }

    /// Find all Apogee Symphony IO devices via CoreAudio enumeration.
    /// Returns Thunderbolt devices first (preferred), then USB.
    public static func discoverAllSymphonyIO() -> [DiscoveredSymphonyIO] {
        guard let deviceIDs = enumerateAudioDevices() else {
            print("[Maestro] discoverAllSymphonyIO: enumerateAudioDevices returned nil")
            return []
        }

        print("[Maestro] discoverAllSymphonyIO: found \(deviceIDs.count) audio devices")
        var results: [DiscoveredSymphonyIO] = []
        for deviceID in deviceIDs {
            guard let name = getDeviceName(deviceID) else { continue }
            print("[Maestro] discoverAllSymphonyIO: device \(deviceID) = \"\(name)\"")
            // Match Symphony devices but exclude the ASP virtual device ("Maestro")
            if name.contains("Symphony") && !name.contains("Maestro") {
                if let identifier = identifierFromDevice(deviceID) {
                    let transport = ThunderboltDeviceConnection.isThunderboltDevice(deviceID)
                        ? TransportType.thunderbolt : TransportType.usb
                    results.append(DiscoveredSymphonyIO(
                        audioDeviceID: deviceID,
                        identifier: identifier,
                        transportType: transport,
                        name: name
                    ))
                }
            }
        }

        // Sort: Thunderbolt first (preferred), then USB
        results.sort { $0.transportType == .thunderbolt && $1.transportType != .thunderbolt }
        return results
    }

    /// Find an Apogee Symphony IO device via CoreAudio enumeration.
    /// Prefers Thunderbolt over USB when both are available.
    public static func discoverSymphonyIO() -> (AudioDeviceID, USBDeviceIdentifier)? {
        let all = discoverAllSymphonyIO()
        guard let first = all.first else { return nil }
        return (first.audioDeviceID, first.identifier)
    }

    /// Enumerate all CoreAudio device IDs.
    private static func enumerateAudioDevices() -> [AudioDeviceID]? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return nil }
        return deviceIDs
    }

    private static func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr else { return nil }
        return name as String
    }

    /// Find an output-capable audio device by its exact CoreAudio name. Returns nil if not present.
    public static func deviceID(named name: String) -> AudioDeviceID? {
        guard let ids = enumerateAudioDevices() else { return nil }
        return ids.first { getDeviceName($0) == name }
    }

    /// Select a stable physical fallback when the Symphony that was the system
    /// default disappears. Prefer a built-in output so macOS does not land on a
    /// virtual device (for example a remote-desktop endpoint) with no keyboard
    /// volume control.
    public static func builtInOutputDevice() -> AudioDeviceID? {
        guard let ids = enumerateAudioDevices() else { return nil }
        let candidates = ids.filter { id in
            guard hasOutputChannels(id), transportType(of: id) == kAudioDeviceTransportTypeBuiltIn else {
                return false
            }
            return true
        }
        return candidates.first { (getDeviceName($0) ?? "").localizedCaseInsensitiveContains("speaker") }
            ?? candidates.first
    }

    /// The current system default output device.
    public static func currentDefaultOutputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// Whether removing the currently remembered default should trigger the
    /// built-in-output safety fallback. This deliberately does not consult the
    /// connect-time auto-switch preference: once a removed Symphony was the
    /// default, leaving CoreAudio's arbitrary virtual fallback can strand the
    /// menu-bar volume control.
    public static func shouldRecoverRemovedDefault(
        removedSymphonyIDs: Set<AudioDeviceID>,
        previousDefault: AudioDeviceID
    ) -> Bool {
        previousDefault != kAudioObjectUnknown
            && removedSymphonyIDs.contains(previousDefault)
    }

    /// Set the system default output device. Returns true on success.
    @discardableResult
    public static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        return status == noErr
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func identifierFromDevice(_ deviceID: AudioDeviceID) -> USBDeviceIdentifier? {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        let streamStatus = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize)

        var totalInputChannels = 0
        if streamStatus == noErr, streamSize > 0 {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: 8)
            defer { buffer.deallocate() }
            if AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, buffer) == noErr {
                let bufferList = buffer.assumingMemoryBound(to: AudioBufferList.self)
                let count = Int(bufferList.pointee.mNumberBuffers)
                let firstBufferOffset = MemoryLayout.offset(of: \AudioBufferList.mBuffers)!
                for i in 0..<count {
                    let bufferOffset = firstBufferOffset + i * MemoryLayout<AudioBuffer>.stride
                    let audioBuffer = buffer.advanced(by: bufferOffset).assumingMemoryBound(to: AudioBuffer.self)
                    totalInputChannels += Int(audioBuffer.pointee.mNumberChannels)
                }
            }
        }

        let pid: UInt16
        if totalInputChannels >= 32 {
            pid = ApogeeUSB.SymphonyIO.pid32ch
        } else if totalInputChannels >= 16 {
            pid = ApogeeUSB.SymphonyIO.pid16ch
        } else if totalInputChannels >= 8 {
            pid = ApogeeUSB.SymphonyIO.pid8ch
        } else {
            pid = ApogeeUSB.SymphonyIO.pid16ch
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
        let deviceUID = uidStatus == noErr ? (uid as String) : "coreaudio-\(deviceID)"

        return USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: pid,
            deviceUID: deviceUID
        )
    }

    // MARK: - Daemon Connection

    /// Connect to the daemon and register. Call before using get/setProperty.
    public func connectToDaemon() throws {
        // Bug 4 fix (P3G-12): Use the real UID from CoreAudio device discovery
        // instead of the hardcoded string. The identifier.deviceUID was read by
        // identifierFromDevice() via kAudioDevicePropertyDeviceUID.
        let deviceUID = identifier.deviceUID
        let bundleID = "com.apogee.MaestroApp"
        print("[Maestro] Connecting to daemon at \(DaemonSocket.socketPath)...")
        do {
            try daemonSocket.connect(
                audioDeviceID: audioDeviceID,
                deviceUID: deviceUID,
                bundleID: bundleID
            )
            print("[Maestro] Daemon connected (AudioDeviceID: \(audioDeviceID))")
        } catch {
            print("[Maestro] Daemon connection FAILED: \(error)")
            throw error
        }
    }

    // MARK: - DeviceConnection Protocol

    public func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        guard isConnected else { throw DeviceConnectionError.notConnected }

        print("[Maestro] GetProperty: \(address.selector) scope=\(address.scope) element=\(address.element)")
        do {
            let data = try daemonSocket.getProperty(
                propertyID: address.selector.rawValue,
                channel: address.element,
                isInput: address.scope == .input
            )

            let dataType = propertyDataType(for: address.selector)
            let result = decodeResponse(data: data, dataType: dataType)
            print("[Maestro] GetProperty RESULT: \(address.selector) = \(result)")
            return result
        } catch {
            print("[Maestro] GetProperty FAILED: \(address.selector) error=\(error)")
            throw error
        }
    }

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        print("[Maestro] SetProperty: \(address.selector) = \(value) scope=\(address.scope) element=\(address.element)")
        let data = encodeValue(value)

        // DaemonSocket handles reconnection internally via ensureConnectedLocked().
        // If the daemon crashed (UB bug) and restarted, reconnect with retry.
        do {
            try daemonSocket.setProperty(
                propertyID: address.selector.rawValue,
                channel: address.element,
                isInput: address.scope == .input,
                data: data
            )

            // Read back to verify the daemon applied the change
            let readBack = try? daemonSocket.getProperty(
                propertyID: address.selector.rawValue,
                channel: address.element,
                isInput: address.scope == .input
            )
            let readBackStr: String
            if let rb = readBack, rb.count >= 4 {
                let val = rb.withUnsafeBytes { $0.load(as: UInt32.self) }
                readBackStr = "readBack=\(val)"
            } else {
                readBackStr = "readBack=nil"
            }
            print("[Maestro] SetProperty RESULT: \(address.selector) = success (\(readBackStr))")

            let change = PropertyChange(address: address, value: value)
            await listenerStorage.notifyListeners(for: address, change: change)
        } catch {
            print("[Maestro] SetProperty FAILED: \(address.selector) error=\(error)")
            throw error
        }
    }

    public func hasProperty(_ address: PropertyAddress) async -> Bool {
        // Try a get — if the daemon returns data, the property exists.
        // This is the only reliable way since the daemon doesn't have a "hasProperty" message.
        guard daemonSocket.isConnected else { return false }
        do {
            _ = try daemonSocket.getProperty(
                propertyID: address.selector.rawValue,
                channel: address.element,
                isInput: address.scope == .input
            )
            return true
        } catch {
            return false
        }
    }

    public func isPropertySettable(_ address: PropertyAddress) async -> Bool {
        // Most Apogee custom properties are settable. The exceptions are read-only
        // properties like version, meter data, and ranges.
        switch address.selector {
        case .version, .versionString, .meterData, .streamMeter,
             .outputLevelRange, .gainRange, .mixerChannelLevelRange, .trimRange,
             .daemonAlive, .deviceType:
            return false
        default:
            return true
        }
    }

    /// Read real-time meter peak levels for all streams via CoreAudio HAL.
    ///
    /// Uses `kMaestroPropertymAEstroStreamMeter` ('AEsm') queried directly with
    /// `AudioObjectGetPropertyData` on each CoreAudio stream AudioObjectID.
    /// The daemon socket path ('AEmD') always returns 'who?' and cannot be used.
    ///
    /// Returns Float32 **dBFS** values (negative or -INFINITY for silence) — already converted.
    /// Evidence: SymphonyIO_Stream.cpp:563 — m_aPeaks[i] = 20*log10(val/16383.0), stored as dBFS.
    /// Returns [] on any error.
    ///
    /// Evidence: mAEstro.h:124–131 — mAEstroStreamMeter struct (UInt32 count + Float32 peaks)
    /// Evidence: mAEstro.h:753–755 — 'AEsm', SymphonyIO, boardStream level, master element
    /// Read real-time meter peak levels via the daemon socket using 'AEsm' on stream NonCA IDs.
    ///
    /// CoreAudio HAL path ('AEsm' on kAudioDevicePropertyStreams IDs) fails with 'who?' — the
    /// Apogee legacy AudioDriverPlugIn doesn't expose custom properties via AudioObjectGetPropertyData.
    /// Correct path: daemon socket GetProperty('AEsm') on each NonCA stream ID discovered at startup.
    ///
    /// Returns Float32 **dBFS** values (negative or -INFINITY for silence).
    /// Evidence: SymphonyIO_Stream.cpp:517–575 — GetProperty('AEsm') reads m_aMeterData → dBFS peaks.
    /// Evidence: mAEstro.h:753–755 — 'AEsm', SymphonyIO, boardStream level, master element.
    public func getStreamMeterLevels(isInput: Bool) -> [Float] {
        // Prefer software metering (CoreAudio IO proc) over daemon 'AEsm'.
        // The daemon's meter collection is broken on firmware 1.6.24 ("Illegal ...>15" errors).
        if isSoftwareMeteringActive {
            let peaks = isInput ? softwareInputPeaks() : softwareOutputPeaks()
            if !peaks.isEmpty { return peaks }
        }

        // Fallback: daemon socket GetProperty('AEsm')
        guard daemonSocket.isConnected else { return [] }

        let streamIDs = isInput
            ? daemonSocket.inputMeterStreamIDsCopy()
            : daemonSocket.outputMeterStreamIDsCopy()

        guard !streamIDs.isEmpty else { return [] }

        let streamMeterPropID: UInt32 = 0x4145736D  // 'AEsm'
        var allLevels: [Float] = []

        for nonCAID in streamIDs {
            if let data = try? daemonSocket.getPropertyForNonCA(
                propertyID: streamMeterPropID,
                nonCA: nonCAID,
                channel: 0,
                isInput: isInput
            ) {
                allLevels.append(contentsOf: CoreAudioDeviceConnection.parseMaestroStreamMeter(data))
            }
        }

        return allLevels
    }

    /// One-shot diagnostic: log per-stream meter peaks for all 4 leaf streams.
    ///
    /// Call once after a short delay from meter startup to identify which streams carry
    /// input (hardware→USB) vs output (USB→hardware) signal. Output from this log
    /// is used to configure inputMeterStreamIDs / outputMeterStreamIDs correctly.
    ///
    /// Usage: call once, then check log for "[MeterDiag] stream=N" entries.
    /// Streams with peaks near -60 dBFS are silent; streams with higher values carry signal.
    public func logMeterDiagnostics() {
        guard daemonSocket.isConnected else { return }
        let inIDs = daemonSocket.inputMeterStreamIDsCopy()
        let outIDs = daemonSocket.outputMeterStreamIDsCopy()
        let allStreamIDs = Array(Set(inIDs + outIDs)).sorted()
        let streamMeterPropID: UInt32 = 0x4145736D  // 'AEsm'
        print("[MeterDiag] === Per-stream meter snapshot (\(allStreamIDs.count) streams, in=\(inIDs) out=\(outIDs)) ===")
        for (idx, nonCAID) in allStreamIDs.enumerated() {
            if let data = try? daemonSocket.getPropertyForNonCA(
                propertyID: streamMeterPropID, nonCA: nonCAID, channel: 0, isInput: false
            ) {
                let hex = data.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
                let levels = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
                let peaks = levels.map { $0.isFinite ? String(format: "%.1f", $0) : "-inf" }
                    .joined(separator: ", ")
                print("[MeterDiag] stream[\(idx)] nonCA=\(nonCAID): \(data.count)B hex=[\(hex)] → \(levels.count)ch [\(peaks)]")
            } else {
                print("[MeterDiag] stream[\(idx)] nonCA=\(nonCAID): NO RESPONSE")
            }
        }
        // Also try querying the SymphonyIO parent and other sibling objects
        // Also try parent/sibling NonCA objects (from AEsi children of device)
        let siblings: [UInt32] = [536871070, 536871071, 536871067, 536871062]
        for nonCAID in siblings {
            if let data = try? daemonSocket.getPropertyForNonCA(
                propertyID: streamMeterPropID, nonCA: nonCAID, channel: 0, isInput: false
            ) {
                let hex = data.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
                let levels = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
                let peaks = levels.prefix(8).map { $0.isFinite ? String(format: "%.1f", $0) : "-inf" }
                    .joined(separator: ", ")
                print("[MeterDiag] parent/sib nonCA=\(nonCAID): \(data.count)B hex=[\(hex)] → \(levels.count)ch [\(peaks)...]")
            } else {
                print("[MeterDiag] parent/sib nonCA=\(nonCAID): NO RESPONSE")
            }
        }
        // Also try CoreAudio HAL meter query via AudioObjectGetPropertyData
        // on the device's AudioStreamIDs
        logCoreAudioMeterDiag()
        print("[MeterDiag] === End ===")
    }

    /// Parse a raw `mAEstroStreamMeter` response blob into dBFS peak levels.
    ///
    /// Wire format: `UInt32 m_nNumChannels` + `Float32 m_aPeaks[numChannels]` (little-endian).
    /// Values are already in dBFS (negative; SymphonyIO_Stream.cpp:563 uses 20*log10).
    ///
    /// Returns empty array if data is too short or numChannels is 0.
    /// Evidence: mAEstro.h:126–127, mAEstroUtilities.c:1224–1231.
    static func parseMaestroStreamMeter(_ data: Data) -> [Float] {
        guard data.count >= 8 else { return [] }
        let numChannels = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard numChannels > 0, data.count >= 4 + Int(numChannels) * 4 else { return [] }
        return (0..<Int(numChannels)).map { ch in
            data.withUnsafeBytes { $0.load(fromByteOffset: 4 + ch * 4, as: Float32.self) }
        }
    }

    /// CoreAudio HAL meter diagnostic — query AEsm via AudioObjectGetPropertyData
    /// to compare with daemon socket results. Uses the device's AudioStreamIDs.
    private func logCoreAudioMeterDiag() {
        // Get device's CoreAudio streams
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(audioDeviceID, &streamAddr, 0, nil, &streamSize) == noErr else {
            print("[MeterDiag] CoreAudio: can't get output stream count")
            return
        }
        let streamCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: streamCount)
        guard AudioObjectGetPropertyData(audioDeviceID, &streamAddr, 0, nil, &streamSize, &streams) == noErr else {
            print("[MeterDiag] CoreAudio: can't get output stream IDs")
            return
        }
        print("[MeterDiag] CoreAudio: device \(audioDeviceID) has \(streamCount) output streams: \(streams)")

        // Try querying 'AEsm' on each CoreAudio stream
        let aesmSelector = AudioObjectPropertySelector(0x4145736D) // 'AEsm'
        for streamID in streams {
            var meterAddr = AudioObjectPropertyAddress(
                mSelector: aesmSelector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let hasProp = AudioObjectHasProperty(streamID, &meterAddr)
            var meterSize: UInt32 = 256
            var meterBuf = [UInt8](repeating: 0, count: Int(meterSize))
            let status = AudioObjectGetPropertyData(streamID, &meterAddr, 0, nil, &meterSize, &meterBuf)
            if status == noErr && meterSize > 8 {
                let data = Data(meterBuf.prefix(Int(meterSize)))
                let levels = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
                let peaks = levels.prefix(8).map { $0.isFinite ? String(format: "%.1f", $0) : "-inf" }
                    .joined(separator: ", ")
                print("[MeterDiag] CoreAudio stream \(streamID): hasProp=\(hasProp) \(meterSize)B → \(levels.count)ch [\(peaks)]")
            } else {
                print("[MeterDiag] CoreAudio stream \(streamID): hasProp=\(hasProp) status=\(status) size=\(meterSize)")
            }
        }

        // Also try input streams
        streamAddr.mScope = kAudioObjectPropertyScopeInput
        streamSize = 0
        guard AudioObjectGetPropertyDataSize(audioDeviceID, &streamAddr, 0, nil, &streamSize) == noErr else {
            print("[MeterDiag] CoreAudio: can't get input stream count")
            return
        }
        let inCount = Int(streamSize) / MemoryLayout<AudioStreamID>.size
        var inStreams = [AudioStreamID](repeating: 0, count: inCount)
        guard AudioObjectGetPropertyData(audioDeviceID, &streamAddr, 0, nil, &streamSize, &inStreams) == noErr else {
            print("[MeterDiag] CoreAudio: can't get input stream IDs")
            return
        }
        print("[MeterDiag] CoreAudio: device \(audioDeviceID) has \(inCount) input streams: \(inStreams)")
        for streamID in inStreams {
            var meterAddr = AudioObjectPropertyAddress(
                mSelector: aesmSelector,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            let hasProp = AudioObjectHasProperty(streamID, &meterAddr)
            var meterSize: UInt32 = 256
            var meterBuf = [UInt8](repeating: 0, count: Int(meterSize))
            let status = AudioObjectGetPropertyData(streamID, &meterAddr, 0, nil, &meterSize, &meterBuf)
            if status == noErr && meterSize > 8 {
                let data = Data(meterBuf.prefix(Int(meterSize)))
                let levels = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
                let peaks = levels.prefix(8).map { $0.isFinite ? String(format: "%.1f", $0) : "-inf" }
                    .joined(separator: ", ")
                print("[MeterDiag] CoreAudio inStream \(streamID): hasProp=\(hasProp) \(meterSize)B → \(levels.count)ch [\(peaks)]")
            } else {
                print("[MeterDiag] CoreAudio inStream \(streamID): hasProp=\(hasProp) status=\(status) size=\(meterSize)")
            }
        }

        // Also try 'AEmD' on the device itself (legacy device-level meter)
        var devMeterAddr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x41456D44), // 'AEmD'
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let devHas = AudioObjectHasProperty(audioDeviceID, &devMeterAddr)
        var devMeterSize: UInt32 = 2048
        var devMeterBuf = [UInt8](repeating: 0, count: Int(devMeterSize))
        let devStatus = AudioObjectGetPropertyData(audioDeviceID, &devMeterAddr, 0, nil, &devMeterSize, &devMeterBuf)
        print("[MeterDiag] CoreAudio device 'AEmD': hasProp=\(devHas) status=\(devStatus) size=\(devMeterSize)")
        if devStatus == noErr && devMeterSize > 8 {
            let hex = devMeterBuf.prefix(min(40, Int(devMeterSize))).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[MeterDiag] CoreAudio device 'AEmD' hex: [\(hex)]")
        }
    }

    public func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerStorage.addListener(listener, for: address)
    }

    public func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerStorage.removeListener(listener, for: address)
    }

    public func disconnect() async {
        _isConnected = false
        stopSoftwareMetering()
        daemonSocket.disconnect()
    }

    // MARK: - Software Metering (CoreAudio IO Proc)
    //
    // Bypass: The daemon's 'AEsm' meter collection is broken on firmware 1.6.24
    // ("Illegal ...>15" errors). Instead, we install a CoreAudio IO proc on the
    // device to read actual audio samples and calculate peak levels in software.
    // This uses the standard USB audio class path (usbaudiod), not the daemon.

    /// Serializes start/stop and `meterIOProcID` access (S4).
    private let meterLock = NSLock()

    /// IO proc ID for software metering (nil when not active). Guarded by `meterLock`.
    private var meterIOProcID: AudioDeviceIOProcID?

    /// Whether software metering is active.
    public var isSoftwareMeteringActive: Bool {
        meterLock.lock(); defer { meterLock.unlock() }
        return meterIOProcID != nil
    }

    // S4: peaks AND counts are class-lifetime heap allocations initialized here and
    // freed once in `deinit` (after the IO proc is destroyed). The RT IO proc writes
    // through the count pointers, so they must be stable — never `&`-escaped locals.
    /// Peak input levels (dBFS) updated by the IO proc. Size = input channel count.
    private let _softwareInputPeaks: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        p.initialize(repeating: -.infinity, count: 64)
        return p
    }()
    private let _softwareInputCount: UnsafeMutablePointer<Int32> = {
        let p = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    /// Peak output levels (dBFS) updated by the IO proc.
    private let _softwareOutputPeaks: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        p.initialize(repeating: -.infinity, count: 64)
        return p
    }()
    private let _softwareOutputCount: UnsafeMutablePointer<Int32> = {
        let p = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    /// Class-lifetime context handed to the RT IO proc. Allocated lazily in
    /// `startSoftwareMetering`, reused across start/stop, freed once in `deinit`.
    private var _meterContext: UnsafeMutablePointer<SoftwareMeterContext>?

    /// Read the latest software-metered input peaks (dBFS). Thread-safe.
    public func softwareInputPeaks() -> [Float] {
        let count = Int(OSAtomicAdd32(0, _softwareInputCount))
        guard count > 0 else { return [] }
        return (0..<min(count, 64)).map { _softwareInputPeaks[$0] }
    }

    /// Read the latest software-metered output peaks (dBFS). Thread-safe.
    public func softwareOutputPeaks() -> [Float] {
        let count = Int(OSAtomicAdd32(0, _softwareOutputCount))
        guard count > 0 else { return [] }
        return (0..<min(count, 64)).map { _softwareOutputPeaks[$0] }
    }

    /// Start software metering by installing a CoreAudio IO proc on this device.
    /// This reads actual audio samples through usbaudiod, bypassing the daemon.
    public func startSoftwareMetering() {
        meterLock.lock(); defer { meterLock.unlock() }
        guard meterIOProcID == nil else { return }

        // Reset peaks to -inf
        for i in 0..<64 {
            _softwareInputPeaks[i] = -Float.infinity
            _softwareOutputPeaks[i] = -Float.infinity
        }

        // Class-lifetime context the RT callback reads. Allocated once, reused —
        // it points at the stable class-lifetime peak/count buffers (S4).
        let ctx: UnsafeMutablePointer<SoftwareMeterContext>
        if let existing = _meterContext {
            ctx = existing
        } else {
            ctx = UnsafeMutablePointer<SoftwareMeterContext>.allocate(capacity: 1)
            ctx.initialize(to: SoftwareMeterContext(
                inputPeaks: _softwareInputPeaks,
                outputPeaks: _softwareOutputPeaks,
                inputCount: _softwareInputCount,
                outputCount: _softwareOutputCount
            ))
            _meterContext = ctx
        }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            audioDeviceID,
            softwareMeterIOProc,
            UnsafeMutableRawPointer(ctx),
            &procID
        )
        guard status == noErr, let procID else {
            print("[Maestro] SoftwareMeter: AudioDeviceCreateIOProcID failed: \(status)")
            return
        }

        meterIOProcID = procID

        // Start IO — this tells CoreAudio to start streaming from/to the device
        let startStatus = AudioDeviceStart(audioDeviceID, procID)
        if startStatus != noErr {
            print("[Maestro] SoftwareMeter: AudioDeviceStart failed: \(startStatus)")
            AudioDeviceDestroyIOProcID(audioDeviceID, procID)
            meterIOProcID = nil
            return
        }

        print("[Maestro] SoftwareMeter: started on device \(audioDeviceID)")
    }

    /// Stop software metering.
    public func stopSoftwareMetering() {
        meterLock.lock(); defer { meterLock.unlock() }
        guard let procID = meterIOProcID else { return }
        AudioDeviceStop(audioDeviceID, procID)
        AudioDeviceDestroyIOProcID(audioDeviceID, procID)
        meterIOProcID = nil
        // Keep _meterContext allocated for reuse; it is freed once in deinit,
        // strictly after the IO proc has been destroyed above.
        print("[Maestro] SoftwareMeter: stopped")
    }

    // MARK: - Software Metering Test Injection

    /// Inject fake peak data into software meter buffers for testing.
    /// This simulates what the IO proc callback does on the audio render thread.
    /// Only use from tests — not safe to call while the real IO proc is running.
    func testInjectSoftwareMeterData(inputPeaks: [Float], outputPeaks: [Float]) {
        for i in 0..<min(inputPeaks.count, 64) {
            _softwareInputPeaks[i] = inputPeaks[i]
        }
        OSAtomicCompareAndSwap32(_softwareInputCount.pointee, Int32(inputPeaks.count), _softwareInputCount)

        for i in 0..<min(outputPeaks.count, 64) {
            _softwareOutputPeaks[i] = outputPeaks[i]
        }
        OSAtomicCompareAndSwap32(_softwareOutputCount.pointee, Int32(outputPeaks.count), _softwareOutputCount)
    }

    /// Simulate software metering being active without actually installing an IO proc.
    /// This sets a sentinel IO proc ID so `isSoftwareMeteringActive` returns true.
    func testSetSoftwareMeteringActive(_ active: Bool) {
        meterLock.lock(); defer { meterLock.unlock() }
        if active {
            // Use a sentinel value that won't match any real IO proc
            meterIOProcID = unsafeBitCast(UInt(0xDEAD), to: AudioDeviceIOProcID.self)
        } else {
            meterIOProcID = nil
        }
    }

    // MARK: - Value Encoding/Decoding

    func decodeResponse(data: Data, dataType: PropertyDataType) -> PropertyValue {
        switch dataType {
        case .uint32:
            guard data.count >= 4 else { return .uint32(0) }
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            return .uint32(value)

        case .float64:
            if data.count >= 8 {
                let value = data.withUnsafeBytes { $0.load(as: Float64.self) }
                return .float64(value)
            } else if data.count >= 4 {
                // Daemon may return UInt32 for properties like outputLevel
                // that are Float64 in CoreAudio but UInt32 over USB
                let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
                return .float64(Double(value))
            }
            return .float64(0)

        case .string:
            return .string(String(data: data, encoding: .utf8) ?? "")

        case .data:
            return .data(data)

        case .range:
            if data.count >= 16 {
                let min = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float64.self) }
                let max = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float64.self) }
                return .range(min: min, max: max)
            }
            return .range(min: 0, max: 0)

        case .bool:
            guard data.count >= 4 else { return .bool(false) }
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            return .bool(value != 0)
        }
    }

    func encodeValue(_ value: PropertyValue) -> Data {
        switch value {
        case .uint32(let v):
            var mutable = v
            return Data(bytes: &mutable, count: 4)
        case .int32(let v):
            var mutable = v
            return Data(bytes: &mutable, count: 4)
        case .float64(let v):
            var mutable = v
            return Data(bytes: &mutable, count: 8)
        case .string(let v):
            return Data(v.utf8)
        case .data(let v):
            return v
        case .range:
            return Data()  // ranges are read-only
        case .bool(let v):
            var mutable: UInt32 = v ? 1 : 0
            return Data(bytes: &mutable, count: 4)
        }
    }

    // MARK: - Property Type Registry

    /// Property data types for daemon IPC response decoding.
    enum PropertyDataType: Equatable {
        case uint32
        case float64
        case string
        case data
        case range
        case bool
    }

    func propertyDataType(for selector: AudioPropertySelector) -> PropertyDataType {
        switch selector {
        case .sampleRate, .mixerChannelLevel, .mixerChannelPan, .trim:
            return .float64

        // Output/HP levels are UInt32 (0-127 attenuation) over daemon IPC, NOT Float64.
        // Bug 8: Legacy spec says UInt32 — mAEstro.h:1027, mAEstroUtilities.c:715.
        // Mixer level/pan ARE Float64 — mAEstroUtilities.c:767.
        case .outputLevel, .headphone1Level, .headphone2Level:
            return .uint32

        case .versionString, .prefix, .audioSystemName,
             .analogIOTypeNameForID, .insertNameForID, .groupNameForID,
             .mixerChannelLabel, .metersShowNameForID,
             .headphone1RoutingNameForID, .headphone2RoutingNameForID,
             .monitorOutputNameForID, .mixerSoftwareReturnNameForID,
             .spdifReplaceNameForID, .spdifMirrorNameForID,
             .digitalRefLevelNameForID:
            return .string

        case .meterData, .streamMeter, .route, .routing:
            return .data

        case .outputLevelRange, .gainRange, .mixerChannelLevelRange, .trimRange:
            return .range

        case .outputMute, .outputDim, .outputSumToMono,
             .phantom, .phaseReverse, .highPassFilter, .insertReturnEnable,
             .headphone1Mute, .headphone2Mute,
             .headphone1Dim, .headphone2Dim,
             .headphone1SumToMono, .headphone2SumToMono,
             .mixerChannelMute, .mixerChannelSolo:
            return .bool

        default:
            return .uint32
        }
    }
}

// MARK: - HAL Stream Configuration

/// Analog/digital channel split for routing grids, derived from CoreAudio HAL stream terminal types.
///
/// Terminal type 0x0601 (kAudioStreamTerminalTypeLine, USB Audio Class 1.0 Line Connector) = analog.
/// All other terminal types (S/PDIF 0x0605, ADAT/optical, etc.) = digital.
///
/// Evidence: USB Audio Class 1.0 spec Appendix B — USB terminal type codes.
/// Evidence: og_source/maestro2/App/Controllers/APRoutingDeviceColumnViewController.m:90-107.
/// Evidence: og_source/maestro2/APAudioObjectExplorer/SymIORoutingChannel.m:43-79.
public struct RoutingStreamConfig: Sendable {
    /// Analog stereo pairs for hardware inputs (Line connector terminal type).
    public let analogInputPairs: Int
    /// Digital stereo pairs for hardware inputs (S/PDIF, ADAT, AES3, etc.).
    public let digitalInputPairs: Int
    /// Analog stereo pairs for hardware outputs.
    public let analogOutputPairs: Int
    /// Digital stereo pairs for hardware outputs.
    public let digitalOutputPairs: Int

    public var totalInputPairs: Int { analogInputPairs + digitalInputPairs }
    public var totalOutputPairs: Int { analogOutputPairs + digitalOutputPairs }
}

extension CoreAudioDeviceConnection {

    /// Query HAL streams to determine analog vs digital pair counts for routing grid labels.
    ///
    /// Uses `kAudioDevicePropertyStreams` (input and output scope) + `kAudioStreamPropertyTerminalType`
    /// per stream. Only standard CoreAudio APIs — no daemon IPC required.
    ///
    /// Returns nil if the HAL reports no streams for this device (plugin not active).
    public var routingStreamConfig: RoutingStreamConfig? {
        let inputPairs = halStreamPairsByType(scope: kAudioObjectPropertyScopeInput)
        let outputPairs = halStreamPairsByType(scope: kAudioObjectPropertyScopeOutput)
        guard inputPairs != nil || outputPairs != nil else { return nil }
        let (analogIn, digitalIn) = inputPairs ?? (0, 0)
        let (analogOut, digitalOut) = outputPairs ?? (0, 0)
        return RoutingStreamConfig(
            analogInputPairs: analogIn,
            digitalInputPairs: digitalIn,
            analogOutputPairs: analogOut,
            digitalOutputPairs: digitalOut
        )
    }

    /// Returns (analogPairs, digitalPairs) from HAL streams in the given scope, or nil on error.
    private func halStreamPairsByType(scope: AudioObjectPropertyScope) -> (analog: Int, digital: Int)? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(audioDeviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streamIDs = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(audioDeviceID, &addr, 0, nil, &size, &streamIDs) == noErr else {
            return nil
        }
        var analogPairs = 0
        var digitalPairs = 0
        for streamID in streamIDs {
            let channels = halStreamChannelCount(streamID)
            let pairs = max(1, (channels + 1) / 2)
            if isAnalogHALStream(streamID) {
                analogPairs += pairs
            } else {
                digitalPairs += pairs
            }
        }
        guard analogPairs > 0 || digitalPairs > 0 else { return nil }
        return (analogPairs, digitalPairs)
    }

    /// Read `kAudioStreamPropertyPhysicalFormat.mChannelsPerFrame` for a stream.
    private func halStreamChannelCount(_ streamID: AudioStreamID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(streamID, &addr, 0, nil, &size, &format) == noErr else {
            return 2  // default: stereo
        }
        return max(1, Int(format.mChannelsPerFrame))
    }

    /// Returns true if this HAL stream's terminal type is 0x0601 (Line connector = analog).
    private func isAnalogHALStream(_ streamID: AudioStreamID) -> Bool {
        // kAudioStreamPropertyTerminalType ('term') — returns IOAudio terminal type code.
        // Evidence: AudioHardwareBase.h kAudioStreamPropertyTerminalType.
        let kStreamTerminalType: AudioObjectPropertySelector = 0x7465726D  // 'term'
        var addr = AudioObjectPropertyAddress(
            mSelector: kStreamTerminalType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var termType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(streamID, &addr, 0, nil, &size, &termType) == noErr else {
            return false  // unknown → treat as digital
        }
        // USB Audio Class 1.0 terminal type 0x0601 = External Line Connector (analog).
        // S/PDIF = 0x0605, ADAT/optical = other values (0x0700 range or 0x0603).
        return termType == 0x0601
    }
}

// MARK: - Daemon-Native Preset Save/Recall

/// Errors thrown by the preset save/recall CoreAudio property calls.
public enum PresetError: LocalizedError {
    case storeFailed(OSStatus)
    case recallFailed(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .storeFailed(let s):
            return "Could not save preset via daemon (OSStatus \(s)). Ensure the Apogee daemon is running."
        case .recallFailed(let s):
            return "Could not apply preset via daemon (OSStatus \(s)). Ensure the Apogee daemon is running."
        }
    }
}

extension CoreAudioDeviceConnection {

    /// Tell the daemon to write all current device settings to a plist file at `path`.
    ///
    /// The daemon writes the full hardware state: output levels, headphone levels,
    /// routing (RoutingSourceToIOBoard0/1, RoutingSourceToUSBStream), mixer state
    /// (InputFaderLevels/Pans/Mutes/Solos), per-stream trim/refLevel/softLimit,
    /// and all other device properties. This is the complete .mst2 bundle format
    /// used by the original Maestro 2 app.
    ///
    /// Evidence: kmAEstroPropertyStorePreferenceFile = 'AESP' (mAEstro.h:1197)
    ///           APMaestroFullViewWindow.m:445–494 — storeMaestroPreferenceFile:
    public func storePreferenceFile(at path: String) throws {
        // Send AESP directly through daemon socket instead of AudioObjectSetPropertyData.
        // The HAL plugin path (AudioObjectSetPropertyData → CFStringRef → C string → daemon)
        // fails on ARM64/macOS 26 because the legacy Apogee AudioDriverPlugIn may not load.
        // Direct socket: pass the path as a null-terminated C string in the data payload.
        // Evidence: ONEv2DeviceController.cpp:732 — daemon extracts C string from SetProperty msg.
        guard let cData = path.data(using: .utf8) else {
            throw PresetError.storeFailed(0)
        }
        // Null-terminated C string
        var payload = cData
        payload.append(0)
        try daemonSocket.setProperty(propertyID: 0x41455350, channel: 0, isInput: false, data: payload)
        print("[Maestro] storePreferenceFile: daemon wrote preset to \(path)")
    }

    /// Tell the daemon to read and apply all device settings from a plist file at `path`.
    ///
    /// The daemon parses the plist and calls SetSettingsFromDictionary() then
    /// ApplySettingsToHardware(), restoring the full hardware state including
    /// routing, mixer, levels, and all device properties.
    ///
    /// Evidence: kmAEstroPropertyRecallPreferenceFile = 'AERP' (mAEstro.h:1199)
    ///           APMaestroFullViewWindow.m:497–650 — recallMaestroPreferenceFile:
    ///           ONEv2DeviceController.cpp:3239–3331 — RecallSettingsFromPreferenceFile
    public func recallPreferenceFile(from path: String) throws {
        // Send AERP directly through daemon socket (same rationale as storePreferenceFile).
        // Evidence: ONEv2DeviceController.cpp:3239 — RecallSettingsFromPreferenceFile
        guard let cData = path.data(using: .utf8) else {
            throw PresetError.recallFailed(0)
        }
        var payload = cData
        payload.append(0)
        try daemonSocket.setProperty(propertyID: 0x41455250, channel: 0, isInput: false, data: payload)
        print("[Maestro] recallPreferenceFile: daemon applied preset from \(path)")
    }

    /// Query the daemon's preferred plist filename for this device.
    ///
    /// Returns a filename like "USBAudio_Symphony I_O_AF716C51A63F6C.plist".
    /// The UID suffix matches the device hardware UID so multiple devices can
    /// coexist in a single bundle. Falls back to nil if the HAL plugin is absent.
    ///
    /// Evidence: kmAEstroPropertyPreferenceFileName = 'AEPN' (mAEstro.h:1204)
    ///           APMaestroFullViewWindow.m:549–566 — Symphony I/O path handling
    public func getPreferenceFileName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: 0x4145504E, // 'AEPN' = kmAEstroPropertyPreferenceFileName
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr else {
            print("[Maestro] getPreferenceFileName: AEPN failed status=\(status)")
            return nil
        }
        let result = name as String
        print("[Maestro] getPreferenceFileName: '\(result)'")
        return result.isEmpty ? nil : result
    }
}

// MARK: - MaestroLink Daemon Socket

/// Low-level UNIX socket communication with the Apogee daemon.
///
/// Implements the MaestroLink framing protocol:
///   Frame: [MLNK magic (4)][packet size (4)][packed message (N)]
///   Message: [Transportable (12)][MessageContent (16)][type-specific payload]
///
/// Evidence: og_source/maestrolink/Software/Messaging/MessageTX.cpp
/// Evidence: og_source/maestrolink/Software/Messaging/apogeeDriverPlugInMessageTypes/
/// Public for hardware test CLI and @testable import in protocol framing tests.
public final class DaemonSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var messageCounter: UInt32 = 0
    private var _isConnected = false

    /// DeviceControllerID assigned by the daemon during registration.
    /// The daemon routes all Get/SetProperty messages using this ID.
    /// Bug 3: Previously hardcoded as 0, causing messages to be misrouted.
    /// Evidence: daemonCommunication.cpp:606, apogDriverPlugInServer.cpp:779
    private var deviceControllerID: UInt32 = 0

    /// Stored connection parameters for auto-reconnect.
    /// Root cause: daemon has a UB bug in WaitForNextMessageInList() where
    /// std::list::front() is called on empty list after 1s pthread_cond_timedwait.
    /// This crashes the daemon ~1s after registration if GetProperty or SetProperty
    /// worker threads receive no messages. Fix: send keepalive to BOTH queues.
    private var storedAudioDeviceID: AudioDeviceID = 0
    private var storedDeviceUID: String = ""
    private var storedBundleID: String = ""

    /// Dual keepalive timer: feeds both GetProperty and SetProperty daemon worker
    /// threads every 400ms to prevent the std::list::front() UB crash.
    private var keepaliveTimer: DispatchSourceTimer?
    private let keepaliveQueue = DispatchQueue(label: "com.maestro.daemon.keepalive")
    /// Cached output level for SetProperty keepalive (no-op write of current value).
    private var cachedOutputLevel: UInt32 = 20  // default: -20 dB attenuation

    /// Monitor device NonCoreAudioObject ID, queried via 'AEmd' after registration.
    /// The legacy HAL plugin always sends this as nonCA in Get/SetProperty messages
    /// for direct peripheral routing. With nonCA=0, the daemon uses
    /// FindMonitorDeviceIfNeeded() which may have subtle routing differences.
    /// Evidence: daemonCommunication.cpp:1623 always passes pTransp->m_nNonCADeviceID
    /// Evidence: SymphonyController.cpp:245 — direct lookup when nonCA != 0
    /// Evidence: mAEstro.h:780 — kMaestroPropertyMonitorDevice = 'AEmd'
    private var monitorDeviceID: UInt32 = 0

    /// SymphonyIO NonCoreAudioObject ID — direct child of monitorDeviceID (SymphonyPeripheralDevice).
    /// Required for input routing writes ('AEsA', isInput=true). SymphonyIO::SetProperty routing
    /// case handles fIsInput=true in USB mode; SymphonyPeripheralDevice has no routing handler.
    /// Evidence: SymphonyIO.cpp:2671-2715 — routing case, USB mode, fIsInput check.
    private var symphonyIONonCAID: UInt32 = 0

    /// IOBoard output stream NonCA IDs — children of SymphonyIO.
    /// Required for output routing writes ('AEsA', isInput=false). SymphonyIO::SetProperty
    /// BLOCKS !fIsInput routing writes (returns 'who?'). Output must target stream directly.
    /// Evidence: SymphonyIOUSBAudioRoutingController.cpp:85-219 — SetRouting with pDestSIOStream.
    private var outputRoutingStreamIDs: [UInt32] = []

    /// IOBoard input stream NonCA IDs — children of SymphonyIO, discovered via 'AEsi' probing.
    /// Used as fallback source IDs for InputRoutingView when routing read-back returns no data.
    /// maestroRoute objectID formula: (0xF << 32) | streamNonCAID (Evidence: mAEstro.h:567-571)
    private var inputRoutingStreamIDs: [UInt32] = []

    /// Source objectIDs captured during startup for each IOBoard output stream's first pair.
    /// Used as fallback source IDs for OutputRoutingView when routing read-back returns no data.
    /// Each entry is the maestroRoute source (objectID, leftElement) for HW output ch1 of one stream.
    private var outputRoutingSourceHints: [(objectID: UInt64, leftElement: UInt64)] = []

    /// Meter stream NonCA IDs — ALL leaf streams.
    /// Each SymphonyIO_Stream object has its own ADC+DAC meter data. Querying 'AEsm' on
    /// any stream returns that stream's meters regardless of direction.
    /// We use all leaf streams for BOTH input and output meters so the user always sees
    /// signal regardless of which IOBoard their analog inputs are connected to.
    /// Evidence: SymphonyIO_Stream.cpp:517-575 — GetProperty('AEsm') returns all peaks.
    private var inputMeterStreamIDs: [UInt32] = []
    private var outputMeterStreamIDs: [UInt32] = []

    public static let socketPath = "/var/run/com.apogee.symphonyIOUSBDaemon/Socket"
    public static let magic: UInt32 = 0x4D4C4E4B  // 'MLNK'

    /// Called on the main queue each time the socket reconnects after a drop.
    /// P3G-26: used to surface reconnection events in the app status bar.
    public var onReconnect: (() -> Void)?

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    deinit {
        disconnect()
    }

    public init() {}

    /// Connect to daemon socket and send registration.
    /// Stores connection parameters for automatic reconnection.
    public func connect(audioDeviceID: AudioDeviceID, deviceUID: String, bundleID: String) throws {
        lock.lock()
        defer { lock.unlock() }

        // Store for reconnection
        storedAudioDeviceID = audioDeviceID
        storedDeviceUID = deviceUID
        storedBundleID = bundleID

        if _isConnected { return }

        // Ignore SIGPIPE
        signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DeviceConnectionError.transportError("Cannot create UNIX socket: errno \(errno)")
        }

        // Large receive buffer so daemon notifications don't fill the kernel buffer.
        var rcvBuf: Int32 = 524_288  // 512KB
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        // Connect
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Self.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            pathBytes.withUnsafeBufferPointer { pathBuf in
                UnsafeMutableRawPointer(sunPathPtr)
                    .copyMemory(from: pathBuf.baseAddress!, byteCount: min(pathBuf.count, 104))
            }
        }

        let addrLen = socklen_t(2 + pathBytes.count)  // sun_len + sun_family + path with null

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        let savedErrno = errno
        guard connectResult == 0 else {
            close(fd)
            throw DeviceConnectionError.transportError(
                "Cannot connect to daemon: \(String(cString: strerror(savedErrno)))"
            )
        }

        // Send registration
        let uidBytes = Array(deviceUID.utf8) + [0]
        let bundleBytes = Array(bundleID.utf8) + [0]
        let regPayloadSize = 12 + 16 + 12 + uidBytes.count + bundleBytes.count

        var payload = Data(count: regPayloadSize)
        messageCounter += 1
        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0

            // Transportable (12)
            writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(regPayloadSize), objectType: 3)

            // MessageContent (16)
            // P3G-15j fix (Bug 16): priority 4 → 6 to match legacy PluginRegisters priority.
            // Evidence: apogeeDriverPlugInMessageTypes.cpp:103.
            writeMessageContent(to: ptr, offset: &offset, msgID: messageCounter, priority: 6, msgType: 0x01)

            // RegistrationContent (12)
            var devID = UInt32(audioDeviceID)
            var uidLen = UInt32(uidBytes.count)
            var bundleLen = UInt32(bundleBytes.count)
            memcpy(ptr + offset, &devID, 4); offset += 4
            memcpy(ptr + offset, &uidLen, 4); offset += 4
            memcpy(ptr + offset, &bundleLen, 4); offset += 4

            // Strings
            uidBytes.withUnsafeBufferPointer { memcpy(ptr + offset, $0.baseAddress!, uidBytes.count) }
            offset += uidBytes.count
            bundleBytes.withUnsafeBufferPointer { memcpy(ptr + offset, $0.baseAddress!, bundleBytes.count) }
        }

        let frame = buildFrame(payload: payload)
        try sendFrame(frame, fd: fd)

        // Read registration response (no notifications expected during registration).
        // Bug 12 fix (P3G-15e): 10s timeout — daemon starts slowly on some systems.
        // Evidence: BiDirConnection.cpp:51 — legacy client uses generous timeout.
        guard let responseData = readSingleMessage(fd: fd, timeout: 10000) else {
            close(fd)
            throw DeviceConnectionError.transportError("No registration response from daemon")
        }

        // Parse response status
        let minResponseSize = 8 + 12 + 16 + 12  // frame header + Transportable + Message + Response
        guard responseData.count >= minResponseSize else {
            close(fd)
            throw DeviceConnectionError.transportError("Registration response too short")
        }

        let returnStatus = responseData.withUnsafeBytes {
            $0.load(fromByteOffset: 8 + 12 + 16, as: UInt32.self)
        }
        guard returnStatus == 0 else {
            close(fd)
            throw DeviceConnectionError.transportError("Registration rejected: status \(returnStatus)")
        }

        // Extract DeviceControllerID from response (Bug 3 fix — P3G-15).
        // Evidence: daemonCommunication.cpp:606 — m_nDeviceControllerID=*(UInt32*)pResponseMsg->m_pReturnData
        deviceControllerID = DaemonSocket.parseDeviceControllerID(from: responseData)

        socketFD = fd
        _isConnected = true
        print("[Maestro] DaemonSocket: connected (fd=\(fd), devCtrlID=\(deviceControllerID))")

        // Immediately prime BOTH daemon worker threads to prevent the 1s crash.
        // The daemon has a UB bug: std::list::front() on empty list after 1s timeout.
        // By sending one message to each queue, we reset both threads' timers.
        sendPrimingGetPropertyLocked()
        sendPrimingSetPropertyLocked()

        // Query monitor device NonCoreAudioObject ID for direct peripheral routing.
        // The HAL plugin always sends this as nonCA — we must match its behavior.
        queryMonitorDeviceIDLocked()

        // Discover SymphonyIO NonCA ID and output stream IDs for correct routing dispatch.
        // Routing writes ('AEsA') must target the correct child object, not monitorDeviceID.
        discoverRoutingStreamIDsLocked()

        // Start dual keepalive timer (400ms interval) to keep both threads alive
        startKeepaliveTimer()
    }

    /// Start the dual keepalive timer that feeds both daemon worker threads.
    /// Must be called after a successful connect+register (with lock held).
    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: keepaliveQueue)
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            self?.keepaliveTick()
        }
        keepaliveTimer = timer
        timer.resume()
    }

    /// Stop the keepalive timer.
    private func stopKeepaliveTimer() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    /// Keepalive tick: drain notifications, then send GetProperty + SetProperty
    /// to keep both daemon worker threads alive and prevent the std::list::front() crash.
    private func keepaliveTick() {
        lock.lock()
        defer { lock.unlock() }

        guard _isConnected, socketFD >= 0 else { return }

        // 1. Drain any pending notifications
        drainNotificationsLocked()

        // 1.5. Retry discovery if:
        //   a) symphonyIONonCAID is still 0 (no discovery at all yet), OR
        //   b) symphonyIONonCAID was set by formula fallback but stream IDs weren't discovered
        //      (outputRoutingStreamIDs.isEmpty means full discovery never completed).
        // Once both are populated they stay valid for the session.
        if symphonyIONonCAID == 0 || outputRoutingStreamIDs.isEmpty {
            discoverRoutingStreamIDsLocked()
        }

        // 2. Send GetProperty for output level (feeds GetProperty worker thread)
        let getPropID: UInt32 = 0x41456C33  // 'AEl3' — output level
        let getPayloadSize = 12 + 16 + 28
        var getPayload = Data(count: getPayloadSize)
        messageCounter += 1
        let getMsgID = messageCounter
        getPayload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            self.writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(getPayloadSize), objectType: 4)
            self.writeMessageContent(to: ptr, offset: &offset, msgID: getMsgID, priority: 3, msgType: 0x05)
            var devCtrl = self.deviceControllerID
            // 'AEl3' GET must use nonCA=0 (SymphonyPeripheralDevice root stores readable values).
            // SymphonyIO (nonCA=symphonyIONonCAID) handles SetProperty but NOT GetProperty for level —
            // querying it returns an error, leaving cachedOutputLevel stale and causing snap-back.
            // Evidence: priming GET uses nonCA=0 and correctly reads current hardware level.
            var nonCA = UInt32(0)
            var prop = getPropID
            var ch = UInt32(0)
            var maxReturn = UInt32(4096)
            var inputSize = UInt32(0)
            var isIn: UInt8 = 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxReturn, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }
        do {
            try sendFrame(buildFrame(payload: getPayload), fd: socketFD)
        } catch {
            _isConnected = false
            return
        }
        if let resp = readResponseSkippingNotifications(fd: socketFD, timeout: 500, expectedMsgID: getMsgID) {
            // Update cached output level from response
            if let data = try? parseGetPropertyResponse(resp), data.count >= 4 {
                cachedOutputLevel = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            }
        } else {
            _isConnected = false
            return
        }

        // 3. Send SetProperty for output level = cached value (feeds SetProperty worker thread)
        //    This is a no-op write — same value the hardware already has.
        let setPropID: UInt32 = 0x41456C33  // 'AEl3'
        var levelData = Data(count: 4)
        levelData.withUnsafeMutableBytes { $0.storeBytes(of: cachedOutputLevel, as: UInt32.self) }
        let setFixedSize = 12 + 16 + 28
        let setPayloadSize = setFixedSize + levelData.count
        var setPayload = Data(count: setPayloadSize)
        messageCounter += 1
        let setMsgID = messageCounter  // P3G-15d: capture for response correlation
        setPayload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            self.writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(setPayloadSize), objectType: 5)
            self.writeMessageContent(to: ptr, offset: &offset, msgID: setMsgID, priority: 2, msgType: 0x03)
            var devCtrl = self.deviceControllerID
            // 'AEl3' handled by SymphonyIO — must use symphonyIONonCAID for hardware to respond.
            var nonCA = self.symphonyIONonCAID != 0 ? self.symphonyIONonCAID : self.monitorDeviceID
            var prop = setPropID
            var ch = UInt32(0)
            var dataSize = UInt32(0)
            var inputSize = UInt32(levelData.count)
            var isIn: UInt8 = 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &dataSize, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
            offset += 3
            levelData.withUnsafeBytes { dataBuf in
                memcpy(ptr + offset, dataBuf.baseAddress!, levelData.count)
            }
        }
        do {
            try sendFrame(buildFrame(payload: setPayload), fd: socketFD)
        } catch {
            _isConnected = false
            return
        }
        if readResponseSkippingNotifications(fd: socketFD, timeout: 500, expectedMsgID: setMsgID) == nil {
            _isConnected = false
        }
    }

    /// Drain any pending notifications from the daemon socket (non-blocking).
    /// Reads and discards PropertyChanged messages so they don't clog the buffer.
    private func drainNotificationsLocked() {
        while true {
            var pollFd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFd, 1, 0)  // non-blocking
            if ready <= 0 { break }
            if (pollFd.revents & Int16(POLLHUP | POLLERR)) != 0 {
                _isConnected = false
                break
            }
            if (pollFd.revents & Int16(POLLIN)) != 0 {
                // Read and discard one message
                if readSingleMessage(fd: socketFD, timeout: 50) == nil {
                    _isConnected = false
                    break
                }
            } else {
                break
            }
        }
    }

    /// Ensure connected, with retry for daemon restart (socket file may be temporarily missing).
    /// Must be called with lock held.
    private func ensureConnectedLocked() throws {
        if _isConnected && socketFD >= 0 { return }

        // The daemon may have crashed (std::list::front UB) and is restarting.
        // Retry for up to 3s with backoff.
        var lastError: Error = DeviceConnectionError.notConnected
        let delays = [0, 200, 400, 600, 800]  // ms - total ~2s

        for (i, delay) in delays.enumerated() {
            if delay > 0 {
                lock.unlock()
                Thread.sleep(forTimeInterval: Double(delay) / 1000.0)
                lock.lock()
            }

            do {
                try reconnectAndPrimeLocked()
                return
            } catch {
                lastError = error
                let fileExists = access(Self.socketPath, F_OK) == 0
                print("[Maestro] DaemonSocket.reconnect: attempt \(i+1) failed (socketExists=\(fileExists)): \(error)")
            }
        }
        throw lastError
    }

    /// Full reconnect: connect, register, send priming messages to both queues, start keepalive.
    /// Must be called with lock held.
    private func reconnectAndPrimeLocked() throws {
        // Close stale socket if any
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        _isConnected = false
        stopKeepaliveTimer()

        guard storedAudioDeviceID != 0 else {
            throw DeviceConnectionError.notConnected
        }

        signal(SIGPIPE, SIG_IGN)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DeviceConnectionError.transportError("Cannot create UNIX socket: errno \(errno)")
        }

        var rcvBuf: Int32 = 524_288
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Self.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            pathBytes.withUnsafeBufferPointer { pathBuf in
                UnsafeMutableRawPointer(sunPathPtr)
                    .copyMemory(from: pathBuf.baseAddress!, byteCount: min(pathBuf.count, 104))
            }
        }

        let addrLen = socklen_t(2 + pathBytes.count)
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        let savedErrno = errno
        guard connectResult == 0 else {
            close(fd)
            throw DeviceConnectionError.transportError(
                "Cannot connect to daemon: \(String(cString: strerror(savedErrno)))"
            )
        }

        // Send registration
        let uidBytes = Array(storedDeviceUID.utf8) + [0]
        let bundleBytes = Array(storedBundleID.utf8) + [0]
        let regPayloadSize = 12 + 16 + 12 + uidBytes.count + bundleBytes.count
        var payload = Data(count: regPayloadSize)
        messageCounter += 1
        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(regPayloadSize), objectType: 3)
            // P3G-15j fix (Bug 16): priority 6 to match legacy PluginRegisters.
            writeMessageContent(to: ptr, offset: &offset, msgID: messageCounter, priority: 6, msgType: 0x01)
            var devID = UInt32(storedAudioDeviceID)
            var uidLen = UInt32(uidBytes.count)
            var bundleLen = UInt32(bundleBytes.count)
            memcpy(ptr + offset, &devID, 4); offset += 4
            memcpy(ptr + offset, &uidLen, 4); offset += 4
            memcpy(ptr + offset, &bundleLen, 4); offset += 4
            uidBytes.withUnsafeBufferPointer { memcpy(ptr + offset, $0.baseAddress!, uidBytes.count) }
            offset += uidBytes.count
            bundleBytes.withUnsafeBufferPointer { memcpy(ptr + offset, $0.baseAddress!, bundleBytes.count) }
        }

        try sendFrame(buildFrame(payload: payload), fd: fd)

        // Use readResponseSkippingNotifications (not readSingleMessage) to skip PropertyChanged
        // notifications (objectType=6) that other clients may have caused before our Registration
        // response (objectType=2) arrives. readSingleMessage would consume the notification and
        // mis-parse it as a registration response, causing a spurious "registration rejected" error.
        // 5s timeout: generous, matching the initial connect() path (which uses 10s).
        guard let responseData = readResponseSkippingNotifications(fd: fd, timeout: 5000,
                                                                    expectedMsgID: messageCounter) else {
            close(fd)
            throw DeviceConnectionError.transportError("No registration response")
        }
        let minResponseSize = 8 + 12 + 16 + 12
        guard responseData.count >= minResponseSize else {
            close(fd)
            throw DeviceConnectionError.transportError("Registration response too short")
        }
        let returnStatus = responseData.withUnsafeBytes {
            $0.load(fromByteOffset: 8 + 12 + 16, as: UInt32.self)
        }
        guard returnStatus == 0 else {
            close(fd)
            throw DeviceConnectionError.transportError("Registration rejected: \(returnStatus)")
        }
        deviceControllerID = DaemonSocket.parseDeviceControllerID(from: responseData)

        socketFD = fd
        _isConnected = true
        print("[Maestro] DaemonSocket.reconnect: OK (fd=\(fd), devCtrlID=\(deviceControllerID))")

        // Notify the app (P3G-26) — dispatch to main so AppState can update UI
        let cb = onReconnect
        DispatchQueue.main.async { cb?() }

        // Immediately prime BOTH daemon worker threads to prevent the 1s crash.
        // GetProperty thread: send a GetProperty for output level
        sendPrimingGetPropertyLocked()
        // SetProperty thread: send a SetProperty for output level (no-op, same value)
        sendPrimingSetPropertyLocked()

        // Re-query monitor device ID for direct peripheral routing
        queryMonitorDeviceIDLocked()

        // Re-discover routing stream IDs after reconnect
        symphonyIONonCAID = 0
        outputRoutingStreamIDs = []
        inputRoutingStreamIDs = []
        outputRoutingSourceHints = []
        inputMeterStreamIDs = []
        outputMeterStreamIDs = []
        discoverRoutingStreamIDsLocked()

        // Start the keepalive timer to keep feeding both threads
        startKeepaliveTimer()
    }

    /// Send a priming GetProperty to feed the daemon's GetProperty worker thread.
    /// Must be called with lock held and socketFD valid.
    private func sendPrimingGetPropertyLocked() {
        let propID: UInt32 = 0x41456C33  // 'AEl3'
        let payloadSize = 12 + 16 + 28
        var payload = Data(count: payloadSize)
        messageCounter += 1
        let msgID = messageCounter
        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            self.writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(payloadSize), objectType: 4)
            self.writeMessageContent(to: ptr, offset: &offset, msgID: msgID, priority: 3, msgType: 0x05)
            var devCtrl = self.deviceControllerID
            var nonCA = UInt32(0)
            var prop = propID
            var ch = UInt32(0)
            var maxReturn = UInt32(4096)
            var inputSize = UInt32(0)
            var isIn: UInt8 = 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxReturn, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }
        guard (try? sendFrame(buildFrame(payload: payload), fd: socketFD)) != nil else { return }
        if let resp = readResponseSkippingNotifications(fd: socketFD, timeout: 500, expectedMsgID: msgID),
           let data = try? parseGetPropertyResponse(resp), data.count >= 4 {
            cachedOutputLevel = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        }
    }

    /// Send a priming SetProperty to feed the daemon's SetProperty worker thread.
    /// Writes the cached output level (no-op since value is unchanged).
    /// Must be called with lock held and socketFD valid.
    private func sendPrimingSetPropertyLocked() {
        let propID: UInt32 = 0x41456C33  // 'AEl3'
        var levelData = Data(count: 4)
        levelData.withUnsafeMutableBytes { $0.storeBytes(of: cachedOutputLevel, as: UInt32.self) }
        let fixedSize = 12 + 16 + 28
        let payloadSize = fixedSize + levelData.count
        var payload = Data(count: payloadSize)
        messageCounter += 1
        let msgID = messageCounter  // P3G-15d: capture for response correlation
        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            self.writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(payloadSize), objectType: 5)
            self.writeMessageContent(to: ptr, offset: &offset, msgID: msgID, priority: 2, msgType: 0x03)
            var devCtrl = self.deviceControllerID
            var nonCA = UInt32(0)
            var prop = propID
            var ch = UInt32(0)
            var dataSize = UInt32(0)
            var inputSize = UInt32(levelData.count)
            var isIn: UInt8 = 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &dataSize, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
            offset += 3
            levelData.withUnsafeBytes { dataBuf in
                memcpy(ptr + offset, dataBuf.baseAddress!, levelData.count)
            }
        }
        guard (try? sendFrame(buildFrame(payload: payload), fd: socketFD)) != nil else { return }
        _ = readResponseSkippingNotifications(fd: socketFD, timeout: 500, expectedMsgID: msgID)
    }

    /// Query 'AEmd' (kMaestroPropertyMonitorDevice) to get the monitor device
    /// NonCoreAudioObject ID. The HAL plugin uses this as nonCA in all messages
    /// for direct peripheral routing via NonCoreAudioObject::NonCoreAudioObjectForID().
    /// Must be called with lock held and socketFD valid, AFTER priming.
    /// Evidence: mAEstro.h:780 — kMaestroPropertyMonitorDevice = 'AEmd'
    /// Evidence: SymphonyController.cpp:1666 — GetProperty returns m_nMonitorDeviceID
    private func queryMonitorDeviceIDLocked() {
        let propID: UInt32 = 0x41456D64  // 'AEmd' — kMaestroPropertyMonitorDevice
        let payloadSize = 12 + 16 + 28
        var payload = Data(count: payloadSize)
        messageCounter += 1
        let msgID = messageCounter
        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            self.writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(payloadSize), objectType: 4)
            self.writeMessageContent(to: ptr, offset: &offset, msgID: msgID, priority: 3, msgType: 0x05)
            var devCtrl = self.deviceControllerID
            // 'AEmd' is a SymphonyController-level property.
            // The daemon routes to the SymphonyController object via nonCA = deviceControllerID.
            // nonCA=0 routes to SymphonyPeripheralDevice which doesn't handle 'AEmd' → 'who?' error.
            // Evidence: SymphonyController.cpp:1666 — handles kMaestroPropertyMonitorDevice at controller level.
            var nonCA = self.deviceControllerID
            var prop = propID
            var ch = UInt32(0)
            var maxReturn = UInt32(4096)
            var inputSize = UInt32(0)
            var isIn: UInt8 = 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxReturn, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }
        guard (try? sendFrame(buildFrame(payload: payload), fd: socketFD)) != nil else {
            print("[Maestro] DaemonSocket: failed to send 'AEmd' query")
            return
        }
        if let resp = readResponseSkippingNotifications(fd: socketFD, timeout: 500, expectedMsgID: msgID) {
            // Check daemon return status before parsing
            let minSize = 8 + 12 + 16 + 12
            if resp.count >= minSize {
                let returnStatus = resp.withUnsafeBytes {
                    $0.load(fromByteOffset: 8 + 12 + 16, as: UInt32.self)
                }
                print("[Maestro] DaemonSocket: 'AEmd' response status=\(returnStatus), size=\(resp.count)")
                if returnStatus == 0 {
                    if let data = try? parseGetPropertyResponse(resp), data.count >= 4 {
                        monitorDeviceID = data.withUnsafeBytes { $0.load(as: UInt32.self) }
                        print("[Maestro] DaemonSocket: monitorDeviceID=\(monitorDeviceID) (0x\(String(monitorDeviceID, radix: 16)))")
                    } else {
                        print("[Maestro] DaemonSocket: 'AEmd' parse failed, using nonCA=0 fallback")
                    }
                } else {
                    // Status 2003332927 = 'who?' = kAudioHardwareUnknownPropertyError
                    print("[Maestro] DaemonSocket: 'AEmd' returned error \(returnStatus), using nonCA=0 fallback")
                }
            } else {
                print("[Maestro] DaemonSocket: 'AEmd' response too short (\(resp.count) bytes)")
            }
        } else {
            print("[Maestro] DaemonSocket: 'AEmd' no response received, using nonCA=0 fallback")
        }
    }

    /// Query 'AEsi' (kmAEstroPropertySubDeviceIDList = 0x41457369) on a NonCA object.
    /// Returns the list of child NonCoreAudioObject IDs. Empty on failure or no children.
    /// Must be called with lock held and socketFD valid.
    /// Evidence: og_source/generic/CoreAudio/mAEstro.h — kmAEstroPropertySubDeviceIDList = 'AEsi'
    private func querySubDeviceIDsLocked(nonCA: UInt32) -> [UInt32] {
        let propID: UInt32 = 0x41457369  // 'AEsi' = kmAEstroPropertySubDeviceIDList
        let payloadSize = 12 + 16 + 28
        var payload = Data(count: payloadSize)
        messageCounter += 1
        let msgID = messageCounter
        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            self.writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(payloadSize), objectType: 4)
            self.writeMessageContent(to: ptr, offset: &offset, msgID: msgID, priority: 3, msgType: 0x05)
            var devCtrl = self.deviceControllerID
            var nca = nonCA
            var prop = propID
            var ch = UInt32(0)
            var maxReturn = UInt32(4096)
            var inputSize = UInt32(0)
            var isIn: UInt8 = 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nca, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxReturn, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }
        guard (try? sendFrame(buildFrame(payload: payload), fd: socketFD)) != nil else { return [] }
        guard let resp = readResponseSkippingNotifications(fd: socketFD, timeout: 500, expectedMsgID: msgID),
              let data = try? parseGetPropertyResponse(resp), data.count >= 4 else { return [] }
        let count = data.count / 4
        return (0..<count).compactMap { i -> UInt32? in
            let id = data.withUnsafeBytes { $0.load(fromByteOffset: i * 4, as: UInt32.self) }
            return id != 0 ? id : nil
        }
    }

    /// Try GetProperty 'AEsA' (kMaestroPropertyRouting = 0x41457341) on a specific NonCA object.
    /// Returns parsed response data if daemon answers kAudioHardwareNoError, nil otherwise.
    /// Short timeout (300ms) for use during discovery probing.
    /// Must be called with lock held and socketFD valid.
    private func tryGetRoutingLocked(nonCA: UInt32, channel: UInt32, isInput: Bool) -> Data? {
        let propID: UInt32 = 0x41457341  // 'AEsA' = kMaestroPropertyRouting
        let payloadSize = 12 + 16 + 28
        var payload = Data(count: payloadSize)
        messageCounter += 1
        let msgID = messageCounter
        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            self.writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(payloadSize), objectType: 4)
            self.writeMessageContent(to: ptr, offset: &offset, msgID: msgID, priority: 3, msgType: 0x05)
            var devCtrl = self.deviceControllerID
            var nca = nonCA
            var prop = propID
            var ch = channel
            var maxReturn = UInt32(4096)
            var inputSize = UInt32(0)
            var isIn: UInt8 = isInput ? 1 : 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nca, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxReturn, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }
        guard (try? sendFrame(buildFrame(payload: payload), fd: socketFD)) != nil else { return nil }
        guard let resp = readResponseSkippingNotifications(fd: socketFD, timeout: 300, expectedMsgID: msgID) else { return nil }
        return try? parseGetPropertyResponse(resp)
    }

    /// Discover SymphonyIO NonCA ID and output stream IDs for correct routing write dispatch.
    ///
    /// Root cause of routing write failures:
    ///   monitorDeviceID → SymphonyPeripheralDevice → no 'AEsA' SetProperty handler → 'who?' error
    ///
    /// Fix:
    ///   INPUT  routing writes: use symphonyIONonCAID (SymphonyIO handles fIsInput=true in USB mode)
    ///   OUTPUT routing writes: use outputRoutingStreamIDs[0] (IOBoard output stream as destination)
    ///
    /// Discovery strategy:
    ///   1. 'AEsi' on monitorDeviceID → find child with its own children (= SymphonyIO)
    ///   2. 'AEsi' on SymphonyIO → get stream children
    ///   3. Probe each stream with GetProperty('AEsA', isInput=false, ch=1) → output streams respond
    ///
    /// Must be called with lock held, AFTER queryMonitorDeviceIDLocked() and priming.
    private func discoverRoutingStreamIDsLocked() {
        // 'AEmd' query always fails (returns 'who?' with nonCA=0, '!dev' with nonCA=deviceControllerID).
        // monitorDeviceID is therefore always 0. Skip it and query AEsi(0) directly —
        // this asks the root SymphonyPeripheralDevice for its children, which is equivalent.
        // Evidence: SymphonyController.cpp:1666 — AEmd returns m_nMonitorDeviceID which may
        // not be exposed via this daemon path. AEsi(0) should return the same object tree.

        // Step 1: Get direct children of the root object (nonCA=0 = SymphonyPeripheralDevice)
        let startID: UInt32 = monitorDeviceID  // = 0 when AEmd fails, which is always
        let monitorChildren = querySubDeviceIDsLocked(nonCA: startID)
        print("[Maestro] DaemonSocket: AEsi(nonCA=\(startID)) children=\(monitorChildren)")
        guard !monitorChildren.isEmpty else {
            // Daemon device tree not yet initialized — AEsi(nonCA=0) returned empty.
            // Strategy: derive symphonyIONonCAID from formula, then probe it directly.
            // Formula: symphonyIONonCAID = 0x20000000 + deviceControllerID.
            // Evidence: all working sessions show deviceControllerID=124,
            // symphonyIONonCAID=536871036 = 0x20000000 + 124. Stable across daemon restarts.
            guard deviceControllerID != 0 else {
                print("[Maestro] DaemonSocket: routing discovery: AEsi empty and deviceControllerID=0, cannot recover")
                return
            }
            let derivedID = UInt32(0x20000000) &+ deviceControllerID
            symphonyIONonCAID = derivedID  // set formula ID regardless (best-effort for volume/mute)

            // Probe AEsi(nonCA=derivedID): if SymphonyIO has stream children, complete full
            // discovery even though the root query was empty. This handles the case where the
            // daemon's SymphonyIO object is initialized but the root doesn't list it yet.
            let derivedChildren = querySubDeviceIDsLocked(nonCA: derivedID)
            guard !derivedChildren.isEmpty else {
                print("[Maestro] DaemonSocket: derived ID=\(derivedID) also empty — using formula ID as best-effort for volume/mute")
                return
            }

            // SymphonyIO found via derived ID — run Step 2.5 onwards directly.
            print("[Maestro] DaemonSocket: SymphonyIO NonCA ID=\(derivedID) (derived), stream children=\(derivedChildren)")
            var leafStreams: [UInt32] = []
            for childID in derivedChildren {
                let grandchildren = querySubDeviceIDsLocked(nonCA: childID)
                if grandchildren.isEmpty {
                    leafStreams.append(childID)
                } else {
                    leafStreams.append(contentsOf: grandchildren)
                    print("[Maestro] DaemonSocket: IOBoard ID=\(childID) stream children=\(grandchildren)")
                }
            }
            var outStreamIDs: [UInt32] = []
            var outSourceHints: [(objectID: UInt64, leftElement: UInt64)] = []
            for streamID in Array(leafStreams.prefix(32)) {
                if let routeData = tryGetRoutingLocked(nonCA: streamID, channel: 1, isInput: false) {
                    outStreamIDs.append(streamID)
                    if routeData.count >= 16 {
                        let src = routeData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
                        let el  = routeData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
                        if src != 0 { outSourceHints.append((objectID: src, leftElement: el)) }
                    }
                }
            }
            outputRoutingStreamIDs = outStreamIDs
            outputRoutingSourceHints = outSourceHints
            var inStreamIDs: [UInt32] = []
            for streamID in Array(leafStreams.prefix(32)) {
                if tryGetRoutingLocked(nonCA: streamID, channel: 1, isInput: true) != nil {
                    inStreamIDs.append(streamID)
                }
            }
            inputRoutingStreamIDs = inStreamIDs
            // Meter streams: use ALL leaf streams for both input and output.
            // Each SymphonyIO_Stream has its own ADC+DAC meter data. We can't reliably
            // distinguish ADC from DAC streams via routing probes (all 4 respond to both).
            // Using all streams ensures the user sees signal regardless of which IOBoard
            // their analog inputs feed. Both views show 32 channels (4 × 8ch).
            let sortedLeaves = leafStreams.sorted()
            inputMeterStreamIDs = sortedLeaves
            outputMeterStreamIDs = sortedLeaves
            print("[Maestro] DaemonSocket: routing IDs (derived) — SIO=\(derivedID), in=\(inStreamIDs), out=\(outStreamIDs)")
            print("[Maestro] DaemonSocket: meter streams (derived) — all \(sortedLeaves.count) streams for both in/out")
            return
        }

        // Step 2: Find SymphonyIO — it's the child that has stream children of its own
        var sioID: UInt32 = monitorChildren[0]  // fallback: first child
        var sioChildren: [UInt32] = []
        for childID in monitorChildren {
            let grandchildren = querySubDeviceIDsLocked(nonCA: childID)
            if !grandchildren.isEmpty {
                sioID = childID
                sioChildren = grandchildren
                print("[Maestro] DaemonSocket: SymphonyIO NonCA ID=\(sioID), stream children=\(sioChildren)")
                break
            }
        }
        symphonyIONonCAID = sioID

        // Step 2.5: sioChildren may be IOBoard container IDs, not stream IDs.
        // IOBoards don't handle 'AEsA' in GetProperty — they fall through to NonCADeviceObject
        // which returns 'who?' (kAudioHardwareUnknownPropertyError).
        // Evidence: SymphonyIO_IOBoard.cpp:1007-1380 — no kMaestroPropertyRouting case.
        // Fix: if a sioChild has its own children, it's a container (IOBoard); add its children.
        // If it has no children, it's a leaf (stream); add it directly.
        var leafStreams: [UInt32] = []
        for childID in sioChildren {
            let grandchildren = querySubDeviceIDsLocked(nonCA: childID)
            if grandchildren.isEmpty {
                leafStreams.append(childID)
            } else {
                leafStreams.append(contentsOf: grandchildren)
                print("[Maestro] DaemonSocket: IOBoard ID=\(childID) stream children=\(grandchildren)")
            }
        }
        print("[Maestro] DaemonSocket: \(leafStreams.count) leaf streams to probe for routing")

        // Step 3: Among leaf stream candidates, identify output routing streams
        // by probing GetProperty('AEsA', isInput=false, channel=1).
        // IOBoard output streams respond; input streams and P2P streams do not.
        // Limit probing to max 32 streams to bound startup time.
        var outStreamIDs: [UInt32] = []
        var outSourceHints: [(objectID: UInt64, leftElement: UInt64)] = []
        let streamsToProbe = Array(leafStreams.prefix(32))
        for streamID in streamsToProbe {
            if let routeData = tryGetRoutingLocked(nonCA: streamID, channel: 1, isInput: false) {
                outStreamIDs.append(streamID)
                print("[Maestro] DaemonSocket: output routing stream ID=\(streamID)")
                // Capture the source objectID for pair 0 — used as fallback in OutputRoutingView.
                if routeData.count >= 16 {
                    let srcObjectID = routeData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
                    let srcElement  = routeData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
                    if srcObjectID != 0 {
                        outSourceHints.append((objectID: srcObjectID, leftElement: srcElement))
                        print("[Maestro] DaemonSocket: output source hint: objectID=\(srcObjectID) element=\(srcElement)")
                    }
                }
            }
        }

        // Fallback: if no stream responds to isInput=false, try isInput=true
        // (may indicate firmware returns routing data regardless of scope flag)
        if outStreamIDs.isEmpty {
            for streamID in streamsToProbe {
                if let routeData = tryGetRoutingLocked(nonCA: streamID, channel: 1, isInput: true) {
                    outStreamIDs.append(streamID)
                    print("[Maestro] DaemonSocket: routing stream (isInput=true fallback) ID=\(streamID)")
                    if routeData.count >= 16 {
                        let srcObjectID = routeData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
                        let srcElement  = routeData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
                        if srcObjectID != 0 {
                            outSourceHints.append((objectID: srcObjectID, leftElement: srcElement))
                        }
                    }
                }
            }
        }

        outputRoutingStreamIDs = outStreamIDs
        outputRoutingSourceHints = outSourceHints

        // Step 4: Among leaf stream candidates, identify input routing streams
        // by probing GetProperty('AEsA', isInput=true, channel=1).
        // IOBoard input streams respond; output streams and P2P streams do not.
        var inStreamIDs: [UInt32] = []
        for streamID in streamsToProbe {
            if tryGetRoutingLocked(nonCA: streamID, channel: 1, isInput: true) != nil {
                inStreamIDs.append(streamID)
                print("[Maestro] DaemonSocket: input routing stream ID=\(streamID)")
            }
        }
        inputRoutingStreamIDs = inStreamIDs

        // Meter stream IDs: use ALL leaf streams for both input and output.
        // Each SymphonyIO_Stream has its own meter data (ADC+DAC). We can't distinguish
        // ADC from DAC streams via routing probes. Using all streams for both views ensures
        // the user always sees their signal. Both views show 32 channels (4 × 8ch).
        let sortedLeaves = leafStreams.sorted()
        inputMeterStreamIDs = sortedLeaves
        outputMeterStreamIDs = sortedLeaves
        print("[Maestro] DaemonSocket: routing IDs — SIO=\(symphonyIONonCAID), inStreams=\(inputRoutingStreamIDs), outStreams=\(outputRoutingStreamIDs)")
        print("[Maestro] DaemonSocket: meter streams — all \(sortedLeaves.count) streams for both in/out")
    }

    /// Thread-safe snapshot of discovered input routing stream IDs.
    /// Used by CoreAudioDeviceConnection to expose fallback source IDs to the view layer.
    func inputRoutingStreamIDsCopy() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return inputRoutingStreamIDs
    }

    /// Thread-safe snapshot of discovered output routing source hints.
    /// Used by CoreAudioDeviceConnection to expose fallback source IDs to the view layer.
    func outputRoutingSourceHintsCopy() -> [(objectID: UInt64, leftElement: UInt64)] {
        lock.lock()
        defer { lock.unlock() }
        return outputRoutingSourceHints
    }

    /// Thread-safe snapshot of discovered output routing stream NonCA IDs.
    func outputRoutingStreamIDsCopy() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return outputRoutingStreamIDs
    }

    /// Thread-safe snapshot of input meter stream NonCA IDs (first half of leafStreams).
    func inputMeterStreamIDsCopy() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return inputMeterStreamIDs
    }

    /// Thread-safe snapshot of output meter stream NonCA IDs (second half of leafStreams).
    func outputMeterStreamIDsCopy() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return outputMeterStreamIDs
    }

    /// Send GetProperty with an explicit nonCA ID (bypasses internal nonCA selection logic).
    /// Used for stream-level properties like 'AEsm' that must target a specific stream object.
    func getPropertyForNonCA(propertyID: UInt32, nonCA: UInt32, channel: UInt32, isInput: Bool) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        try ensureConnectedLocked()
        drainNotificationsLocked()

        let payloadSize = 12 + 16 + 28
        var payload = Data(count: payloadSize)
        messageCounter += 1
        let msgID = messageCounter
        var explicitNonCA = nonCA

        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0
            writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(payloadSize), objectType: 4)
            writeMessageContent(to: ptr, offset: &offset, msgID: msgID, priority: 3, msgType: 0x05)
            var devCtrl = self.deviceControllerID
            var prop = propertyID
            var ch = channel
            var maxReturn = UInt32(4096)
            var inputSize = UInt32(0)
            var isIn: UInt8 = isInput ? 1 : 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &explicitNonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxReturn, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }

        let frame = buildFrame(payload: payload)
        try sendFrame(frame, fd: socketFD)

        guard let response = readResponseSkippingNotifications(fd: socketFD, timeout: 2000, expectedMsgID: msgID) else {
            throw DeviceConnectionError.transportError("No response for prop=0x\(String(propertyID, radix: 16)) nonCA=\(nonCA)")
        }
        return try parseGetPropertyResponse(response)
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        stopKeepaliveTimer()
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        _isConnected = false
    }

    /// Send GetProperty and return response data.
    public func getProperty(propertyID: UInt32, channel: UInt32, isInput: Bool) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        // Auto-reconnect if needed (daemon may have crashed and restarted).
        try ensureConnectedLocked()

        // Drain notifications before our query
        drainNotificationsLocked()

        let payloadSize = 12 + 16 + 28  // Transportable + Message + GetPropertyContents
        var payload = Data(count: payloadSize)
        messageCounter += 1
        let msgID = messageCounter

        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0

            // Transportable (12)
            writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(payloadSize), objectType: 4)

            // MessageContent (16)
            writeMessageContent(to: ptr, offset: &offset, msgID: msgID, priority: 3, msgType: 0x05)

            // GetPropertyContents (28)
            // Bug 3 fix: use extracted deviceControllerID instead of hardcoded 0
            // Routing fix: 'AEsA' reads use symphonyIONonCAID (input) or the IOBoard output
            // stream covering the requested channel (output). monitorDeviceID cascades through
            // SymphonyPeripheralDevice — correct for input but returns wrong scope for output.
            // Multi-stream: each IOBoard output stream covers 8 channels. Select by channel range.
            // Evidence: SymphonyIOUSBAudioRoutingController.cpp:85-219 — SetRouting targets stream.
            var devCtrl = self.deviceControllerID
            let routingPropID: UInt32 = 0x41457341  // 'AEsA'
            var nonCA: UInt32
            if propertyID == routingPropID {
                if isInput {
                    nonCA = symphonyIONonCAID != 0 ? symphonyIONonCAID : monitorDeviceID
                } else if !outputRoutingStreamIDs.isEmpty {
                    // Select stream by channel range: each IOBoard stream covers 8 channels.
                    let channelsPerStream = 8
                    let streamIdx = outputRoutingStreamIDs.count > 1
                        ? min((Int(channel) - 1) / channelsPerStream, outputRoutingStreamIDs.count - 1)
                        : 0
                    nonCA = outputRoutingStreamIDs[streamIdx]
                } else {
                    nonCA = monitorDeviceID
                }
            } else {
                // getPropertyNonCA: 'AEmD' → symphonyIONonCAID; all others (incl. symphonioPropIDs
                // like 'AEl3', 'AEm3') → monitorDeviceID (=0). Asymmetric: SymphonyIO handles SET
                // for output control props but NOT GET. See getPropertyNonCA() doc for details.
                nonCA = Self.getPropertyNonCA(
                    propertyID: propertyID,
                    symphonyIONonCAID: symphonyIONonCAID,
                    monitorDeviceID: self.monitorDeviceID
                )
            }
            var prop = propertyID
            var ch = channel
            var maxReturn = UInt32(4096)
            var inputSize = UInt32(0)
            var isIn: UInt8 = isInput ? 1 : 0

            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxReturn, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }

        let frame = buildFrame(payload: payload)
        try sendFrame(frame, fd: socketFD)

        // Skip PropertyChanged notifications — wait for the Response matching our request.
        guard let response = readResponseSkippingNotifications(fd: socketFD, timeout: 2000, expectedMsgID: msgID) else {
            throw DeviceConnectionError.transportError("No response from daemon for property 0x\(String(propertyID, radix: 16))")
        }

        return try parseGetPropertyResponse(response)
    }

    /// Send SetProperty.
    public func setProperty(propertyID: UInt32, channel: UInt32, isInput: Bool, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        // Auto-reconnect if needed (daemon may have crashed and restarted).
        try ensureConnectedLocked()

        // Drain notifications before our query
        drainNotificationsLocked()

        let fixedSize = 12 + 16 + 28  // Transportable + Message + SetPropertyContents
        let payloadSize = fixedSize + data.count
        var payload = Data(count: payloadSize)
        messageCounter += 1
        let msgID = messageCounter  // P3G-15d: capture for response correlation

        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0

            // Transportable (12)
            writeTransportable(to: ptr, offset: &offset, totalPacked: UInt32(payloadSize), objectType: 5)

            // MessageContent (16)
            writeMessageContent(to: ptr, offset: &offset, msgID: msgID, priority: 2, msgType: 0x03)

            // SetPropertyContents (28)
            // Field order: devCtrl, nonCA, propID, channel, m_dataSize, m_inputSize, isInput
            // m_dataSize (offset 16) = auxiliary data size (unused, always 0)
            // m_inputSize (offset 20) = PRIMARY value size (the property value)
            // Evidence: og_source/maestrolink/.../ApogeeDriverPlugInMessageSetProperty.cpp
            // Bug 3 fix: use extracted deviceControllerID instead of hardcoded 0
            // Routing fix: 'AEsA' writes use symphonyIONonCAID (input) or the IOBoard output
            // stream covering the destination channel (output). Sending to monitorDeviceID →
            // SymphonyPeripheralDevice → no routing handler → 'who?' error.
            // Multi-stream: each IOBoard output stream covers 8 channels. Select by channel range.
            // Evidence: SymphonyIO.cpp:2671-2715, SymphonyIOUSBAudioRoutingController.cpp:85-219.
            var devCtrl = self.deviceControllerID
            let routingPropID: UInt32 = 0x41457341  // 'AEsA'
            // Mixer property IDs: 'AEMl' level, 'AEMp' pan, 'AEMm' mute, 'AEMs' solo.
            // These are handled by SymphonyIO (symphonyIONonCAID), not SymphonyPeripheralDevice.
            // Evidence: SymphonyIOControl.cpp:1904-1942 — mixer SetProperty targets SymphonyIO.
            let mixerPropIDs: Set<UInt32> = [0x41454D6C, 0x41454D70, 0x41454D6D, 0x41454D73]
            // Output/monitor control properties handled by SymphonyIO object (not SymphonyPeripheralDevice).
            // Root cause of volume/mute regression: sending these with nonCA=0 causes daemon to store
            // the value in SymphonyPeripheralDevice (generic store), but SymphonyIO never sees the write.
            // SymphonyIO.cpp validates nonCA == m_nNonCAObjectID before calling hardware control methods.
            // Evidence: SymphonyIO.cpp:1978-2009 (MainOutLevel), :2014 (MainOutMute), :2031 (MainOutDim),
            //           :2041 (MainOutSum), :2188-2214 (HP1/HP2 Level), :2073-2103 (HP1/HP2 Mute),
            //           :2123-2140 (HP1/HP2 Dim), :2158 (HP1/HP2 Sum), :1335 (ActiveSpeakerSet).
            let symphonioPropIDs: Set<UInt32> = [
                0x41456C33, // 'AEl3' kmAEstroPropertyMainOutLevel (SymphonyIO.cpp:1978)
                0x41456D33, // 'AEm3' kmAEstroPropertyMainOutMute (SymphonyIO.cpp:2014)
                0x41456D34, // 'AEm4' kmAEstroPropertyMainOutDim (SymphonyIO.cpp:2031)
                0x41456D35, // 'AEm5' kmAEstroPropertyMainOutSum (SymphonyIO.cpp:2041)
                0x41456C31, // 'AEl1' kmAEstroPropertyHeadPhone1Level (SymphonyIO.cpp:2188)
                0x41456C32, // 'AEl2' kmAEstroPropertyHeadPhone2Level (SymphonyIO.cpp:2191)
                0x41456D31, // 'AEm1' kMaestroPropertyHeadphone1Mute (SymphonyIO.cpp:2073)
                0x41456D32, // 'AEm2' kMaestroPropertyHeadphone2Mute (SymphonyIO.cpp:2074)
                0x41456864, // 'AEhd' kMaestroPropertyHeadphone1Dim (SymphonyIO.cpp:2123)
                0x41456865, // 'AEhe' kMaestroPropertyHeadphone2Dim (SymphonyIO.cpp:2126)
                0x41456873, // 'AEhs' kMaestroPropertyHeadphone1Sum (SymphonyIO.cpp:2158)
                0x41456874, // 'AEht' kMaestroPropertyHeadphone2Sum (SymphonyIO.cpp)
                0x41456173, // 'AEas' kmAEstroPropertyActiveSpeakerSet (SymphonyIO.cpp:1335)
            ]
            var nonCA: UInt32
            var routingIsIn: Bool = isInput  // may be overridden for output routing
            if propertyID == routingPropID {
                if isInput {
                    nonCA = symphonyIONonCAID != 0 ? symphonyIONonCAID : monitorDeviceID
                } else if !outputRoutingStreamIDs.isEmpty {
                    // Select stream by channel range: each IOBoard stream covers 8 channels.
                    let channelsPerStream = 8
                    let streamIdx = outputRoutingStreamIDs.count > 1
                        ? min((Int(channel) - 1) / channelsPerStream, outputRoutingStreamIDs.count - 1)
                        : 0
                    nonCA = outputRoutingStreamIDs[streamIdx]
                    // IOBoard output streams accept AEsA SetProperty only when fIsInput=true.
                    // The flag describes the direction FROM the stream's perspective: "what feeds
                    // in to my output channels". isInput=false causes the daemon to return 'who?'.
                    // Evidence: output routing SET with isInput=false → 2003332927 ('who?');
                    //           input routing SET with isInput=true and SymphonyIO → success.
                    routingIsIn = true
                } else {
                    nonCA = monitorDeviceID
                }
            } else if mixerPropIDs.contains(propertyID) || symphonioPropIDs.contains(propertyID) {
                // Mixer and output/monitor control properties all target the SymphonyIO object.
                nonCA = symphonyIONonCAID != 0 ? symphonyIONonCAID : monitorDeviceID
            } else {
                nonCA = self.monitorDeviceID
            }
            var prop = propertyID
            var ch = channel
            var dataSize = UInt32(0)             // m_dataSize: auxiliary (unused)
            var inputSize = UInt32(data.count)   // m_inputSize: value size (PRIMARY)
            var isIn: UInt8 = routingIsIn ? 1 : 0

            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &dataSize, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
            offset += 3  // padding to 28

            // Data payload
            data.withUnsafeBytes { dataBuf in
                memcpy(ptr + offset, dataBuf.baseAddress!, data.count)
            }
        }

        let frame = buildFrame(payload: payload)
        try sendFrame(frame, fd: socketFD)

        // Read response, skipping PropertyChanged notifications and mismatched responses.
        // Evidence: daemon sends PropertyChanged (objectType=6) to all registered
        // clients whenever a property changes, including back to the sender.
        guard let response = readResponseSkippingNotifications(fd: socketFD, timeout: 2000, expectedMsgID: msgID) else {
            throw DeviceConnectionError.transportError("No SetProperty response from daemon")
        }

        let minSize = 8 + 12 + 16 + 12
        guard response.count >= minSize else {
            throw DeviceConnectionError.transportError("SetProperty response too short (\(response.count) bytes)")
        }

        let returnStatus = response.withUnsafeBytes {
            $0.load(fromByteOffset: 8 + 12 + 16, as: UInt32.self)
        }
        guard returnStatus == 0 else {
            throw DeviceConnectionError.transportError(
                "SetProperty failed: daemon returned \(returnStatus)"
            )
        }

        // Keep cachedOutputLevel in sync when 'AEl3' is written successfully.
        // See cachedLevelUpdate() for full explanation of snap-back prevention.
        if let newLevel = Self.cachedLevelUpdate(propertyID: propertyID, data: data) {
            cachedOutputLevel = newLevel
        }
    }

    // MARK: - Protocol Helpers

    /// Parse DeviceControllerID from a daemon registration response.
    ///
    /// Layout: [8 frame][12 Transportable][16 MessageContent][12 ResponseContents][N data]
    /// ResponseContents: returnStatus(4) + senderPID(4) + returnDataSize(4) = 12 bytes.
    /// DeviceControllerID is the first 4 bytes of return data, at combined offset 48.
    /// Evidence: daemonCommunication.cpp:606 — m_nDeviceControllerID=*(UInt32*)pResponseMsg->m_pReturnData
    ///
    /// Returns 0 if the response is too short or returnDataSize < 4 (safe default: daemon treats 0
    /// as "unregistered" and will return kAudioHardwareBadObjectError rather than routing to wrong device).
    // MARK: - Testable Static Helpers

    /// Returns the nonCA value that GetProperty uses for a given propertyID.
    ///
    /// Asymmetric nonCA dispatch — why GET and SET use different nonCA values:
    /// - 'AEmD' meterData: SymphonyIO handles GetProperty for meter data → use symphonyIONonCAID.
    /// - All other props (incl. symphonioPropIDs like 'AEl3', 'AEm3', …): the root
    ///   SymphonyPeripheralDevice (nonCA=0) stores the readable values. SymphonyIO handles
    ///   SetProperty for these but NOT GetProperty. Querying via symphonyIONonCAID returns an
    ///   error, leaving cachedOutputLevel stale → keepalive writes stale value → snap-back.
    /// Evidence: keepalive priming GET for 'AEl3' uses nonCA=0 and reads correct hardware level.
    static func getPropertyNonCA(
        propertyID: UInt32,
        symphonyIONonCAID: UInt32,
        monitorDeviceID: UInt32
    ) -> UInt32 {
        let meterDataPropID: UInt32 = 0x41456D44  // 'AEmD' = kApogeeCustomProperty_MeterData
        if propertyID == meterDataPropID {
            // SymphonyIO DOES handle GetProperty for meter data.
            return symphonyIONonCAID != 0 ? symphonyIONonCAID : monitorDeviceID
        }
        // All other props: root SymphonyPeripheralDevice stores readable values.
        return monitorDeviceID
    }

    /// If propertyID is 'AEl3' and data has ≥4 bytes, returns the new level (UInt32). Otherwise nil.
    ///
    /// Used by setProperty to keep cachedOutputLevel in sync so the keepalive SET (every 400ms)
    /// writes the current user-selected level rather than an old stale value (snap-back bug).
    /// Only 'AEl3' is cached because the keepalive only writes that property.
    static func cachedLevelUpdate(propertyID: UInt32, data: Data) -> UInt32? {
        guard propertyID == 0x41456C33, data.count >= 4 else { return nil }
        return data.withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    static func parseDeviceControllerID(from response: Data) -> UInt32 {
        let returnDataSizeOffset = 8 + 12 + 16 + 8  // 44: ResponseContents.returnDataSize
        let devCtrlOffset = 8 + 12 + 16 + 12        // 48: start of return data
        guard response.count >= devCtrlOffset + 4 else { return 0 }
        let returnDataSize = response.withUnsafeBytes {
            $0.load(fromByteOffset: returnDataSizeOffset, as: UInt32.self)
        }
        guard returnDataSize >= 4 else { return 0 }
        return response.withUnsafeBytes {
            $0.load(fromByteOffset: devCtrlOffset, as: UInt32.self)
        }
    }

    // MARK: - Framing

    private func buildFrame(payload: Data) -> Data {
        var frame = Data(capacity: 8 + payload.count)
        var magicVal = Self.magic
        var packetSize = UInt32(payload.count)
        frame.append(Data(bytes: &magicVal, count: 4))
        frame.append(Data(bytes: &packetSize, count: 4))
        frame.append(payload)
        return frame
    }

    private func sendFrame(_ frame: Data, fd: Int32) throws {
        // P3G-15g fix (Bug 14): packet size guard — legacy caps total frame at 4096 bytes.
        // Evidence: MaestroLinkMessaging.h:20 — MAESTROLINK_MAX_PACKETSIZE_BYTES = 4096.
        guard frame.count <= 4096 else {
            throw DeviceConnectionError.transportError(
                "Packet too large (\(frame.count) bytes, max 4096 per MaestroLinkMessaging.h)"
            )
        }
        // P3G-13 fix (Bug 13 partial): loop until all bytes are sent.
        // Darwin.send() may return less than frame.count for large packets
        // or when the kernel send buffer is temporarily full.
        var totalSent = 0
        try frame.withUnsafeBytes { buf in
            let base = buf.baseAddress!
            while totalSent < frame.count {
                let n = Darwin.send(fd, base + totalSent, frame.count - totalSent, 0)
                if n < 0 {
                    _isConnected = false
                    throw DeviceConnectionError.transportError(
                        "Socket send failed at offset \(totalSent)/\(frame.count): errno \(errno)"
                    )
                }
                if n == 0 {
                    _isConnected = false
                    throw DeviceConnectionError.transportError(
                        "Socket closed during send (sent \(totalSent)/\(frame.count))"
                    )
                }
                totalSent += n
            }
        }
    }

    private func readSingleMessage(fd: Int32, timeout: Int32) -> Data? {
        var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFd, 1, timeout) > 0 else { return nil }

        // Read frame header first (8 bytes: magic + size)
        var header = [UInt8](repeating: 0, count: 8)
        let headerRead = recv(fd, &header, 8, MSG_WAITALL)
        guard headerRead == 8 else { return nil }

        let packetSize = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        guard packetSize > 0, packetSize <= 65536 else { return nil }

        // Read the payload
        var payload = [UInt8](repeating: 0, count: Int(packetSize))
        var totalRead = 0
        while totalRead < Int(packetSize) {
            let remaining = Int(packetSize) - totalRead
            let n = payload.withUnsafeMutableBytes { buf in
                recv(fd, buf.baseAddress! + totalRead, remaining, 0)
            }
            if n <= 0 { break }
            totalRead += n
        }
        guard totalRead == Int(packetSize) else { return nil }

        // Combine header + payload
        var result = Data(header)
        result.append(Data(payload))
        return result
    }

    /// Read messages from the daemon, skipping PropertyChanged notifications and
    /// mismatched responses, until we get a Response (objectType=2) for our request.
    ///
    /// The daemon broadcasts PropertyChanged notifications (objectType=6) to ALL registered
    /// clients whenever a property changes. These arrive interleaved with our request/response
    /// messages and must be skipped.
    ///
    /// P3G-15d fix (Bug 11): Response correlation by uniqueMessageID.
    /// The daemon echoes our request's uniqueMessageID in the response's MessageContent.
    /// When `expectedMsgID` is set, we skip responses whose uniqueID doesn't match —
    /// these are stale responses from concurrent requests (e.g. keepalive tick).
    /// Evidence: BiDirConnection.cpp:72,186 — legacy matches by uniqueMessageID + senderPID.
    ///
    /// Evidence for notification skip: Daemon test showed objectType=6 (PropertyChanged)
    /// arriving before objectType=2 (Response) after a SetProperty command.
    func readResponseSkippingNotifications(fd: Int32, timeout: Int32,
                                           expectedMsgID: UInt32? = nil) -> Data? {
        // P3G-15f fix (Bug 13): deadline-based loop instead of fixed attempt limit.
        // A fixed attempt limit (e.g. 10) fails if the daemon sends many notifications
        // before the response (batch property changes, keepalive tick, other clients).
        // Total wait is bounded by `timeout` ms regardless of notification count.
        // Evidence: BiDirConnection.cpp:97 — legacy uses timeout-based waiting.
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)

        while Date() <= deadline {
            // Remaining time for this readSingleMessage call (at least 1ms)
            let remainingMs = Int32(max(1, min(timeout, Int32(deadline.timeIntervalSinceNow * 1000))))
            guard let message = readSingleMessage(fd: fd, timeout: remainingMs) else {
                return nil  // Socket closed or hard error
            }
            // Need at least frame(8) + Transportable(12) + MessageContent.uniqueID(4) = 24 bytes
            guard message.count >= 24 else { return message }

            let objectType = message.withUnsafeBytes {
                $0.load(fromByteOffset: 8 + 4, as: UInt32.self)
            }

            if objectType == 2 {
                // Got a Response — verify it's for our request via uniqueMessageID correlation.
                // MessageContent.uniqueID is at offset 8 (frame) + 12 (Transportable) = 20.
                // The daemon echoes the request's uniqueMessageID back in the response.
                if let expected = expectedMsgID {
                    let responseUID = message.withUnsafeBytes {
                        $0.load(fromByteOffset: 20, as: UInt32.self)
                    }
                    if responseUID != expected {
                        // Stale response for a different (e.g. keepalive) request — skip.
                        print("[Maestro] DaemonSocket: correlation skip (uid=\(responseUID) != expected=\(expected))")
                        continue
                    }
                }
                return message  // Correlation passed — got the Response we were waiting for
            }
            // objectType == 6: PropertyChanged notification — skip and continue
        }
        return nil  // Deadline exceeded without finding a matching Response
    }

    private func parseGetPropertyResponse(_ response: Data) throws -> Data {
        let minSize = 8 + 12 + 16 + 12  // frame + Transportable + Message + ResponseContents
        guard response.count >= minSize else {
            throw DeviceConnectionError.transportError("GetProperty response too short (\(response.count) bytes)")
        }

        let returnStatus = response.withUnsafeBytes {
            $0.load(fromByteOffset: 8 + 12 + 16, as: UInt32.self)
        }
        guard returnStatus == 0 else {
            throw DeviceConnectionError.transportError("GetProperty failed: daemon returned \(returnStatus)")
        }

        let returnDataSize = response.withUnsafeBytes {
            $0.load(fromByteOffset: 8 + 12 + 16 + 8, as: UInt32.self)
        }

        let dataOffset = 8 + 12 + 16 + 12  // After ResponseContents
        guard dataOffset + Int(returnDataSize) <= response.count else {
            throw DeviceConnectionError.transportError("Response data truncated")
        }

        return Data(response[dataOffset..<(dataOffset + Int(returnDataSize))])
    }

    // MARK: - Message Packing Helpers

    /// Pack TransportableContents (12 bytes):
    ///   [4] totalPackedSize  [4] objectType  [1] byteOrder  [3] padding
    private func writeTransportable(to ptr: UnsafeMutableRawPointer, offset: inout Int,
                                     totalPacked: UInt32, objectType: UInt32) {
        // P3G-15i fix (Bug 15): write 0 like legacy Transportable constructor (Transportable.cpp:20).
        // The Transportable constructor sets m_nTotalPackedSize=0 and Pack() never updates it.
        // The daemon reads actual packet size from the MLNK frame header's packetSize field,
        // not from m_nTotalPackedSize, so this field is effectively ignored by the daemon.
        _ = totalPacked  // parameter kept for documentation; wire value is always 0
        var tp = UInt32(0)
        var ot = objectType
        var bo: UInt8 = 0x4C  // 'L' for Little Endian
        memcpy(ptr + offset, &tp, 4); offset += 4
        memcpy(ptr + offset, &ot, 4); offset += 4
        memcpy(ptr + offset, &bo, 1); offset += 1
        offset += 3  // padding
    }

    /// Pack MessageContent (16 bytes):
    ///   [4] uniqueID  [4] priority  [4] processID  [1] messageType  [3] padding
    private func writeMessageContent(to ptr: UnsafeMutableRawPointer, offset: inout Int,
                                      msgID: UInt32, priority: Int32, msgType: UInt8) {
        var uid = msgID
        var prio = priority
        var pid = UInt32(getpid())
        var mt = msgType
        memcpy(ptr + offset, &uid, 4); offset += 4
        memcpy(ptr + offset, &prio, 4); offset += 4
        memcpy(ptr + offset, &pid, 4); offset += 4
        memcpy(ptr + offset, &mt, 1); offset += 1
        offset += 3  // padding
    }

    // MARK: - Testable Payload Builders

    /// Build a SetProperty payload (without frame header) for protocol verification.
    /// Returns the raw bytes that would be packed inside the MLNK frame.
    public func buildSetPropertyPayload(propertyID: UInt32, channel: UInt32,
                                  isInput: Bool, data: Data) -> Data {
        let fixedSize = 12 + 16 + 28
        let payloadSize = fixedSize + data.count
        var payload = Data(count: payloadSize)

        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0

            writeTransportable(to: ptr, offset: &offset,
                             totalPacked: UInt32(payloadSize), objectType: 5)
            writeMessageContent(to: ptr, offset: &offset,
                              msgID: 99, priority: 2, msgType: 0x03)

            // SetPropertyContents (28 bytes) — same layout as setProperty()
            var devCtrl = UInt32(0)
            var nonCA = UInt32(0)
            var prop = propertyID
            var ch = channel
            var auxDataSize = UInt32(0)             // m_dataSize: auxiliary (unused)
            var inputSize = UInt32(data.count)       // m_inputSize: value size (PRIMARY)
            var isIn: UInt8 = isInput ? 1 : 0

            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &auxDataSize, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
            offset += 3

            data.withUnsafeBytes { dataBuf in
                memcpy(ptr + offset, dataBuf.baseAddress!, data.count)
            }
        }

        return payload
    }

    /// Build a GetProperty payload (without frame header) for protocol verification.
    public func buildGetPropertyPayload(propertyID: UInt32, channel: UInt32,
                                  isInput: Bool) -> Data {
        let payloadSize = 12 + 16 + 28
        var payload = Data(count: payloadSize)

        payload.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            var offset = 0

            writeTransportable(to: ptr, offset: &offset,
                             totalPacked: UInt32(payloadSize), objectType: 4)
            writeMessageContent(to: ptr, offset: &offset,
                              msgID: 99, priority: 3, msgType: 0x05)

            // GetPropertyContents (28 bytes)
            var devCtrl = UInt32(0)
            var nonCA = UInt32(0)
            var prop = propertyID
            var ch = channel
            var maxReturn = UInt32(4096)
            var inputSize = UInt32(0)
            var isIn: UInt8 = isInput ? 1 : 0

            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxReturn, 4); offset += 4
            memcpy(ptr + offset, &inputSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }

        return payload
    }
}

// MARK: - Listener Storage

private final class CoreAudioListenerStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [PropertyAddress: [WeakListenerRef]] = [:]

    func addListener(_ listener: PropertyListener, for address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        var list = listeners[address] ?? []
        list.append(WeakListenerRef(listener))
        listeners[address] = list
    }

    func removeListener(_ listener: PropertyListener, for address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        listeners[address]?.removeAll { $0.value === listener }
    }

    func notifyListeners(for address: PropertyAddress, change: PropertyChange) async {
        let toNotify = getListeners(for: address)
        for listener in toNotify {
            await listener.propertyDidChange(change)
        }
    }

    private func getListeners(for address: PropertyAddress) -> [PropertyListener] {
        lock.lock()
        defer { lock.unlock() }
        return (listeners[address] ?? []).compactMap { $0.value }
    }

    private final class WeakListenerRef: @unchecked Sendable {
        weak var value: PropertyListener?
        init(_ value: PropertyListener) { self.value = value }
    }
}
