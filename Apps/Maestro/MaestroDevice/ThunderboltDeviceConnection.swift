/// Thunderbolt device connection for Symphony IO via ThunderBridge.
///
/// Uses two communication paths:
/// 1. CoreAudio HAL properties (volume, mute, sample rate) — direct to dext
/// 2. IOUserClient (mic gain, phantom, routing, clock, mixer, etc.) — via DextUserClient
///
/// The IOUserClient path sends vendor commands through the dext's XLink control
/// pipe, matching the same protocol the USB proxy uses for EP0 transfers.

import MaestroCore
import CoreAudio
import Foundation

// MARK: - ThunderboltDeviceConnection

public final class ThunderboltDeviceConnection: DeviceConnection, @unchecked Sendable {

    /// DriverKit-local command handled by the card FPGA, not sent over XLink.
    private static let mixerSoftwareReturnSourceCommand: UInt8 = 0xB4

    public let identifier: USBDeviceIdentifier
    public private(set) var isConnected: Bool = true

    /// CoreAudio device ID for the ThunderBridge dext audio device.
    private let audioDeviceID: AudioDeviceID

    /// Whether Core Audio currently has an active I/O cycle for this device.
    /// ThunderBridge can remain enumerated over PCIe after the Symphony is
    /// powered down, so enumeration alone is not evidence that meter DMA is
    /// producing fresh audio data.
    public var isAudioRunning: Bool? {
        CoreAudioDeviceConnection.isDeviceRunning(audioDeviceID)
    }

    /// IOUserClient connection for vendor commands (mic gain, phantom, etc.)
    private let dextClient = DextUserClient()

    /// Listener storage (NSLock-protected, same pattern as XPCDeviceConnection).
    private let listenerLock = NSLock()
    private var listeners: [AudioPropertySelector: [WeakListener]] = [:]

    /// Property selectors handled via CoreAudio HAL (more efficient path).
    private static let coreAudioSelectors: Set<AudioPropertySelector> = [
        .outputLevel,       // → kAudioDevicePropertyVolumeDecibels
        .outputMute,        // → kAudioDevicePropertyMute
        .sampleRate,        // → kAudioDevicePropertyNominalSampleRate
    ]

    /// Property selectors routed through vendor commands via dext custom property.
    /// This covers the full XMOS command surface — matches SymphonyIOPropertyMapper.buildWriteRequest.
    private static let dextSelectors: Set<AudioPropertySelector> = [
        // Mic preamp
        .micGain, .phantom, .phaseReverse, .highPassFilter, .softLimit,
        // MicPre8 group / insert (0xC7 / 0xC8 / 0xC9). Inert on a unit with no
        // MicPre module — the Input page never offers the controls, so nothing
        // is ever written for them.
        .groupID, .insertID, .insertReturnEnable,
        // Analog / digital input
        .analogIOType, .digitalRefLevel,
        // Output monitoring
        .outputDim, .outputSumToMono,
        .headphone1Level, .headphone2Level,
        .headphone1Mute, .headphone2Mute,
        .headphone1Dim, .headphone2Dim,
        .headphone1SumToMono, .headphone2SumToMono,
        .headphone1RoutingID, .headphone2RoutingID,
        .activeSpeakerSet,
        // Routing
        .routing,
        // Card-mixer software-return source. ThunderBridge handles this in the
        // card FPGA, rather than through the USB-only Symphony IO crosspoint.
        .mixerSoftwareReturnID,
        // Clock
        .clockSource,
        // Mixer
        .mixerChannelLevel, .mixerChannelPan, .mixerChannelMute, .mixerChannelSolo,
        // Metering / status
        .frontPanelMeterBank, .metersShowInput,
        .peakHoldMode, .oversHoldMode, .peaksClear, .prefix,
        // Optical / SPDIF
        .opticalInFormat, .opticalOutFormat,
        .spdifReplaceID, .spdifMirrorID,
        // Speaker
        .speakerOutputMode,
    ]

