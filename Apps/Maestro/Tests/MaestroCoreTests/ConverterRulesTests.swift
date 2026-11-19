import Foundation
import Testing
@testable import MaestroCore

/// The same vectors as `Drivers/Thunderbolt/Scripts/test-converters.sh`, one
/// `#expect` per CHECK, SLOT and NAME line there, so the app and the driver
/// agree on every placement and name.
@Suite("Converter rules (SymphonyConverters.h)")
struct ConverterRulesTests {
    private let R = ConverterKind.rosetta, AD = ConverterKind.ad16x, DA = ConverterKind.da16x
    private let DD = ConverterKind.ddAsAD

    private func chain(_ p1: [ConverterKind], _ p2: [ConverterKind] = []) -> ConverterRules.Chain {
        ConverterRules.Chain(port1: p1, port2: p2)
    }
    /// host channel (1-based) -> "port:slot" (1-based), "-" when unrouted.
    private func slot(_ c: ConverterRules.Chain, _ input: Bool, _ host1: Int) -> String {
        guard let m = ConverterRules.hostMap(c, input: input).map[host1 - 1] else { return "-" }
        return "\(m.port + 1):\(m.slot + 1)"
    }
    private func name(_ c: ConverterRules.Chain, _ input: Bool, _ host1: Int) -> String {
        ConverterRules.hostChannelName(c, input: input, host: host1 - 1)
    }

    @Test("identity: routing = (XTD & 0xF0) | (INQUIRE >> 4)")
    func identity() {
        #expect(ConverterRules.routing(inquire: 0x37, xtd: 0x02) == ConverterRules.routingAD)
        #expect(ConverterRules.routing(inquire: 0xC5, xtd: 0x00) == ConverterRules.routingDA)
        #expect(ConverterRules.routing(inquire: 0xF0, xtd: 0xF1) == ConverterRules.routingSymphony)
        #expect(ConverterRules.kind(routing: 0x0F) == .ddAsAD)
        #expect(ConverterRules.kind(routing: 0x0F, ddIsAD: false) == .ddAsDA)
        #expect(ConverterRules.kind(routing: 0x05) == .rosetta)
        #expect(ConverterRules.kind(routing: 0x09) == .unknown)
    }

