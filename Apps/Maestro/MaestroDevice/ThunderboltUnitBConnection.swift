/// The second Symphony I/O (unit B) on ThunderBridge port 2, as a device
/// connection of its own.
///
/// While 64 channels run with a Symphony I/O on port 2, the driver forwards a
/// vendor command or read to it when the request carries port byte 1
/// (`SymphonyVendorCommandInput.port`), with its own message sequence, as the
/// original kept one protocol object per peripheral
/// (`og_source/maestrolink/Software/ControlProtocol/SimpleControlProtocolSymphony.cpp:34-48`).
/// This connection sends every request with that byte, so the Input, Output,
/// Input Routing and Device Settings pages can point at unit B without knowing
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

    private let writeGate: HardwareWriteGate
    public var hardwareWriteGate: HardwareWriteGate? { writeGate }
    public let identifier: USBDeviceIdentifier
    public var isConnected: Bool { infoLock.withLock { connected } && transport.isConnected }

    /// Read unit B's identity through the shared vendor-read path (port byte 1).
    public func readHardwareUniqueID() async -> UInt64? {
        guard isConnected else { return nil }
        return await SymphonyIdentityReader.readThunderbolt(transport: transport, port: Self.port)
    }
    private var connected = true
    private let infoLock = NSLock()
    private var infoStarted = false
    private var infoCache = SymphonyDeviceInfo()
    private let infoRouting: @Sendable () -> SymphonyRoutingModel

    public var deviceInfo: SymphonyDeviceInfo { infoLock.withLock { infoCache } }

    /// The same driver client unit A uses; every call carries `port`.
    private let transport: any VendorTransport
    /// The driver's unit B report, read when asked (no bus access).
    private let state: @Sendable () -> UnitBState?

    /// Port byte for unit B.
    public static let port: UInt8 = DeviceUnit.b.portByte

    /// Unit B's own settings (see `DeviceSettingsStore`), under its own key.
    public let settingsStore: DeviceSettingsStore

    private let sequenceLock: NSRecursiveLock
    private var headphoneAssignments: UInt8?

    private let listenerLock = NSLock()
    private var listeners: [AudioPropertySelector: [WeakUnitListener]] = [:]

    public init(identifier: USBDeviceIdentifier, transport: any VendorTransport,
                settingsStore: DeviceSettingsStore = DeviceSettingsStore(),
                sequenceLock: NSRecursiveLock = NSRecursiveLock(),
                writeGate: HardwareWriteGate = HardwareWriteGate(),
                infoRouting: @escaping @Sendable () -> SymphonyRoutingModel = {
                    SymphonyRoutingModel(topology: .unknown, hostChannels: 0)
                },
                state: @escaping @Sendable () -> UnitBState?) {
        self.writeGate = writeGate
        self.identifier = identifier
        self.transport = transport
        self.settingsStore = settingsStore
        self.sequenceLock = sequenceLock
        self.state = state
        self.infoRouting = infoRouting
    }

    /// The existing front-panel owner awaits one bounded read per cycle. Recheck
    /// live 64-channel topology on the worker, not just when the task was created.
    public func readParameterUpdates() async -> SymphonyIOParameterUpdates? {
        await Task.detached(priority: .utility) { [self] in
            guard isConnected, state()?.present == true, state()?.info?.setupComplete == true,
                  infoRouting().allows(.deviceInfo, at: .peripheral(.init(port: .two)!)) else { return nil }
            guard let data = try? transport.readVendorCommand(command: 0x28, value: 1,
                responseLength: SymphonyIOParameterUpdates.byteCount, port: Self.port) else { return nil }
            return SymphonyIOParameterUpdates(data: data)
        }.value
    }

    /// One attempt per connection. No lock spans a bus call, no batch is queued,
    /// and the first failure ends the attempt. Each synchronous driver read runs
    /// off the main actor and uses the existing bounded vendor-read timeout.
    public func readDeviceInfo() async -> SymphonyDeviceInfo {
        guard infoLock.withLock({
            if infoStarted { return false }
            infoStarted = true
            return true
        }) else { return deviceInfo }
        var requests: [(UInt8, UInt32, Int)] = [(0xC0, 0, 8), (0xA1, 0, 1), (0xA1, 1, 1)]
        requests += [0, 1, 4, 2, 3, 5, 6].map { (0xA0, UInt32($0), 3) }
        for (command, value, length) in requests {
            guard !Task.isCancelled else { break }
            // Empty slots have no FPGA version: og_source/maestrolink/Software/SymphonyIO.cpp:977-996.
            let slot: UInt32? = command == 0xA0 ? ([2: 0, 3: 1, 5: 0, 6: 1][value]) : nil
            if let slot, deviceInfo.boards[slot] == IOCardType.none { continue }
            let succeeded = await Task.detached(priority: .background) { [self] in
                guard isConnected, state()?.info?.setupComplete == true,
                      infoRouting().allows(.deviceInfo, at: .peripheral(.init(port: .two)!)) else { return false }
                do {
                    let data = try transport.readVendorCommand(command: command, value: value,
                                                               responseLength: length, port: Self.port)
                    return infoLock.withLock {
                        guard connected else { return false }
                        return infoCache.decode(command: command, value: value, data: data)
                    }
                } catch { return false }
            }.value
            guard succeeded else { break }
            await Task.yield()
        }
        return deviceInfo
    }

    /// A captured B connection never retargets to A. Validate the live topology
    /// and both detected boards before capture/recall and before every send.
    public func checkPresetLayout(_ layout: CardLayout, unitBGeneration: UInt32? = nil) throws {
        let live = state()
        guard isConnected, live?.present == true, live?.info?.setupComplete == true,
              infoRouting().allows(.preferenceLock, at: .peripheral(.init(port: .two)!)),
              layout.isKnown, layout.converter == nil, layout.converterLayout == nil,
              live?.info?.slotValid == [true, true],
              live?.info?.slot1 == layout.slot1, live?.info?.slot2 == layout.slot2,
              unitBGeneration.map({ live?.generation == $0 }) ?? true else {
            throw ThunderboltPreset.RecallError.unsupported("unit B's live card layout could not be verified.")
        }
    }

    public func withPresetLock<T>(_ body: () throws -> T) rethrows -> T {
        try sequenceLock.withLock(body)
    }

    private func presetRead(_ command: UInt8, _ value: UInt32, _ count: Int, layout: CardLayout) throws -> Data {
        try checkPresetLayout(layout)
        let data = try transport.readVendorCommand(command: command, value: value, responseLength: count, port: Self.port)
        guard data.count == count else { throw DeviceConnectionError.transportError("Short unit B preset read") }
        return data
    }

    public func capturePreset(_ seed: ThunderboltPreset, layout: CardLayout,
                              onSkipped: @Sendable @escaping (String) -> Void = { _ in }) throws -> ThunderboltPreset {
        try sequenceLock.withLock {
            try checkPresetLayout(layout)
            return try ThunderboltPreset.capture(seed, layout: layout, hostChannels: 64, peripheralB: true,
                readProperty: { address in
                    let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
                    let data = try self.presetRead(request.request, DextUserClient.nValue(for: request), max(1, request.data.count), layout: layout)
                    if ThunderboltPreset.monitorOrder.contains(address.selector) { return .uint32(UInt32(data[0])) }
                    return try SymphonyIOPropertyMapper.decodeResponse(USBControlResponse(data: data, bytesTransferred: data.count), for: address)
                }, readRaw: { try self.presetRead($0, $1, $2, layout: layout) }, onSkipped: onSkipped)
        }
    }

    public func routingResetWrites(layout: CardLayout, input: Bool) throws -> [ThunderboltPreset.Write] {
        try checkPresetLayout(layout)
        return try ThunderboltPreset.peripheralReset(layout: layout, input: input) { selector in
            try self.readProperty(PropertyAddress(selector: selector)).asUInt32
        }
    }

    public func presetWrites(_ saved: ThunderboltPreset.Peripheral, layout: CardLayout,
                             cardInputSupported: Bool = true,
                             onSkipped: ((String) -> Void)? = nil) throws -> [ThunderboltPreset.Write] {
        try checkPresetLayout(layout)
        return try saved.preset(layout: layout).writes(layout: layout, currentUnitID: layout.slot2 == .micPre8 ? try? presetRead(0xC0, 0, 8, layout: layout) : nil, hostChannels: 64,
                                                        peripheralB: true, cardInputSupported: cardInputSupported,
                                                        onSkipped: onSkipped)
    }

    public func applyPresetWrites(_ writes: [ThunderboltPreset.Write], layout: CardLayout,
                                  cardWrite: (PropertyAddress, PropertyValue) throws -> Void,
                                  unitBGeneration: UInt32? = nil) throws {
        try sequenceLock.withLock {
            try checkPresetLayout(layout, unitBGeneration: unitBGeneration)
            try ThunderboltPreset.recall(writes, send: { write in
                try self.checkPresetLayout(layout, unitBGeneration: unitBGeneration)
                switch write {
                case .property(let address, let value):
                    if [.mixerChannelLevel, .mixerChannelPan, .mixerChannelMute, .mixerChannelSolo].contains(address.selector) {
                        try cardWrite(address, value)
                    } else {
                        if Self.isHeadphoneSource(address.selector), self.headphoneAssignments == nil {
                            _ = try self.readProperty(address)
                        }
                        try self.writeProperty(address, value: value)
                    }
                case .frontPanel(let selection):
                    try self.transport.sendVendorCommand(command: 0x2A, value: 0, payload: Data([selection]), port: Self.port)
                case .output, .cardInput:
                    throw DeviceConnectionError.transportError("Card routing is not a unit B vendor command")
                }
            }, unlock: {
                // Always run the original unlock/read-back for the captured
                // connection, even after a generation fence aborts writes.
                try self.checkPresetLayout(layout)
                try self.transport.sendVendorCommand(command: 0xDD, value: 0, payload: Data([0]), port: Self.port)
                return try self.presetRead(0xDD, 0, 1, layout: layout) == Data([0])
            })
        }
    }

    private func sendVendorCommand(command: UInt8, value: UInt32, payload: Data, port: UInt8) throws {
        try writeGate.check()
        try transport.sendVendorCommand(command: command, value: value, payload: payload, port: port)
    }

    // MARK: - What unit B supports

    /// Written to unit B through the property mapper, with port byte 1.
    static let mappedWrites: Set<AudioPropertySelector> = [
        .micGain, .instrumentGain, .phantom, .phaseReverse, .highPassFilter, .softLimit,
        .groupID, .insertID, .insertReturnEnable,
        .analogIOType, .digitalRefLevel,
        .outputLevel, .outputMute, .outputDim, .outputSumToMono,
        .identify, .routing,
        .headphone1Level, .headphone2Level, .headphone1Mute, .headphone2Mute,
        .headphone1Dim, .headphone2Dim, .headphone1SumToMono, .headphone2SumToMono,
        .headphone1RoutingID, .headphone2RoutingID,
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
    /// Monitor state is recalled from hardware, not replayed from the host.
    /// Firmware indices are supplied by the existing mapper: HP1=0, HP2=1,
    /// speaker=2 (og_source/symphonymk1/ext/Symphony64/generic/Products/
    /// SymphonyIO/SymphonyIOControl.cpp:25-31,2119-2160).
    public static let monitorSelectors: Set<AudioPropertySelector> = [
        .outputLevel, .outputMute, .outputDim, .outputSumToMono, .speakerOutputMode,
        .headphone1Level, .headphone1Mute, .headphone1Dim, .headphone1SumToMono,
        .headphone2Level, .headphone2Mute, .headphone2Dim, .headphone2SumToMono,
        .headphone1RoutingID, .headphone2RoutingID,
        .activeSpeakerSet,
    ]

    static let vendorReads: Set<AudioPropertySelector> = [
        .outputLevel, .outputMute, .headphone1Level, .headphone2Level,
        .headphone1Mute, .headphone2Mute, .opticalInFormat, .opticalOutFormat,
    ]

    static let storedSelectors = Set(DeviceSettingsStore.ownedSettings).subtracting(monitorSelectors)

    private static var supported: Set<AudioPropertySelector> {
        mappedWrites.union(heldUntilDriverKeepsUnitsApart).union(vendorReads)
            .union([.primaryBoardType, .secondaryBoardType, .clockSource])
    }

    // MARK: - DeviceConnection

    public func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        try sequenceLock.withLock { try readProperty(address) }
    }

    private func readProperty(_ address: PropertyAddress) throws -> PropertyValue {
        guard isConnected else { throw DeviceConnectionError.notConnected }
        if Self.isHeadphoneSource(address.selector) {
            return try sequenceLock.withLock {
                try requireHeadphoneUnit()
                let data = try transport.readVendorCommand(command: 0x54, value: 0,
                                                            responseLength: 1, port: Self.port)
                // 0xFF is also the failed-read sentinel; never turn it into a
                // guessed 15/15 selection (see the unit A crosspoint policy).
                guard let byte = data.first, byte != 0xFF else {
                    throw DeviceConnectionError.transportError("Unit B headphone sources are unreadable")
                }
                headphoneAssignments = byte
                return .uint32(UInt32(address.selector == .headphone1RoutingID ? byte & 15 : byte >> 4))
            }
        }
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
        guard Self.vendorReads.union(Self.monitorSelectors).contains(address.selector) else {
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
        case .outputMute, .headphone1Mute, .headphone2Mute,
             .outputDim, .outputSumToMono, .headphone1Dim, .headphone2Dim,
             .headphone1SumToMono, .headphone2SumToMono:
            return .bool(byte != 0)
        case .activeSpeakerSet:
            return .uint32(UInt32(byte & 0x07))
        default:
            return .uint32(UInt32(byte))
        }
    }

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        try writeProperty(address, value: value)
    }

    func writeProperty(_ address: PropertyAddress, value: PropertyValue) throws {
        try writeGate.check()
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        try requireHeadphoneUnit()
        guard isConnected else { throw DeviceConnectionError.notConnected }
        let selector = address.selector
        if Self.isHeadphoneSource(selector) {
            try sequenceLock.withLock {
                try requireHeadphoneUnit()
                guard let id = value.asUInt32, id < 16 else {
                    throw DeviceConnectionError.typeMismatch(expected: "headphone source 0-15", got: "\(value)")
                }
                guard let previous = headphoneAssignments else {
                    throw DeviceConnectionError.transportError("Unit B headphone sources have not been read")
                }
                let headphone: SymphonyIOHeadphoneRouting.Headphone = selector == .headphone1RoutingID ? .headphone1 : .headphone2
                let byte = headphone == .headphone1 ? (previous & 0xF0) | UInt8(id) : (previous & 15) | UInt8(id << 4)
                try sendVendorCommand(command: 0x54, value: 0, payload: Data([byte]), port: Self.port)
                headphoneAssignments = byte
                try sendHeadphoneCrosspoint(headphone, sourceID: id)
            }
            notifyListeners(for: selector, value: value)
            return
        }
        if selector == .routing {
            // Selector 11 reports only a configured Symphony I/O; the driver
            // additionally checks 64-channel mode and peripheral identity.
            let unitState = state()
            let model = SymphonyRoutingModel(topology: .symphonyOnly, hostChannels: 64,
                unitBConfigured: unitState?.present == true && unitState?.info?.setupComplete == true)
            guard model.allows(.unitRouting, at: .peripheral(.init(port: .two)!)),
                  ((address.scope == .input && (192..<224).contains(address.element)) ||
                   (address.scope == .output && (224..<228).contains(address.element))) else {
                throw DeviceConnectionError.unsupportedProperty(selector)
            }
        }

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
            try? sendVendorCommand(command: ThunderboltDeviceConnection.prefixCommand, value: 0,
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
            try sendVendorCommand(command: request.request, value: DextUserClient.nValue(for: request),
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
        Self.mappedWrites.contains(address.selector)
            || (Self.driverKeepsUnitsApart && Self.heldUntilDriverKeepsUnitsApart.contains(address.selector))
    }

    public func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerLock.withLock { listeners[address.selector, default: []].append(WeakUnitListener(listener)) }
    }

    public func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        listenerLock.withLock { listeners[address.selector]?.removeAll { $0.ref === listener } }
    }

    /// Unit B shares unit A's driver client; disconnecting it only stops this
    /// connection from sending.
    public func disconnect() async { invalidate() }

    public func invalidate() {
        infoLock.withLock {
            connected = false
            infoCache = SymphonyDeviceInfo()
        }
    }

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

    private static func isHeadphoneSource(_ selector: AudioPropertySelector) -> Bool {
        selector == .headphone1RoutingID || selector == .headphone2RoutingID
    }

    private func requireHeadphoneUnit() throws {
        let s = state()
        let model = SymphonyRoutingModel(topology: .symphonyOnly, hostChannels: 64,
            unitBConfigured: s?.present == true && s?.info?.setupComplete == true)
        guard isConnected, model.allows(.monitor, at: .peripheral(.init(port: .two)!)) else {
            throw DeviceConnectionError.notConnected
        }
    }

    private func sendHeadphoneCrosspoint(_ headphone: SymphonyIOHeadphoneRouting.Headphone,
                                         sourceID: UInt32) throws {
        try requireHeadphoneUnit()
        // The card feeds B's local XLink slots 0-31. Never use card slots 32-63
        // as peripheral source bytes. The original follows the output pair:
        // og_source/maestrolink/Software/SymphonyIO_Stream.cpp:773-801.
        let left = UInt8(sourceID * 2)
        let request = SymphonyIORequestBuilder.setHeadphoneCrosspoint(
            headphone: headphone, leftSource: left, rightSource: left + 1)
        try sendVendorCommand(command: request.request, value: DextUserClient.nValue(for: request),
                                        payload: request.data, port: Self.port)
    }

    /// Re-run after B's output reset or settings replay, even with Outputs closed.
    /// Unknown sources cause no writes; this cache belongs to this connection only.
    /// Evidence: og_source/maestrolink/Software/SymphonyIO.cpp:2716-2737;
    /// og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:1003-1008.
    public func reapplyHeadphoneCrosspoints() async throws {
        try sequenceLock.withLock { try replayHeadphones() }
    }

    /// Card output reset/preset writes stay on the card; only the following
    /// headphone replay goes to the peripheral. Refuse A's channels up front.
    public func applyOutputRouting(_ routes: [ThunderboltCardRouting.Route],
                                   send: @Sendable (ThunderboltCardRouting.Route) throws -> Void) async throws {
        guard routes.allSatisfy({ (32..<64).contains($0.channel) }) else {
            throw DeviceConnectionError.transportError("Not a unit B output route")
        }
        try sequenceLock.withLock {
            for route in routes {
                try requireHeadphoneUnit()
                try send(route)
            }
            try replayHeadphones()
        }
    }

    private func replayHeadphones() throws {
        try requireHeadphoneUnit()
        guard let byte = headphoneAssignments else { return }
        try sendHeadphoneCrosspoint(.headphone1, sourceID: UInt32(byte & 15))
        try sendHeadphoneCrosspoint(.headphone2, sourceID: UInt32(byte >> 4))
    }

    /// Fresh hardware assignment, never a host-saved monitor default.
    func replayRecoveryHeadphones() throws {
        try requireHeadphoneUnit()
        let data = try transport.readVendorCommand(command: 0x54, value: 0,
                                                    responseLength: 1, port: Self.port)
        headphoneAssignments = nil
        guard let byte = data.first, byte != 0xFF else {
            throw DeviceConnectionError.transportError("Unit B headphone sources are unreadable")
        }
        headphoneAssignments = byte
        try replayHeadphones()
    }

    func finishRecovery() throws -> Bool {
        try requireHeadphoneUnit()
        try sendVendorCommand(command: 0xDD, value: 0, payload: Data([0]), port: Self.port)
        try requireHeadphoneUnit()
        return try transport.readVendorCommand(command: 0xDD, value: 0, responseLength: 1,
                                              port: Self.port) == Data([0])
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