    /// All supported selectors (union of CoreAudio + dext paths).
    private static let supportedSelectors: Set<AudioPropertySelector> = {
        var s = coreAudioSelectors
        s.formUnion(dextSelectors)
        s.insert(.outputLevelRange)
        s.formUnion(readOnlyDextSelectors)
        return s
    }()

    /// Read-only selectors served by an IOUserClient READ selector rather than a
    /// vendor write. Kept out of `dextSelectors` so they never join
    /// `settableSelectors` — writing a board type is meaningless.
    private static let readOnlyDextSelectors: Set<AudioPropertySelector> = [
        .primaryBoardType, .secondaryBoardType,
    ]

    /// Property selectors that are settable.
    private static let settableSelectors: Set<AudioPropertySelector> = {
        var s: Set<AudioPropertySelector> = [.outputLevel, .outputMute, .sampleRate]
        s.formUnion(dextSelectors.subtracting(SymphonyIOPropertyMapper.readOnlySelectors))
        return s
    }()

    public init(identifier: USBDeviceIdentifier, audioDeviceID: AudioDeviceID) {
        self.identifier = identifier
        self.audioDeviceID = audioDeviceID

        // Connect vendor command transport to the dext's custom property
        dextClient.connect(audioDeviceID: audioDeviceID)
    }

    // MARK: - DeviceConnection Protocol

    public func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        guard isConnected else { throw DeviceConnectionError.notConnected }

