import CoreAudio
import Foundation
import MaestroCore

/// An in-memory ThunderBridge driver for tests: it stands where
/// `DextUserClient` does under a real `ThunderboltDeviceConnection`, keeps the
/// card's output routes and mixers as the driver would, records every write
/// that lands, can refuse chosen writes, and can change its state the way the
/// driver does (a link recovery, a card re-init, a restart).
///
/// It starts, and comes back after a link recovery or a restart, in the
/// default state of a driver before build 142: the main pair (card channels 0
/// and 1) on card mixer 1, every other channel direct, mixer inputs muted,
/// Software Return and Master at 0 dB. From build 142 the driver starts with
/// every channel direct (Drivers/Thunderbolt/Source/SymphonyThunderbridge.cpp,
/// step 21b); the older default is kept here because it is the harder case
/// and such a driver can still be the one loaded after an update.
///
/// A card re-init is different, as in the driver (`ReprogramCardAfterReset`):
/// each channel gets the last route the app wrote to it where there is one
/// and the default elsewhere, and each mixer the app has written is computed
/// again from the app's last controls. So after a re-init an output can be
/// back on a mixer route of the app's with that mixer holding whatever the
/// app last sent, complete or not.
///
/// Card channels 32-63 are unit B's: a route to one is refused unless 64
/// channels run with a unit B (the driver's `CardMixerUnitBActive` test in
/// the 0xB5 handler), and channels past 63 always.
public final class FakeThunderboltDriver: ThunderboltDriverClient, @unchecked Sendable {
    /// One thing that happened on the card, in order.
    public enum Event: Equatable, Sendable {
        /// The driver (re)programmed the card: a start, a link recovery or a
        /// card re-init. `feeds` is which card channel plays which mixer
        /// afterwards.
        case driverState(feeds: [UInt8: Int])
        /// A card output route landed (0xB5): the mixer it plays, nil for
        /// direct or disabled.
        case route(channel: UInt8, mixer: Int?, enabled: Bool)
        /// A card mixer control landed (0xB0-0xB3), or its Software Return
        /// source (0xB4, `channel` 0).
        case mixer(mixer: Int, command: UInt8, channel: UInt32, byte: UInt8)
    }

    public struct Command: Equatable, Sendable {
        public let command: UInt8
        public let value: UInt32
        public let payload: [UInt8]
        public let port: UInt8
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var commands: [Command] = []
    private var feeds: [UInt8: Int] = [0: 0, 1: 0]
    private var lastRoutes: [UInt8: ThunderboltCardRouting.Route] = [:]
    private var controls: [Int: [UInt64: UInt8]] = [:]
    private var nonce: UInt64 = 0x1000
    private var recoveryCount: UInt32 = 0
    private var cardReinitCount: UInt32 = 0
    private var held = [false, false]
    private var connected = true

    public let hardwareWriteGate = HardwareWriteGate()
    /// Return true to make this write fail (it does not land and is not logged).
    public var shouldFail: (@Sendable (Command) -> Bool)?
    /// Called after each write that landed, outside the driver's lock.
    public var onWrite: (@Sendable (Event) -> Void)?
    /// Called before each vendor read with its command, outside the lock
    /// (a test can make a read slow).
    public var onRead: (@Sendable (UInt8) -> Void)?
    public var boards: (primary: UInt8?, secondary: UInt8?)?
    public var unitB: UnitBState?
    public var port2: SecondPortState?
    public var portSelectionOverride: UInt32? = PortSelection.port1.rawValue
    public var linkReported = true
    /// The Volume Keys output choices that reached the driver (selector 15).
    public struct MonitorOutputCall: Equatable, Sendable {
        public let unit: DeviceUnit
        public let output: KeyboardVolumeOutput
        public init(unit: DeviceUnit, output: KeyboardVolumeOutput) { self.unit = unit; self.output = output }
    }
    private var monitorOutputs: [MonitorOutputCall] = []
    public var monitorOutputCalls: [MonitorOutputCall] { lock.withLock { monitorOutputs } }
    /// False: the driver refuses the choice (unit B not configured, a failed read).
    public var acceptsMonitorOutput = true
    /// The build the driver reports for itself; nil = it does not answer.
    public var driverBuild: UInt32? = 200
    /// VBus (selector 16): the sizes that reached the driver, and its state.
    private var vbusSets: [VBusChannels] = []
    public var vbusSetCalls: [VBusChannels] { lock.withLock { vbusSets } }
    public var acceptsVBus = true
    /// Every selector-16 call that reached the driver client, whatever came of it.
    private var vbusCalls = 0
    public var vbusCallCount: Int { lock.withLock { vbusCalls } }
    /// False: a request stays "requested" until `performVBusChange()` (Core
    /// Audio has not made the configuration change yet).
    public var vbusPublishesAtOnce = true
    /// That many of the next sizes cannot be published: VBus is off and the
    /// driver's failed flag is set, as when AddStream fails.
    public var vbusFailPublishes = 0
    public var vbusPublished: UInt32 = 0
    public var vbusRequested: UInt32 = 0
    public var vbusFlags: UInt32 = 0
    public var vbusHardwareChannels: UInt32 = 32
    public func performVBusChange() { lock.withLock { vbusPublished = vbusRequested } }

