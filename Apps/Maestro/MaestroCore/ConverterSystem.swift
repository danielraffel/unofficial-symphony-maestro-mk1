import Foundation

/// The driver's converter report (user-client selector 9,
/// `SymphonyConverterStateOutput`, dext 131+): 28 words. Older drivers reject
/// the selector, and the app then uses the link state's probe word and
/// `SecondPortState`.
public struct ConverterState: Sendable, Equatable {
    /// Words in `SymphonyConverterStateOutput` (112 bytes). The driver checks the size exactly.
    public static let wordCount = 28

    // flags (kSymphonyConv*)
    public static let flagPort1Converters: UInt32 = 0x01
    public static let flagPort2Converters: UInt32 = 0x02
    public static let flagClockExternal: UInt32 = 0x04
    public static let flagHealthy: UInt32 = 0x08
    public static let flagRecoveryPending: UInt32 = 0x10
    public static let flagRoutingApplied: UInt32 = 0x20

    // unit[port][n] (kSymphonyConvUnit*): bits 7:0 INQUIRE, 15:8 XTD_INQUIRE, then these.
    public static let unitInquireOK: UInt32 = 0x0001_0000
    public static let unitXtdOK: UInt32 = 0x0002_0000
    public static let unitAddressed: UInt32 = 0x0004_0000
    public static let unitAuthRan: UInt32 = 0x0008_0000
    public static let unitAuthOK: UInt32 = 0x0010_0000
    public static let unitTypeIsDA: UInt32 = 0x0020_0000
    public static let unitIsR200: UInt32 = 0x0040_0000

    public var version: UInt32
    public var flags: UInt32
    /// Per port, 0-4.
    public var unitCount: [Int]
    /// Per port, four words each, nearest unit first.
    public var units: [[UInt32]]
    /// Last WCLK_PHASE reading per port; byte n is unit n+1.
    public var phase: [UInt32]
    public var healthTicks: UInt32
    public var phaseErrors: UInt32
    public var unlocks: UInt32
    public var recoveries: UInt32
    /// Converter latency reported to Core Audio, in samples before the frame.
    public var latencyIn: UInt32
    public var latencyOut: UInt32
    public var hostInputs: UInt32
    public var hostOutputs: UInt32
    /// The last `SymphonyConverterConfigInput.config` the driver applied.
    public var config: UInt32

    public init(version: UInt32 = 1, flags: UInt32 = 0, unitCount: [Int] = [0, 0],
                units: [[UInt32]] = [[0, 0, 0, 0], [0, 0, 0, 0]], phase: [UInt32] = [0, 0],
                healthTicks: UInt32 = 0, phaseErrors: UInt32 = 0, unlocks: UInt32 = 0,
                recoveries: UInt32 = 0, latencyIn: UInt32 = 0, latencyOut: UInt32 = 0,
                hostInputs: UInt32 = 0, hostOutputs: UInt32 = 0, config: UInt32 = 0) {
        self.version = version; self.flags = flags; self.unitCount = unitCount; self.units = units
        self.phase = phase; self.healthTicks = healthTicks; self.phaseErrors = phaseErrors
        self.unlocks = unlocks; self.recoveries = recoveries; self.latencyIn = latencyIn
        self.latencyOut = latencyOut; self.hostInputs = hostInputs; self.hostOutputs = hostOutputs
        self.config = config
    }

    /// Decode the driver's 28 words. Nil when the size is wrong or the status
    /// word is nonzero, both of which mean the selector did not answer.
    public static func decode(_ words: [UInt32]) -> ConverterState? {
        guard words.count == wordCount, words[0] == 0 else { return nil }
        return ConverterState(
            version: words[1], flags: words[2],
            unitCount: [Int(min(words[3], 4)), Int(min(words[4], 4))],
            units: [Array(words[5..<9]), Array(words[9..<13])],
            phase: [words[13], words[14]],
            healthTicks: words[15], phaseErrors: words[16], unlocks: words[17], recoveries: words[18],
            latencyIn: words[19], latencyOut: words[20],
            hostInputs: words[21], hostOutputs: words[22], config: words[23])
    }

    public var port1Converters: Bool { flags & Self.flagPort1Converters != 0 }
    public var port2Converters: Bool { flags & Self.flagPort2Converters != 0 }
    public var clockExternal: Bool { flags & Self.flagClockExternal != 0 }

