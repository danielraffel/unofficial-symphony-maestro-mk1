/// The second Symphony I/O (unit B) on ThunderBridge port 2, as a device
/// connection of its own.
///
/// While 64 channels run with a Symphony I/O on port 2, the driver forwards a
/// vendor command or read to it when the request carries port byte 1
/// (`SymphonyVendorCommandInput.port`), with its own message sequence, as the
/// original kept one protocol object per peripheral
/// (`og_source/maestrolink/Software/ControlProtocol/SimpleControlProtocolSymphony.cpp:34-48`).
/// This connection sends every request with that byte, so the Input, Output,
/// Device Settings and System Setup pages can point at unit B without knowing
/// about ports. Unit A's `ThunderboltDeviceConnection` is not changed by it.
///
/// What differs from unit A:
/// - Speaker level and mute and the optical formats go as vendor commands:
///   the Core Audio controls unit A uses belong to unit A.
/// - Clock source and sample rate are not unit B's to set. The driver makes it
///   a Loop Sync slave of unit A when 64 channels start; the clock read
///   answers that.
/// - The card mixer (0xB0-0xB4) and the card output routing (0xB5) are the
///   card's, not a unit's: they go through unit A's connection with mixer
///   channels 32-63 and XLink TX 32-63.
/// - Board types and the prefix the unit keeps come from the driver's unit B
///   report (selector 11), read when 64 channels started.

import Foundation
import MaestroCore

public final class ThunderboltUnitBConnection: DeviceConnection, @unchecked Sendable {

    public let identifier: USBDeviceIdentifier
    public var isConnected: Bool { connected && transport.isConnected }
    private var connected = true

    /// The same driver client unit A uses; every call carries `port`.
    private let transport: any VendorTransport
    /// The driver's unit B report, read when asked (no bus access).
    private let state: @Sendable () -> UnitBState?

    /// Port byte for unit B.
    public static let port: UInt8 = DeviceUnit.b.portByte

    /// Unit B's own settings (see `DeviceSettingsStore`), under its own key.
    public let settingsStore: DeviceSettingsStore

    private let listenerLock = NSLock()
    private var listeners: [AudioPropertySelector: [WeakUnitListener]] = [:]

    public init(identifier: USBDeviceIdentifier, transport: any VendorTransport,
                settingsStore: DeviceSettingsStore = DeviceSettingsStore(),
                state: @escaping @Sendable () -> UnitBState?) {
        self.identifier = identifier
        self.transport = transport
        self.settingsStore = settingsStore
        self.state = state
    }

    // MARK: - What unit B supports

    /// Written to unit B through the property mapper, with port byte 1.
    static let mappedWrites: Set<AudioPropertySelector> = [
        .micGain, .instrumentGain, .phantom, .phaseReverse, .highPassFilter, .softLimit,
        .groupID, .insertID, .insertReturnEnable,
        .analogIOType, .digitalRefLevel,
        .outputLevel, .outputMute, .outputDim, .outputSumToMono,
        .headphone1Level, .headphone2Level, .headphone1Mute, .headphone2Mute,
        .headphone1Dim, .headphone2Dim, .headphone1SumToMono, .headphone2SumToMono,
        .activeSpeakerSet,
        .frontPanelMeterBank, .metersShowInput, .peakHoldMode, .oversHoldMode, .peaksClear,
        .opticalInFormat, .opticalOutFormat,
    ]

    /// Not sent to unit B yet. The driver at the time of writing (79f7c1b)
    /// applies what these commands mean for unit A after every send or read,
    /// whatever the port: the prefix renames unit A's channels, Speaker Mode
    /// moves unit A's volume control between its speakers and headphone 1,
    /// Coax Replaces renames unit A's S/PDIF channels and Coax Mirrors is put
    /// back on unit A after a link recovery (`SendVendorCommand`/
    /// `ReadVendorCommand` in `SymphonyThunderbridge.cpp`). Until the driver
    /// keeps those apart by port, a write is kept on the Mac (as with the
    /// prefix for unit A when the send fails) or refused, and nothing reaches
    /// the bus. Set `driverKeepsUnitsApart` once it does.
    static let heldUntilDriverKeepsUnitsApart: Set<AudioPropertySelector> = [
        .prefix, .speakerOutputMode, .spdifReplaceID, .spdifMirrorID,
    ]
    static let driverKeepsUnitsApart = true   // driver b79f988: port-1 commands leave unit A's state alone

    /// Read from unit B with a vendor read on port 2, decoded as USB decodes
    /// it. Each unanswered read holds the driver's command path for its
    /// timeout, so this is kept to what the pages ask for and unit A's
    /// connection can also answer (plus the controls unit A reads from Core
    /// Audio).
    static let vendorReads: Set<AudioPropertySelector> = [
        .outputLevel, .outputMute, .headphone1Level, .headphone2Level,
        .headphone1Mute, .headphone2Mute, .opticalInFormat, .opticalOutFormat,
    ]

    static let storedSelectors = Set(DeviceSettingsStore.ownedSettings)

    private static var supported: Set<AudioPropertySelector> {
        mappedWrites.union(heldUntilDriverKeepsUnitsApart).union(vendorReads)
            .union([.primaryBoardType, .secondaryBoardType, .clockSource])
    }

    // MARK: - DeviceConnection