    public init(primary: IOCardType = .analogADDA16, secondary: IOCardType = .analogADDA16) {
        boards = (primary.rawValue, secondary.rawValue)
        events.append(.driverState(feeds: feeds))
    }

    // MARK: Test controls

    public var log: [Event] { lock.withLock { events } }
    public var sent: [Command] { lock.withLock { commands } }
    /// Which mixer each card channel plays now (absent: direct or disabled).
    public var mixerFeeds: [UInt8: Int] { lock.withLock { feeds } }
    /// The last byte written to one control of a mixer, nil when the driver
    /// still has its default there.
    public func control(mixer: Int, command: UInt8, channel: UInt32) -> UInt8? {
        lock.withLock { controls[mixer]?[UInt64(command) << 32 | UInt64(channel)] }
    }

    /// The last route written to each card channel since the driver last
    /// (re)programmed the card.
    public var routes: [UInt8: ThunderboltCardRouting.Route] { lock.withLock { lastRoutes } }

    /// The driver reports that it holds app state for both mixers (an
    /// earlier session wrote them), which proves nothing about whose.
    public func claimAppState() { lock.withLock { held = [true, true] } }

    /// The driver keeps running but an earlier session left this route.
    public func seedRoute(channel: UInt8, mixer: Int) {
        lock.withLock {
            feeds[channel] = mixer
            events.append(.driverState(feeds: feeds))
        }
    }

    private func reprogramLocked() {
        feeds = [0: 0, 1: 0]
        lastRoutes = [:]
        events.append(.driverState(feeds: feeds))
    }

    /// 64 channels with a unit B: its card channels (32-63) exist.
    private var unitBActiveLocked: Bool {
        portSelectionOverride == PortSelection.ports1And2.rawValue && unitB?.present == true
    }

    /// An in-place link recovery: the default table is back on the card.
    public func simulateLinkRecovery() { lock.withLock { recoveryCount += 1; reprogramLocked() } }
    /// The card was re-initialised after a power cycle: the app's last routes
    /// where it wrote one, the default elsewhere; a mixer the app wrote keeps
    /// the app's last controls, one it never wrote is at the default.
    public func simulateCardReinit() {
        lock.withLock {
            cardReinitCount += 1
            var now: [UInt8: Int] = [:]
            for channel in UInt8(0)..<64 {
                if let route = lastRoutes[channel] {
                    if let mixer = CardOutputTableOrder.mixer(of: route) { now[channel] = mixer }
                } else if channel < 2 {
                    now[channel] = 0
                }
            }
            feeds = now
            for mixer in 0..<2 where !held[mixer] { controls[mixer] = nil }
            events.append(.driverState(feeds: feeds))
        }
    }
    /// A new driver instance.
    public func simulateDriverRestart() {
        lock.withLock {
            nonce += 1; recoveryCount = 0; cardReinitCount = 0; held = [false, false]; controls = [:]
            vbusPublished = 0; vbusRequested = 0; vbusFlags = 0   // a new driver starts without VBus
            reprogramLocked()
        }
    }