    /// The flags in words, for the copied details.
    public var flagsText: String {
        var names: [String] = []
        if port1Converters { names.append("port 1 converters") }
        if port2Converters { names.append("port 2 converters") }
        if clockExternal { names.append("external clock") }
        if flags & Self.flagHealthy != 0 { names.append("healthy") }
        if flags & Self.flagRecoveryPending != 0 { names.append("recovery pending") }
        if flags & Self.flagRoutingApplied != 0 { names.append("routing applied") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

/// The Device Type choice for the two routings that do not say which unit
/// they are, as the original's "Device Type" menu offered it.
public enum ConverterDeviceType: String, Sendable, CaseIterable, Identifiable {
    /// Routing 0x0F: a DD-16X, or an AD-16X in Advanced Routing (the original's default).
    case ddAsAD = "ad"
    /// Routing 0x0F: a DA-16X in Advanced Routing.
    case ddAsDA = "da"
    /// Routing 0x05: a Rosetta 800 (default).
    case rosetta800 = "r800"
    /// Routing 0x05: a Rosetta 200.
    case rosetta200 = "r200"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ddAsAD: return "DD-16X / AD-16X (Advanced Routing)"
        case .ddAsDA: return "DA-16X (Advanced Routing)"
        case .rosetta800: return "Rosetta 800"
        case .rosetta200: return "Rosetta 200"
        }
    }

    /// The choices for a routing byte, default first. Empty for a routing
    /// that needs no choice.
    public static func choices(routing: UInt8) -> [ConverterDeviceType] {
        switch routing {
        case ConverterRules.routingDD: return [.ddAsAD, .ddAsDA]
        case ConverterRules.routingRosetta: return [.rosetta800, .rosetta200]
        default: return []
        }
    }

    /// One unit's place in `ConverterConfig.deviceTypes`, and its older
    /// UserDefaults key: `converterDeviceType.p1.u2` for port 1, unit address 2.
    /// Saved now per unit with its routing (`ConverterConfig.deviceTypeKey`).
    public static func defaultsKey(port: Int, address: Int) -> String {
        "converterDeviceType.p\(port + 1).u\(address)"
    }
}

/// The user's converter choices, stored per port and unit address, and the
/// `SymphonyConverterConfigInput.config` word they make.
public struct ConverterConfig: Sendable, Equatable {
    public static let clockExternalBit: UInt32 = 0x01
    public static let ddAsDAShift: UInt32 = 8
    public static let r200Shift: UInt32 = 16
    /// The older UserDefaults key of the clock choice (one for every chain),
    /// and the start of the per-chain keys (`clockKey(for:simulated:)`).
    public static let clockDefaultsKey = "converterClockExternal"

    /// Units (by `ConverterDeviceType.defaultsKey`) whose choice is not the default.
    public var deviceTypes: [String: ConverterDeviceType]
    /// Nil until the user has picked a clock source for converters.
    public var clockExternal: Bool?

    public init(deviceTypes: [String: ConverterDeviceType] = [:], clockExternal: Bool? = nil) {
        self.deviceTypes = deviceTypes
        self.clockExternal = clockExternal
    }

    // MARK: Where the choices are kept
    //
    // A Device Type is kept for the unit it was made for: its port, address
    // and routing byte, so another unit at that address does not take it. (Not
    // the whole chain: the chain's signature changes with the Device Type
    // itself and with every 32/64 switch.) The clock is kept for port 1's
    // chain, the converters that own it. A simulation keeps its own (`sim`).
    // The older unscoped keys are moved to the first unit or chain that
    // reads them, once.

    /// Storage key of one unit's Device Type.
    public static func deviceTypeKey(port: Int, address: Int, routing: UInt8, simulated: Bool) -> String {
        let hex = String(routing, radix: 16)
        return "converterDeviceType." + (simulated ? "sim." : "")
            + "p\(port + 1).u\(address).r" + (hex.count < 2 ? "0" + hex : hex)
    }

    /// Storage key of the clock choice for port 1's chain, nil without one.
    public static func clockKey(for system: ConverterSystem, simulated: Bool) -> String? {
        let chain = system.clockChainSignature
        guard !chain.isEmpty else { return nil }
        return clockDefaultsKey + "." + (simulated ? "sim:" : "") + chain
    }

