/// XPC-based DeviceConnection routing property operations through MaestroVolumeProxy.
///
/// Uses SymphonyIOPropertyMapper to convert property addresses to USB control requests,
/// then serializes them as XPC messages to the proxy daemon which executes them via
/// direct USB vendor EP0 commands.
///
/// This bypasses the broken Apogee daemon on macOS 26 and uses the same USB path
/// that the AudioServerPlugin's volume/mute controls already use successfully.

import MaestroCore
import Foundation

// MARK: - XPC Reply

/// Sendable reply from an XPC getProperty request.
public struct XPCPropertyReply: Sendable {
    /// 0 = success, negative = error.
    public let status: Int64
    /// Response data from the USB device.
    public let data: Data

    public init(status: Int64, data: Data) {
        self.status = status
        self.data = data
    }
}

// MARK: - XPC Transport Protocol

/// Abstraction over the XPC connection for testability.
///
/// Real implementation uses `xpc_connection_t`; tests can substitute a mock.
public protocol XPCTransport: Sendable {
    /// Counts the times the helper behind this connection went away
    /// (restarted or crashed) while the app kept running. Unit A's connection
    /// generation does not change then, but the helper that answers next
    /// programs the direct routes again, so the app's restore must run again.
    var helperEpoch: UInt64 { get }

    /// Send a setProperty message and await the proxy's reply. Throws if the XPC
    /// round-trip fails or the proxy reports a non-zero (USB write) status (S5).
    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws

    /// Send a getProperty message and wait for a reply.
    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply

    /// Query software return meter peaks from proxy render callback.
    /// Returns (peakL, peakR) in linear 0..1, or nil if not available.
    func getSoftwareMeterLevels() async -> (Float, Float)?

    /// Per-USB-playback-channel peaks measured in the proxy render callback,
    /// linear 0..1, index = USB channel (0/1 are post software gain/mute).
    /// Reading resets the proxy's accumulators, so a caller must not also call
    /// `getSoftwareMeterLevels()` in the same cycle. Returns nil when the proxy
    /// is unreachable. An older proxy that only reports L/R yields a 2-element
    /// array.
    func getSoftwareOutputPeaks() async -> [Float]?

    /// Set the proxy's software mute on USB playback 1-2. When it may be on is
    /// one rule, ``USBHelperSoftwareReturn``.
    func setSwReturnMute(_ muted: Bool)

    /// Send a mixer parameter command directly (bypasses generic setProperty).
    /// usbCmd: 0xB0=fader, 0xB1=pan, 0xB2=solo, 0xB3=mute.
    /// nValue = (mixer << 16) | channel, data = 1 byte value.
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8)

    /// Set the proxy's software SW Return gain in dB (both sides). Maestro keeps
    /// this at 0 dB: the unit's own mixer (strip 32) owns the Software Return
    /// fader. Overwrites both per-side gains.
    func setSwReturnLevel(_ dB: Double)

    /// Set one side of the software return independently.
    func setSwReturnChannelLevel(channel: Int, dB: Double)

    /// Select whether the software gain/mute stage should process USB channels 1-2.
    func setSwReturnProcessing(_ enabled: Bool)

    /// Ask the proxy to tear down and rebuild its output AudioUnit.
    ///
    /// This is the half "Reconnect Hardware" was missing. Reconnecting the app
    /// re-establishes the app-to-proxy link and clears stale meters, but the
    /// audio path is proxy-to-hardware -- so if the AudioUnit is bound to a
    /// device that has gone away (or to the wrong one), reconnecting the app
    /// cannot fix it. Rebuilding re-resolves the device, re-coerces the sample
    /// rate, recomputes the presentation delay and bumps the clock generation.
    func resetAudioOutput()

    /// The installed helper's version (`MAESTRO_HELPER_VERSION` in
    /// Drivers/VolumeProxy/MaestroVolumeProxy.c), nil when it did not answer:
    /// a helper from before the question existed, or one that is not there.
    func helperVersion() async -> UInt64?

    /// The output the helper's volume and mute move now (1 speakers, 2
    /// Headphone 1, 3 Headphone 2), nil when it did not say.
    func helperMonitorOutput() async -> UInt64?

    /// Tell the helper which output the volume and mute of "Maestro USB" move
    /// from now on ("setMonitorOutput"), with that output's current level
    /// (attenuation, 0-64 dB) and mute. Nothing is written to the unit.
    /// False when the helper refused or did not answer.
    func setMonitorOutput(_ output: UInt64, attenuation: UInt64, muted: Bool) async -> Bool

    /// What the unit holds of what the helper wrote to it since it opened it
    /// (helper "getWriteShadow"): nil from a helper without the question, or
    /// with no unit open.
    func writeShadow() async -> USBWriteShadow?

    /// Whether the transport is connected.
    var isConnected: Bool { get }
}

/// What the unit holds, as far as the helper knows: every route and digital
/// format setting (0x34 optical format, 0x35/0x36 S/PDIF coax, per board) it
/// has written to the unit it has open and the unit took, configure's direct
/// table included. Forgotten by the helper when the unit goes away.
///
/// The connect restore skips a write the unit already holds
/// (``XPCDeviceConnection/beginRestoreElision()``): 0.9.25 rewrote every saved
/// route, both headphones and the optical format while USB audio played,
/// about 3 s after a replug, and the owner heard the audio stop briefly.
/// Only the routes of audible destinations (outputs 32-63, headphones
/// 224-227) and the digital settings are ever skipped.
public struct USBWriteShadow: Sendable, Equatable {
    /// Destination to source.
    public var routes: [UInt8: UInt8]
    /// `(request << 8) | board` to value.
    public var digital: [UInt16: UInt8]
    /// How many times the helper has configured a unit since it started
    /// (every configure puts all outputs and headphones back on the direct
    /// table); nil from a helper that does not say.
    public var configures: UInt64?

    public init(routes: [UInt8: UInt8] = [:], digital: [UInt16: UInt8] = [:], configures: UInt64? = nil) {
        self.routes = routes
        self.digital = digital
        self.configures = configures
    }

    static func isAudibleDestination(_ destination: UInt8) -> Bool {
        (32...63).contains(destination) || (224...227).contains(destination)
    }

    private static func routePairs(_ request: USBControlRequest) -> [(UInt8, UInt8)]? {
        guard request.request == SymphonyIOCommand.audioRouting.rawValue,
              !request.data.isEmpty, request.data.count % 2 == 0 else { return nil }
        let bytes = Array(request.data)
        return stride(from: 0, to: bytes.count, by: 2).map { (bytes[$0], bytes[$0 + 1]) }
    }

    private static func digitalKey(_ request: USBControlRequest) -> UInt16? {
        guard (0x34...0x36).contains(request.request), request.value == 0, request.index <= 1,
              request.data.count == 1 else { return nil }
        return UInt16(request.request) << 8 | request.index
    }

    /// Whether the unit already holds everything `request` writes, and it is
    /// one of the writes that may be skipped.
    public func holds(_ request: USBControlRequest) -> Bool {
        if let pairs = Self.routePairs(request) {
            return pairs.allSatisfy { Self.isAudibleDestination($0.0) && routes[$0.0] == $0.1 }
        }
        if let key = Self.digitalKey(request) { return digital[key] == request.data.first }
        return false
    }

    /// `request` was sent: what the unit holds now (unknown where it failed).
    public mutating func note(_ request: USBControlRequest, ok: Bool) {
        if let pairs = Self.routePairs(request) {
            for (destination, source) in pairs { routes[destination] = ok ? source : nil }
        } else if let key = Self.digitalKey(request) {
            digital[key] = ok ? request.data.first : nil
        }
    }
}

public extension XPCTransport {
    /// Transports that predate per-channel software peaks report nothing; the
    /// app then keeps its SW Return L/R path and shows no software output meters.
    func getSoftwareOutputPeaks() async -> [Float]? { nil }