    // MARK: ThunderboltDriverClient

    public var isConnected: Bool { lock.withLock { connected } }
    public func connect(audioDeviceID: AudioDeviceID) { lock.withLock { connected = true } }
    public func disconnect() { lock.withLock { connected = false } }

    public func sendVendorCommand(command: UInt8, value: UInt32, payload: Data, port: UInt8) throws {
        try hardwareWriteGate.check()
        let sent = Command(command: command, value: value, payload: Array(payload), port: port)
        if let shouldFail, shouldFail(sent) {
            throw DeviceConnectionError.transportError("fake driver: write refused")
        }
        let event: Event? = try lock.withLock {
            guard connected else { throw DeviceConnectionError.notConnected }
            if command == ThunderboltCardRouting.outputRouteCommand, port == 0 {
                // kIOReturnBadArgument in the driver: nothing is written.
                guard payload.count == 3, sent.payload[0] < 64,
                      sent.payload[0] < ThunderboltCardRouting.unitBChannelBase || unitBActiveLocked else {
                    throw DeviceConnectionError.transportError(
                        "fake driver: card output route refused (channel \(sent.payload.first ?? 0xFF))")
                }
            }
            commands.append(sent)
            let readKey = Self.readKey(command: command, value: value, port: port)
            if readReplies[readKey] != nil, !sent.payload.isEmpty { readReplies[readKey] = sent.payload }
            var event: Event?
            switch command {
            case ThunderboltCardRouting.outputRouteCommand where payload.count == 3 && port == 0:
                let route = ThunderboltCardRouting.Route(channel: sent.payload[0], slot: sent.payload[1],
                                                         enabled: sent.payload[2] != 0)
                let mixer = CardOutputTableOrder.mixer(of: route)
                feeds[route.channel] = mixer
                lastRoutes[route.channel] = route
                event = .route(channel: route.channel, mixer: mixer, enabled: route.enabled)
            case 0xB0...0xB4 where port == 0 && (1...2).contains(value >> 16):
                let mixer = Int(value >> 16) - 1
                let channel = value & 0xFFFF
                let byte = sent.payload.first ?? 0
                controls[mixer, default: [:]][UInt64(command) << 32 | UInt64(channel)] = byte
                if command != 0xB4 { held[mixer] = true }
                event = .mixer(mixer: mixer, command: command, channel: channel, byte: byte)
            default: break
            }
            if let event { events.append(event) }
            return event
        }
        if let event { onWrite?(event) }
    }

    public func readVendorCommand(command: UInt8, value: UInt32, responseLength: Int, port: UInt8) throws -> Data {
        guard isConnected else { throw DeviceConnectionError.notConnected }
        onRead?(command)
        return try lock.withLock {
            let key = Self.readKey(command: command, value: value, port: port)
            if refusedReads.contains(key) {
                throw DeviceConnectionError.transportError("fake driver: read refused")
            }
            if let reply = readReplies[key] {
                var data = Data(reply.prefix(responseLength))
                if data.count < responseLength { data.append(Data(count: responseLength - data.count)) }
                return data
            }
            return Data(count: responseLength)
        }
    }

    // MARK: Unit reads (tests)

    private var readReplies: [UInt64: [UInt8]] = [:]
    private var refusedReads: Set<UInt64> = []

    private static func readKey(command: UInt8, value: UInt32, port: UInt8) -> UInt64 {
        UInt64(command) << 40 | UInt64(port) << 32 | UInt64(value)
    }

    /// What the unit answers to one vendor read. Unseeded reads answer zeros,
    /// as before. A seeded value is also what a later write of the same
    /// command and value leaves there, so a level written reads back.
    public func seedRead(command: UInt8, value: UInt32 = 0, port: UInt8 = 0, reply: [UInt8]) {
        lock.withLock { readReplies[Self.readKey(command: command, value: value, port: port)] = reply }
    }