        // CoreAudio HAL path (volume, mute, sample rate)
        switch address.selector {
        case .outputLevel:
            return try .float64(Float64(readVolumeDecibels()))
        case .outputMute:
            return try .uint32(readMute() ? 1 : 0)
        case .sampleRate:
            return try .float64(readNominalSampleRate())
        case .outputLevelRange:
            return .range(min: -64.0, max: 0.0)
        case .primaryBoardType, .secondaryBoardType:
            // The dext read OptionBoardType (0xA1) for both slots at Start and kept
            // the bytes; there is no EP0 on this transport for us to read ourselves.
            // A slot whose read failed comes back nil and MUST throw rather than
            // report 0: AppState treats a live 0 as "nothing reported" only because
            // it can tell the two apart, and a fabricated "empty" unlocks writes
            // that silence real outputs.
            guard let types = dextClient.readBoardTypes() else {
                throw DeviceConnectionError.unsupportedProperty(address.selector)
            }
            let raw = (address.selector == .primaryBoardType) ? types.primary : types.secondary
            guard let raw else {
                throw DeviceConnectionError.unsupportedProperty(address.selector)
            }
            return .uint32(UInt32(raw))
        case .opticalInFormat:
            // Read the current selected value of the dext's DataSource control for this board
            // (element = board+1). Entitlement-free; mirrors the write path. Returns 0=ADAT/SMUX,
            // 1=S/PDIF. Throws if the board has no optical control published (non-optical board).
            return try .uint32(readOpticalFormat(board: address.element))
        case .opticalOutFormat:
            return try .uint32(readOpticalFormat(board: address.element))
        case .routing:
            let data = try dextClient.readVendorCommand(
                command: SymphonyIOCommand.audioRouting.rawValue,
                value: address.element,
                responseLength: 1)
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("ThunderBridge routing read returned no data")
            }
            return .uint32(UInt32(byte))
        default:
            break
        }

        // IOUserClient path (all other vendor commands)
        // Note: reads via IOUserClient are not implemented yet (write-only path).
        // For read-only properties, the dext would need a read command dispatch.
        // For now, unsupported reads throw.
        throw DeviceConnectionError.unsupportedProperty(address.selector)
    }

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        guard isConnected else { throw DeviceConnectionError.notConnected }

        // CoreAudio HAL path
        switch address.selector {
        case .outputLevel:
            // The UI sends .outputLevel as a UInt32 ATTENUATION (0..64, where 0 = loudest),
            // matching the USB path (SymphonyIOPropertyMapper). The dext's VolumeControl is in
            // decibels (-64..0), so attenuation N maps to -N dB. Accept both forms (a Float64 dB
            // value from any other caller too) — previously this only accepted Float64, so the
            // app's UInt32 knob writes threw typeMismatch and were silently swallowed (mute worked
            // because it accepts UInt32/Bool; the volume knob did nothing).
            let db: Float32
            if let d = value.asFloat64 {
                db = Float32(d)                     // already dB (negative)
            } else if let atten = value.asUInt32 {
                db = -Float32(atten)                // attenuation 0..64 → -atten dB
            } else {
                throw DeviceConnectionError.typeMismatch(expected: "Float64 or UInt32", got: "\(value)")
            }
            try writeVolumeDecibels(db)
            notifyListeners(for: address.selector, value: value)
            return

        case .outputMute:
            let muted: Bool
            if let u = value.asUInt32 { muted = u != 0 }
            else if let b = value.asBool { muted = b }
            else { throw DeviceConnectionError.typeMismatch(expected: "UInt32/Bool", got: "\(value)") }
            try writeMute(muted)
            notifyListeners(for: address.selector, value: value)
            return

        case .sampleRate:
            guard let rate = value.asFloat64 else {
                throw DeviceConnectionError.typeMismatch(expected: "Float64", got: "\(value)")
            }
            try writeNominalSampleRate(rate)
            notifyListeners(for: address.selector, value: value)
            return

        case .clockSource:
            // Entitlement-free path: the dext publishes a Clock Source AudioDriverKit control
            // object ('clck', Global scope), so we drive it via the standard CoreAudio clock-source
            // property rather than the (Apple-blocked) IOUserClient. The control's selector IDs are
            // the legacy eSymphonyIOClockSource enum values (1..5), so the value maps 1:1.
            guard let src = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            try writeClockSource(src)
            notifyListeners(for: address.selector, value: value)
            return

        case .opticalInFormat:
            // Entitlement-free path: the dext publishes a per-optical-board DataSource control
            // object ('dest', Output scope, element = board+1) that drives vendor cmd 0x34. We route
            // the legacy 'AEoi' write through the standard CoreAudio DataSource property rather
            // than the (Apple-blocked) IOUserClient. `address.element` is the 0-based board index;
            // the control lives on element board+1 (element 0/Main holds output volume+mute).
            // Value: 0=ADAT/SMUX, 1=S/PDIF. Only published for boards the dext detected as Optical,
            // so a write to a non-optical board is a no-op OSStatus (safe).
            guard let fmt = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            try writeOpticalFormat(board: address.element, format: fmt)
            notifyListeners(for: address.selector, value: value)
            return

        case .opticalOutFormat:
            guard let fmt = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            try writeOpticalFormat(board: address.element, format: fmt)
            notifyListeners(for: address.selector, value: value)
            return

        default:
            break
        }

        // IOUserClient path — route through DextUserClient
        guard Self.dextSelectors.contains(address.selector) else {
            throw DeviceConnectionError.unsupportedProperty(address.selector)
        }

        // The USB mapper's AEsR implementation writes Symphony IO destinations
        // (0xE4/0xE5). ThunderBridge's original PCIe mixer instead selects a
        // host-playback pair by changing the card FPGA mixer return route.
        if address.selector == .mixerSoftwareReturnID {
            guard let source = value.asUInt32, source <= 7 else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 software return source 0...7", got: "\(value)")
            }
            guard address.element & 0xFFFF == 0,
                  (1...2).contains(address.element >> 16) else {
                throw DeviceConnectionError.transportError(
                    "Invalid ThunderBridge mixer element \(address.element)")
            }
            try dextClient.sendVendorCommand(
                command: Self.mixerSoftwareReturnSourceCommand,
                value: address.element,
                payload: Data([UInt8(source)]))
            notifyListeners(for: address.selector, value: value)
            return
        }

        do {
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: value)
            try sendViaDext(request)
        } catch DeviceConnectionError.cacheOnly {
            // No XMOS opcode (or an unsafe one, e.g. front-panel meter config) —
            // skip the send. Never emit the 0xFF sentinel to the dext (S3).
        }
        notifyListeners(for: address.selector, value: value)
    }

    public func hasProperty(_ address: PropertyAddress) async -> Bool {
        Self.supportedSelectors.contains(address.selector)
    }

    public func isPropertySettable(_ address: PropertyAddress) async -> Bool {
        Self.settableSelectors.contains(address.selector)
    }

    public func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        addListenerSync(listener, for: address.selector)
    }

    public func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        removeListenerSync(listener, for: address.selector)
    }

    // NSLock wrappers — called synchronously to avoid Swift 6 async restriction
    private nonisolated func addListenerSync(_ listener: PropertyListener, for selector: AudioPropertySelector) {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        listeners[selector, default: []].append(WeakListener(listener))
    }

    private nonisolated func removeListenerSync(_ listener: PropertyListener, for selector: AudioPropertySelector) {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        listeners[selector]?.removeAll { $0.ref === listener }
    }

    public func disconnect() async {
        closeDextClient()
    }

    // MARK: - Dext Vendor Command

    /// Send a vendor command to the Symphony IO via the dext's custom property.
    /// Program one XLink TX channel of the card's output routing stage. This is
    /// where host playback routing lives on ThunderBridge — see
    /// ``ThunderboltCardRouting``. Handled by the dext (build 111+), never sent
    /// to the Symphony.
    public func setCardOutputRoute(_ route: ThunderboltCardRouting.Route) throws {
        guard isConnected, dextClient.isConnected else { throw DeviceConnectionError.notConnected }
        try dextClient.sendVendorCommand(
            command: ThunderboltCardRouting.outputRouteCommand,
            value: 0,
            payload: route.payload)
    }

    private func sendViaDext(_ request: USBControlRequest) throws {
        guard dextClient.isConnected else {
            throw DeviceConnectionError.notConnected
        }
        try dextClient.sendFromUSBRequest(request)
    }

    /// Read the card FPGA hardware meter buffer (256 raw words), or nil if unavailable.
    /// Word layout: 0-31 = hardware inputs, 64-95 = host playback, 128-131 = mixer0/1 out.
    public func readMeters() -> [UInt32]? {
        dextClient.readMeters()
    }

    /// Read the dext's timing/register snapshot through the same signed
    /// user-client connection Maestro uses for vendor controls. This keeps
    /// latency validation inside the production entitlement boundary; a
    /// standalone unsigned probe cannot open this production user client.
    public func readTimingHealth() -> TimingHealth? {
        dextClient.readTimingHealth()
    }

    /// One serialized liveness probe: the dext's live XLink read plus the
    /// app-side current-link-fault check (see `ThunderboltEndpointHealth`).
    /// This is the only question lifecycle code should ask about the Symphony.
    public func probeEndpoint() -> ThunderboltEndpointVerdict {
        // dext 113: the driver owns the link watch; this read costs no bus traffic.
        // A dext older than 113 rejects selector 5, which reads as `.unavailable`,
        // so fall back to the 0x51 message probe in that one case.
        if let ls = dextClient.readLinkState() {
            lastLinkState = ls
            return ThunderboltEndpointHealth.evaluate(linkState: ls)
        }
        lastLinkState = nil
        return ThunderboltEndpointHealth.evaluate(dextClient.readTimingHealth())
    }

    /// The original round-trip probe (0x51 ClockRateAndLock over XLink). On demand
    /// only — diagnostics and one-off confirmations — never on a timer.
    public func probeEndpointDeep() -> ThunderboltEndpointVerdict {
        ThunderboltEndpointHealth.evaluate(dextClient.readTimingHealth())
    }

    /// Raw link-watch state for diagnostics panels.
    public func linkState() -> LinkState? { dextClient.readLinkState() }

    /// The link-watch state behind the most recent `probeEndpoint()` (nil when the
    /// running dext predates selector 5). Read by the lifecycle log.
    public private(set) var lastLinkState: LinkState?

    /// True only when the card FPGA answers a live read. The PCI endpoint and
    /// dext may remain registered after the Symphony loses power.
    public func isHardwareResponsive() -> Bool {
        dextClient.probeHardwareResponse()
    }

    /// Reopen the app's private dext connection after a physical power flap.
    ///
    /// ThunderBridge's PCI service can remain enumerated while the Symphony is
    /// powered off. In that interval the existing IOUserClient may stay alive
    /// but no longer be able to issue XLink transactions. Reopening the client
    /// is deliberately limited to the control path; Core Audio retains the same
    /// device identity and the health loop decides when the hardware is usable.
    public func reconnectDextClient() {
        dextClient.disconnect()
        dextClient.connect(audioDeviceID: audioDeviceID)
    }

    /// Close the private dext client synchronously (the core of `disconnect()`);
    /// also used by a throwaway connection created only to probe the endpoint.
    public func closeDextClient() {
        isConnected = false
        dextClient.disconnect()
    }

    // MARK: - CoreAudio HAL Property Access

    private func readVolumeDecibels() throws -> Float32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibels,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("VolumeDecibels read failed: \(status)")
        }
        return volume
    }

    private func writeVolumeDecibels(_ db: Float32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibels,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = db
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<Float32>.size), &volume)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("VolumeDecibels write failed: \(status)")
        }
    }

    /// Write the clock source via the dext's AudioDriverKit control object (no entitlement).
    /// `source` is the legacy eSymphonyIOClockSource value (1=Internal..5=IOBoard2), which is
    /// exactly the selector ID the 'clck' control publishes. Global scope, since the control is
    /// created on kAudioObjectPropertyScopeGlobal.
    private func writeClockSource(_ source: UInt32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyClockSource,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var src = source
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &src)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("ClockSource write failed: OSStatus \(status)")
        }
    }

    /// Write the optical output format via the dext's per-board DataSource control object
    /// (no entitlement). `board` is the 0-based board index (0=primary, 1=secondary); the control
    /// lives on `kAudioObjectPropertyScopeOutput` element `board+1` (element 0/Main holds output
    /// volume+mute). `format` is 0=ADAT/SMUX, 1=S/PDIF — the selector value equals the wire byte
    /// the dext forwards as vendor cmd 0x34.
    private func writeOpticalFormat(board: UInt32, format: UInt32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: board &+ 1
        )
        var value: UInt32 = (format != 0) ? 1 : 0
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("OpticalFormat write failed: OSStatus \(status)")
        }
    }

    /// Read the current optical output format from the dext's DataSource control (element
    /// board+1). Returns 0=ADAT/SMUX, 1=S/PDIF. Throws if the board publishes no optical control.
    private func readOpticalFormat(board: UInt32) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: board &+ 1
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("OpticalFormat read failed: OSStatus \(status)")
        }
        return value
    }

    private func readMute() throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("Mute read failed: \(status)")
        }
        return muted != 0
    }

    private func writeMute(_ muted: Bool) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("Mute write failed: \(status)")
        }
    }

    private func readNominalSampleRate() throws -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &rate)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("SampleRate read failed: \(status)")
        }
        return rate
    }

    private func writeNominalSampleRate(_ rate: Float64) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableRate = rate
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<Float64>.size), &mutableRate)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("SampleRate write failed: \(status)")
        }
    }

    // MARK: - Listener Notification

    private func notifyListeners(for selector: AudioPropertySelector, value: PropertyValue) {
        listenerLock.lock()
        let weakListeners = listeners[selector] ?? []
        listenerLock.unlock()

        let change = PropertyChange(
            address: PropertyAddress(selector: selector),
            value: value
        )
        for weak in weakListeners {
            if let listener = weak.ref {
                Task { await listener.propertyDidChange(change) }
            }
        }
    }

    // MARK: - Transport Type Discovery

    /// Check if a CoreAudio device is a Thunderbolt device.
    public static func isThunderboltDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeThunderbolt
    }
}

// MARK: - Weak Listener Wrapper

private struct WeakListener {
    weak var ref: (any PropertyListener)?
    init(_ listener: any PropertyListener) { self.ref = listener }
}