    /// Test transports stand for the helper this app ships.
    func helperVersion() async -> UInt64? { XPCDeviceConnection.audioOutputHelperVersion }

    /// Transports that do not model the helper's volume output say nothing
    /// and accept nothing.
    func helperMonitorOutput() async -> UInt64? { nil }
    func setMonitorOutput(_ output: UInt64, attenuation: UInt64, muted: Bool) async -> Bool { false }

    /// Transports that do not model the helper's record know nothing: every
    /// write is sent.
    func writeShadow() async -> USBWriteShadow? { nil }

    func setSwReturnChannelLevel(channel: Int, dB: Double) {
        // Older test transports and proxies use the linked command.  The real
        // transport overrides this with the side-specific XPC message.
        setSwReturnLevel(dB)
    }
}

// MARK: - Mach XPC Transport (real implementation)

extension XPCTransport {
    public var helperEpoch: UInt64 { 0 }
}

/// XPC transport connecting to the MaestroVolumeProxy LaunchDaemon.
public final class MachXPCTransport: XPCTransport, @unchecked Sendable {
    private let connection: xpc_connection_t
    private let queue: DispatchQueue
    public let hardwareWriteGate: HardwareWriteGate
    private var _connected = true
    private let lock = NSLock()

    public init(serviceName: String = "com.danielraffel.Maestro.volumeproxy",
                hardwareWriteGate: HardwareWriteGate = HardwareWriteGate()) {
        self.hardwareWriteGate = hardwareWriteGate
        self.queue = DispatchQueue(label: "com.danielraffel.Maestro.xpc-transport")
        // Tests never reach the real USB helper (and through it the unit).
        self.connection = xpc_connection_create_mach_service(
            TestEnvironment.isRunningTests ? serviceName + ".unavailable-in-tests" : serviceName, queue, 0)

        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            // Interrupted or invalid: the helper went away. The one that
            // answers next configures the unit again (direct routes).
            self?.bumpHelperEpoch()
            // S5: Only CONNECTION_INVALID is terminal (service gone / cancelled).
            // CONNECTION_INTERRUPTED (e.g. proxy restart) is recoverable — the next
            // successful reply resets _connected, so never latch disconnected on it.
            if xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) {
                self?.setConnected(false)
            }
        }
        xpc_connection_resume(connection)
    }

    private func setConnected(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _connected = value
    }

    private var _helperEpoch: UInt64 = 0
    private func bumpHelperEpoch() { lock.withLock { _helperEpoch &+= 1 } }
    public var helperEpoch: UInt64 { lock.withLock { _helperEpoch } }

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _connected
    }

    public func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        try hardwareWriteGate.check()
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setProperty")
        xpc_dictionary_set_uint64(msg, "bRequest", UInt64(bRequest))
        xpc_dictionary_set_uint64(msg, "wValue", UInt64(wValue))
        xpc_dictionary_set_uint64(msg, "wIndex", UInt64(wIndex))
        data.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                xpc_dictionary_set_data(msg, "data", base, ptr.count)
            }
        }
        // S5: observe the reply so a failed USB write surfaces as a thrown error
        // instead of a false success.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            xpc_connection_send_message_with_reply(connection, msg, queue) { [weak self] reply in
                if xpc_get_type(reply) == XPC_TYPE_ERROR {
                    continuation.resume(throwing: DeviceConnectionError.transportError("XPC reply error"))
                    return
                }
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    continuation.resume(throwing: DeviceConnectionError.transportError("XPC reply not a dictionary"))
                    return
                }
                // A successful reply proves the connection is alive again.
                self?.setConnected(true)
                let status = xpc_dictionary_get_int64(reply, "status")
                if status != 0 {
                    continuation.resume(throwing: DeviceConnectionError.transportError("USB write failed: status \(status)"))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    public func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "getProperty")
        xpc_dictionary_set_uint64(msg, "bRequest", UInt64(bRequest))
        xpc_dictionary_set_uint64(msg, "wValue", UInt64(wValue))
        xpc_dictionary_set_uint64(msg, "wIndex", UInt64(wIndex))
        xpc_dictionary_set_uint64(msg, "dataLength", UInt64(dataLength))

        return try await withCheckedThrowingContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, msg, queue) { [weak self] reply in
                if xpc_get_type(reply) == XPC_TYPE_ERROR {
                    continuation.resume(throwing: DeviceConnectionError.transportError(
                        "XPC reply error"))
                    return
                }
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    continuation.resume(throwing: DeviceConnectionError.transportError(
                        "XPC reply not a dictionary"))
                    return
                }
                // S5: a successful reply proves the connection is alive again.
                self?.setConnected(true)

                let status = xpc_dictionary_get_int64(reply, "status")
                var responseData = Data()
                var dataLen: Int = 0
                if let dataPtr = xpc_dictionary_get_data(reply, "data", &dataLen), dataLen > 0 {
                    responseData = Data(bytes: dataPtr, count: dataLen)
                }
                continuation.resume(returning: XPCPropertyReply(
                    status: status, data: responseData))
            }
        }
    }

    public func getSoftwareOutputPeaks() async -> [Float]? {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "getSoftwareMeterLevels")

        return await withCheckedContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    continuation.resume(returning: nil)
                    return
                }
                var dataLen: Int = 0
                // Proxy >= this change: "levels16" = MAESTRO_SHM_CHANNELS floats.
                if let dataPtr = xpc_dictionary_get_data(reply, "levels16", &dataLen),
                   dataLen >= MemoryLayout<Float>.size * 2,
                   dataLen % MemoryLayout<Float>.size == 0 {
                    let n = dataLen / MemoryLayout<Float>.size
                    let peaks = dataPtr.bindMemory(to: Float.self, capacity: n)
                    continuation.resume(returning: Array(UnsafeBufferPointer(start: peaks, count: n)))
                    return
                }
                // Older proxy: only the SW Return L/R pair.
                guard let dataPtr = xpc_dictionary_get_data(reply, "levels", &dataLen),
                      dataLen == MemoryLayout<Float>.size * 2 else {
                    continuation.resume(returning: nil)
                    return
                }
                let peaks = dataPtr.bindMemory(to: Float.self, capacity: 2)
                continuation.resume(returning: [peaks[0], peaks[1]])
            }
        }
    }

    /// An older helper has no "helperVersion" command and sends no reply; the
    /// question is given two seconds.
    public func helperVersion() async -> UInt64? {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "helperVersion")
        let once = ResumeOnce<UInt64?>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { once.resume(nil); return }
                let version = xpc_dictionary_get_uint64(reply, "helperVersion")
                once.resume(version == 0 ? nil : version)
            }
            queue.asyncAfter(deadline: .now() + 2) { once.resume(nil) }
        }
    }

    public func writeShadow() async -> USBWriteShadow? {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "getWriteShadow")
        let once = ResumeOnce<USBWriteShadow?>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
                      xpc_dictionary_get_int64(reply, "status") == 0 else { once.resume(nil); return }
                func bytes(_ key: String, _ count: Int) -> [UInt8]? {
                    var length = 0
                    guard let pointer = xpc_dictionary_get_data(reply, key, &length), length == count else { return nil }
                    return Array(UnsafeRawBufferPointer(start: pointer, count: length))
                }
                guard let routes = bytes("routes", 256), let routesKnown = bytes("routesKnown", 256),
                      let digital = bytes("digital", 6), let digitalKnown = bytes("digitalKnown", 6) else {
                    once.resume(nil); return
                }
                var shadow = USBWriteShadow()
                for destination in 0..<256 where routesKnown[destination] != 0 {
                    shadow.routes[UInt8(destination)] = routes[destination]
                }
                for slot in 0..<6 where digitalKnown[slot] != 0 {
                    shadow.digital[UInt16(0x34 + slot / 2) << 8 | UInt16(slot % 2)] = digital[slot]
                }
                if xpc_dictionary_get_value(reply, "configures") != nil {
                    shadow.configures = xpc_dictionary_get_uint64(reply, "configures")
                }
                once.resume(shadow)
            }
            // A helper from before the question does not answer it.
            queue.asyncAfter(deadline: .now() + 0.5) { once.resume(nil) }
        }
    }

    public func helperMonitorOutput() async -> UInt64? {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "helperVersion")
        let once = ResumeOnce<UInt64?>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { once.resume(nil); return }
                let output = xpc_dictionary_get_uint64(reply, "monitorOutput")
                once.resume(output == 0 ? nil : output)
            }
            queue.asyncAfter(deadline: .now() + 2) { once.resume(nil) }
        }
    }

    /// A helper from before version 3 does not know the command and sends no
    /// reply; the question is given two seconds.
    public func setMonitorOutput(_ output: UInt64, attenuation: UInt64, muted: Bool) async -> Bool {
        guard hardwareWriteGate.allowsWrites else { return false }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setMonitorOutput")
        xpc_dictionary_set_uint64(msg, "output", output)
        xpc_dictionary_set_uint64(msg, "attenuation", attenuation)
        xpc_dictionary_set_bool(msg, "muted", muted)
        let once = ResumeOnce<Bool>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
                      xpc_dictionary_get_value(reply, "status") != nil else { once.resume(false); return }
                once.resume(xpc_dictionary_get_int64(reply, "status") == 0)
            }
            queue.asyncAfter(deadline: .now() + 2) { once.resume(false) }
        }
    }

    public func getSoftwareMeterLevels() async -> (Float, Float)? {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "getSoftwareMeterLevels")

        return await withCheckedContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    continuation.resume(returning: nil)
                    return
                }
                var dataLen: Int = 0
                guard let dataPtr = xpc_dictionary_get_data(reply, "levels", &dataLen),
                      dataLen == MemoryLayout<Float>.size * 2 else {
                    continuation.resume(returning: nil)
                    return
                }
                let peaks = dataPtr.bindMemory(to: Float.self, capacity: 2)
                continuation.resume(returning: (peaks[0], peaks[1]))
            }
        }
    }

    public func setSwReturnMute(_ muted: Bool) {
        guard hardwareWriteGate.allowsWrites else { return }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setSwReturnMute")
        xpc_dictionary_set_int64(msg, "muted", muted ? 1 : 0)
        // Reply-based — fire-and-forget silently dropped on macOS 26.
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] setSwReturnMute XPC ERROR: \(reply)")
            }
        }
    }

    public func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {
        guard hardwareWriteGate.allowsWrites else { return }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setMixerParam")
        xpc_dictionary_set_uint64(msg, "usbCmd", UInt64(usbCmd))
        xpc_dictionary_set_uint64(msg, "mixer", UInt64(mixer))
        xpc_dictionary_set_uint64(msg, "channel", UInt64(channel))
        xpc_dictionary_set_uint64(msg, "value", UInt64(value))
        // Use reply-based send — fire-and-forget messages from user processes
        // to LaunchDaemons are silently dropped on macOS 26.
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] sendMixerParam XPC ERROR: \(reply)")
            } else {
                print("[Maestro] sendMixerParam reply OK")
            }
        }
    }

    public func setSwReturnLevel(_ dB: Double) {
        guard hardwareWriteGate.allowsWrites else { return }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setSwReturnLevel")
        xpc_dictionary_set_double(msg, "dB", dB)
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] setSwReturnLevel XPC ERROR: \(reply)")
            }
        }
    }

    public func setSwReturnChannelLevel(channel: Int, dB: Double) {
        guard hardwareWriteGate.allowsWrites else { return }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setSwReturnChannelLevel")
        xpc_dictionary_set_int64(msg, "channel", Int64(channel == 0 ? 0 : 1))
        xpc_dictionary_set_double(msg, "dB", dB)
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] setSwReturnChannelLevel XPC ERROR: \(reply)")
            }
        }
    }

    public func setSwReturnProcessing(_ enabled: Bool) {
        guard hardwareWriteGate.allowsWrites else { return }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setSwReturnProcessing")
        xpc_dictionary_set_int64(msg, "enabled", enabled ? 1 : 0)
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] setSwReturnProcessing XPC ERROR: \(reply)")
            }
        }
    }

    public func resetAudioOutput() {
        guard hardwareWriteGate.allowsWrites else { return }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "resetAudioOutput")
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] resetAudioOutput XPC ERROR: \(reply)")
            }
        }
    }

}