    /// The read throws, as when the unit does not answer.
    public func refuseRead(command: UInt8, value: UInt32 = 0, port: UInt8 = 0) {
        lock.withLock { _ = refusedReads.insert(Self.readKey(command: command, value: value, port: port)) }
    }

    /// The converter flags `readConverterState` reports (0: a Symphony I/O).
    public var converterFlags: UInt32 = 0

    public func readLinkState() -> LinkState? {
        lock.withLock {
            guard connected, linkReported else { return nil }
            return LinkState(state: .up, clockPresent: true, ioRunning: true, irqCount: 1,
                             recoveryCount: recoveryCount, hwSuspended: false, linkConfigured: true,
                             lastClockReg: 0, watchTicks: 0, audioWraps: 0, cardReinitCount: cardReinitCount,
                             mixerInstance: DriverMixerInstance(nonce: nonce, holdsAppState: held))
        }
    }

    public func setMonitorDevice(_ unit: DeviceUnit) -> Bool { true }
    public func setMonitorOutput(_ output: KeyboardVolumeOutput, unit: DeviceUnit) -> Bool {
        lock.withLock {
            guard connected, acceptsMonitorOutput else { return false }
            monitorOutputs.append(MonitorOutputCall(unit: unit, output: output))
            return true
        }
    }
    public func vbus(_ channels: VBusChannels?) -> VBusState? {
        lock.withLock {
            vbusCalls += 1
            guard connected, let build = driverBuild, build >= VBusChannels.requiredDriverBuild else { return nil }
            if let channels {
                guard acceptsVBus else { return nil }
                vbusSets.append(channels)
                vbusFlags &= ~VBusState.publishFailedFlag   // a new request clears the flag
                if channels != .none, vbusFailPublishes > 0 {
                    // The configuration change could not add the streams.
                    vbusFailPublishes -= 1
                    vbusRequested = 0; vbusPublished = 0
                    vbusFlags |= VBusState.publishFailedFlag
                } else {
                    vbusRequested = channels.rawValue
                    if vbusPublishesAtOnce { vbusPublished = channels.rawValue }
                }
            }
            return VBusState(published: vbusPublished, requested: vbusRequested,
                             firstChannel: vbusPublished > 0 ? vbusHardwareChannels + 1 : 0, flags: vbusFlags)
        }
    }
    public func readMeters() -> [UInt32]? { nil }
    public func probeHardwareResponse() -> Bool { isConnected }
    public func readDriverBuild() -> UInt32? { driverBuild }
    public func readPort2State() -> SecondPortState? { port2 }
    public func readConverterState() -> ConverterState? {
        var words = Array(repeating: UInt32(0), count: ConverterState.wordCount)
        words[2] = converterFlags
        return ConverterState.decode(words)
    }
    public func setConverterConfig(_ config: UInt32) -> Bool { false }
    public func retireForUpgrade(replacementBuild: UInt32) -> DextUserClient.RetireReply { .refused(0) }
    public func readTimingHealth() -> TimingHealth? { nil }
    public func readBoardTypes() -> (primary: UInt8?, secondary: UInt8?)? { boards }
    public func readUnitBState() -> UnitBState? { unitB }
    /// Selector 17. Unless a test sets `channelOrder`, what a build-150
    /// driver would report from `boards` and `unitB`: analog first where
    /// both of a unit's types were read and are known, card by card for unit
    /// A otherwise; nil from a driver older than 150.
    public var channelOrder: ThunderboltAppliedChannelOrder?
    public func readChannelOrder() -> ThunderboltAppliedChannelOrder? {
        if let channelOrder { return channelOrder }
        guard let build = driverBuild, build == 0 || build >= 150 else { return nil }
        func unit(_ types: [UInt8?], configured: Bool) -> ThunderboltAppliedChannelOrder.Unit {
            guard configured else { return .init(order: nil, slot1: nil, slot2: nil) }
            let cards = types.map { $0.flatMap(IOCardType.init(rawValue:)) }
            let known = cards.allSatisfy { $0 != nil }
            return .init(order: known ? .analogFirst : .cardByCard, slot1: cards[0], slot2: cards[1])
        }
        let b = unitB
        return ThunderboltAppliedChannelOrder(
            unitA: unit([boards?.primary, boards?.secondary], configured: true),
            unitB: unit((0..<2).map { i in
                guard let b, b.boardValid.count > i, b.boardValid[i] != 0, b.boardType.count > i else { return nil }
                return b.boardType[i]
            }, configured: b?.present == true))
    }
    public func publishObservedMicGain(port: UInt8, channel: Int, lane: UInt32, gain: Double) -> Bool { false }
    public func loopSync(_ settings: LoopSyncSettings?) throws -> LoopSyncState {
        throw DeviceConnectionError.notConnected
    }
}

/// Replays a fake driver's log and reports every point at which the safety
/// rule was broken:
///
/// * a route was written that plays a mixer which was not written in full
///   (every required control) in the driver state then serving;
/// * a control of a mixer was written while an output was playing that mixer
///   and it had not been written in full (this is what made an unmute audible
///   on the driver's own main-pair route);
/// * at the end of the log, an output is still playing a mixer that was not
///   written in full (`settled`).
///
/// "Written in full" counts only controls written since the driver last
/// (re)programmed the card, and only a run of them that began while the mixer
/// was on no output.
public enum CardWriteLogChecker {
    /// A control of a mixer: its command and channel.
    public struct Control: Hashable, Sendable {
        public let command: UInt8
        public let channel: UInt32
        public init(command: UInt8, channel: UInt32) { self.command = command; self.channel = channel }
    }