    @Test("placement and names, as the routing layer shipped them")
    func placement() {
        do { let c = chain([AD, AD, DA, DA])
            #expect(slot(c, true, 1) == "1:1"); #expect(slot(c, true, 17) == "1:17")
            #expect(slot(c, true, 32) == "1:32"); #expect(slot(c, true, 33) == "-")
            #expect(slot(c, false, 1) == "1:1"); #expect(slot(c, false, 17) == "1:17")
            #expect(name(c, true, 1) == "A Line 1"); #expect(name(c, true, 17) == "B Line 1")
            #expect(name(c, false, 1) == "C Line 1"); #expect(name(c, false, 32) == "D Line 16")
            #expect(name(c, true, 33) == "N.A.") }
        do { let c = chain([R, AD])
            #expect(slot(c, true, 8) == "1:8"); #expect(slot(c, true, 9) == "1:17"); #expect(slot(c, true, 24) == "1:32")
            #expect(slot(c, false, 8) == "1:8"); #expect(slot(c, false, 9) == "-")
            #expect(name(c, true, 9) == "B Line 1"); #expect(name(c, false, 8) == "A Out 8")
            #expect(name(c, false, 9) == "N.A.") }
        do { let c = chain([DA, R])
            #expect(slot(c, true, 1) == "1:17"); #expect(slot(c, false, 16) == "1:16"); #expect(slot(c, false, 17) == "1:17")
            #expect(name(c, true, 1) == "B In 1"); #expect(name(c, false, 17) == "B Out 1") }
        do { let c = chain([AD, R])
            #expect(slot(c, true, 17) == "1:17"); #expect(slot(c, false, 1) == "1:17") }
        do { let c = chain([DA, AD])
            #expect(slot(c, true, 1) == "1:17"); #expect(slot(c, true, 16) == "1:32"); #expect(slot(c, false, 1) == "1:1") }
        do { let c = chain([AD, DA])
            #expect(slot(c, true, 1) == "1:1"); #expect(slot(c, false, 1) == "1:1") }
        do { let c = chain([R, DD])
            #expect(slot(c, true, 9) == "1:17"); #expect(slot(c, false, 9) == "1:17"); #expect(name(c, false, 9) == "B Dig Out 1") }
        do { let c = chain([R, R, AD])
            #expect(slot(c, true, 9) == "1:9"); #expect(slot(c, true, 17) == "1:17") }
        do { let c = chain([DA, R, R])   // as shipped (Apogee noted the last Rosetta is wrong)
            #expect(slot(c, true, 1) == "1:17"); #expect(slot(c, true, 9) == "1:9"); #expect(slot(c, false, 25) == "1:25") }
        do { let c = chain([AD, AD, AD])  // the third AD does not fit in 32
            #expect(slot(c, true, 33) == "-")
            // ...but its host channels are still counted, as in the driver.
            #expect(ConverterRules.hostMap(c, input: true).used == 48) }
        do { let c = chain([AD, DA], [AD, DA])
            #expect(slot(c, true, 16) == "1:16"); #expect(slot(c, true, 17) == "2:1"); #expect(slot(c, false, 17) == "2:1")
            #expect(name(c, true, 17) == "C Line 1"); #expect(name(c, false, 17) == "D Line 1") }
        do { let c = chain([AD, AD, DA, DA], [AD, AD, DA, DA])
            #expect(slot(c, true, 64) == "2:32"); #expect(slot(c, false, 33) == "2:1")
            #expect(name(c, true, 33) == "E Line 1"); #expect(name(c, false, 64) == "H Line 16") }
        do { let c = chain([.ddAsDA])
            #expect(name(c, true, 3) == "A Dig In 3"); #expect(name(c, false, 3) == "A Line 3") }
    }

    @Test("latency")
    func latency() {
        #expect(ConverterRules.latency(R, rateHz: 48000, input: true) == 36)
        #expect(ConverterRules.latency(R, rateHz: 48000, input: false) == 34)
        #expect(ConverterRules.latency(R, rateHz: 192000, input: false) == 99)
        #expect(ConverterRules.latency(AD, rateHz: 96000, input: true) == 25)
        #expect(ConverterRules.latency(DA, rateHz: 176400, input: false) == 19)
        #expect(ConverterRules.latency(DD, rateHz: 44100, input: false) == 35)
        #expect(ConverterRules.latency(DD, rateHz: 48000, input: false) == 34)
        #expect(ConverterRules.latency(.ddAsDA, rateHz: 88200, input: true) == 24)
    }

    @Test("firmware 2.7 check")
    func firmware() {
        #expect(!ConverterRules.firmwareOutOfDate(major: 0, minor: 0))
        #expect(ConverterRules.firmwareOutOfDate(major: 2, minor: 6))
        #expect(!ConverterRules.firmwareOutOfDate(major: 2, minor: 7))
        #expect(ConverterRules.firmwareOutOfDate(major: 1, minor: 15))
        #expect(!ConverterRules.firmwareOutOfDate(major: 3, minor: 0))
    }
}

@Suite("Converter system")
struct ConverterSystemTests {
    /// A driver unit word: INQUIRE, XTD and flags.
    private func word(_ inquire: UInt8, _ xtd: UInt8, auth: Bool? = true, extra: UInt32 = 0) -> UInt32 {
        var w = UInt32(inquire) | UInt32(xtd) << 8 | ConverterState.unitInquireOK | ConverterState.unitXtdOK
            | ConverterState.unitAddressed | extra
        if let auth { w |= ConverterState.unitAuthRan | (auth ? ConverterState.unitAuthOK : 0) }
        return w
    }

    private func words(flags: UInt32, port1: [UInt32], port2: [UInt32] = [], config: UInt32 = 0) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: 28)
        w[1] = 1; w[2] = flags
        w[3] = UInt32(port1.count); w[4] = UInt32(port2.count)
        for (i, u) in port1.enumerated() { w[5 + i] = u }
        for (i, u) in port2.enumerated() { w[9 + i] = u }
        w[13] = 0x1A1B_1C1D; w[14] = 0x0000_2122
        w[15] = 100; w[16] = 1; w[17] = 2; w[18] = 3; w[19] = 36; w[20] = 35; w[21] = 32; w[22] = 32
        w[23] = config
        return w
    }

    @Test("selector 9 decodes every field and rejects a wrong size or status")
    func decode() throws {
        let raw = words(flags: 0x2D, port1: [word(0x37, 0x02), word(0x37, 0x02)], port2: [word(0xC6, 0x02)],
                        config: 0x0000_0101)
        let state = try #require(ConverterState.decode(raw))
        #expect(state.version == 1)
        #expect(state.port1Converters && !state.port2Converters && state.clockExternal)
        #expect(state.unitCount == [2, 1])
        #expect(state.units[0][1] == raw[6])
        #expect(state.units[1][0] == raw[9])
        #expect(state.phase == [0x1A1B_1C1D, 0x2122])
        #expect(state.healthTicks == 100 && state.phaseErrors == 1 && state.unlocks == 2 && state.recoveries == 3)
        #expect(state.latencyIn == 36 && state.latencyOut == 35)
        #expect(state.hostInputs == 32 && state.hostOutputs == 32)
        #expect(state.config == 0x101)
        #expect(state.flagsText == "port 1 converters, external clock, healthy, routing applied")

        #expect(ConverterState.decode(Array(raw.prefix(27))) == nil)
        var failed = raw; failed[0] = 0xE00002C7
        #expect(ConverterState.decode(failed) == nil)
        // Port 2 is listed but not counted while the driver does not report it.
        let system = try #require(ConverterSystem(state: state))
        #expect(system.source == .driver)
        #expect(system.ports[1].count == 1 && !system.port2Counted)
        #expect(system.hostInputCount == 32 && system.hostOutputCount == 0)
        // Not identified as converters: nothing.
        #expect(ConverterSystem(state: ConverterState(flags: 0)) == nil)
    }

    @Test("a unit word gives model, firmware, authentication and Device Type")
    func unitWord() {
        let ad = ConverterUnit(port: 0, address: 1, word: word(0x37, 0x02))
        #expect(ad.kind == .ad16x)
        #expect(ad.firmwareMajor == 2 && ad.firmwareMinor == 7 && !ad.firmwareOutOfDate)
        #expect(ad.rowValue == "AD-16X (16 inputs), X-Symphony v2.7")
        #expect(ad.authOK == true)
        let old = ConverterUnit(port: 1, address: 3, word: word(0xC6, 0x02, auth: false))
        #expect(old.firmwareOutOfDate)
        #expect(old.authText == "authentication failed")
        // No XTD reply: major 0, minor from INQUIRE, as the original reported it
        // (and warned about: the oldest firmware).
        let noXtd = ConverterUnit(port: 0, address: 1, word: UInt32(0x37) | ConverterState.unitInquireOK)
        #expect(noXtd.firmwareText == "X-Symphony v0.7" && noXtd.firmwareOutOfDate)
        let nothing = ConverterUnit(port: 0, address: 1, word: UInt32(0x30) | ConverterState.unitInquireOK)
        #expect(nothing.firmwareText == "Unknown" && !nothing.firmwareOutOfDate)
        #expect(noXtd.authOK == nil)
        // 0x0F: AD by default, DA when the driver applied that Device Type.
        let dd = ConverterUnit(port: 0, address: 2, word: word(0xF7, 0x02))
        #expect(dd.kind == .ddAsAD && dd.deviceType == .ddAsAD)
        #expect(dd.rowValue == "DD-16X / AD-16X (Advanced Routing) (16 inputs, 16 outputs), X-Symphony v2.7")
        #expect(dd.deviceTypeChoices == [.ddAsAD, .ddAsDA])
        let ddDA = ConverterUnit(port: 0, address: 2, word: word(0xF7, 0x02, extra: ConverterState.unitTypeIsDA))
        #expect(ddDA.kind == .ddAsDA && ddDA.deviceType == .ddAsDA)
        let r200 = ConverterUnit(port: 0, address: 1, word: word(0x57, 0x02, extra: ConverterState.unitIsR200))
        #expect(r200.modelName == "Rosetta 200" && r200.deviceTypeChoices == [.rosetta800, .rosetta200])
        #expect(ConverterUnit(port: 0, address: 1, word: word(0x37, 0x02)).deviceTypeChoices.isEmpty)
    }

    @Test("an older driver: port 1 from the probe word; units 2-4 have the nibble only")
    func probeWordFallback() throws {
        let ran: UInt32 = 0x8000_0000, inquireOK: UInt32 = 0x4000_0000, xtdOK: UInt32 = 0x2000_0000
        let system = try #require(ConverterSystem(probeWord: ran | inquireOK | xtdOK | 0x0200 | 0x37
                                                  | (0x3 << 16) | (0xC << 20) | (0xC << 24)))
        #expect(system.source == .probeWord && !system.port2Counted && system.ports[1].isEmpty)
        #expect(system.ports[0].map(\.kind) == [.ad16x, .ad16x, .da16x, .da16x])
        #expect(system.ports[0][0].firmwareText == "X-Symphony v2.7")
        #expect(system.ports[0][1].firmwareText == "Unknown")
        #expect(system.connectedUnit == .chain([.ad16x, .ad16x, .da16x, .da16x]))
        #expect(system.hostInputCount == 32 && system.hostOutputCount == 32)
        // No XTD reply: v0.N from INQUIRE, which is out of date (the original
        // warned); a unit that reports 0.0 is unknown and never warned about.
        let noXtd = try #require(ConverterSystem(probeWord: ran | inquireOK | 0x31))
        #expect(noXtd.ports[0][0].firmwareText == "X-Symphony v0.1" && noXtd.firmwareNotices.count == 1)
        let zero = try #require(ConverterSystem(probeWord: ran | inquireOK | 0x30))
        #expect(zero.ports[0][0].firmwareText == "Unknown" && zero.firmwareNotices.isEmpty)
        // No probe, or nothing answered: nil.
        #expect(ConverterSystem(probeWord: 0) == nil)
        #expect(ConverterSystem(probeWord: ran) == nil)
        // A stored Device Type is honoured for the probe word.
        let config = ConverterConfig(deviceTypes: [ConverterDeviceType.defaultsKey(port: 0, address: 1): .ddAsDA])
        let dd = try #require(ConverterSystem(probeWord: ran | inquireOK | xtdOK | 0x0200 | 0xF7, config: config))
        #expect(dd.ports[0][0].kind == .ddAsDA)
    }

    @Test("layout: AD, AD, DA, DA on one port and on two")
    func layoutCounts() throws {
        let one = try #require(ConverterSystem(simulationName: "ad16x+ad16x+da16x+da16x"))
        let layout1 = CardLayout(isKnown: false, fallbackChannelCount: 32, converters: one)
        #expect(layout1.analogInputStripCount == 32 && layout1.analogOutputStripCount == 32)
        #expect(layout1.converterChannelName(host: 0, isInput: true) == "A Line 1")
        #expect(layout1.converterChannelName(host: 16, isInput: true) == "B Line 1")
        #expect(layout1.converterChannelName(host: 0, isInput: false) == "C Line 1")
        #expect(layout1.mixerChannels.count == 32)
        #expect(layout1.mixerChannels[16].label == "B Line 1" && layout1.mixerChannels[16].hardwareIndex == 16)
        #expect(layout1.inputRoutingColumns.count == 16)
        #expect(layout1.inputRoutingColumns[0].stereoName == "A Line 1/2")
        #expect(layout1.inputRoutingColumns[8].routingByte == 48)

        let two = try #require(ConverterSystem(simulationName: "ad16x+ad16x+da16x+da16x|ad16x+ad16x+da16x+da16x"))
        #expect(two.port2Counted)
        let layout2 = CardLayout(isKnown: false, fallbackChannelCount: 32, converters: two)
        #expect(layout2.analogInputStripCount == 64 && layout2.analogOutputStripCount == 64)
        #expect(layout2.converterChannelName(host: 32, isInput: true) == "E Line 1")
        #expect(layout2.converterChannelName(host: 63, isInput: false) == "H Line 16")
        // Port 2 is not in the card mixer or the port-1 routing grid.
        #expect(layout2.mixerChannels.count == 32)
        #expect(layout2.inputRoutingColumns.count == 16)
        #expect(layout2.converterPairNames(isInput: true, pairCount: 32)?[16] == "E Line 1/2")
        // Meter words: host input 33 is port 2 slot 1 (word 32).
        let words = ThunderboltWords.channels(two)
        #expect(words[0] == 0 && words[32] == 32 && words[63] == 63)
    }

    @Test("R, AD: the AD sits at slot 17 and the meters follow the slot")
    func rosettaThenAD() throws {
        let system = try #require(ConverterSystem(simulationName: "rosetta800+ad16x"))
        let layout = CardLayout(isKnown: false, fallbackChannelCount: 32, converters: system)
        #expect(layout.analogInputStripCount == 24)
        #expect(layout.analogOutputStripCount == 8)
        #expect(layout.converterChannelName(host: 8, isInput: true) == "B Line 1")
        #expect(layout.converterChannelName(host: 7, isInput: false) == "A Out 8")
        #expect(layout.mixerChannels[8].hardwareIndex == 16)
        #expect(ThunderboltWords.channels(system)[8] == 16)
        #expect(ThunderboltWords.channels(system)[23] == 31)
    }

    @Test("routing grid: the generic columns, bytes and indices kept; only the names follow the units")
    func routingColumnsKeepBytes() throws {
        let generic = CardLayout(isKnown: false, fallbackChannelCount: 32)
        let system = try #require(ConverterSystem(simulationName: "rosetta800+da16x"))
        let layout = CardLayout(isKnown: false, fallbackChannelCount: 32, converters: system)
        for isInput in [true, false] {
            let before = generic.routingColumns(isInput: isInput)
            let after = layout.routingColumns(isInput: isInput)
            #expect(after.map(\.routingByte) == before.map(\.routingByte))
            #expect(after.map(\.isDigital) == before.map(\.isDigital))
            #expect(after.map(\.boardIndex) == before.map(\.boardIndex))
        }
        // Rosetta outputs on slots 1-8, the DA-16X on 17-32 (it follows an
        // 8-output unit), so column 5 (slots 9-10) has nothing and column 9
        // (slots 17-18, byte 48) is the DA-16X.
        let outputs = layout.outputRoutingColumns
        #expect(outputs[0].stereoName == "A Out 1/2")
        #expect(outputs[4].stereoName == "N.A.")
        #expect(outputs[8].stereoName == "B Line 1/2" && outputs[8].routingByte == 48)
        #expect(layout.inputRoutingColumns[0].stereoName == "A In 1/2")
    }

    @Test("Device Type changes the layout and the config word")
    func deviceType() throws {
        let asAD = try #require(ConverterSystem(simulationName: "dd16x"))
        #expect(CardLayout(isKnown: false, converters: asAD).converterChannelName(host: 0, isInput: false) == "A Dig Out 1")
        let key = ConverterDeviceType.defaultsKey(port: 0, address: 1)
        #expect(key == "converterDeviceType.p1.u1")
        let config = ConverterConfig(deviceTypes: [key: .ddAsDA,
                                                   ConverterDeviceType.defaultsKey(port: 1, address: 2): .rosetta200])
        let asDA = try #require(ConverterSystem(simulationName: "dd16x", config: config))
        let layout = CardLayout(isKnown: false, converters: asDA)
        #expect(layout.converterChannelName(host: 0, isInput: false) == "A Line 1")
        #expect(layout.converterChannelName(host: 0, isInput: true) == "A Dig In 1")
        // bit n = port * 4 + address - 1; DA at 8 + n, R200 at 16 + n.
        #expect(config.word() == (1 << 8) | (1 << (16 + 5)))
        #expect(config.word(currentClockExternal: true) & 1 == 1)
        var internalClock = config; internalClock.clockExternal = false
        #expect(internalClock.word(currentClockExternal: true) & 1 == 0)
        // Stored and read back through UserDefaults.
        let defaults = try #require(UserDefaults(suiteName: "ConverterSystemTests.deviceType"))
        defaults.removePersistentDomain(forName: "ConverterSystemTests.deviceType")
        let unit = asAD.ports[0][0]
        ConverterConfig.saveDeviceType(.ddAsDA, unit: unit, simulated: false, defaults: defaults)
        ConverterConfig.saveClockExternal(true, for: asAD, simulated: false, defaults: defaults)
        let loaded = ConverterConfig.load(defaults, for: asAD, simulated: false)
        #expect(loaded.deviceType(port: 0, address: 1) == .ddAsDA && loaded.clockExternal == true)
        #expect(loaded.word() == 1 | 1 << 8)
        defaults.removePersistentDomain(forName: "ConverterSystemTests.deviceType")
    }

    @Test("Device Types are kept per unit, the clock per port-1 chain, simulation apart")
    func configScopes() throws {
        let suite = "ConverterSystemTests.scopes"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let dd = try #require(ConverterSystem(simulationName: "dd16x"))
        let unit = dd.ports[0][0]
        #expect(ConverterConfig.deviceTypeKey(port: 0, address: 1, routing: unit.routing, simulated: false)
                == "converterDeviceType.p1.u1.r0f")
        #expect(ConverterConfig.clockKey(for: dd, simulated: true) == "converterClockExternal.sim:p1u1r0f")
        // A simulation's choice is not a real unit's.
        ConverterConfig.saveDeviceType(.ddAsDA, unit: unit, simulated: true, defaults: defaults)
        ConverterConfig.saveClockExternal(true, for: dd, simulated: true, defaults: defaults)
        #expect(ConverterConfig.load(defaults, for: dd, simulated: false) == ConverterConfig())
        #expect(ConverterConfig.load(defaults, for: dd, simulated: true).deviceType(port: 0, address: 1) == .ddAsDA)
        // The older unscoped keys move to the first chain that reads them, once.
        defaults.set(ConverterDeviceType.ddAsDA.rawValue, forKey: "converterDeviceType.p1.u1")
        defaults.set(true, forKey: ConverterConfig.clockDefaultsKey)
        let migrated = ConverterConfig.load(defaults, for: dd, simulated: false)
        #expect(migrated.deviceType(port: 0, address: 1) == .ddAsDA && migrated.clockExternal == true)
        #expect(defaults.object(forKey: "converterDeviceType.p1.u1") == nil)
        #expect(defaults.object(forKey: ConverterConfig.clockDefaultsKey) == nil)
        // Another chain does not inherit them.
        let rosetta = try #require(ConverterSystem(simulationName: "rosetta800"))
        #expect(ConverterConfig.load(defaults, for: rosetta, simulated: false).clockExternal == nil)
        // Converters only on port 2 (a Symphony I/O on port 1): no converter clock.
        let state = ConverterState(version: 1, flags: ConverterState.flagPort2Converters, unitCount: [0, 1],
                                   units: [[0, 0, 0, 0], [0x0000_0F37 | ConverterState.unitInquireOK, 0, 0, 0]],
                                   phase: [0, 0], healthTicks: 0, phaseErrors: 0, unlocks: 0, recoveries: 0,
                                   latencyIn: 0, latencyOut: 0, hostInputs: 0, hostOutputs: 0, config: 0)
        let port2 = try #require(ConverterSystem(state: state))
        #expect(ConverterConfig.clockKey(for: port2, simulated: false) == nil)
    }

    @Test("Older drivers (probe word) get no converter routing or Device Type")
    func olderDriver() throws {
        let ran: UInt32 = 0x8000_0000, inquireOK: UInt32 = 0x4000_0000
        let probed = try #require(ConverterSystem(probeWord: ran | inquireOK | 0x31))
        #expect(!probed.driverSupportsConverterControls)
        #expect(try #require(ConverterSystem(simulationName: "ad16x")).driverSupportsConverterControls)
    }

    @Test("simulator: one or two ports, old form still accepted")
    func simulator() throws {
        let one = try #require(ConverterSystem(simulationName: "ad16x+da16x"))
        #expect(one.ports[0].count == 2 && one.ports[1].isEmpty && !one.port2Counted)
        #expect(ConnectedUnit(simulationName: "ad16x+da16x") == .chain([.ad16x, .da16x]))
        let two = try #require(ConverterSystem(simulationName: "ad16x|da16x"))
        #expect(two.port2Counted && two.ports[1].map(\.kind) == [.da16x])
        #expect(two.connectedUnit == .ad16x)
        #expect(ConverterSystem(simulationName: "ad16x|da16x|ad16x") == nil)
        #expect(ConverterSystem(simulationName: "ad16x+ad16x+ad16x+ad16x+ad16x") == nil)
        #expect(ConverterSystem(simulationName: "symphony") == nil)
        #expect(ConverterSystem(simulationName: "ad16x|") == nil)
        #expect(try #require(ConverterSystem(simulationName: "rosetta200")).ports[0][0].modelName == "Rosetta 200")
    }

    @Test("firmware notice: below 2.7 only, once per unit")
    func firmwareNotice() throws {
        let raw = words(flags: ConverterState.flagPort1Converters,
                        port1: [word(0x36, 0x02), word(0xC7, 0x02), UInt32(0x37) | ConverterState.unitInquireOK])
        let decoded = try #require(ConverterState.decode(raw))
        let system = try #require(ConverterSystem(state: decoded))
        #expect(system.firmwareNotices == [
            "X-Symphony firmware v2.6 in AD-16X (port 1, unit 1) is out of date. Version 2.7 or later is required.",
            "X-Symphony firmware v0.7 in AD-16X (port 1, unit 3) is out of date. Version 2.7 or later is required.",
        ])
    }

    @Test("Device Info rows and copied details")
    func rows() throws {
        let raw = words(flags: ConverterState.flagPort1Converters,
                        port1: [word(0x37, 0x02), word(0xC7, 0x02, auth: false)], port2: [word(0x37, 0x02)])
        let decoded = try #require(ConverterState.decode(raw))
        let system = try #require(ConverterSystem(state: decoded))
        let rows = system.deviceInfoRows(twoPortDriver: true)
        #expect(rows.map(\.label) == ["Port 1, Unit 1 of up to 4", "Port 1, Unit 2 of up to 4", "Port 2"])
        #expect(rows[0].value == "AD-16X (16 inputs), X-Symphony v2.7")
        #expect(rows[2].value == "Checked when 64 channels is chosen")
        // Authentication only in the copied details.
        #expect(!rows.contains { $0.value.contains("authentication") })
        #expect(system.deviceInfoRows(twoPortDriver: false).count == 2)
        let lines = system.reportLines(twoPortDriver: true)
        #expect(lines.contains("Port 1, Unit 2 of up to 4: DA-16X (16 outputs), X-Symphony v2.7, authentication failed "
                               + "[INQUIRE 0xc7, XTD 0x02, routing 0x0c, word 0x000f02c7]"))
        #expect(lines.contains("Converter Health: checks 100, phase errors 1, unlocks 2, recoveries 3"))
        #expect(lines.contains("Converter Latency: input 36, output 35 samples"))
        #expect(lines.contains("Converter Phase: port 1 0x1a1b1c1d, port 2 0x00002122"))
        #expect(lines.contains("Converter Host Channels: 16 inputs, 16 outputs"))
        #expect(lines.contains { $0.hasPrefix("Port 2, Unit 1 of up to 4: AD-16X") && $0.hasSuffix("(not carrying audio)") })
    }

    @Test("clock picker: Internal and External for converters, the board inputs for a Symphony I/O")
    func clockChoices() {
        #expect(ClockSourceMenu.converters.map(\.name) == ["Internal", "External (Word Clock)"])
        #expect(ClockSourceMenu.converters.map(\.id) == [ClockSourceMenu.internalClock, ClockSourceMenu.wordClock])
        let symphony = ClockSourceMenu.thunderbolt(slot1: .analogADDA16, slot2: .none)
        #expect(symphony.count > ClockSourceMenu.converters.count)
        #expect(symphony.map(\.name).contains("Word Clock"))
    }

    @Test("an unknown unit, or no converters, keeps today's layout")
    func fallbacks() throws {
        let unknown = ConverterSystem(source: .probeWord,
                                      ports: [[ConverterUnit(port: 0, address: 1, inquire: 0x21, xtd: 0, xtdOK: false)], []],
                                      port2Counted: false)
        #expect(!unknown.layoutKnown)
        let layout = CardLayout(isKnown: false, fallbackChannelCount: 32, converters: unknown)
        #expect(layout.converterLayout == nil && layout.analogInputStripCount == 32)
        // A Symphony I/O with cards is never overridden.
        let ad = try #require(ConverterSystem(simulationName: "ad16x"))
        let symphony = CardLayout(slot1: .analogADDA16, isKnown: true, converters: ad)
        #expect(symphony.converterLayout == nil)
        #expect(symphony.analogInputStripCount == symphony.slot1.analogInputChannels)
    }
}

/// The meter words a converter layout reads (`ThunderboltInputMeterMap.converterWords`
/// lives in MaestroDevice; this is the same rule from the host map).
private enum ThunderboltWords {
    static func channels(_ system: ConverterSystem) -> [Int?] {
        let map = system.inputMap
        return (0..<system.hostInputCount).map { map[$0]?.meterWord }
    }
}