    /// The choices kept for these units.
    public static func load(_ defaults: UserDefaults = .standard, for system: ConverterSystem,
                            simulated: Bool) -> ConverterConfig {
        var types: [String: ConverterDeviceType] = [:]
        for unit in system.ports[0] + system.ports[1] where !unit.deviceTypeChoices.isEmpty {
            let key = deviceTypeKey(port: unit.port, address: unit.address, routing: unit.routing,
                                    simulated: simulated)
            if !simulated {
                migrate(from: ConverterDeviceType.defaultsKey(port: unit.port, address: unit.address),
                        to: key, defaults: defaults)
            }
            if let raw = defaults.string(forKey: key), let type = ConverterDeviceType(rawValue: raw),
               unit.deviceTypeChoices.contains(type) {
                types[ConverterDeviceType.defaultsKey(port: unit.port, address: unit.address)] = type
            }
        }
        var clock: Bool?
        if let key = clockKey(for: system, simulated: simulated) {
            if !simulated { migrate(from: clockDefaultsKey, to: key, defaults: defaults) }
            clock = defaults.object(forKey: key) as? Bool
        }
        return ConverterConfig(deviceTypes: types, clockExternal: clock)
    }

    public static func saveDeviceType(_ type: ConverterDeviceType, unit: ConverterUnit, simulated: Bool,
                                      defaults: UserDefaults = .standard) {
        defaults.set(type.rawValue, forKey: deviceTypeKey(port: unit.port, address: unit.address,
                                                          routing: unit.routing, simulated: simulated))
    }

    public static func saveClockExternal(_ external: Bool, for system: ConverterSystem, simulated: Bool,
                                         defaults: UserDefaults = .standard) {
        guard let key = clockKey(for: system, simulated: simulated) else { return }
        defaults.set(external, forKey: key)
    }

    private static func migrate(from legacy: String, to key: String, defaults: UserDefaults) {
        guard defaults.object(forKey: key) == nil, let value = defaults.object(forKey: legacy) else { return }
        defaults.set(value, forKey: key)
        defaults.removeObject(forKey: legacy)
    }

    public func deviceType(port: Int, address: Int) -> ConverterDeviceType? {
        deviceTypes[ConverterDeviceType.defaultsKey(port: port, address: address)]
    }

    /// Whether a routing-0x0F unit is used as an AD (the default).
    public func ddIsAD(port: Int, address: Int) -> Bool {
        deviceType(port: port, address: address) != .ddAsDA
    }

    public func isR200(port: Int, address: Int) -> Bool {
        deviceType(port: port, address: address) == .rosetta200
    }

    /// The config word. Mask bit n = port * 4 + (address - 1). With no stored
    /// clock choice, bit 0 keeps `currentClockExternal` (what the driver runs now).
    public func word(currentClockExternal: Bool = false) -> UInt32 {
        var word: UInt32 = (clockExternal ?? currentClockExternal) ? Self.clockExternalBit : 0
        for port in 0..<2 {
            for address in 1...ConverterRules.maxUnitsPerPort {
                let bit = UInt32(port * 4 + address - 1)
                switch deviceType(port: port, address: address) {
                case .ddAsDA: word |= 1 << (Self.ddAsDAShift + bit)
                case .rosetta200: word |= 1 << (Self.r200Shift + bit)
                default: break
                }
            }
        }
        return word
    }
}

/// One converter unit.
public struct ConverterUnit: Sendable, Equatable {
    /// 0 or 1.
    public let port: Int
    /// 1-4, nearest the computer first.
    public let address: Int
    /// The driver's unit word, nil when the unit came from the older probe word
    /// or a simulation.
    public let word: UInt32?
    public let inquire: UInt8
    public let xtd: UInt8
    public let inquireOK: Bool
    public let xtdOK: Bool
    public let addressed: Bool
    /// Nil when the authentication exchange did not run (or is not reported).
    public let authOK: Bool?
    public let routing: UInt8
    public let kind: ConverterKind
    /// Routing 0x05 named Rosetta 200.
    public let isR200: Bool
    /// X-Symphony firmware; 0.0 when unknown.
    public let firmwareMajor: UInt8
    public let firmwareMinor: UInt8

