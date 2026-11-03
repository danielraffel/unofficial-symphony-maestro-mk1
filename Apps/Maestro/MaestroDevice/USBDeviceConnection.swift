/// USB-based DeviceConnection for Apogee Symphony IO MKI.
///
/// Bridges the property-based DeviceConnection protocol to the
/// XMOS vendor-specific USB control protocol. Each AudioPropertySelector
/// is mapped to the corresponding SymphonyIOCommand and its encoding.
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` — property selectors
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp` — USB command usage
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h` — opcodes

import MaestroCore
import Foundation

// MARK: - USB Device Connection

/// DeviceConnection implementation that communicates via USB vendor-specific requests.
///
/// Maps property get/set operations to the USB command protocol used by
/// the XMOS-based Symphony IO firmware.
public final class USBDeviceConnection: DeviceConnection, @unchecked Sendable {
    public let identifier: USBDeviceIdentifier

    /// The underlying USB transport. Exposed for connection probing and reconnection.
    public let transport: USBTransport
    private let listenerStorage = ListenerStorage()

    /// Cached sample rate — opcode 0x03 is write-only, so we track what was set.
    /// Defaults to 48000 Hz (the Symphony IO factory default).
    ///
    /// Hardware discovery note: opcode 0x51 (ClockRateAndLock) returns the
    /// measured rate only when using an external clock. With internal clock,
    /// bytes 1-4 are zero. See Docs/Learnings.md entry 2026-02-17.
    private let lock = NSLock()
    private var cachedSampleRate: Double = 48000

    /// Cached clock source — opcode 0x50 (ClockMode) is write-only.
    /// Opcode 0x51 only returns lock status + measured rate, NOT the source.
    /// Defaults to 0 (Internal).
    private var cachedClockSource: UInt32 = 0

    /// Cached property settability — delegates to SymphonyIOPropertyMapper.
    private static let readOnlySelectors = SymphonyIOPropertyMapper.readOnlySelectors

    public init(identifier: USBDeviceIdentifier, transport: USBTransport) {
        self.identifier = identifier
        self.transport = transport
    }

    /// Get the cached sample rate.
    private func getCachedSampleRate() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return cachedSampleRate
    }

    /// Update the cached sample rate.
    private func setCachedSampleRate(_ rate: Double) {
        lock.lock()
        cachedSampleRate = rate
        lock.unlock()
    }

    /// Get the cached clock source.
    private func getCachedClockSource() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return cachedClockSource
    }

    /// Update the cached clock source.
    private func setCachedClockSource(_ source: UInt32) {
        lock.lock()
        cachedClockSource = source
        lock.unlock()
    }

    // MARK: - DeviceConnection Protocol

    public var isConnected: Bool {
        transport.isConnected
    }

    public func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        guard transport.isConnected else {
            throw DeviceConnectionError.notConnected
        }

        // Write-only properties: return cached values.
        if address.selector == .sampleRate {
            return .float64(getCachedSampleRate())
        }
        if address.selector == .clockSource {
            return .uint32(getCachedClockSource())
        }

        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        let response = try await sendWithRetry(request)
        return try SymphonyIOPropertyMapper.decodeResponse(
            response, for: address,
            cachedSampleRate: getCachedSampleRate(),
            cachedClockSource: getCachedClockSource())
    }

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        guard transport.isConnected else {
            throw DeviceConnectionError.notConnected
        }

        guard !Self.readOnlySelectors.contains(address.selector) else {
            throw DeviceConnectionError.readOnly(address.selector)
        }

        do {
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: value)
            _ = try await sendWithRetry(request)
        } catch DeviceConnectionError.cacheOnly {
            // No hardware opcode (or an unsafe one) — skip the send entirely.
        }

        // Cache sample rate on successful write (opcode 0x03 is write-only)
        if address.selector == .sampleRate, let hz = value.asFloat64 {
            setCachedSampleRate(hz)
        }

        // Cache clock source on successful write (opcode 0x50 is write-only)
        if address.selector == .clockSource, let source = value.asUInt32 {
            setCachedClockSource(source)
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
        !Self.readOnlySelectors.contains(address.selector)
    }

    public func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerStorage.addListener(listener, for: address)
    }

    public func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerStorage.removeListener(listener, for: address)
    }

    public func disconnect() async {
        await transport.close()
    }

    // MARK: - Device Initialization

    /// Run the full hardware initialization sequence.
    ///
    /// This matches the legacy daemon's startup sequence and is required
    /// for audio output to work. Must be called after opening the USB connection.
    ///
    /// Sequence: connectivity check → speaker mode → active speaker set →
    /// speaker volume → speaker unmute → USB routing → preference lock release
    ///
    /// Evidence: `og_source/maestrolink/Software/SymphonyIO.cpp` init() + ApplySettingsToHardware()
    public func initializeDevice() async throws {
        guard transport.isConnected else {
            throw DeviceConnectionError.notConnected
        }

        let channelCount = identifier.mode.channelCount

        // Step 1: Connectivity verification — wait for firmware ready
        for _ in 1...10 {
            let resp = try? await transport.send(SymphonyIORequestBuilder.getConnectivityVerification())
            if let data = resp?.data, data.count >= 4 {
                let code = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
                if code == SymphonyIOConstants.connectivityVerificationCode {
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Step 2: Speaker output mode → stereo
        _ = try await sendWithRetry(SymphonyIORequestBuilder.setSpeakerMode(.stereo))

        // Step 3: Active speaker set → enable set A
        _ = try await sendWithRetry(SymphonyIORequestBuilder.setActiveSpeakerSet(mask: 1))

        // Step 4: Speaker volume → -20 dB attenuation, unmute
        _ = try await sendWithRetry(SymphonyIORequestBuilder.setSpeakerVolume(attenuation: 20))
        _ = try await sendWithRetry(SymphonyIORequestBuilder.setSpeakerMute(muted: false))

        // Step 5: Route USB playback → IOBoard0 physical outputs
        // Send routes ONE AT A TIME matching legacy daemon behavior.
        // Evidence: SymphonyIORoutingController::ApplySettingsToHardware()
        // sends individual setAudioRoute(dest, src) calls, not batch.
        let ioBoard0Base: UInt8 = 32        // eSymphonyIORoutingSource_IOBoard0Ch0
        let usbPlaybackBase: UInt8 = 192    // eSymphonyIORoutingSource_FromP2Pch0
        for ch in 0..<UInt8(channelCount) {
            _ = try await sendWithRetry(SymphonyIORequestBuilder.setAudioRoute(
                destination: ioBoard0Base &+ ch,
                source: usbPlaybackBase &+ ch
            ))
        }

        // Step 6: Release preference load lock — signals firmware init is complete
        _ = try await sendWithRetry(SymphonyIORequestBuilder.setPreferenceLoadLock(locked: false))
    }

    // MARK: - Retry Logic

    /// Send a request with retry (2 attempts, matching legacy behavior).
    ///
    /// Evidence: `og_source/generic/USB/ApoUSB.h` — SimpleControlProtocol
    /// uses 2 retries with 1ms delay.
    private func sendWithRetry(_ request: USBControlRequest, retries: Int = 2) async throws -> USBControlResponse {
        var lastError: Error?
        for attempt in 0...retries {
            do {
                return try await transport.send(request)
            } catch {
                lastError = error
                if attempt < retries {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        throw lastError!
    }

    // buildReadRequest, buildWriteRequest, decodeResponse — see SymphonyIOPropertyMapper
}

// MARK: - Listener Storage

/// Thread-safe listener storage for USBDeviceConnection.
private final class ListenerStorage: @unchecked Sendable {
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
