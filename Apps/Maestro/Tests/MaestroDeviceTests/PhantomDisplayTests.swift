import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

/// 0.9.28 (dext 153): 48V is shown in Maestro whichever side switched it, but
/// a DAW's ON is display only. It never becomes a strip's saved phantom or
/// provenance, so it never reaches `restoresPhantom` or a settings replay.
@Suite struct PhantomDisplayTests {
    private static let layout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
    private static let dawOn = MicPreEditRecord.phantomValid | MicPreEditRecord.phantomBit
    private static let driverOn = MicPreEditRecord.statePhantomKnown | MicPreEditRecord.statePhantom

    private static func records(_ fields: [Int: UInt32], stamp: UInt64 = 7) -> [MicPreEditRecord] {
        (0..<16).map { MicPreEditRecord(stamp: fields[$0] == nil ? 0 : stamp, fields: fields[$0] ?? 0) }
    }

    @Test func recordBitsMatchTheDriverHeader() {
        // Drivers/Thunderbolt/Source/SymphonyThunderbridgeShared.h kMicPreEditPhantom*, kMicPreStatePhantom*.
        #expect(MicPreEditRecord.phantomBit == 1 << 18 && MicPreEditRecord.phantomValid == 1 << 19)
        #expect(MicPreEditRecord.statePhantom == 1 << 20 && MicPreEditRecord.statePhantomKnown == 1 << 21)
        #expect(MicPreEditRecord(stamp: 1, fields: Self.dawOn).phantom == true)
        #expect(MicPreEditRecord(stamp: 1, fields: MicPreEditRecord.phantomValid).phantom == false)
        #expect(MicPreEditRecord(stamp: 1, fields: MicPreEditRecord.phantomBit).phantom == nil)
        #expect(MicPreEditRecord(stamp: 0, fields: Self.driverOn).driverPhantom == true)
        #expect(MicPreEditRecord(stamp: 0, fields: MicPreEditRecord.statePhantomKnown).driverPhantom == false)
        #expect(MicPreEditRecord(stamp: 0, fields: MicPreEditRecord.statePhantom).driverPhantom == nil)
        #expect(!MicPreEditRecord(stamp: 1, fields: Self.dawOn | Self.driverOn).hasEdit)
    }

    @Test(arguments: [
        (ServingDextBuild.build(153), true),
        (ServingDextBuild.build(160), true),
        (ServingDextBuild.build(152), false),
        (ServingDextBuild.olderThanBuildReporting, false),
    ])
    func observedOnNeedsDriver153(build: ServingDextBuild, shown: Bool) {
        let observed = PhantomDisplay.observedOn(
            Self.records([0: Self.dawOn, 1: MicPreEditRecord.phantomValid, 9: Self.dawOn, 3: Self.driverOn]),
            servingBuild: build)
        #expect(observed.count == 16)
        #expect(observed[0] == shown && observed[9] == shown)
        // An OFF, and the driver's own state (Maestro's ON), are not a DAW ON.
        #expect(!observed[1] && !observed[3])
        #expect(PhantomDisplay.observedOn(Self.records([0: Self.dawOn]), servingBuild: nil) == Array(repeating: false, count: 16))
        #expect(PhantomDisplay.observedOn([], servingBuild: build) == Array(repeating: false, count: 16))
    }

