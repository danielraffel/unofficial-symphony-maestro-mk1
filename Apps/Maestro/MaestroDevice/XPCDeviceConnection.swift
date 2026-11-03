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
    /// Send a setProperty message and await the proxy's reply. Throws if the XPC
    /// round-trip fails or the proxy reports a non-zero (USB write) status (S5).
    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws

    /// Send a getProperty message and wait for a reply.
    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply

    /// Query software return meter peaks from proxy render callback.
    /// Returns (peakL, peakR) in linear 0..1, or nil if not available.
    func getSoftwareMeterLevels() async -> (Float, Float)?

    /// Per-USB-playback-channel peaks measured in the proxy render callback,
    /// linear 0..1, index = USB channel (0/1 are post software gain/pan/mute).
    /// Reading resets the proxy's accumulators, so a caller must not also call
    /// `getSoftwareMeterLevels()` in the same cycle. Returns nil when the proxy
    /// is unreachable. An older proxy that only reports L/R yields a 2-element
    /// array.
    func getSoftwareOutputPeaks() async -> [Float]?

    /// Set software mute on the SW Return audio path.
    /// USB audio routes directly to DAC, bypassing the FPGA mixer — so
    /// hardware mixer mute has no effect. This zeros the render buffer instead.
    func setSwReturnMute(_ muted: Bool)

    /// Send a mixer parameter command directly (bypasses generic setProperty).
    /// usbCmd: 0xB0=fader, 0xB1=pan, 0xB2=solo, 0xB3=mute.
    /// nValue = (mixer << 16) | channel, data = 1 byte value.
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8)

    /// Set SW Return fader level in dB. USB audio bypasses the FPGA mixer,
    /// so hardware fader commands have no effect. This scales samples in
    /// the proxy's render callback. Range: -48 to +6 dB.
    func setSwReturnLevel(_ dB: Double)

    /// Set one side of the software return independently.
    func setSwReturnChannelLevel(channel: Int, dB: Double)

    /// Set SW Return pan position. USB audio bypasses the FPGA mixer,
    /// so hardware pan commands have no effect. Stereo balance preserves unity
    /// at center and attenuates the opposite side. Range: -1.0 (left) to +1.0 (right).
    func setSwReturnPan(_ pan: Double)

    /// Select whether software gain/pan/mute should process USB channels 1-2.
    /// Other source pairs use the FPGA mixer controls directly.
    func setSwReturnProcessing(_ enabled: Bool)

    /// Set FPGA routing mode: 0 = DAW (null passthrough), 1 = Direct Monitor (1:1 passthrough).
    func setRoutingMode(_ mode: Int)

    /// Ask the proxy to tear down and rebuild its output AudioUnit.
    ///
    /// This is the half "Reconnect Hardware" was missing. Reconnecting the app
    /// re-establishes the app-to-proxy link and clears stale meters, but the
    /// audio path is proxy-to-hardware -- so if the AudioUnit is bound to a
    /// device that has gone away (or to the wrong one), reconnecting the app
    /// cannot fix it. Rebuilding re-resolves the device, re-coerces the sample
    /// rate, recomputes the presentation delay and bumps the clock generation.
    func resetAudioOutput()

    /// Whether the transport is connected.
    var isConnected: Bool { get }
}

public extension XPCTransport {
    /// Transports that predate per-channel software peaks report nothing; the
    /// app then keeps its SW Return L/R path and shows no software output meters.
    func getSoftwareOutputPeaks() async -> [Float]? { nil }

    func setSwReturnChannelLevel(channel: Int, dB: Double) {
        // Older test transports and proxies use the linked command.  The real
        // transport overrides this with the side-specific XPC message.
        setSwReturnLevel(dB)
    }
}

// MARK: - Mach XPC Transport (real implementation)

/// XPC transport connecting to the MaestroVolumeProxy LaunchDaemon.
public final class MachXPCTransport: XPCTransport, @unchecked Sendable {
    private let connection: xpc_connection_t
    private let queue: DispatchQueue
    private var _connected = true
    private let lock = NSLock()

    public init(serviceName: String = "com.danielraffel.Maestro.volumeproxy") {
        self.queue = DispatchQueue(label: "com.danielraffel.Maestro.xpc-transport")
        self.connection = xpc_connection_create_mach_service(
            serviceName, queue, 0)

        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
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

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _connected
    }

    public func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
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