    public init(port: Int, address: Int, word: UInt32? = nil, inquire: UInt8, xtd: UInt8,
                inquireOK: Bool = true, xtdOK: Bool, addressed: Bool = true, authOK: Bool? = nil,
                ddIsAD: Bool = true, isR200: Bool = false) {
        self.port = port; self.address = address; self.word = word
        self.inquire = inquire; self.xtd = xtd; self.inquireOK = inquireOK; self.xtdOK = xtdOK
        self.addressed = addressed; self.authOK = authOK
        let routing = ConverterRules.routing(inquire: inquire, xtd: xtdOK ? xtd : 0)
        self.routing = routing
        self.kind = ConverterRules.kind(routing: routing, ddIsAD: ddIsAD)
        self.isR200 = routing == ConverterRules.routingRosetta && isR200
        // As the original (XLink.cpp:1503-1548, SymphonyController.cpp:2573-2588):
        // major from XTD_INQUIRE, 0 when the unit does not answer it (the oldest
        // firmware), minor from INQUIRE. v0.N is real and out of date.
        self.firmwareMajor = xtdOK ? xtd & 0x0F : 0
        self.firmwareMinor = inquireOK ? inquire & 0x0F : 0
    }

    /// A unit from the driver's unit word (selector 9).
    public init(port: Int, address: Int, word: UInt32) {
        let authRan = word & ConverterState.unitAuthRan != 0
        self.init(port: port, address: address, word: word,
                  inquire: UInt8(word & 0xFF), xtd: UInt8((word >> 8) & 0xFF),
                  inquireOK: word & ConverterState.unitInquireOK != 0,
                  xtdOK: word & ConverterState.unitXtdOK != 0,
                  addressed: word & ConverterState.unitAddressed != 0,
                  authOK: authRan ? word & ConverterState.unitAuthOK != 0 : nil,
                  ddIsAD: word & ConverterState.unitTypeIsDA == 0,
                  isR200: word & ConverterState.unitIsR200 != 0)
    }

    public var firmwareKnown: Bool { firmwareMajor != 0 || firmwareMinor != 0 }
    public var firmwareOutOfDate: Bool {
        ConverterRules.firmwareOutOfDate(major: firmwareMajor, minor: firmwareMinor)
    }
    public var firmwareText: String {
        firmwareKnown ? "X-Symphony v\(firmwareMajor).\(firmwareMinor)" : "firmware unknown"
    }

    /// The model, as the Device Type choice makes it.
    public var modelName: String {
        switch kind {
        case .rosetta: return isR200 ? "Rosetta 200" : "Rosetta 800"
        case .ad16x: return "AD-16X"
        case .da16x: return "DA-16X"
        case .ddAsAD: return ConverterDeviceType.ddAsAD.label
        case .ddAsDA: return ConverterDeviceType.ddAsDA.label
        case .none, .unknown:
            return "Not recognised (routing 0x" + String(routing, radix: 16) + ")"
        }
    }

    public var channelsText: String? {
        let (i, o) = ConverterRules.channels(kind)
        switch (i, o) {
        case (0, 0): return nil
        case (_, 0): return "\(i) inputs"
        case (0, _): return "\(o) outputs"
        default: return "\(i) inputs, \(o) outputs"
        }
    }

    /// "AD-16X (16 inputs)".
    public var displayName: String {
        channelsText.map { "\(modelName) (\($0))" } ?? modelName
    }

    /// "AD-16X (16 inputs), X-Symphony v2.7".
    public var rowValue: String { displayName + ", " + firmwareText }

    /// The Device Type choices for this unit, default first; empty when the
    /// routing says what the unit is.
    public var deviceTypeChoices: [ConverterDeviceType] { ConverterDeviceType.choices(routing: routing) }

    /// The Device Type in effect.
    public var deviceType: ConverterDeviceType? {
        switch routing {
        case ConverterRules.routingDD: return kind == .ddAsDA ? .ddAsDA : .ddAsAD
        case ConverterRules.routingRosetta: return isR200 ? .rosetta200 : .rosetta800
        default: return nil
        }
    }

    /// "AD-16X (port 1, unit 2)".
    public var shortName: String {
        let model: String
        switch kind {
        case .ddAsAD: model = "DD-16X"
        case .ddAsDA: model = "DA-16X"
        default: model = modelName
        }
        return "\(model) (port \(port + 1), unit \(address))"
    }