    /// The observed ON never survives into saved state, `recalled`,
    /// `restoresPhantom` or the settings replay.
    @Test func observedOnNeverReachesSavedStateRecallOrReplay() throws {
        let defaults = try #require(ScratchUserDefaults(suiteName: UUID().uuidString))
        let store = ChannelStateStore(defaults: defaults, layout: Self.layout, isSimulatingCards: false, identity: 42)
        let strips = (0..<8).map { _ in InputChannelState(inputType: AnalogInputLevel.mic.rawValue) }
        store.save(strips, for: ChannelStateStore.inputKey)
        store.save([UInt64](repeating: 1, count: 8), for: MicPreDAWObservation.seenKey)
        let records = Self.records([0: Self.dawOn | Self.driverOn])
        #expect(PhantomDisplay.observedOn(records, servingBuild: .build(153))[0])
        // The DAW record (a new stamp) is acknowledged without touching phantom.
        #expect(!MicPreDAWObservation.apply(records, to: store))
        let saved = try #require(store.load(ChannelStateStore.inputKey, as: [InputChannelState].self))
        #expect(!saved[0].phantom && saved[0].phantomProvenance == nil)
        #expect(store.load(MicPreDAWObservation.seenKey, as: [UInt64].self)?[0] == 7)
        let recalled = saved[0].recalled(identity: 42, boardSlot: 1, channel: 0)
        #expect(!recalled.phantom && recalled.phantomProvenance == nil)
        // Even a strip the app keeps lit for its own pending ON cannot be lit
        // by a DAW: keepsUnverifiedOn only keeps a saved ON.
        #expect(!saved[0].recalled(identity: nil, boardSlot: 1, channel: 0, keepsUnverifiedOn: true).phantom)
        #expect(!saved[0].restoresPhantom(identity: 42, boardSlot: 1, channel: 0))
        let writes = MicPreSettingsReplay.writes(inputs: saved, layout: Self.layout, identity: 42)
        let phantom = PropertyAddress(selector: .phantom, scope: .global, element: 0)
        #expect(writes.contains(.property(phantom, .bool(false))))
        #expect(!writes.contains(.property(phantom, .bool(true))))
        // finishProvenance only finishes channels Maestro itself switched on.
        var states = saved
        #expect(!PhantomDisplay.finishProvenance(channels: [], records: records, unit: .a, identity: 42,
                                                 servingBuild: .build(153), states: &states))
        #expect(states == saved)
    }

    /// Maestro's own ON made before the identity was known: shown across a
    /// reload, and once the identity is known it gets its provenance (only
    /// where the driver says the unit has it on and the strip is Mic).
    @Test func ownOnSurvivesReloadAndFinishesWhenIdentityKnown() {
        var state = InputChannelState(inputType: AnalogInputLevel.mic.rawValue)
        state.recordPhantomRequest(true, identity: nil, boardSlot: 1, channel: 2)
        state.finishPhantomRequest(state, accepted: true, identity: nil, boardSlot: 1, channel: 2)
        #expect(state.phantom && state.phantomProvenance == nil)
        // Before: a reload dropped it.
        #expect(!state.recalled(identity: nil, boardSlot: 1, channel: 2).phantom)
        let kept = state.recalled(identity: nil, boardSlot: 1, channel: 2, keepsUnverifiedOn: true)
        #expect(kept.phantom && kept.phantomProvenance == nil)
        #expect(!kept.restoresPhantom(identity: 42, boardSlot: 1, channel: 2))
        let replay = MicPreSettingsReplay.writes(inputs: [InputChannelState(), InputChannelState(), kept],
                                                 layout: Self.layout, identity: 42)
        let address = PropertyAddress(selector: .phantom, scope: .global, element: 2)
        #expect(!replay.contains(.property(address, .bool(true))), "a pending ON is never replayed")

        var states = [InputChannelState(), InputChannelState(), kept]
        let records = Self.records([2: Self.driverOn])
        #expect(PhantomDisplay.finishProvenance(channels: [2], records: records, unit: .a, identity: 42,
                                                servingBuild: .build(153), states: &states))
        #expect(states[2].phantom && states[2].phantomProvenance == PhantomProvenance(unitID: 42, boardSlot: 1, channel: 2))
        #expect(states[2].recalled(identity: 42, boardSlot: 1, channel: 2).phantom)
        #expect(!states[0].phantom && !states[1].phantom)
    }

    @Test func finishProvenanceNeedsDriverOnMicAndAKnownIdentity() {
        let mic = InputChannelState(inputType: AnalogInputLevel.mic.rawValue)
        func finish(_ records: [MicPreEditRecord], unit: DeviceUnit = .a, identity: UInt64 = 42,
                    build: ServingDextBuild = .build(153), strip: InputChannelState = mic) -> Bool {
            var states = [strip]
            let changed = PhantomDisplay.finishProvenance(channels: [0], records: records, unit: unit,
                                                          identity: identity, servingBuild: build, states: &states)
            #expect(changed == states[0].phantom)
            return changed
        }
        #expect(finish(Self.records([0: Self.driverOn])))
        // The unit no longer has it on (a DAW or a type change turned it off).
        #expect(!finish(Self.records([0: MicPreEditRecord.statePhantomKnown])))
        #expect(!finish(Self.records([:])))
        // A DAW's ON in the record is not the driver's state.
        #expect(!finish(Self.records([0: Self.dawOn])))
        #expect(!finish(Self.records([0: Self.driverOn]), build: .build(152)))
        #expect(!finish(Self.records([0: Self.driverOn]), identity: 0))
        #expect(!finish(Self.records([0: Self.driverOn]), identity: UInt64.max))
        #expect(!finish(Self.records([0: Self.driverOn]), strip: InputChannelState(inputType: AnalogInputLevel.plus4dBu.rawValue)))
        // Unit B reads records 8..<16.
        #expect(!finish(Self.records([0: Self.driverOn]), unit: .b))
        #expect(finish(Self.records([8: Self.driverOn]), unit: .b))
    }

    @Test func diagnosticsLinesCarryDriverMaestroDAWAndIdentity() {
        var verified = InputChannelState(inputType: AnalogInputLevel.mic.rawValue)
        verified.recordPhantomRequest(true, identity: 42, boardSlot: 1, channel: 0)
        var unverified = InputChannelState(inputType: AnalogInputLevel.mic.rawValue)
        unverified.recordPhantomRequest(true, identity: nil, boardSlot: 1, channel: 1)
        let records = Self.records([0: Self.driverOn, 1: Self.driverOn, 2: Self.dawOn | Self.driverOn,
                                    3: MicPreEditRecord.statePhantomKnown])
        var observed = [Bool](repeating: false, count: 8)
        observed[2] = true
        let lines = MicPrePhantomReport.lines(unit: "A", identityKnown: true, servingBuild: .build(153),
            records: records[0..<8], saved: [verified, unverified, InputChannelState(inputType: 3), InputChannelState()],
            observed: observed[0..<8], pending: [1], identity: 42)
        #expect(lines.count == 9)
        #expect(lines[0] == "8MicPre 48V, unit A (unit identity known):")
        #expect(lines[1] == "  Ch 1: driver on, Maestro on")
        #expect(lines[2] == "  Ch 2: driver on, Maestro on (identity pending)")
        #expect(lines[3] == "  Ch 3: driver on, Maestro off, shown on (set from a DAW)")
        #expect(lines[4] == "  Ch 4: driver off, Maestro off")
        #expect(lines[5] == "  Ch 5: driver unknown, Maestro no saved strip")
        let old = MicPrePhantomReport.lines(unit: "B", identityKnown: false, servingBuild: .build(152),
            records: nil, saved: nil, observed: observed[0..<8], pending: [], identity: nil)
        #expect(old[0] == "8MicPre 48V, unit B (unit identity not known):")
        #expect(old[1].hasPrefix("  Ch 1: driver not reported (driver before build 153)"))
    }
}