    public func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        guard isConnected else { throw DeviceConnectionError.notConnected }
        switch address.selector {
        case .primaryBoardType, .secondaryBoardType:
            guard let s = state(), s.present else { throw DeviceConnectionError.unsupportedProperty(address.selector) }
            let i = address.selector == .primaryBoardType ? 0 : 1
            guard i < s.boardValid.count, s.boardValid[i] != 0, i < s.boardType.count else {
                throw DeviceConnectionError.unsupportedProperty(address.selector)
            }
            return .uint32(UInt32(s.boardType[i]))
        case .clockSource:
            guard let s = state(), s.present, s.clockSource != 0 else {
                throw DeviceConnectionError.unsupportedProperty(address.selector)
            }
            return .uint32(UInt32(s.clockSource))
        case .prefix:
            if let value = rememberedValue(for: address) { return value }
            guard let letter = state()?.info?.prefixLetter else {
                throw DeviceConnectionError.unsupportedProperty(address.selector)
            }
            return .string(letter)
        default:
            break
        }
        if let value = rememberedValue(for: address) { return value }
        guard Self.vendorReads.contains(address.selector) else {
            throw DeviceConnectionError.unsupportedProperty(address.selector)
        }
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        let data = try transport.readVendorCommand(
            command: request.request, value: DextUserClient.nValue(for: request),
            responseLength: max(1, request.data.count), port: Self.port)
        guard let byte = data.first else {
            throw DeviceConnectionError.transportError("Unit B read returned no data")
        }
        switch address.selector {
        case .outputLevel, .headphone1Level, .headphone2Level:
            return .uint32(UInt32(byte))          // attenuation, as the pages read it
        case .outputMute, .headphone1Mute, .headphone2Mute:
            return .bool(byte != 0)
        default:
            return .uint32(UInt32(byte))
        }
    }

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        guard isConnected else { throw DeviceConnectionError.notConnected }
        let selector = address.selector

        if Self.heldUntilDriverKeepsUnitsApart.contains(selector) && !Self.driverKeepsUnitsApart {
            if selector == .prefix {
                guard CardLayout.peripheralPrefixByte(value.asString) != nil else {
                    throw DeviceConnectionError.typeMismatch(expected: "a letter A-Z", got: "\(value)")
                }
                remember(value, for: address)
                notifyListeners(for: selector, value: value)
                return
            }
            throw DeviceConnectionError.transportError(
                "Unit B \(selector) is not sent yet: the driver would apply it to unit A too")
        }
        if selector == .prefix {
            guard let byte = CardLayout.peripheralPrefixByte(value.asString) else {
                throw DeviceConnectionError.typeMismatch(expected: "a letter A-Z", got: "\(value)")
            }
            remember(value, for: address)
            try? transport.sendVendorCommand(command: ThunderboltDeviceConnection.prefixCommand, value: 0,
                                             payload: Data([byte]), port: Self.port)
            notifyListeners(for: selector, value: value)
            return
        }
        guard Self.mappedWrites.contains(selector) || Self.heldUntilDriverKeepsUnitsApart.contains(selector) else {
            // Clock, rate, mixer and card routing are not unit B's to set here.
            throw DeviceConnectionError.unsupportedProperty(selector)
        }
        // The mapper wants Bool for the mutes; the pages also send 0/1.
        var sent = value
        if [.outputMute, .headphone1Mute, .headphone2Mute].contains(selector), let u = value.asUInt32 {
            sent = .bool(u != 0)
        }
        do {
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: sent)
            try transport.sendVendorCommand(command: request.request, value: DextUserClient.nValue(for: request),
                                            payload: request.data, port: Self.port)
        } catch DeviceConnectionError.cacheOnly {
            // No opcode (or an unsafe one): kept, not sent, as for unit A.
        }
        remember(value, for: address)
        notifyListeners(for: selector, value: value)
    }

    public func hasProperty(_ address: PropertyAddress) async -> Bool {
        Self.supported.contains(address.selector)
    }

    public func isPropertySettable(_ address: PropertyAddress) async -> Bool {
        Self.mappedWrites.contains(address.selector) || address.selector == .prefix
    }

    public func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerLock.withLock { listeners[address.selector, default: []].append(WeakUnitListener(listener)) }
    }

    public func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerLock.withLock { listeners[address.selector]?.removeAll { $0.ref === listener } }
    }

    /// Unit B shares unit A's driver client; disconnecting it only stops this
    /// connection from sending.
    public func disconnect() async { connected = false }

    /// Write unit B's stored settings back, as unit A's connection does at connect.
    public func reapplyStoredSettings() async -> DeviceSettingsReplay {
        var replay = DeviceSettingsReplay()
        for entry in settingsStore.entries() where Self.storedSelectors.contains(entry.address.selector) {
            do {
                try await setProperty(entry.address, value: entry.value)
                replay.applied += 1
            } catch {
                replay.failed.append(entry.address.selector)
            }
        }
        return replay
    }

    // MARK: - Private

    private func remember(_ value: PropertyValue, for address: PropertyAddress) {
        guard Self.storedSelectors.contains(address.selector) else { return }
        settingsStore.record(value, for: address)
    }

    private func rememberedValue(for address: PropertyAddress) -> PropertyValue? {
        guard Self.storedSelectors.contains(address.selector) else { return nil }
        return settingsStore.value(for: address)
    }

    private func notifyListeners(for selector: AudioPropertySelector, value: PropertyValue) {
        let weak = listenerLock.withLock { listeners[selector] ?? [] }
        let change = PropertyChange(address: PropertyAddress(selector: selector), value: value)
        for listener in weak.compactMap(\.ref) {
            Task { await listener.propertyDidChange(change) }
        }
    }
}

private struct WeakUnitListener {
    weak var ref: (any PropertyListener)?
    init(_ listener: any PropertyListener) { self.ref = listener }
}
