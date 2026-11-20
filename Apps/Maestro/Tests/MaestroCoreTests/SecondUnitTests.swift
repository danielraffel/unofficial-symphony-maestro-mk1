import Testing
@testable import MaestroCore

@Suite("Two Symphony I/Os: unit B")
struct SecondUnitTests {
    @Test("Unit B's layout comes from its own board types")
    func layoutFromBoardTypes() {
        let info = SecondUnitInfo(boardType: [IOCardType.analogADDA16.rawValue, IOCardType.micPre8.rawValue],
                                  boardValid: [1, 1], prefix: 0, clockSource: 2, setupFlags: 1, txErrors: 0)
        let layout = info.layout()
        #expect(layout.slot1 == .analogADDA16)
        #expect(layout.slot2 == .micPre8)
        #expect(layout.isKnown)
        #expect(layout == CardLayout(slot1: .analogADDA16, slot2: .micPre8, isKnown: true, fallbackChannelCount: 32))
        // A slot that was not read is not a card.
        let half = SecondUnitInfo(boardType: [IOCardType.optical.rawValue, 9], boardValid: [1, 0],
                                  prefix: 0, clockSource: 2, setupFlags: 1, txErrors: 0)
        #expect(half.slot2 == .none)
        #expect(half.layout().slot1 == .optical)
        let none = SecondUnitInfo(boardType: [1, 1], boardValid: [0, 0], prefix: 0, clockSource: 2,
                                  setupFlags: 0, txErrors: 0)
        #expect(!none.layout().isKnown)
    }

    @Test("Prefix: the unit's own letter, else the one after unit A's")
    func prefix() {
        let own = SecondUnitInfo(slot1: .optical, slot2: .none, prefixByte: 0x44)
        #expect(own.prefix(after: "A") == "D")
        let none = SecondUnitInfo(slot1: .optical, slot2: .none, prefixByte: 0xFF)
        #expect(none.prefixLetter == nil)
        #expect(none.prefix(after: "A") == "B")
        #expect(none.prefix(after: "C") == "D")
        // After 'Z' the driver names unit B's channels 'A'.
        #expect(none.prefix(after: "Z") == "A")
        #expect(none.prefix(after: "?") == "B")
    }

    @Test("Clock and report lines")
    func report() {
        let info = SecondUnitInfo(slot1: .analogAES, slot2: .none, slotValid: [true, true], prefixByte: 0,
                                  clockSource: 2, setupFlags: 1, txErrors: 4)
        #expect(info.clockSourceName == "Word Clock")
        let lines = info.reportLines(unitAPrefix: "A")
        #expect(lines.contains("Unit B clock: Word Clock"))
        #expect(lines.contains("Unit B set-up: complete"))
        #expect(lines.contains("Unit B message errors: 4"))
        #expect(lines.contains("Unit B IOBoard 1: \(IOCardType.analogAES.productName)"))
        #expect(lines.contains("Unit B prefix: B (none kept on the unit)"))
    }

    @Test("A failed setup flag remains visible as incomplete")
    func failedSetupIsNotComplete() {
        let info = SecondUnitInfo(slot1: .analogAES, slot2: .none, slotValid: [true, true],
                                  setupFlags: 1 << 10, txErrors: 1)
        #expect(!info.setupComplete)
        #expect(info.reportLines(unitAPrefix: "A").contains("Unit B set-up: incomplete"))
        #expect(info.reportLines(unitAPrefix: "A").contains("Unit B message errors: 1"))
    }

    @Test("The picker shows only on ThunderBridge with unit B configured at 64 channels")
    func pickerVisibility() {
        let b = SecondUnitInfo(slot1: .optical, slot2: .none)
        #expect(UnitPicker.isVisible(transport: .thunderbolt, unitB: b, portSelection: .ports1And2, convertersPresent: false))
        #expect(UnitPicker.isVisible(transport: .thunderbolt, unitB: b, portSelection: nil, convertersPresent: false))
        #expect(!UnitPicker.isVisible(transport: .thunderbolt, unitB: nil, portSelection: .ports1And2, convertersPresent: false))
        #expect(!UnitPicker.isVisible(transport: .thunderbolt, unitB: b, portSelection: .port1, convertersPresent: false))
        #expect(!UnitPicker.isVisible(transport: .usb, unitB: b, portSelection: .ports1And2, convertersPresent: false))
        #expect(!UnitPicker.isVisible(transport: nil, unitB: b, portSelection: nil, convertersPresent: false))
        #expect(!UnitPicker.isVisible(transport: .thunderbolt, unitB: b, portSelection: .ports1And2, convertersPresent: true))
        #expect(UnitPicker.isPerUnit(page: "Input") && UnitPicker.isPerUnit(page: "Output"))
        #expect(UnitPicker.isPerUnit(page: "Input Routing") && UnitPicker.isPerUnit(page: "Device Settings"))
        // App Settings is Maestro's own, never one unit's; the retired page names are gone.
        for page in ["App Settings", "System Setup", "Hardware", "Preferences"] {
            #expect(!UnitPicker.isPerUnit(page: page), "\(page)")
        }
        #expect(!UnitPicker.isPerUnit(page: "Mixer") && !UnitPicker.isPerUnit(page: "Output Routing"))
        #expect(UnitPicker.label(.b, prefix: "B") == "Unit B (B)")
        #expect(DeviceUnit.a.portByte == 0 && DeviceUnit.b.portByte == 1)
    }