    public var authText: String {
        guard let authOK else { return "authentication not run" }
        return authOK ? "authentication verified" : "authentication failed"
    }

    /// The legacy single-unit description, for code that still takes `ConnectedUnit`.
    var legacy: ConnectedUnit {
        switch kind {
        case .ad16x: return .ad16x
        case .da16x: return .da16x
        case .ddAsAD, .ddAsDA: return .dd16x
        case .rosetta: return .rosetta800
        case .none, .unknown: return .unrecognised(reply: inquire)
        }
    }
}

/// Every converter unit the driver found, on both ports, with what the app
/// needs to lay out, name and meter their channels.
public struct ConverterSystem: Sendable, Equatable {
    public enum Source: String, Sendable { case driver, probeWord, simulation }

    public let source: Source
    /// Units per port, nearest first.
    public let ports: [[ConverterUnit]]
    /// Whether port 2's units carry audio (the driver reports port-2 converters,
    /// which it does only while 64 channels run).
    public let port2Counted: Bool
    /// The driver's report, for a driver with selector 9.
    public let state: ConverterState?

    public init(source: Source, ports: [[ConverterUnit]], port2Counted: Bool, state: ConverterState? = nil) {
        self.source = source
        self.ports = [ports.first ?? [], ports.count > 1 ? ports[1] : []]
        self.port2Counted = port2Counted
        self.state = state
    }

    /// From the driver's report. Nil unless a port is identified as
    /// converters. With a Symphony I/O on port 1 and converters on port 2,
    /// port 1 lists no units (the Symphony I/O is not a converter), so
    /// `connectedUnit` stays nil and everything Symphony I/O keeps working;
    /// port 2's units get their Device Info rows and Device Type choices.
    public init?(state: ConverterState) {
        guard state.port1Converters || state.port2Converters else { return nil }
        let ports = (0..<2).map { port -> [ConverterUnit] in
            if port == 0 && !state.port1Converters { return [] }
            return (0..<state.unitCount[port]).map { n in
                ConverterUnit(port: port, address: n + 1, word: state.units[port][n])
            }
        }
        self.init(source: .driver, ports: ports, port2Counted: state.port2Converters, state: state)
    }

    /// From the older drivers' probe word (link state word 15): unit 1's
    /// INQUIRE and XTD replies, then a bank nibble for units 2-4. Port 1 only.
    /// Nil when the driver did not probe or nothing answered.
    public init?(probeWord: UInt32, config: ConverterConfig = ConverterConfig()) {
        guard probeWord & 0x8000_0000 != 0, probeWord & 0x4000_0000 != 0 else { return nil }
        let inquire = UInt8(probeWord & 0xFF)
        let xtdOK = probeWord & 0x2000_0000 != 0
        let xtd = UInt8((probeWord >> 8) & 0xFF)
        guard inquire >> 4 != 0 else { return nil }
        var units = [ConverterUnit(port: 0, address: 1, inquire: inquire, xtd: xtd, xtdOK: xtdOK,
                                   ddIsAD: config.ddIsAD(port: 0, address: 1),
                                   isR200: config.isR200(port: 0, address: 1))]
        for index in 0..<3 {
            let nibble = UInt8((probeWord >> (16 + 4 * UInt32(index))) & 0xF)
            guard nibble != 0 else { break }
            let address = index + 2
            units.append(ConverterUnit(port: 0, address: address, inquire: nibble << 4, xtd: 0, xtdOK: false,
                                       ddIsAD: config.ddIsAD(port: 0, address: address),
                                       isR200: config.isR200(port: 0, address: address)))
        }
        self.init(source: .probeWord, ports: [units, []], port2Counted: false)
    }