    public func setSwReturnPan(_ pan: Double) {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setSwReturnPan")
        xpc_dictionary_set_double(msg, "pan", pan)
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] setSwReturnPan XPC ERROR: \(reply)")
            }
        }
    }

    public func setSwReturnProcessing(_ enabled: Bool) {
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
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "resetAudioOutput")
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] resetAudioOutput XPC ERROR: \(reply)")
            }
        }
    }

    public func setRoutingMode(_ mode: Int) {
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "command", "setRoutingMode")
        xpc_dictionary_set_int64(msg, "mode", Int64(mode))
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            if xpc_get_type(reply) == XPC_TYPE_ERROR {
                print("[Maestro] setRoutingMode XPC ERROR: \(reply)")
            }
        }
    }
}

// MARK: - XPC Device Connection

/// DeviceConnection implementation that routes through XPC to MaestroVolumeProxy.
///
/// Property selectors are mapped to raw USB fields by SymphonyIOPropertyMapper,
/// then sent as generic setProperty/getProperty XPC commands to the proxy.
public final class XPCDeviceConnection: DeviceConnection, @unchecked Sendable {
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
    private var cachedKBVolPeripheralID: UInt32 = 0
    private var cachedKBVolOutputID: UInt32 = 0

    public init(identifier: USBDeviceIdentifier, transport: XPCTransport? = nil) {
        self.identifier = identifier
        self.transport = transport ?? MachXPCTransport()
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
        case .keyboardVolumePeripheralID: return .uint32(cachedKBVolPeripheralID)
        case .keyboardVolumeOutputID:     return .uint32(cachedKBVolOutputID)
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
        case .keyboardVolumePeripheralID:
            if let pid = value.asUInt32 { cachedKBVolPeripheralID = pid }
        case .keyboardVolumeOutputID:
            if let oid = value.asUInt32 { cachedKBVolOutputID = oid }
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
            return getCachedWriteOnly(address)
        }

        let usbRequest = try SymphonyIOPropertyMapper.buildReadRequest(for: address)

        let reply = try await transport.sendGetProperty(
            bRequest: usbRequest.request,
            wValue: usbRequest.value,
            wIndex: usbRequest.index,
            dataLength: UInt16(usbRequest.data.count))

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

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        guard transport.isConnected else {
            throw DeviceConnectionError.notConnected
        }

        guard !SymphonyIOPropertyMapper.readOnlySelectors.contains(address.selector) else {
            throw DeviceConnectionError.readOnly(address.selector)
        }

        // keyboardVolume* are daemon-only prefs with no mapper write case; cache
        // them directly. Other cache-only properties (prefix, front-panel meter
        // config) surface as DeviceConnectionError.cacheOnly from the mapper below.
        let noOpcodeSelectors: Set<AudioPropertySelector> = [
            .keyboardVolumePeripheralID, .keyboardVolumeOutputID
        ]
        if noOpcodeSelectors.contains(address.selector) {
            updateCacheForWriteOnly(address, value: value)
        } else {
            do {
                let usbRequest = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: value)
                // S5: await the reply — a failed USB write throws instead of
                // silently reporting success and updating caches.
                try await transport.sendSetProperty(
                    bRequest: usbRequest.request,
                    wValue: usbRequest.value,
                    wIndex: usbRequest.index,
                    data: usbRequest.data)
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
        }

        // Notify listeners
        let change = PropertyChange(address: address, value: value)
        await listenerStorage.notifyListeners(for: address, change: change)
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

    /// Mute/unmute the SW Return audio path in software.
    /// Hardware mixer mute has no effect because USB audio routes
    /// directly to DAC, bypassing the FPGA mixer.
    public func setSwReturnMute(_ muted: Bool) {
        transport.setSwReturnMute(muted)
    }

    /// Send a mixer parameter directly via dedicated XPC command.
    /// Bypasses the generic setProperty path which has delivery issues.
    public func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {
        transport.sendMixerParam(usbCmd: usbCmd, mixer: mixer, channel: channel, value: value)
    }

    /// Set SW Return fader level in dB (software gain in proxy render callback).
    public func setSwReturnLevel(_ dB: Double) {
        transport.setSwReturnLevel(dB)
    }

    public func setSwReturnChannelLevel(channel: Int, dB: Double) {
        transport.setSwReturnChannelLevel(channel: channel, dB: dB)
    }

    /// Set SW Return pan position (software pan in proxy render callback).
    public func setSwReturnPan(_ pan: Double) {
        transport.setSwReturnPan(pan)
    }

    public func setSwReturnProcessing(_ enabled: Bool) {
        transport.setSwReturnProcessing(enabled)
    }

    /// Ask the proxy to rebuild its output AudioUnit. See the protocol comment:
    /// this is the audio-path half of "Reconnect Hardware".
    public func resetAudioOutput() {
        transport.resetAudioOutput()
    }

    /// Set FPGA routing mode: 0 = DAW (null passthrough), 1 = Direct Monitor.
    public func setRoutingMode(_ mode: Int) {
        transport.setRoutingMode(mode)
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