    @Test("Mixer at 64 channels: unit A's strips, then unit B's on mixer channels 32-63")
    func mixerStrips() {
        let a = CardLayout(slot1: .analogADDA16, slot2: .analogADDA16, isKnown: true)
        let b = CardLayout(slot1: .analogADDA16, slot2: .analogADDA16, isKnown: true)
        let strips = TwoUnitMixer.channels(unitA: a, unitB: b, prefixB: "B")
        #expect(strips.count == 64)
        #expect(strips.prefix(32).map(\.hardwareIndex) == Array(0..<32))
        #expect(strips.suffix(32).map(\.hardwareIndex) == Array(32..<64))
        #expect(strips[32].label == "B \(b.mixerChannels[0].label)")
        #expect(strips[0] == a.mixerChannels[0])
        // Without unit B nothing changes.
        #expect(TwoUnitMixer.channels(unitA: a, unitB: nil, prefixB: "B") == a.mixerChannels)
        // Smaller cards: unit B's IDs start at 32 whatever unit A has.
        let small = TwoUnitMixer.channels(unitA: CardLayout(slot1: .analogAES, slot2: .none, isKnown: true),
                                          unitB: CardLayout(slot1: .optical, slot2: .none, isKnown: true), prefixB: "C")
        #expect(small.count == 32)
        #expect(small[16].hardwareIndex == 32)
        #expect(small[16].label.hasPrefix("C "))
    }

    @Test("Unit B names share one prefix rule across mixer and routing columns")
    func perUnitNamesAndNotApplicable() {
        let optical = CardLayout(slot1: .optical, slot2: .none, isKnown: true,
                                 naming: .init(sampleRate: 192000, opticalIsSPDIF: [false, nil]))
        let strips = TwoUnitMixer.unitBChannels(layout: optical, prefix: "D")
        #expect(strips.first?.label == "D Line 1")
        #expect(strips.contains { $0.label == CardLayout.notApplicable })

        let columns = TwoUnitMixer.unitBRoutingColumns(layout: optical, prefix: "D", isInput: false)
        #expect(columns.first?.stereoName == "D Line 1/2")
        #expect(columns.contains { $0.stereoName == CardLayout.notApplicable })

        // Changing unit B's prefix never changes unit A's names; changing B's
        // optical format changes only B's derived digital labels.
        let a = CardLayout(slot1: .optical, slot2: .none, isKnown: true,
                           naming: .init(sampleRate: 48000, opticalIsSPDIF: [false, nil]))
        #expect(a.mixerChannels.first?.label == "Line 1")
        let adat = TwoUnitMixer.unitBChannels(layout: a, prefix: "Q")
        let spdif = TwoUnitMixer.unitBChannels(
            layout: CardLayout(slot1: .optical, slot2: .none, isKnown: true,
                               naming: .init(sampleRate: 48000, opticalIsSPDIF: [true, nil])),
            prefix: "Q")
        #expect(adat[8].label == "Q ADAT 1")
        #expect(spdif[8].label == "Q SPDIF Opt 1")
        #expect(a.mixerChannels.first?.label == "Line 1")
    }

    @Test("Software Return: 8 pairs with one unit, 32 with unit B")
    func softwareReturnPairs() {
        #expect(TwoUnitMixer.softwareReturnPairCount(unitBActive: false) == 8)
        #expect(TwoUnitMixer.softwareReturnPairCount(unitBActive: true) == 32)
        #expect(TwoUnitMixer.softwareReturnName(0) == "1-2")
        #expect(TwoUnitMixer.softwareReturnName(31) == "63-64")
    }

    @Test("The second-unit simulation parses card tokens")
    func simulationParse() {
        #expect(SecondUnitSimulation.key == "MaestroSimulateSecondUnit")
        #expect(SecondUnitSimulation.parse("16x16") == SecondUnitInfo(slot1: .analogADDA16, slot2: .none))
        #expect(SecondUnitSimulation.parse("analogAES+analogAD16") == SecondUnitInfo(slot1: .analogAES, slot2: .analogAD16))
        #expect(SecondUnitSimulation.parse("8x8+a16")?.slot2 == .analogAD16)
        #expect(SecondUnitSimulation.parse("nonsense") == nil)
        // An 8MicPre cannot be in slot 1.
        #expect(SecondUnitSimulation.parse("micPre8") == nil)
    }