/// Resumes a continuation with the first answer only.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    func set(_ continuation: CheckedContinuation<T, Never>) { lock.withLock { self.continuation = continuation } }
    func resume(_ value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

// MARK: - XPC Device Connection

/// DeviceConnection implementation that routes through XPC to MaestroVolumeProxy.
///
/// Property selectors are mapped to raw USB fields by SymphonyIOPropertyMapper,
/// then sent as generic setProperty/getProperty XPC commands to the proxy.
public final class XPCDeviceConnection: DeviceConnection, @unchecked Sendable {
    private let writeGate = HardwareWriteGate()
    public var hardwareWriteGate: HardwareWriteGate? { writeGate }

    public let identifier: USBDeviceIdentifier

    private let transport: XPCTransport
    private let listenerStorage = XPCListenerStorage()

    /// Cached write-only properties.
    private let lock = NSLock()
    private var cachedSampleRate: Double = 48000
    private var cachedClockSource: UInt32 = 0
    private var cachedFrontPanelMeterBank: UInt32 = 0
    private var cachedMetersShowInput: [UInt32: UInt32] = [1: 0, 2: 0]
    private var cachedPeakHoldMode: UInt32 = 0
    private var cachedOversHoldMode: UInt32 = 0
    private var cachedPrefix: String = "A"

    /// Settings that are saved on the Mac and written back to the unit on
    /// connect: the same list as ThunderBridge, see
    /// ``DeviceSettingsStore/ownedSettings`` for what is in it and why. Most of
    /// them can also be read on USB, and reads still come from the hardware;
    /// storing them is what lets a power-cycled unit be put back.
    static let storedSelectors = Set(DeviceSettingsStore.ownedSettings)

    /// Whether stored settings are written to the unit on connect over USB.
    ///
    /// On. It was switched off for a day during hardware testing (2026-11-13)
    /// while intermittent clicking after power cycles was chased: the replayed
    /// writes were the only new traffic and were suspected. The clicking turned
    /// out to track what reached the unit WHILE IT WAS STARTING UP -- the
    /// helper reconfiguring it before macOS had published its audio device, and
    /// this app's reconnect burst a second later. With the helper standing down
    /// during start-up and the app waiting `AppState.usbSettleInterval` after
    /// the unit appears, three of three power cycles were clean and the
    /// 8.6-second clock disturbance that had accompanied every one was gone.
    ///
    /// The replay now runs only after that wait, before meter polling starts,
    /// and with a pause between writes. `MAESTRO_USB_REPLAY_SETTINGS=0` turns it
    /// off; any other value leaves it on, so a typo cannot disable it silently.
    public static let replaysOnConnect: Bool =
        ProcessInfo.processInfo.environment["MAESTRO_USB_REPLAY_SETTINGS"] != "0"

    /// Pause between replayed writes. The unit's controller serves this control
    /// endpoint and the audio stream; there is no reason to send it a burst.
    static let replaySpacing: Duration = .milliseconds(25)

    /// In-memory unless the app hands in a persistent one.
    public let settingsStore: DeviceSettingsStore

    /// See `XPCTransport.helperEpoch`.
    public var helperEpoch: UInt64 { transport.helperEpoch }

    /// The helper version this app is built for. From 2 on, every configure of
    /// the unit leaves both I/O boards and both headphones on direct sources
    /// and the helper mutes no mixer strip. An older helper puts Line 1/2 on
    /// Mixer 1 each time it configures the unit, with that mixer's inputs
    /// muted to hide them, so Maestro must not unmute them under it.
    /// This is the requirement for mixers and routing only; Volume Keys ›
    /// Audio Output needs `audioOutputHelperVersion`.
    public static let requiredHelperVersion: UInt64 = 2

    /// The first helper with "setMonitorOutput" (Volume Keys › Audio
    /// Output). An older one always moves the speakers with the keys; it is
    /// still safe for mixers and routing from `requiredHelperVersion` on.
    public static let audioOutputHelperVersion: UInt64 = 3

    /// The status the helper's "getProperty" replies with when it has no
    /// unit open (`MaestroVolumeProxy.c`, `HELPER_STATUS_UNIT_NOT_OPEN`).
    public static let helperStatusUnitNotOpen: Int64 = -2

    /// The helper's version, nil when it did not say.
    public func helperVersionNumber() async -> UInt64? { await transport.helperVersion() }

    /// The level and mute an output had when it became the keys' output.
    public struct KeyboardVolumeState: Sendable, Equatable {
        public let attenuation: UInt32
        public let muted: Bool
        public init(attenuation: UInt32, muted: Bool) {
            self.attenuation = attenuation
            self.muted = muted
        }
    }

    /// The output the helper's volume and mute move now, nil when unknown.
    public func keyboardVolumeOutputInHelper() async -> KeyboardVolumeOutput? {
        guard let value = await transport.helperMonitorOutput() else { return nil }
        return [KeyboardVolumeOutput.speakers, .headphone1, .headphone2].first { $0.helperValue == value }
    }

    /// The level and mute of an output, read from the unit; nil when either
    /// read failed or the output is not one of the unit's.
    public func keyboardVolumeState(of output: KeyboardVolumeOutput) async -> KeyboardVolumeState? {
        guard let level = output.levelSelector, let mute = output.muteSelector,
              let reading = try? await getProperty(PropertyAddress(selector: level)),
              let muted = (try? await getProperty(PropertyAddress(selector: mute)))?.asBool else { return nil }
        // Levels are read as dB (0 to -64) over USB; an attenuation is taken too.
        let attenuation: Double
        if case .float64(let dB) = reading { attenuation = -dB }
        else if let value = reading.asUInt32 { attenuation = Double(value) }
        else { return nil }
        return KeyboardVolumeState(attenuation: UInt32(max(0, min(64, attenuation.rounded()))), muted: muted)
    }

    /// Make `output` the one the volume and mute of "Maestro USB" move. The
    /// helper is given the output's own level and mute, read from the unit
    /// first, so that what it keeps (and puts back after a reconnect) belongs
    /// to that output and not to the one chosen before. Nothing is sent when
    /// they cannot be read. Returns what was read, nil when nothing changed.
    /// `known` stands in for the read where the unit cannot be asked (the
    /// speakers in Line answer 0).
    public func setKeyboardVolumeOutput(_ output: KeyboardVolumeOutput,
                                        known: KeyboardVolumeState? = nil) async -> KeyboardVolumeState? {
        var state = known
        if state == nil { state = await keyboardVolumeState(of: output) }
        guard let value = output.helperValue, let state,
              await transport.setMonitorOutput(value, attenuation: UInt64(state.attenuation), muted: state.muted)
        else { return nil }
        return state
    }

    public enum HelperStatus: Sendable, Equatable {
        /// The helper this app ships, or a newer one.
        case current
        /// An older helper: it answers, but not with a version this app
        /// accepts (or not the version question at all).
        case outdated
        /// No helper answered anything; nothing is concluded.
        case unknown
    }

    /// Asks the helper which one it is. A helper that does not know the
    /// question but answers the meter read it has always had is an old one.
    public func helperStatus() async -> HelperStatus {
        if let version = await transport.helperVersion() {
            return version >= Self.requiredHelperVersion ? .current : .outdated
        }
        return await transport.getSoftwareMeterLevels() != nil ? .outdated : .unknown
    }

    public init(identifier: USBDeviceIdentifier, transport: XPCTransport? = nil,
                settingsStore: DeviceSettingsStore = DeviceSettingsStore()) {
        self.identifier = identifier
        self.transport = transport ?? MachXPCTransport(hardwareWriteGate: writeGate)
        self.settingsStore = settingsStore
        // Start from what was saved, so a relaunch shows the user's settings
        // instead of the cache's built-in defaults.
        if let v = settingsStore.value(for: PropertyAddress(selector: .peakHoldMode))?.asUInt32 {
            cachedPeakHoldMode = v
        }
        if let v = settingsStore.value(for: PropertyAddress(selector: .oversHoldMode))?.asUInt32 {
            cachedOversHoldMode = v
        }
        if let v = settingsStore.value(for: PropertyAddress(selector: .prefix))?.asString, !v.isEmpty {
            cachedPrefix = v
        }
    }

    /// Read the original Symphony 0xC0 hardware UID through the existing USB
    /// proxy path, with the same bounded zero-retry rule.
    public func readHardwareUniqueID() async -> UInt64? {
        await SymphonyIdentityReader.read(attempts: SymphonyIdentityReader.maximumAttempts,
                                          delay: SymphonyIdentityReader.retryDelay) {
            let reply = try await self.transport.sendGetProperty(
                bRequest: SymphonyIdentityReader.command, wValue: 0, wIndex: 0,
                dataLength: UInt16(SymphonyIdentityReader.responseLength))
            guard reply.status == 0 else { throw DeviceConnectionError.transportError("USB identity status \(reply.status)") }
            return reply.data
        }
    }

    // MARK: - Cache Accessors

    private func getCachedSampleRate() -> Double {
        lock.lock(); defer { lock.unlock() }
        return cachedSampleRate
    }

    private func setCachedSampleRate(_ rate: Double) {
        lock.lock(); cachedSampleRate = rate; lock.unlock()
    }

    private func getCachedClockSource() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return cachedClockSource
    }

    private func setCachedClockSource(_ source: UInt32) {
        lock.lock(); cachedClockSource = source; lock.unlock()
    }

    /// Display settings from the existing read/write cache, with no USB request.
    public func cachedMeterHoldModes() -> (peak: UInt32, over: UInt32) {
        lock.lock(); defer { lock.unlock() }
        return (cachedPeakHoldMode, cachedOversHoldMode)
    }

    /// Return cached value for a write-only property.
    private func getCachedWriteOnly(_ address: PropertyAddress) -> PropertyValue {
        lock.lock(); defer { lock.unlock() }
        switch address.selector {
        case .sampleRate:       return .float64(cachedSampleRate)
        case .clockSource:      return .uint32(cachedClockSource)
        case .frontPanelMeterBank: return .uint32(cachedFrontPanelMeterBank)
        case .metersShowInput:  return .uint32(cachedMetersShowInput[address.element] ?? 0)
        case .peakHoldMode:     return .uint32(cachedPeakHoldMode)
        case .oversHoldMode:    return .uint32(cachedOversHoldMode)
        case .prefix:           return .string(cachedPrefix)
        default:                return .uint32(0)
        }
    }

    /// Update cached value for a write-only property.
    private func updateCacheForWriteOnly(_ address: PropertyAddress, value: PropertyValue) {
        lock.lock(); defer { lock.unlock() }
        switch address.selector {
        case .sampleRate:
            if let hz = value.asFloat64 { cachedSampleRate = hz }
        case .clockSource:
            if let src = value.asUInt32 { cachedClockSource = src }
        case .frontPanelMeterBank:
            if let bank = value.asUInt32 { cachedFrontPanelMeterBank = bank }
        case .metersShowInput:
            if let src = value.asUInt32 { cachedMetersShowInput[address.element] = src }
        case .peakHoldMode:
            if let mode = value.asUInt32 { cachedPeakHoldMode = mode }
        case .oversHoldMode:
            if let mode = value.asUInt32 { cachedOversHoldMode = mode }
        case .prefix:
            if let pfx = value.asString { cachedPrefix = pfx }
        default:
            break
        }
    }

    // MARK: - DeviceConnection Protocol

    public var isConnected: Bool {
        transport.isConnected
    }

    /// Query software return meter peaks from the proxy's render callback.
    /// Returns (peakL, peakR) in dBFS, or nil if unavailable.
    public func getSoftwareMeterLevels() async -> (Double, Double)? {
        guard let peaks = await transport.getSoftwareMeterLevels() else { return nil }
        let dBL = peaks.0 > 0.00001 ? 20.0 * log10(Double(peaks.0)) : -60.0
        let dBR = peaks.1 > 0.00001 ? 20.0 * log10(Double(peaks.1)) : -60.0
        return (max(dBL, -60.0), max(dBR, -60.0))
    }

    /// Per-USB-channel playback peaks (linear 0..1) from the proxy render
    /// callback. See `XPCTransport.getSoftwareOutputPeaks()`.
    public func getSoftwareOutputPeaks() async -> [Float]? {
        await transport.getSoftwareOutputPeaks()
    }

    public func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        guard transport.isConnected else {
            throw DeviceConnectionError.notConnected
        }

        // Write-only properties: return cached values.
        // These have no USB read opcode — the XMOS firmware only accepts writes.
        if SymphonyIOPropertyMapper.writeOnlySelectors.contains(address.selector) {
            // Peak hold and over hold can be read from the unit, which is the
            // truth after a power cycle or a change made elsewhere. The saved
            // value is only the answer when the unit does not give one.
            if Self.readFromUnitWhenPossible.contains(address.selector),
               let live = try? await readFromUnit(address) {
                updateCacheForWriteOnly(address, value: live)
                return live
            }
            return getCachedWriteOnly(address)
        }

        return try await readFromUnit(address)
    }

    /// One read of the unit's front panel state (vendor read `0x28`). Nil when
    /// the unit does not answer or the reply is not a real reading.
    public func readParameterUpdates() async -> SymphonyIOParameterUpdates? {
        guard transport.isConnected else { return nil }
        let request = SymphonyIOParameterUpdates.readRequest
        guard let reply = try? await transport.sendGetProperty(
                bRequest: request.request, wValue: request.value, wIndex: request.index,
                dataLength: UInt16(request.data.count)),
              reply.status == 0 else { return nil }
        return SymphonyIOParameterUpdates(data: reply.data)
    }

    /// Take the clock source the unit reports when this session has not set one.
    ///
    /// USB has no dedicated read for the clock source, so it was remembered only
    /// until Maestro quit and showed "Internal" after every relaunch. The front
    /// panel report carries it. A source chosen in this session is not
    /// overridden: Apogee's daemon noted that the firmware does not report it
    /// reliably in the USB interface mode (`SymphonyIO.cpp:6462-6466`).
    public func seedClockSource(reported: UInt8) {
        guard (1...5).contains(reported) else { return }
        lock.lock(); defer { lock.unlock() }
        if cachedClockSource == 0 { cachedClockSource = UInt32(reported) }
    }

    /// A slot's board hardware major version: `SymphonyIOVersion` (0xA0) with
    /// type 5 (slot 1) or 6 (slot 2), 3 bytes back (major, minor, build), the
    /// way the original read it (`SymphonyIOControl.cpp:1120-1142`). The type is
    /// nValue, which the USB transport puts in wIndex. Nil when unanswered.
    public func readBoardHardwareMajor(slot: Int) async -> UInt8? {
        guard transport.isConnected, slot == 0 || slot == 1,
              let reply = try? await transport.sendGetProperty(
                bRequest: 0xA0, wValue: 0, wIndex: UInt16(5 + slot), dataLength: 3),
              reply.status == 0, reply.data.count >= 3 else { return nil }
        return reply.data[0]
    }

    static let readFromUnitWhenPossible: Set<AudioPropertySelector> = [.peakHoldMode, .oversHoldMode]

    private func readFromUnit(_ address: PropertyAddress) async throws -> PropertyValue {

        // The mapper is shared with ThunderBridge, so USB's own strip numbers
        // (Software Return 32, Master 33) are applied here, not there.
        let usbRequest = try SymphonyIOPropertyMapper.buildReadRequest(
            for: try USBMixerAddressing.usbAddress(for: address))

        let reply = try await transport.sendGetProperty(
            bRequest: usbRequest.request,
            wValue: usbRequest.value,
            wIndex: usbRequest.index,
            dataLength: UInt16(usbRequest.data.count))

        // -2: the helper has no unit open (helper 0.9.26 on; an older one
        // says -1 for that too). The app's recovery tells it from a read
        // that failed once (`USBLossDetector`).
        if reply.status == Self.helperStatusUnitNotOpen { throw DeviceConnectionError.notConnected }
        guard reply.status == 0 else {
            throw DeviceConnectionError.transportError(
                "XPC getProperty failed (status=\(reply.status))")
        }

        let response = USBControlResponse(data: reply.data, bytesTransferred: reply.data.count)
        return try SymphonyIOPropertyMapper.decodeResponse(
            response, for: address,
            cachedSampleRate: getCachedSampleRate(),
            cachedClockSource: getCachedClockSource())
    }

    private let sequenceOwner = AsyncSequenceOwner()

    /// While the connect restore runs: what the unit holds
    /// (``USBWriteShadow``), and how many writes it already held.
    private var elisionShadow: USBWriteShadow?
    private var elidedCount = 0
    /// While the restore runs: read the unit before a write that can be read
    /// back (``readCompareRequest(for:)``) and skip it when the unit has the
    /// value. Off after `readCompareFailureLimit` reads in a row fail.
    private var readCompareActive = false
    private var readCompareFailures = 0
    private var readComparedCount = 0
    static let readCompareFailureLimit = 3
    /// The helper's configure count when the restore began
    /// (``USBWriteShadow/configures``).
    private var elisionConfigures: UInt64?

    /// Start skipping writes the unit already holds, for the restore: routes
    /// of outputs and headphones and the digital format settings the helper
    /// says it holds, and, with `compareReads`, every write whose value the
    /// unit can be asked for first (``readCompareRequest(for:)``). Returns
    /// whether the helper said what it holds.
    @discardableResult
    public func beginRestoreElision(compareReads: Bool = false) async -> Bool {
        let shadow = await transport.writeShadow()
        lock.withLock {
            elisionShadow = shadow
            elidedCount = 0
            readCompareActive = compareReads
            readCompareFailures = 0
            readComparedCount = 0
            elisionConfigures = shadow?.configures
        }
        return shadow != nil
    }

    /// Stop skipping. Returns how many writes were skipped.
    @discardableResult
    public func endRestoreElision() -> Int {
        lock.withLock {
            elisionShadow = nil
            readCompareActive = false
            return elidedCount
        }
    }

    /// Writes skipped since `beginRestoreElision`.
    public var restoreElidedWrites: Int { lock.withLock { elidedCount } }
    /// Of those, the ones skipped because a read showed the unit had it.
    public var restoreReadComparedSkips: Int { lock.withLock { readComparedCount } }
    /// The helper's configure count when the last restore began.
    public var restoreHelperConfigures: UInt64? { lock.withLock { elisionConfigures } }

    /// How many times the helper has configured a unit (nil: it does not
    /// say, or has no unit open). Asks the helper, not the unit.
    public func helperConfigureCount() async -> UInt64? {
        await transport.writeShadow()?.configures
    }

    /// Whether `request` is skipped because the unit already holds it.
    private func elides(_ request: USBControlRequest) -> Bool {
        lock.withLock {
            guard let shadow = elisionShadow, shadow.holds(request) else { return false }
            elidedCount += 1
            return true
        }
    }

    /// How to ask the unit whether it holds what `request` writes: the reads
    /// and the replies that mean it does. Nil for a write that cannot be read
    /// back over USB. The firmware answers each of these reads with the
    /// value its write sets (SymphonyIOCore3MainController.cpp: 0x20 :1475,
    /// 0x21 :1508, 0x22 :1536, 0xE9 :1593, 0xE7/0xE8 :1616, 0x25 :1676,
    /// 0xB0-0xB3 :2379-2495; 0x31 the routing table, one read per
    /// destination; 0x10-0x12 through the 0xDE preference block,
    /// `SymphonyIOPropertyMapper`, handled by the caller).
    ///
    /// 0x20 (analog reference level) is a question, not a read: "is type T
    /// current?", with T in bits 16-23 of nValue (wValue's low byte), and the
    /// reply is [isCurrent, the trim kept for T]. A trim of
    /// `doNotSetTrimValue` is not compared.
    public static func readCompareRequest(for request: USBControlRequest)
        -> (reads: [USBControlRequest], matches: @Sendable ([Data]) -> Bool)? {
        let data = request.data
        switch request.request {
        case 0x21, 0x22, 0x25, 0xE7, 0xE8, 0xE9, 0xB0, 0xB1, 0xB2, 0xB3:
            guard data.count == 1 else { return nil }
            let read = USBControlRequest(direction: .read, request: request.request,
                                         value: request.value, index: request.index, data: Data(count: 1))
            return ([read], { $0.count == 1 && $0[0].first == data.first })
        case 0x20:
            guard data.count == 2, request.value & 0x00FF == 0 else { return nil }
            let type = data[data.startIndex], trim = data[data.startIndex + 1]
            let read = USBControlRequest(direction: .read, request: 0x20,
                                         value: request.value | UInt16(type),
                                         index: request.index, data: Data(count: 2))
            return ([read], { replies in
                guard replies.count == 1, replies[0].count >= 2 else { return false }
                let reply = Array(replies[0])
                return reply[0] == 1 && (trim == SymphonyIOConstants.doNotSetTrimValue || reply[1] == trim)
            })
        case 0x31:
            // [destination, source] pairs: the source each destination plays now.
            let bytes = Array(data)
            guard !bytes.isEmpty, bytes.count % 2 == 0 else { return nil }
            let pairs = stride(from: 0, to: bytes.count, by: 2).map { (bytes[$0], bytes[$0 + 1]) }
            let reads = pairs.map { SymphonyIORequestBuilder.getAudioRoute(destination: UInt16($0.0)) }
            let sources = pairs.map(\.1)
            return (reads, { replies in
                replies.count == sources.count && zip(replies, sources).allSatisfy { $0.first == $1 }
            })
        default:
            return nil
        }
    }

    /// The restore's read before a write: true when the unit already holds
    /// what `request` (for `address`) writes, so it is not sent. A read that
    /// fails sends the write, as before; after a few in a row the restore
    /// stops asking.
    private func unitHolds(_ request: USBControlRequest, address: PropertyAddress) async -> Bool {
        guard lock.withLock({ readCompareActive }) else { return false }
        var held: Bool?
        if [0x10, 0x11, 0x12].contains(request.request) {
            // Front panel meter source, peak and over hold: read from the 0xDE
            // block and compared as the write they would make.
            if let value = try? await readFromUnit(address),
               let again = try? SymphonyIOPropertyMapper.buildWriteRequest(
                for: try USBMixerAddressing.usbAddress(for: address), value: value) {
                held = again.request == request.request && again.value == request.value
                    && again.index == request.index && again.data == request.data
            }
        } else if let compare = Self.readCompareRequest(for: request) {
            var replies: [Data] = []
            for read in compare.reads {
                guard let reply = try? await transport.sendGetProperty(
                    bRequest: read.request, wValue: read.value,
                    wIndex: read.index, dataLength: UInt16(read.data.count)),
                      reply.status == 0 else { break }
                replies.append(reply.data)
            }
            if replies.count == compare.reads.count { held = compare.matches(replies) }
        } else {
            return false
        }
        return lock.withLock {
            guard let held else {
                readCompareFailures += 1
                if readCompareFailures >= Self.readCompareFailureLimit { readCompareActive = false }
                return false
            }
            readCompareFailures = 0
            if held { elidedCount += 1; readComparedCount += 1 }
            return held
        }
    }

    /// The unit's reset request (0xDB, `SymphonyIOResetRequestType`):
    /// nil when it cannot be read.
    public func readResetRequest() async -> SymphonyIOResetRequest? {
        guard transport.isConnected,
              let reply = try? await transport.sendGetProperty(bRequest: SymphonyIOResetRequest.command,
                                                                wValue: 0, wIndex: 0, dataLength: 1),
              reply.status == 0, let byte = reply.data.first else { return nil }
        return SymphonyIOResetRequest(rawValue: byte)
    }

    /// Acknowledge a front-panel reset once the settings are on the unit:
    /// write None, as the original's clearResetRequest did
    /// (eecontrol/generic/Products/SymphonyIO/SymphonyIOControl.cpp,
    /// SymphonyIO.cpp:6427).
    @discardableResult
    public func clearResetRequest() async -> Bool {
        guard writeGate.allowsWrites, transport.isConnected else { return false }
        await sequenceOwner.acquire()
        var sent = true
        do {
            try await transport.sendSetProperty(bRequest: SymphonyIOResetRequest.command, wValue: 0, wIndex: 0,
                                                data: Data([SymphonyIOResetRequest.none.rawValue]))
        } catch {
            sent = false
        }
        await sequenceOwner.release()
        return sent
    }

    private func noteSent(_ request: USBControlRequest, ok: Bool) {
        lock.withLock { elisionShadow?.note(request, ok: ok) }
    }

    public func applyMicPreWrites(_ writes: [ThunderboltPreset.Write]) async throws {
        await sequenceOwner.acquire()
        var failure: (any Error)?
        var changes: [PropertyChange] = []
        do {
            for write in writes {
                guard case .property(let address, let value) = write else { continue }
                try await setOwnedProperty(address, value: value)
                changes.append(PropertyChange(address: address, value: value))
            }
        } catch { failure = error }
        if failure != nil {
            for write in MicPreSettingsReplay.phantomOffWrites(writes) {
                if case .property(let address, let value) = write {
                    do {
                        try await setOwnedProperty(address, value: value)
                        changes.append(PropertyChange(address: address, value: value))
                    } catch { failure = error }
                }
            }
        }
        var ready = false
        for attempt in 0..<10 {
            if attempt == 9 {
                for write in MicPreSettingsReplay.phantomOffWrites(writes) {
                    if case .property(let address, let value) = write {
                        do {
                            try await setOwnedProperty(address, value: value)
                            changes.append(PropertyChange(address: address, value: value))
                        } catch { failure = error }
                    }
                }
                if failure == nil { failure = DeviceConnectionError.transportError("Preference unlock timed out") }
            }
            do {
                try await transport.sendSetProperty(bRequest: 0xDD, wValue: 0, wIndex: 0, data: Data([0]))
                let reply = try await transport.sendGetProperty(bRequest: 0xDD, wValue: 0, wIndex: 0, dataLength: 1)
                ready = reply.status == 0 && reply.data == Data([0])
            } catch { if failure == nil { failure = error } }
            if ready { break }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        await sequenceOwner.release()
        for change in changes { await listenerStorage.notifyListeners(for: change.address, change: change) }
        if !ready { throw DeviceConnectionError.transportError("The unit did not confirm the preference unlock") }
        if let failure { throw failure }
    }

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        try await setProperty(address, value: value, helperMuted: nil)
    }

    /// A Software Return mute on one mixer: the unit's own mute for that
    /// mixer, then the helper's single software mute set to `helperMuted`,
    /// which the caller takes from ``USBHelperSoftwareReturn`` (it is on only
    /// while a mixer that takes USB 1-2 feeds an output), never from this
    /// mixer's mute alone. Both happen in one turn of the write sequence, so
    /// the two never disagree.
    ///
    /// A plain `setProperty` of a Software Return mute writes the unit only.
    /// It used to be copied to the helper as well, which muted "Maestro USB"
    /// on outputs that no mixer fed.
    ///
    /// Solo stays the unit's 0xB2 alone: the helper has no solo, and the
    /// unit's mixer is what silences the other strips.
    public func setSoftwareReturnMute(_ address: PropertyAddress, muted: Bool, helperMuted: Bool) async throws {
        try await setProperty(address, value: .bool(muted), helperMuted: helperMuted)
    }

    private func setProperty(_ address: PropertyAddress, value: PropertyValue,
                             helperMuted: Bool?) async throws {
        await sequenceOwner.acquire()
        do {
            try await setOwnedProperty(address, value: value)
            if let helperMuted { transport.setSwReturnMute(helperMuted) }
            await sequenceOwner.release()
        } catch {
            await sequenceOwner.release()
            throw error
        }
        await listenerStorage.notifyListeners(for: address, change: PropertyChange(address: address, value: value))
    }

    private func setOwnedProperty(_ address: PropertyAddress, value: PropertyValue) async throws {

        guard transport.isConnected else {
            throw DeviceConnectionError.notConnected
        }

        guard !SymphonyIOPropertyMapper.readOnlySelectors.contains(address.selector) else {
            throw DeviceConnectionError.readOnly(address.selector)
        }

        // Cache-only properties (prefix, front-panel meter config) surface as
        // DeviceConnectionError.cacheOnly from the mapper below.
        do {
            do {
                // USB strip numbers (Software Return 32, Master 33); see readFromUnit.
                let usbRequest = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: try USBMixerAddressing.usbAddress(for: address), value: value)
                // S5: await the reply — a failed USB write throws instead of
                // silently reporting success and updating caches.
                // During the restore, a write the unit already holds is not
                // sent (`beginRestoreElision`); it counts as written.
                if !elides(usbRequest), await !unitHolds(usbRequest, address: address) {
                    do {
                        try await transport.sendSetProperty(
                            bRequest: usbRequest.request,
                            wValue: usbRequest.value,
                            wIndex: usbRequest.index,
                            data: usbRequest.data)
                        noteSent(usbRequest, ok: true)
                    } catch {
                        noteSent(usbRequest, ok: false)
                        throw error
                    }
                }
            } catch DeviceConnectionError.cacheOnly {
                // No hardware opcode (or an unsafe one) — cache only, never send.
                //
                // Log it. The cache still updates below, so the UI shows the new
                // value either way; without this line a gated control looks
                // identical to one that reached the hardware, which is how the
                // front-panel dropdowns spent a session appearing to work.
                print("[Maestro] \(address.selector) is cache-only — "
                    + "cache updated, nothing sent to hardware")
            }

            // Update cache for write-only properties
            if SymphonyIOPropertyMapper.writeOnlySelectors.contains(address.selector) {
                updateCacheForWriteOnly(address, value: value)
            }
            // Reached only when the send did not throw.
            if Self.storedSelectors.contains(address.selector) {
                settingsStore.record(value, for: address)
            }
        }

        // Notification happens after releasing the sequence owner, so a
        // listener may write another property without waiting on itself.
    }

    /// Hold the helper's software level at 0 dB (the unit's mixer owns the
    /// fader) and give it the mute ``USBHelperSoftwareReturn`` allows. Send
    /// this only after the unit's own strips have taken their values. There is
    /// no `muted` default on purpose.
    public func setHelperNeutral(muted: Bool) {
        guard writeGate.allowsWrites else { return }
        transport.setSwReturnLevel(0)
        transport.setSwReturnMute(muted)
    }

    /// Put the helper's software stage in the state the one rule gives.
    public func applyHelperSoftwareReturn(_ state: USBHelperSoftwareReturn.State) {
        setHelperNeutral(muted: state.muted)
        setSwReturnProcessing(state.processing)
    }

    /// One write to the unit's mixer, tried again once after a short delay.
    /// Returns whether it landed.
    public func setUnitMixerWithRetry(
        _ address: PropertyAddress, value: PropertyValue,
        retryDelay: Duration = .milliseconds(150)
    ) async -> Bool {
        for attempt in 0..<2 {
            do {
                try await setProperty(address, value: value, helperMuted: nil)
                return true
            } catch {
                if attempt == 0 { try? await Task.sleep(for: retryDelay) }
            }
        }
        return false
    }

    /// Put the unit's Software Return source, Master and Software Return
    /// strips, for both mixers, and the helper's software stage back to what
    /// Maestro has saved.
    ///
    /// Runs when Maestro connects, reconnects, and recovers after the unit was
    /// power-cycled (its mixer then returns to 0 dB, unmuted). The unit's mixer
    /// owns Software Return level, mute and solo and the Master level. The unit
    /// is written first; only when every unit write has landed (each is tried
    /// twice) is the helper set, so a level or mute an older Maestro
    /// left in the helper is never dropped before the unit holds its value.
    /// Returns whether the restore completed.
    @discardableResult
    public func restoreReturnAndMaster(helperMixer: Int = 0, defaults: UserDefaults,
                                      routedToOutput: [Bool] = [false, false],
                                      retryDelay: Duration = .milliseconds(150)) async -> Bool {
        await restoreReturnAndMaster(helperMixer: helperMixer,
            preferences: MixerPreferences(legacyDefaults: defaults),
            routedToOutput: routedToOutput, retryDelay: retryDelay)
    }

    @discardableResult
    public func restoreReturnAndMaster(
        helperMixer: Int = 0, preferences: MixerPreferences,
        routedToOutput: [Bool] = [false, false],
        retryDelay: Duration = .milliseconds(150)
    ) async -> Bool {
        var state = USBMixerSavedState.load(preferences: preferences)
        var unitOK = true
        var helperSteps: [USBMixerRestorePlan.Step] = []
        // An edit saved while these writes were going out is written again, so
        // the unit ends on what is saved now, not on the snapshot taken first.
        for _ in 0..<Self.restoreEditPasses {
            unitOK = true
            helperSteps = []
            for step in USBMixerRestorePlan.steps(for: state, helperMixer: helperMixer,
                                                  routedToOutput: routedToOutput) {
                if case .hardware(let address, let value) = step {
                    if await !setUnitMixerWithRetry(address, value: value, retryDelay: retryDelay) {
                        unitOK = false
                    }
                } else {
                    helperSteps.append(step)
                }
            }
            let now = USBMixerSavedState.load(preferences: preferences)
            if !unitOK || now == state { break }
            state = now
        }
        guard unitOK else {
            print("[Maestro] USB mixer restore did not complete: a write to the unit failed twice; the helper was left as it was")
            return false
        }
        for step in helperSteps {
            switch step {
            case .helperNeutral(let muted): setHelperNeutral(muted: muted)
            case .helperProcessing(let on): setSwReturnProcessing(on)
            case .hardware: break
            }
        }
        return true
    }

    /// How often a restore writes a strip (or the Master and Software Return
    /// block) again because its saved value changed while it was being written.
    static let restoreEditPasses = 4

    /// Write both mixers' input strips, saved or default, to the unit
    /// (``USBMixerRestorePlan/stripSteps(saved:hardwareIndexes:)``), paced like
    /// the other connect-time replays. Stops when `isCurrent` turns false.
    /// Returns how many writes landed and how many the unit refused.
    @discardableResult
    public func restoreMixerStrips(
        saved: [[MixerChannelState]], hardwareIndexes: [Int],
        spacing: Duration = .milliseconds(25),
        isCurrent: @Sendable () async -> Bool = { true }
    ) async -> (applied: Int, failed: Int) {
        let result = await restoreMixerStrips(
            hardwareIndexes: hardwareIndexes, spacing: spacing,
            savedStrip: { mixer, strip in
                mixer < saved.count && strip < saved[mixer].count ? saved[mixer][strip] : nil
            }, isCurrent: isCurrent)
        return (result.applied, result.failed)
    }

    /// The same restore with each strip's saved value read at the moment the
    /// strip is written (`savedStrip`, nil for a strip nobody saved), and read
    /// again after its four writes: a mute or level the user changes while the
    /// restore runs is what ends up on the unit. A restore that took one
    /// snapshot up front wrote the old value over such an edit while the page
    /// and the store showed the new one.
    ///
    /// `mixersWritten[m]` is true only when every strip of mixer `m` took all
    /// its writes: the caller routes a mixer to an output only then.
    @discardableResult
    public func restoreMixerStrips(
        hardwareIndexes: [Int],
        spacing: Duration = .milliseconds(25),
        savedStrip: @Sendable (_ mixer: Int, _ strip: Int) async -> MixerChannelState?,
        isCurrent: @Sendable () async -> Bool = { true }
    ) async -> (applied: Int, failed: Int, mixersWritten: [Bool]) {
        var applied = 0, failed = 0
        var written = [true, true]
        mixers: for mixer in 0..<2 {
            for (strip, channel) in hardwareIndexes.enumerated() where (0...31).contains(channel) {
                var state = await savedStrip(mixer, strip) ?? USBMixerRestorePlan.defaultStrip
                for _ in 0..<Self.restoreEditPasses {
                    for step in USBMixerRestorePlan.stripSteps(mixer: mixer, channel: channel, state: state) {
                        guard case .hardware(let address, let value) = step else { continue }
                        guard await isCurrent() else {
                            for unfinished in mixer..<2 { written[unfinished] = false }
                            break mixers
                        }
                        if applied + failed > 0, spacing > .zero { try? await Task.sleep(for: spacing) }
                        do {
                            try await setProperty(address, value: value, helperMuted: nil)
                            applied += 1
                        } catch {
                            failed += 1
                            written[mixer] = false
                        }
                    }
                    let now = await savedStrip(mixer, strip) ?? USBMixerRestorePlan.defaultStrip
                    if now == state { break }
                    state = now
                }
            }
        }
        return (applied, failed, written)
    }

    /// The monitor (speaker) mode, written on every connect and after a
    /// recovery: the saved one, or Stereo when none is saved, as the original
    /// did (og_source/maestrolink/Software/SymphonyIO.cpp:4669
    /// `setSpeakerOutputMode(m_MainOutMode)`, whose default at :128 is
    /// `eSymphonyIOSpeakerOutputMode_Stereo`). In a mode other than a speaker
    /// mode Line 1/2 play at full level and the volume keys do nothing, so
    /// this is never left to the unit's own default. A default is sent
    /// without being stored: only what the user chose is saved.
    /// Returns the mode sent, nil if the unit refused it.
    @discardableResult
    public func applySpeakerOutputMode() async -> UInt32? {
        let address = PropertyAddress(selector: .speakerOutputMode)
        do {
            if let saved = settingsStore.value(for: address), let mode = saved.asUInt32 {
                try await setProperty(address, value: saved)
                return mode
            }
            let stereo = UInt32(SymphonyIOSpeakerMode.stereo.rawValue)
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: .uint32(stereo))
            guard transport.isConnected else { throw DeviceConnectionError.notConnected }
            await sequenceOwner.acquire()
            do {
                // During the restore a unit already in Stereo is not told so.
                if await !unitHolds(request, address: address) {
                    try await transport.sendSetProperty(bRequest: request.request, wValue: request.value,
                                                        wIndex: request.index, data: request.data)
                }
                await sequenceOwner.release()
            } catch {
                await sequenceOwner.release()
                throw error
            }
            return stereo
        } catch {
            print("[Maestro] Speaker mode was not applied: \(error)")
            return nil
        }
    }

    /// Write every stored setting to the hardware. Called once per connect, as
    /// the original daemon did, so a unit that was power-cycled is put back to
    /// what the app is showing. A setting the hardware refuses stays stored and
    /// is reported in `failed`.
    public func reapplyStoredSettings(force: Bool = false) async -> DeviceSettingsReplay {
        var replay = DeviceSettingsReplay()
        guard Self.replaysOnConnect || force else { return replay }
        for entry in settingsStore.entries() where Self.storedSelectors.contains(entry.address.selector) {
            if replay.applied > 0 || !replay.failed.isEmpty {
                try? await Task.sleep(for: Self.replaySpacing)
            }
            do {
                try await setProperty(entry.address, value: entry.value)
                replay.applied += 1
            } catch {
                replay.failed.append(entry.address.selector)
            }
        }
        return replay
    }

    public func hasProperty(_ address: PropertyAddress) async -> Bool {
        if SymphonyIOPropertyMapper.writeOnlySelectors.contains(address.selector) { return true }
        return (try? SymphonyIOPropertyMapper.buildReadRequest(for: address)) != nil
    }

    public func isPropertySettable(_ address: PropertyAddress) async -> Bool {
        !SymphonyIOPropertyMapper.readOnlySelectors.contains(address.selector)
    }

    public func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerStorage.addListener(listener, for: address)
    }

    public func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerStorage.removeListener(listener, for: address)
    }

    /// Mute/unmute the helper's software stage only (USB channels 1-2 of the
    /// "Maestro USB" device, while a mixer uses the default 1-2 pair). The
    /// Mixer page does not call this directly: a Software Return mute written
    /// with `setProperty` reaches the unit (0xB3) and this stage together.
    public func setSwReturnMute(_ muted: Bool) {
        guard writeGate.allowsWrites else { return }
        transport.setSwReturnMute(muted)
    }

    /// Send a mixer parameter directly via dedicated XPC command.
    /// Bypasses the generic setProperty path which has delivery issues.
    public func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {
        guard writeGate.allowsWrites else { return }
        // Never put the CoreAudio-level IDs (1000/2000, stereo sides) on the USB
        // wire: the unit numbers Software Return 32 and Master 33.
        var channel = channel
        if USBMixerStrip.neverOnUSBWire.contains(channel) {
            switch channel {
            case USBMixerStrip.softwareReturnLogicalID: channel = USBMixerStrip.softwareReturn
            case USBMixerStrip.masterLogicalID: channel = USBMixerStrip.master
            default: return
            }
            // Neither strip has a pan.
            if usbCmd == SymphonyIOCommand.mixerInputPan.rawValue { return }
        }
        transport.sendMixerParam(usbCmd: usbCmd, mixer: mixer, channel: channel, value: value)
    }

    /// Set SW Return fader level in dB (software gain in proxy render callback).
    public func setSwReturnLevel(_ dB: Double) {
        guard writeGate.allowsWrites else { return }
        transport.setSwReturnLevel(dB)
    }

    public func setSwReturnChannelLevel(channel: Int, dB: Double) {
        guard writeGate.allowsWrites else { return }
        transport.setSwReturnChannelLevel(channel: channel, dB: dB)
    }

    public func setSwReturnProcessing(_ enabled: Bool) {
        guard writeGate.allowsWrites else { return }
        transport.setSwReturnProcessing(enabled)
    }

    /// Ask the proxy to rebuild its output AudioUnit. See the protocol comment:
    /// this is the audio-path half of "Reconnect Hardware".
    public func resetAudioOutput() {
        guard writeGate.allowsWrites else { return }
        transport.resetAudioOutput()
    }

    public func disconnect() async {
        // XPC connections are lightweight — no explicit teardown needed.
    }
}

// MARK: - Listener Storage

/// Thread-safe listener storage for XPCDeviceConnection.
private final class XPCListenerStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [PropertyAddress: [WeakRef]] = [:]

    func addListener(_ listener: PropertyListener, for address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        var list = listeners[address] ?? []
        list.append(WeakRef(listener))
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

    private final class WeakRef: @unchecked Sendable {
        weak var value: PropertyListener?
        init(_ value: PropertyListener) { self.value = value }
    }
}