    /// The controls a complete write of each mixer of this layout reaches.
    public static func required(layout: CardLayout, second: CardLayout? = nil,
                                routes: [CardMixerReplay.InputRoute]? = nil,
                                secondRoutes: [CardMixerReplay.InputRoute]? = nil) -> [Int: Set<Control>] {
        var result: [Int: Set<Control>] = [:]
        for mixer in 0..<2 {
            result[mixer] = Set(CardMixerReplay.requiredAddresses(mixer: mixer, layout: layout, second: second,
                                                                      routes: routes, secondRoutes: secondRoutes).map {
                let command: UInt8 = switch $0.selector {
                case .mixerChannelLevel: 0xB0
                case .mixerChannelPan: 0xB1
                case .mixerChannelSolo: 0xB2
                default: 0xB3
                }
                return Control(command: command, channel: $0.element & 0xFFFF)
            })
        }
        return result
    }

    public static func violations(_ log: [FakeThunderboltDriver.Event], required: [Int: Set<Control>],
                                  settled: Bool = true) -> [String] {
        var problems: [String] = []
        var feeds: [UInt8: Int] = [:]
        var seen: [Int: Set<Control>] = [:]
        var written: Set<Int> = []
        func fed(_ mixer: Int) -> [UInt8] { feeds.filter { $0.value == mixer }.keys.sorted() }
        for (index, event) in log.enumerated() {
            switch event {
            case .driverState(let now):
                feeds = now; seen = [:]; written = []
            case .route(let channel, let mixer, _):
                if let mixer, !written.contains(mixer) {
                    problems.append("event \(index): output channel \(channel) routed from mixer \(mixer + 1) before that mixer was written")
                }
                feeds[channel] = mixer
            case .mixer(let mixer, let command, let channel, _):
                if !written.contains(mixer) {
                    let outputs = fed(mixer)
                    if !outputs.isEmpty {
                        problems.append("event \(index): mixer \(mixer + 1) control 0x\(String(command, radix: 16))/\(channel) written while it played on output channel(s) \(outputs) and was not written")
                        seen[mixer] = []
                        continue
                    }
                    seen[mixer, default: []].insert(Control(command: command, channel: channel))
                    if let needed = required[mixer], needed.isSubset(of: seen[mixer] ?? []) { written.insert(mixer) }
                }
            }
        }
        if settled {
            for (channel, mixer) in feeds.sorted(by: { $0.key < $1.key }) where !written.contains(mixer) {
                problems.append("end: output channel \(channel) is still on mixer \(mixer + 1), which was not written")
            }
        }
        return problems
    }
}