    @Test("Help says how to cable and clock two units")
    func help() {
        let text = SecondUnitHelp.lines.joined(separator: " ")
        for phrase in ["PC-32", "port 1", "port 2", "Loop Sync", "Use Loop Sync", "master", "Word Clock",
                       "**Unit A / Unit B**", "SYM AIM", "Output Routing"] {
            #expect(text.contains(phrase), "\(phrase)")
        }
        for word in ["beta", "Beta", "test build"] { #expect(!text.contains(word)) }
        // The prefix, Speaker Mode and coax settings are sent to unit B now.
        #expect(!text.contains("Not sent to the second unit"))
        #expect(text.contains("The clock master's source cannot be Loop Sync"))
    }

    @Test("Software Return beyond DAW 1-16 after unit B goes")
    func softwareReturnAfterUnitB() {
        // Shown as 1-2 while only 8 pairs are offered; kept while unit B may still come.
        #expect(TwoUnitMixer.shownSoftwareReturnSource(20, pairCount: 8) == 0)
        #expect(TwoUnitMixer.shownSoftwareReturnSource(20, pairCount: 32) == 20)
        #expect(TwoUnitMixer.shownSoftwareReturnSource(7, pairCount: 8) == 7)
        #expect(TwoUnitMixer.sourceToSave(shown: 0, saved: 20, pairCount: 8) == 20)
        #expect(TwoUnitMixer.sourceToSave(shown: 3, saved: 20, pairCount: 8) == 3)
        #expect(TwoUnitMixer.sourceToSave(shown: 0, saved: 20, pairCount: 32) == 0)
        #expect(TwoUnitMixer.sourceToSave(shown: 0, saved: 5, pairCount: 8) == 0)
        // Held: neither saved over nor sent while unit B may still appear.
        #expect(TwoUnitMixer.isHeld(shown: 0, saved: 20, pairCount: 8))
        #expect(!TwoUnitMixer.isHeld(shown: 0, saved: 20, pairCount: 32))
        #expect(!TwoUnitMixer.isHeld(shown: 0, saved: 0, pairCount: 8))
        #expect(!TwoUnitMixer.isHeld(shown: 3, saved: 20, pairCount: 8))
        // Saved back to 1-2 only once unit B is known to be gone, as the driver does.
        #expect(TwoUnitMixer.resetsSavedSoftwareReturn(8, unitBKnownAbsent: true))
        #expect(!TwoUnitMixer.resetsSavedSoftwareReturn(7, unitBKnownAbsent: true))
        #expect(!TwoUnitMixer.resetsSavedSoftwareReturn(20, unitBKnownAbsent: false))
    }

    @Test("Device Info and Diagnostics carry unit B's lines")
    func deviceInfoLines() {
        var report = DeviceInfoReport(connection: "ThunderBridge")
        let without = report.clipboardText
        #expect(!without.contains("Unit B"))
        report.unitBLines = SecondUnitInfo(slot1: .optical, slot2: .none).reportLines(unitAPrefix: "A")
        #expect(report.clipboardText.hasPrefix(without))
        #expect(report.clipboardText.contains("Unit B (port 2): Symphony I/O"))
        #expect(report.clipboardText.contains("Unit B clock: Loop Sync"))
    }

    @Test("Output Routing at 64: unit A's saved rows keep their meaning")
    func outputRoutingRows() {
        #expect(TwoUnitOutputRouting.rowCount == 34)
        #expect(TwoUnitOutputRouting.gridRow(unitARow: 3, unitAPairs: 16) == 3)
        #expect(TwoUnitOutputRouting.gridRow(unitARow: 16, unitAPairs: 16) == 32)
        #expect(TwoUnitOutputRouting.gridRow(unitARow: 17, unitAPairs: 16) == 33)
        #expect(TwoUnitOutputRouting.gridRow(unitARow: 18, unitAPairs: 16) == 16)
        for row in 0..<34 {
            let grid = TwoUnitOutputRouting.gridRow(unitARow: row, unitAPairs: 16)!
            #expect(TwoUnitOutputRouting.unitARow(gridRow: grid, unitAPairs: 16) == row)
        }
        #expect(TwoUnitOutputRouting.unitARow(gridRow: 20, unitAPairs: 16) == 22)
        #expect(TwoUnitOutputRouting.unitAAccepts(gridRow: 16, unitAPairs: 16))
        #expect(TwoUnitOutputRouting.unitAAccepts(gridRow: 33, unitAPairs: 16))
        // Unit B output 1-2 plays DAW 33-34 by default (row 16).
        #expect(TwoUnitOutputRouting.defaultRow(unitBChannel: 0) == 16)
        #expect(TwoUnitOutputRouting.defaultRow(unitBChannel: 30) == 31)
    }
}