    /// Debug only: `-MaestroSimulateConnectedUnit` names, `+` between units and
    /// `|` between ports, e.g. `ad16x+da16x|ad16x+da16x`. A second port means
    /// 64 channels are running. Names: `ad16x`, `da16x`, `dd16x`, `rosetta800`,
    /// `rosetta200`; at most four per port.
    public init?(simulationName: String, config: ConverterConfig = ConverterConfig()) {
        let portNames = simulationName.lowercased().split(separator: "|", omittingEmptySubsequences: false)
        guard (1...2).contains(portNames.count) else { return nil }
        var ports: [[ConverterUnit]] = []
        for (port, text) in portNames.enumerated() {
            let names = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !names.isEmpty, names.count <= ConverterRules.maxUnitsPerPort else { return nil }
            var units: [ConverterUnit] = []
            for (n, name) in names.enumerated() {
                let address = n + 1
                // INQUIRE high nibble = banks; firmware 2.7 so nothing is flagged.
                let banks: UInt8
                var r200 = config.isR200(port: port, address: address)
                switch name {
                case "ad16x": banks = 0x3
                case "da16x": banks = 0xC
                case "dd16x": banks = 0xF
                case "rosetta800": banks = 0x5
                case "rosetta200": banks = 0x5; r200 = true
                default: return nil
                }
                units.append(ConverterUnit(port: port, address: address, inquire: banks << 4 | 0x7, xtd: 0x02,
                                           xtdOK: true, authOK: true,
                                           ddIsAD: config.ddIsAD(port: port, address: address), isR200: r200))
            }
            ports.append(units)
        }
        self.init(source: .simulation, ports: ports, port2Counted: ports.count == 2)
    }

    /// The units whose channels count, port 1's then (while 64 channels run) port 2's.
    public var countedUnits: [ConverterUnit] { ports[0] + (port2Counted ? ports[1] : []) }

    public var chain: ConverterRules.Chain {
        ConverterRules.Chain(port1: ports[0].map(\.kind), port2: port2Counted ? ports[1].map(\.kind) : [])
    }

    /// Port 1's units by address and routing byte, e.g. `p1u1r03-p1u2r0c`:
    /// the converters whose clock the converter config sets. Empty when port
    /// 1 has a Symphony I/O. Unlike `routingSignature` it does not change
    /// with a Device Type or with 32/64 channels.
    public var clockChainSignature: String {
        ports[0].map { unit in
            let hex = String(unit.routing, radix: 16)
            return "p1u\(unit.address)r" + (hex.count < 2 ? "0" + hex : hex)
        }.joined(separator: "-")
    }

    /// Whether the driver itself reports the units (selector 9). The older
    /// probe word comes from drivers that cannot route converters or take a
    /// Device Type.
    public var driverSupportsConverterControls: Bool { source != .probeWord }

    /// Build a system twice: once to learn its units, then with the choices
    /// kept for them.
    public static func withStoredConfig(simulated: Bool, defaults: UserDefaults = .standard,
                                        _ make: (ConverterConfig) -> ConverterSystem?) -> ConverterSystem? {
        guard let first = make(ConverterConfig()) else { return nil }
        return make(ConverterConfig.load(defaults, for: first, simulated: simulated)) ?? first
    }

    /// Whether every counted unit is a converter we know, so the app can lay
    /// its channels out. Otherwise the generic layout is the honest answer.
    public var layoutKnown: Bool {
        !ports[0].isEmpty && countedUnits.allSatisfy { $0.kind != .unknown && $0.kind != .none }
    }

    /// Host channels the device carries: 32, or 64 while port 2 counts.
    public var hostCapacity: Int { port2Counted ? 64 : 32 }

    public var inputMap: [ConverterRules.Channel?] { ConverterRules.hostMap(chain, input: true).map }
    public var outputMap: [ConverterRules.Channel?] { ConverterRules.hostMap(chain, input: false).map }

    /// Host input channels used, at most the device's width.
    public var hostInputCount: Int { min(ConverterRules.hostMap(chain, input: true).used, hostCapacity) }
    public var hostOutputCount: Int { min(ConverterRules.hostMap(chain, input: false).used, hostCapacity) }

    /// The names of the used host channels, "A Line 1" or "N.A.".
    public func hostChannelNames(input: Bool) -> [String] {
        let chain = self.chain
        let (map, _) = ConverterRules.hostMap(chain, input: input)
        let count = input ? hostInputCount : hostOutputCount
        return (0..<count).map { ConverterRules.hostChannelName(chain, map: map, input: input, host: $0) }
    }

    /// Port 1 as the older single-port description, so the guards that keep
    /// Symphony I/O commands away from converters keep working.
    public var connectedUnit: ConnectedUnit? {
        let units = ports[0].map(\.legacy)
        guard let first = units.first else { return nil }
        return units.count == 1 ? first : .chain(units)
    }

    public var clockExternal: Bool { state?.clockExternal ?? false }

    /// One notice per unit whose X-Symphony firmware is below 2.7 (not unknown),
    /// adapted from the original's warning.
    public var firmwareNotices: [String] {
        (ports[0] + ports[1]).filter(\.firmwareOutOfDate).map {
            "X-Symphony firmware v\($0.firmwareMajor).\($0.firmwareMinor) in \($0.shortName) is out of date. "
                + "Version 2.7 or later is required."
        }
    }

    /// Changes whenever the channel layout does, for `AppState.cardLayoutToken`.
    public var layoutToken: Int {
        var hasher = Hasher()
        hasher.combine(port2Counted)
        for unit in countedUnits { hasher.combine(unit.routing); hasher.combine(unit.kind == .ddAsDA) }
        return hasher.finalize()
    }

    /// The Device Info row label of a unit.
    public static func rowLabel(port: Int, address: Int) -> String {
        "Port \(port + 1), Unit \(address) of up to \(ConverterRules.maxUnitsPerPort)"
    }

    public static let port2NotCheckedText = "Checked when 64 channels is chosen"

    /// Device Info rows: one per unit, by port. `twoPortDriver` adds the port
    /// 2 line while 64 channels are not running. Authentication is left to the
    /// copied details.
    public func deviceInfoRows(twoPortDriver: Bool) -> [(label: String, value: String)] {
        var rows = ports[0].map { (label: Self.rowLabel(port: 0, address: $0.address), value: $0.rowValue) }
        if port2Counted {
            rows += ports[1].map { (label: Self.rowLabel(port: 1, address: $0.address), value: $0.rowValue) }
        } else if twoPortDriver, source == .driver {
            rows.append((label: "Port 2", value: Self.port2NotCheckedText))
        }
        return rows
    }

    /// The copied details and the diagnostics report: every unit with its raw
    /// word and authentication result, then the driver's flags, phase, health
    /// counters, latency and host channel counts.
    public func reportLines(twoPortDriver: Bool = false) -> [String] {
        var lines: [String] = []
        let counted = port2Counted ? "ports 1 and 2" : "port 1"
        lines.append("Converters: \(countedUnits.count) unit\(countedUnits.count == 1 ? "" : "s") on \(counted) (from \(source.rawValue))")
        for unit in ports[0] + ports[1] {
            var line = Self.rowLabel(port: unit.port, address: unit.address) + ": " + unit.rowValue
            line += ", " + unit.authText
            if !unit.addressed { line += ", could not be addressed" }
            line += " [INQUIRE " + (unit.inquireOK ? Self.hex(UInt32(unit.inquire), 2) : "none")
                + ", XTD " + (unit.xtdOK ? Self.hex(UInt32(unit.xtd), 2) : "none")
                + ", routing " + Self.hex(UInt32(unit.routing), 2)
                + (unit.word.map { ", word " + Self.hex($0, 8) } ?? "") + "]"
            if unit.port == 1 && !port2Counted { line += " (not carrying audio)" }
            lines.append(line)
        }
        if !port2Counted, twoPortDriver, source == .driver {
            lines.append("Port 2: " + Self.port2NotCheckedText)
        }
        lines.append("Converter Host Channels: \(hostInputCount) inputs, \(hostOutputCount) outputs")
        if let state {
            lines.append("Converter Flags: \(Self.hex(state.flags, 8)) (\(state.flagsText))")
            lines.append("Converter Config: \(Self.hex(state.config, 8))")
            lines.append("Converter Phase: port 1 \(Self.hex(state.phase[0], 8)), port 2 \(Self.hex(state.phase[1], 8))")
            lines.append("Converter Health: checks \(state.healthTicks), phase errors \(state.phaseErrors), "
                         + "unlocks \(state.unlocks), recoveries \(state.recoveries)")
            lines.append("Converter Latency: input \(state.latencyIn), output \(state.latencyOut) samples")
            lines.append("Converter Driver Host Channels: \(state.hostInputs) inputs, \(state.hostOutputs) outputs")
        }
        lines.append(contentsOf: firmwareNotices)
        return lines
    }

    static func hex(_ value: UInt32, _ digits: Int) -> String {
        let text = String(value, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
