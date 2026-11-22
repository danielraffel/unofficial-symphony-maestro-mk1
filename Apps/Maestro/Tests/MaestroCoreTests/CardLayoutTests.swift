import Testing
@testable import MaestroCore

/// Every user-facing count, for every card pair.
///
/// These exist because `IOCardTypeTests` looked like coverage and was not: it
/// asserts `micPre8.analogInputPairsPerBoard == 8`, which is true of the XLink
/// **bus slice** and has nothing to do with what the user sees. The views read
/// that number, so a 16x16 + 8MicPre unit drew 32 output strips for 16 outputs,
/// 32 mixer strips for 16 channels, and eight routing columns for a module with
/// no converters at all.
@Suite("CardLayout")
struct CardLayoutTests {

    /// What each module physically contributes, from the evidence — not from the
    /// code under test.
    ///
    /// Analog: `SymphonyIOAnalogBoard.cpp:9-23`, `:74-78` (converter chip counts).
    /// Digital: `SymphonyIOBoard_AnalogOptical.cpp` / `_AnalogAES.cpp`, and for
    /// the 2x6 the user guide p. 12 (2 AES + up to 8 optical each way).
    /// MicPre8: zero of everything — it is a delegate
    /// (`SymphonyIO.cpp:955-961` → `SymphonyIO_IOBoard.cpp:606-627`).
    struct Contribution {
        let analogIn: Int, analogOut: Int, digitalIn: Int, digitalOut: Int
    }

    static func contribution(_ card: IOCardType) -> Contribution {
        switch card {
        case .none:         return Contribution(analogIn: 0,  analogOut: 0,  digitalIn: 0,  digitalOut: 0)
        case .micPre8:      return Contribution(analogIn: 0,  analogOut: 0,  digitalIn: 0,  digitalOut: 0)
        case .analogAES:    return Contribution(analogIn: 8,  analogOut: 8,  digitalIn: 8,  digitalOut: 8)
        case .optical:      return Contribution(analogIn: 8,  analogOut: 8,  digitalIn: 8,  digitalOut: 8)
        case .analogAD16:   return Contribution(analogIn: 16, analogOut: 0,  digitalIn: 0,  digitalOut: 16)
        case .analogDA16:   return Contribution(analogIn: 0,  analogOut: 16, digitalIn: 16, digitalOut: 0)
        case .analogADDA16: return Contribution(analogIn: 16, analogOut: 16, digitalIn: 0,  digitalOut: 0)
        case .twoBySix:     return Contribution(analogIn: 2,  analogOut: 6,  digitalIn: 10, digitalOut: 10)
        }
    }

    /// Every slot-1 × slot-2 pairing, including the ones hardware forbids —
    /// the layout must still answer sanely for a stale cache or a bad read.
    static let allPairs: [(IOCardType, IOCardType)] = IOCardType.allCases.flatMap { a in
        IOCardType.allCases.map { b in (a, b) }
    }

    // MARK: - The counts, across all 8 cards in both slots

    @Test func analogStripCountsMatchTheConverters() {
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            let c1 = Self.contribution(slot1), c2 = Self.contribution(slot2)
            #expect(layout.analogInputStripCount == c1.analogIn + c2.analogIn,
                    "\(slot1) + \(slot2) input strips")
            #expect(layout.analogOutputStripCount == c1.analogOut + c2.analogOut,
                    "\(slot1) + \(slot2) output strips")
        }
    }

    @Test func mixerStripCountMatchesTheInputChannels() {
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            let c1 = Self.contribution(slot1), c2 = Self.contribution(slot2)
            #expect(layout.mixerChannelCount
                    == c1.analogIn + c1.digitalIn + c2.analogIn + c2.digitalIn,
                    "\(slot1) + \(slot2) mixer strips")
        }
    }

    @Test func routingColumnCountsMatchTheConverters() {
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            let c1 = Self.contribution(slot1), c2 = Self.contribution(slot2)
            #expect(layout.inputRoutingColumns.count
                    == (c1.analogIn + c1.digitalIn + c2.analogIn + c2.digitalIn) / 2,
                    "\(slot1) + \(slot2) input columns")
            #expect(layout.outputRoutingColumns.count
                    == (c1.analogOut + c1.digitalOut + c2.analogOut + c2.digitalOut) / 2,
                    "\(slot1) + \(slot2) output columns")
        }
    }

    @Test func digitalSectionShowsWheneverAModuleIsInstalled() {
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            // Every module carries S/PDIF coax except the 8MicPre, and the
            // section holds the S/PDIF Replace / Mirrors controls.
            let expected = slot1.hasSPDIFCoax || slot2.hasSPDIFCoax
                || !layout.digitalInputPairs.isEmpty
            #expect(layout.showsDigitalSection(isInput: true) == expected,
                    "\(slot1) + \(slot2) input DIGITAL section")
            let expectedOut = slot1.hasSPDIFCoax || slot2.hasSPDIFCoax
                || !layout.digitalOutputPairs.isEmpty
            #expect(layout.showsDigitalSection(isInput: false) == expectedOut,
                    "\(slot1) + \(slot2) output DIGITAL section")
        }
    }

    @Test func headphoneSourceCountMatchesTheOutputPairs() {
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            let c1 = Self.contribution(slot1), c2 = Self.contribution(slot2)
            let pairs = (c1.analogOut + c1.digitalOut + c2.analogOut + c2.digitalOut) / 2
            // With no output pairs at all the popup falls back to four entries
            // rather than being empty.
            #expect(layout.headphoneSources.count == (pairs == 0 ? 4 : pairs),
                    "\(slot1) + \(slot2) HP sources")
            // IDs stay inside the 4-bit nibble of register 0x54.
            for source in layout.headphoneSources {
                #expect(source.id <= 15, "\(slot1) + \(slot2) HP id \(source.id)")
            }
        }
    }

    // MARK: - The unit this shipped for

    /// 16x16 Analog In/Out + 8MicPre — the configuration from issue #1.
    ///
    /// Before the fix: 32 output strips for 16 outputs, 32 mixer strips, 16
    /// routing columns each way (8 of them for a module with no converters), 16
    /// headphone sources where 8 exist, and NO S/PDIF controls — the card's only
    /// digital I/O.
    @Test func sixteenBySixteenPlusMicPre() {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        #expect(layout.analogInputStripCount == 16)
        #expect(layout.analogOutputStripCount == 16)
        #expect(layout.mixerChannelCount == 16)
        #expect(layout.inputRoutingColumns.count == 8)
        #expect(layout.outputRoutingColumns.count == 8)
        #expect(layout.digitalInputPairs.isEmpty)
        #expect(layout.digitalOutputPairs.isEmpty)
        // The S/PDIF column is present, from slot 1 only.
        #expect(layout.showsDigitalSection(isInput: true))
        #expect(layout.showsDigitalSection(isInput: false))
        #expect(layout.hasSPDIF(slot: 0))
        #expect(layout.hasSPDIF(slot: 1) == false)
        #expect(layout.headphoneSources.count == 8)
        #expect(layout.headphoneSources.first?.name == "Line 1-2")
        #expect(layout.headphoneSources.last?.name == "Line 15-16")
        // Every strip belongs to the 16x16 — the preamps are delegates on its
        // inputs, not channels of their own.
        for i in 0..<16 {
            #expect(layout.cardForAnalogInputStrip(i) == .analogADDA16)
        }
        // All eight S/PDIF Replace targets are analog pairs of the 16x16, not
        // four analog + four phantom "Digital" entries.
        let replace = layout.spdifOptions(slot: 0, isInput: true)
        #expect(replace.count == 9)  // Off + 8 pairs
        #expect(replace[1].name == "Analog 1-2")
        #expect(replace[8].name == "Analog 15-16")
        #expect(layout.spdifOptions(slot: 1, isInput: true).count == 1)  // Off only
    }

    /// A16 IP + 8MicPre: sixteen analog INPUTS and zero analog outputs. The old
    /// code drew sixteen analog *output* strips here.
    @Test func a16InputPlusMicPreHasNoAnalogOutputs() {
        let layout = CardLayout(slot1: .analogAD16, slot2: .micPre8)
        #expect(layout.analogInputStripCount == 16)
        #expect(layout.analogOutputStripCount == 0)
        #expect(layout.mixerChannelCount == 16)
        #expect(layout.inputRoutingColumns.count == 8)
        #expect(layout.outputRoutingColumns.count == 8)   // 8 ADAT output pairs
        #expect(layout.headphoneSources.count == 8)
        #expect(layout.headphoneSources.first?.name == "Optical 1-2")
    }

    /// The developer's own unit. Nothing about it may change.
    @Test func devUnitIsUnchanged() {
        let layout = CardLayout(slot1: .optical, slot2: .analogAD16)
        #expect(layout.analogInputStripCount == 24)   // 8 + 16
        #expect(layout.analogOutputStripCount == 8)   // 8 + 0
        #expect(layout.mixerChannelCount == 32)       // (8+8) + (16+0)
        #expect(layout.inputRoutingColumns.count == 16)
        #expect(layout.outputRoutingColumns.count == 16)
        #expect(layout.digitalInputPairs.count == 4)  // optical ADAT in
        #expect(layout.digitalOutputPairs.count == 12) // 4 optical + 8 AD16
        #expect(layout.headphoneSources.count == 16)
        #expect(layout.hasSPDIF(slot: 0))
        #expect(layout.hasSPDIF(slot: 1))
        #expect(layout.hasOpticalPorts(slot: 0))
        #expect(layout.hasOpticalPorts(slot: 1))

        // Routing bytes: identical to the pre-fix mapping, which is what keeps
        // this unit's routing grid working.
        let inputBytes = layout.inputRoutingColumns.map(\.routingByte)
        #expect(inputBytes == [32, 34, 36, 38,           // optical analog in
                               48, 50, 52, 54, 56, 58, 60, 62,  // AD16 analog in
                               40, 42, 44, 46])          // optical ADAT in
        let outputBytes = layout.outputRoutingColumns.map(\.routingByte)
        #expect(outputBytes == [32, 34, 36, 38,          // optical analog out
                                40, 42, 44, 46,          // optical ADAT out
                                48, 50, 52, 54, 56, 58, 60, 62])  // AD16 ADAT out
    }

    // MARK: - Meter indices (the page-open crash)

    /// `digital*MeterLevels` is a fixed 24 entries. `analogDA16 + analogDA16`
    /// reaches 16 digital input pairs and `analogAD16 + analogAD16` 16 digital
    /// output pairs; `pair * 2 + 1` on those ran off the end of the array.
    @Test func digitalMeterIndicesNeverEscapeTheArray() {
        let meterArrayCount = 24
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            for pair in layout.digitalInputPairs + layout.digitalOutputPairs {
                guard let index = pair.meterIndex else { continue }
                #expect(index + 1 < meterArrayCount,
                        "\(slot1) + \(slot2) \(pair.label) index \(index)")
            }
        }
    }

    @Test func dualDA16ExposesSixteenInputPairsAndMetersTheFirstFourPerBoard() {
        let layout = CardLayout(slot1: .analogDA16, slot2: .analogDA16)
        #expect(layout.digitalInputPairs.count == 16)
        let metered = layout.digitalInputPairs.filter { $0.meterIndex != nil }
        #expect(metered.count == 8)   // 4 per board
        #expect(layout.digitalInputPairs[0].meterIndex == 0)
        #expect(layout.digitalInputPairs[3].meterIndex == 6)
        #expect(layout.digitalInputPairs[4].meterIndex == nil)   // board 0 pair 5
        #expect(layout.digitalInputPairs[8].meterIndex == 8)     // board 1 pair 1
    }

    // MARK: - Empty and unknown slots

    /// `.none` and "not read yet" used to share a fallback, so an empty slot
    /// contributed eight columns a click could land on.
    @Test func aKnownEmptySlotContributesNothing() {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .none)
        #expect(layout.analogInputStripCount == 16)
        #expect(layout.inputRoutingColumns.count == 8)
        #expect(layout.outputRoutingColumns.count == 8)
        #expect(layout.inputRoutingColumns.allSatisfy { $0.boardIndex == 0 })
        #expect(layout.hasSPDIF(slot: 1) == false)
        #expect(layout.mixerChannelCount == 16)
    }

    /// Until slot 1 answers, the pages keep the full-width fallback so they are
    /// not blank — but nothing is claimed about the cards.
    @Test func anUnknownLayoutFallsBackToTheDeviceChannelCount() {
        let layout = CardLayout(slot1: .none, slot2: .none,
                                isKnown: false, fallbackChannelCount: 32)
        #expect(layout.analogInputStripCount == 32)
        #expect(layout.analogOutputStripCount == 32)
        #expect(layout.mixerChannelCount == 16)          // mixer caps at 16 here
        #expect(layout.inputRoutingColumns.count == 16)  // 8 pairs per slot
        #expect(layout.outputRoutingColumns.count == 16)
        #expect(layout.headphoneSources.count == 4)
        #expect(layout.hasSPDIF)
        #expect(layout.hasOpticalPorts(slot: 0))
    }

    // MARK: - Routing bytes

    /// Every column must address a real IOBoard byte, no column may collide with
    /// another, and the byte must map back to the column that produced it.
    @Test func routingBytesAreUniqueInRangeAndRoundTrip() {
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            for isInput in [true, false] {
                let columns = layout.routingColumns(isInput: isInput)
                var seen = Set<UInt8>()
                for (index, column) in columns.enumerated() {
                    #expect(column.routingByte >= 32 && column.routingByte <= 62,
                            "\(slot1) + \(slot2) col \(index) byte \(column.routingByte)")
                    #expect(column.routingByte % 2 == 0)
                    #expect(seen.insert(column.routingByte).inserted,
                            "\(slot1) + \(slot2) duplicate byte \(column.routingByte)")
                    // A board's bytes stay inside its own 16-byte region.
                    let base = column.boardIndex == 0 ? UInt8(32) : UInt8(48)
                    #expect(column.routingByte >= base && column.routingByte < base + 16)

                    #expect(IOCardType.columnToRoutingByte(
                        col: index, isInput: isInput, board1: slot1, board2: slot2)
                            == column.routingByte)
                    #expect(IOCardType.routingByteToColumn(
                        byte: column.routingByte, isInput: isInput,
                        board1: slot1, board2: slot2) == index)
                    // The right channel of the pair resolves to the same column.
                    #expect(IOCardType.routingByteToColumn(
                        byte: column.routingByte + 1, isInput: isInput,
                        board1: slot1, board2: slot2) == index)
                }
                // One past the end is nil, not a byte in an empty region.
                // Two empty slots are the exception: the static helper reads
                // that as "not detected yet" and keeps the launch-time
                // fallback grid (see undetectedBoardsKeepTheLegacyFallbackBytes).
                if slot1 != .none || slot2 != .none {
                    #expect(IOCardType.columnToRoutingByte(
                        col: columns.count, isInput: isInput,
                        board1: slot1, board2: slot2) == nil)
                }
            }
        }
    }

    /// Two `.none` slots are read as "not detected yet", which keeps the historic
    /// 16-column fallback the routing grid has always used at launch.
    @Test func undetectedBoardsKeepTheLegacyFallbackBytes() {
        #expect(IOCardType.columnToRoutingByte(col: 0, isInput: true,
                                               board1: .none, board2: .none) == 32)
        #expect(IOCardType.columnToRoutingByte(col: 15, isInput: true,
                                               board1: .none, board2: .none) == 62)
        #expect(IOCardType.columnToRoutingByte(col: 0, isInput: false,
                                               board1: .none, board2: .none) == 32)
    }

    // MARK: - Mixer channel order and IDs

    /// The daemon builds the mixer's input list by plug type first and board
    /// second — analog on both boards, then AES, then optical — and the channel
    /// ID the `0xB0`-`0xB3` commands take is the position in that compacted list.
    /// Evidence: `SymphonyIOMixer::init` (`SymphonyIOMixer.cpp:121-172`).
    @Test func mixerChannelsFollowTheDaemonsPlugTypeOrder() {
        let dev = CardLayout(slot1: .optical, slot2: .analogAD16)
        #expect(dev.mixerChannels.count == 32)
        #expect(dev.mixerChannels.map(\.hardwareIndex) == Array(0..<32))
        #expect(dev.mixerChannels[0].label == "Line 1")
        #expect(dev.mixerChannels[7].label == "Line 8")    // 8x8 OPT analog
        #expect(dev.mixerChannels[8].label == "Line 9")    // AD16 analog, not ADAT
        #expect(dev.mixerChannels[23].label == "Line 24")
        #expect(dev.mixerChannels[24].label == "ADAT 1")   // digital comes last
        #expect(dev.mixerChannels[31].label == "ADAT 8")
        #expect(dev.mixerChannels[8].boardIndex == 1)
        #expect(dev.mixerChannels[24].boardIndex == 0)
    }

    /// AES3 is walked before Optical.
    @Test func mixerPutsAESBeforeOptical() {
        let layout = CardLayout(slot1: .optical, slot2: .analogAES)
        let labels = layout.mixerChannels.map(\.label)
        #expect(labels.prefix(16) == ["Line 1", "Line 2", "Line 3", "Line 4",
                                      "Line 5", "Line 6", "Line 7", "Line 8",
                                      "Line 9", "Line 10", "Line 11", "Line 12",
                                      "Line 13", "Line 14", "Line 15", "Line 16"])
        // Slot 2's AES comes before slot 1's ADAT, and each plug type is
        // numbered from 1 in its own right.
        #expect(labels[16] == "AES 1")
        #expect(labels[23] == "AES 8")
        #expect(labels[24] == "ADAT 1")
    }

    /// The IDs stay dense: nothing is reserved for a slot that supplies nothing.
    @Test func mixerHardwareIDsAreCompact() {
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            #expect(layout.mixerChannels.map(\.hardwareIndex)
                    == Array(0..<layout.mixerChannels.count),
                    "\(slot1) + \(slot2) mixer IDs")
        }
    }

    /// A 16x16 + 8MicPre mixes sixteen channels, not thirty-two.
    @Test func mixerOnTheMicPreUnit() {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        #expect(layout.mixerChannels.map(\.label).last == "Line 16")
        #expect(layout.mixerChannels.allSatisfy { $0.boardIndex == 0 })
    }

    // MARK: - S/PDIF options

    /// The `SymphonyIOBoardSPDIFCoaxReplace` values are pair indices 1-8 inside
    /// the board's own slice — its header says so at `:936`, warning that the
    /// `Analog`/`Digital` names "dont make sense for certain boards (e.g. AD16
    /// which should have analog 1 through 16 instead of digital)".
    @Test func spdifOptionsAreTheBoardsOwnPairs() {
        let dev = CardLayout(slot1: .optical, slot2: .analogAD16)

        let slot1In = dev.spdifOptions(slot: 0, isInput: true)
        #expect(slot1In.map(\.id) == [0, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(slot1In[1].name == "Analog 1-2")
        #expect(slot1In[5].name == "Optical 1-2")

        // AD16: sixteen analog inputs, so all eight values are analog — and the
        // numbering continues past slot 1's eight analog inputs.
        let slot2In = dev.spdifOptions(slot: 1, isInput: true)
        #expect(slot2In.count == 9)
        #expect(slot2In[1].name == "Analog 9-10")
        #expect(slot2In[8].name == "Analog 23-24")

        // AD16 output side: all digital, numbered after slot 1's ADAT 1-8.
        let slot2Out = dev.spdifOptions(slot: 1, isInput: false)
        #expect(slot2Out[1].name == "Optical 9-10")
        #expect(slot2Out.map(\.id) == [0, 1, 2, 3, 4, 5, 6, 7, 8])

        // A module with no coax offers nothing but Off.
        let micPre = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        #expect(micPre.spdifOptions(slot: 1, isInput: false).map(\.id) == [0])
    }

    @Test func spdifOptionIDsNeverLeaveTheEnum() {
        for (slot1, slot2) in Self.allPairs {
            let layout = CardLayout(slot1: slot1, slot2: slot2)
            for slot in 0..<2 {
                for isInput in [true, false] {
                    for option in layout.spdifOptions(slot: slot, isInput: isInput) {
                        #expect(option.id <= 8,
                                "\(slot1) + \(slot2) slot \(slot) id \(option.id)")
                    }
                }
            }
        }
    }

    // MARK: - Front-panel meter banks

    @Test func meterBankSourcesFollowTheCards() {
        let sixteen = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        #expect(sixteen.hasMeterSource(0))      // Analog Out 1-8
        #expect(sixteen.hasMeterSource(1))      // Analog In 1-8
        #expect(sixteen.hasMeterSource(2) == false)  // Digital Out 1-8: none
        #expect(sixteen.hasMeterSource(3) == false)  // Digital In 1-8: none
        #expect(sixteen.hasMeterSource(4))      // Analog Out 9-16
        #expect(sixteen.hasMeterSource(5))      // Analog In 9-16

        let a16ip = CardLayout(slot1: .analogAD16, slot2: .none)
        #expect(a16ip.hasMeterSource(0) == false)  // no analog outputs at all
        #expect(a16ip.hasMeterSource(1))
        #expect(a16ip.hasMeterSource(2))           // 16 digital out
        #expect(a16ip.hasMeterSource(6))           // Digital Out 9-16
        #expect(a16ip.hasMeterSource(3) == false)  // no digital inputs
    }
}

// MARK: - 2x6 module (AES 1-2 then optical 1-8 on each side)

@Suite("2x6 module layout")
struct TwoBySixLayoutTests {
    // Evidence: SymphonyIOBoard_2x6.cpp:31-58 — AnalogIn(2), AESIn(2),
    // OpticalIn(8); AnalogOut(6), AESOut(2), OpticalOut(8), each stream taking
    // the next channels of the board's 16-channel region.

    @Test("Input routing columns: Line 1/2, AES 1/2, ADAT 1/2…7/8 at the legacy byte offsets")
    func inputColumns() {
        let layout = CardLayout(slot1: .twoBySix, slot2: .none)
        let cols = layout.inputRoutingColumns
        #expect(cols.map { "\($0.type) \($0.channels)" }
                == ["Line 1/2", "AES 1/2", "ADAT 1/2", "ADAT 3/4", "ADAT 5/6", "ADAT 7/8"])
        #expect(cols.map(\.routingByte) == [32, 34, 36, 38, 40, 42])
    }

    @Test("Output routing columns: Line 1/2…5/6, AES 1/2, ADAT 1/2…7/8")
    func outputColumns() {
        let layout = CardLayout(slot1: .twoBySix, slot2: .none)
        let cols = layout.outputRoutingColumns
        #expect(cols.map { "\($0.type) \($0.channels)" }
                == ["Line 1/2", "Line 3/4", "Line 5/6", "AES 1/2", "ADAT 1/2", "ADAT 3/4", "ADAT 5/6", "ADAT 7/8"])
        #expect(cols.map(\.routingByte) == [32, 34, 36, 38, 40, 42, 44, 46])
    }

    @Test("Digital pairs, headphone sources, S/PDIF options and mixer strips carry the split labels")
    func labelsEverywhere() {
        let layout = CardLayout(slot1: .twoBySix, slot2: .none)
        #expect(layout.digitalInputPairs.map(\.label) == ["AES 1/2", "ADAT 1/2", "ADAT 3/4", "ADAT 5/6", "ADAT 7/8"])
        #expect(layout.digitalOutputPairs.map(\.label) == ["AES 1/2", "ADAT 1/2", "ADAT 3/4", "ADAT 5/6", "ADAT 7/8"])
        #expect(layout.headphoneSources.map(\.name)
                == ["Line 1-2", "Line 3-4", "Line 5-6", "AES 1-2", "Optical 1-2", "Optical 3-4", "Optical 5-6", "Optical 7-8"])
        // S/PDIF replace IDs are pair indices within the board's input channels,
        // which is what the daemon sent for the 2x6 too (SymphonyIOBoard_2x6.cpp:391-401).
        #expect(layout.spdifOptions(slot: 0, isInput: true).map(\.name)
                == ["Off", "Analog 1-2", "AES 1-2", "Optical 1-2", "Optical 3-4", "Optical 5-6", "Optical 7-8"])
        #expect(layout.spdifOptions(slot: 0, isInput: true).map(\.id) == [0, 1, 2, 3, 4, 5, 6])
        #expect(layout.mixerChannels.map(\.label)
                == ["Line 1", "Line 2", "AES 1", "AES 2"] + (1...8).map { "ADAT \($0)" })
    }

    @Test("A second-slot 8x8 optical continues the 2x6's ADAT numbering, not its AES")
    func secondSlotNumbering() {
        let layout = CardLayout(slot1: .twoBySix, slot2: .optical)
        let names = layout.outputRoutingColumns.map { "\($0.type) \($0.channels)" }
        #expect(names.contains("ADAT 9/10"))      // slot 2 optical continues after the 2x6's ADAT 1-8
        #expect(!names.contains("AES 3/4"))
        #expect(layout.spdifOptions(slot: 1, isInput: false).map(\.name).contains("Optical 9-10"))
    }

    @Test("Every other module is unchanged: the per-pair label equals its single label")
    func otherModulesUnchanged() {
        for card in IOCardType.allCases where card != .twoBySix {
            for pair in 0..<8 {
                #expect(card.digitalLabel(forPair: pair) == card.digitalRoutingLabel, "\(card)")
            }
            for channel in 0..<16 {
                #expect(card.digitalChannelNumber(forChannel: channel) == channel + 1, "\(card)")
            }
        }
    }

    // MARK: - A unit that never reports its cards

    /// Reported with a DA-16X on a ThunderBridge: every fader on first launch,
    /// then no outputs at all on every later one. Two empty slots must fall back
    /// to the generic layout, not be drawn as a unit with nothing in it.
    @Test("two empty slots are not a known layout")
    func twoEmptySlotsAreUnknown() {
        #expect(!CardLayout.readingsDescribeAUnit(slot1: .none, slot2: .none))
        let layout = CardLayout(
            slot1: .none, slot2: .none,
            isKnown: CardLayout.readingsDescribeAUnit(slot1: .none, slot2: .none),
            fallbackChannelCount: 32)
        #expect(layout.analogOutputStripCount == 32)
        #expect(layout.analogInputStripCount == 32)
        #expect(layout.hasAnyCard)
    }

    @Test("one reported card makes the layout known, with the other slot empty")
    func oneCardIsKnown() {
        for card in IOCardType.allCases where card != .none {
            #expect(CardLayout.readingsDescribeAUnit(slot1: card, slot2: .none))
            #expect(CardLayout.readingsDescribeAUnit(slot1: .none, slot2: card))
        }
    }
}

/// The S/PDIF Coax Replaces / Mirrors menus, card by card, against the names
/// and IDs Apogee's daemon built. The daemon's menu ID is the wire value plus
/// one (`SymphonyIO_IOBoard.cpp:536-562`); ours is the wire value. Replaces
/// starts with Off; Mirrors has no Off (`SymphonyIO_IOBoard.cpp:1195-1220`).
@Suite("S/PDIF menus per card")
struct SPDIFMenuParityTests {

    /// The menu as the tab shows it: Replaces (input) as `spdifOptions` gives
    /// it, Mirrors (output) through `OutputChannelLogic.mirrorOptions`, which
    /// is what the Output tab lists.
    private func options(_ card: IOCardType, input: Bool,
                         slot2 other: IOCardType? = nil) -> [CardLayout.SPDIFOption] {
        let layout = other.map { CardLayout(slot1: $0, slot2: card) }
            ?? CardLayout(slot1: card, slot2: .none)
        let all = layout.spdifOptions(slot: other == nil ? 0 : 1, isInput: input)
        return input ? all : OutputChannelLogic.mirrorOptions(all)
    }

    private func menu(_ card: IOCardType, input: Bool, slot2 other: IOCardType? = nil) -> [String] {
        options(card, input: input, slot2: other).map(\.name)
    }

    /// Replaces starts with Off; Mirrors has no Off
    /// (`SymphonyIO_IOBoard.cpp:1195-1220`: nine Replaces IDs from 1, eight
    /// Mirrors IDs from 2).
    private func off(_ input: Bool) -> [String] { input ? ["Off"] : [] }

    /// The IDs are the wire values: the daemon's menu ID minus one
    /// (`SymphonyIO_IOBoard.cpp:536-562`). Replaces 0-8 (2x6: 0-6,
    /// `SymphonyIOBoard_2x6.cpp:568-584`), Mirrors 1-8, never 0.
    @Test func wireValues() {
        for card in [IOCardType.optical, .analogAES, .analogAD16, .analogDA16, .analogADDA16] {
            #expect(options(card, input: true).map(\.id) == Array(0...8))
            #expect(options(card, input: false).map(\.id) == Array(1...8))
        }
        #expect(options(.twoBySix, input: true).map(\.id) == Array(0...6))
        #expect(options(.twoBySix, input: false).map(\.id) == Array(1...8))
        // No coax jacks, no entries beyond Replaces' Off.
        #expect(options(.micPre8, input: false).isEmpty)
        #expect(options(.none, input: true).map(\.name) == ["Off"])
    }

    private func pairs(_ prefix: String, from first: Int, count: Int) -> [String] {
        (0..<count).map { "\(prefix) \(first + 2 * $0)-\(first + 2 * $0 + 1)" }
    }

    /// `SymphonyIOBoard_AnalogOptical.cpp:143-155`, `SymphonyIOBoard_AnalogAES.cpp:118-133`.
    @Test func eightByEight() {
        for input in [true, false] {
            #expect(menu(.optical, input: input)
                    == off(input) + pairs("Analog", from: 1, count: 4) + pairs("Optical", from: 1, count: 4))
            #expect(menu(.analogAES, input: input)
                    == off(input) + pairs("Analog", from: 1, count: 4) + pairs("AES", from: 1, count: 4))
        }
    }

    /// AD16 (A16 IP): Replaces names analog inputs, Mirrors names optical
    /// outputs (`SymphonyIOBoard_AD16ch.cpp:110-145, 151-187`). DA16 (A16 OP) is
    /// the reverse (`SymphonyIOBoard_DA16ch.cpp:113-150, 152-187`). ADDA16 is
    /// analog both ways (`SymphonyIOBoard_ADDA16ch.cpp:80-117`).
    @Test func sixteenChannelCards() {
        #expect(menu(.analogAD16, input: true) == ["Off"] + pairs("Analog", from: 1, count: 8))
        #expect(menu(.analogAD16, input: false) == pairs("Optical", from: 1, count: 8))
        #expect(menu(.analogDA16, input: true) == ["Off"] + pairs("Optical", from: 1, count: 8))
        #expect(menu(.analogDA16, input: false) == pairs("Analog", from: 1, count: 8))
        for input in [true, false] {
            #expect(menu(.analogADDA16, input: input) == off(input) + pairs("Analog", from: 1, count: 8))
        }
    }

    /// 2x6: Replaces IDs 1-7 = Off, Analog 1-2, AES 1-2, Optical 1-2..7-8;
    /// Mirrors IDs 2-9 = Analog 1-2..5-6, AES 1-2, Optical 1-2..7-8
    /// (`SymphonyIOBoard_2x6.cpp:18-24, 568-684`).
    @Test func twoBySix() {
        #expect(menu(.twoBySix, input: true)
                == ["Off", "Analog 1-2", "AES 1-2"] + pairs("Optical", from: 1, count: 4))
        #expect(menu(.twoBySix, input: false)
                == pairs("Analog", from: 1, count: 3) + ["AES 1-2"] + pairs("Optical", from: 1, count: 4))
    }

    /// Slot 2 numbers on from slot 1's channels of the same plug type
    /// (`SymphonyIO_IOBoard.cpp:1533-1541`). The owner's unit: an 8x8 AES/OPT
    /// in slot 1 (either switch position) and an A16 IP in slot 2.
    @Test func secondSlotContinuesSlotOnesNumbering() {
        #expect(menu(.analogAD16, input: true, slot2: .analogAES)
                == ["Off"] + pairs("Analog", from: 9, count: 8))
        // An AES board has no optical channels, so the A16 IP's optical starts at 1.
        #expect(menu(.analogAD16, input: false, slot2: .analogAES)
                == pairs("Optical", from: 1, count: 8))
        #expect(menu(.analogAD16, input: false, slot2: .optical)
                == pairs("Optical", from: 9, count: 8))
    }

    /// Optical outputs are "Optical n-m" in the headphone source list
    /// (`OpticalOut_SymphonyIO_Stream.cpp:121-150`), AES "AES n-m"
    /// (`AESOut_SymphonyIO_Stream.cpp:45-75`), analog "Line n-m"
    /// (`SymphonyIO_Stream.cpp:485-495`).
    @Test func headphoneSourceNames() {
        let names = CardLayout(slot1: .analogAES, slot2: .analogAD16).headphoneSources.map(\.name)
        #expect(names == pairs("Line", from: 1, count: 4) + pairs("AES", from: 1, count: 4)
                + pairs("Optical", from: 1, count: 8))
    }
}

/// Channel names follow the optical format, the rate and S/PDIF Coax Replaces,
/// as the daemon's `kAudioObjectPropertyElementName` did
/// (`OpticalIn_SymphonyIO_Stream.cpp:166-234`, `OpticalOut_SymphonyIO_Stream.cpp:170-232`,
/// `SymphonyIO_IOBoard.cpp:1312-1349`). The channel count never changes.
@Suite("Channel names follow rate, format and coax replace")
struct ChannelNamingTests {

    private func layout(_ s1: IOCardType, _ s2: IOCardType = .none, rate: Double? = nil,
                        spdif: [Bool?] = [nil, nil], replace: [UInt32] = [0, 0]) -> CardLayout {
        CardLayout(slot1: s1, slot2: s2,
                   naming: .init(sampleRate: rate, opticalIsSPDIF: spdif, spdifReplace: replace))
    }

    @Test func micPreNamesFollowInputLevelsAndCustomLabels() {
        let base = layout(.optical, .micPre8)
        for (level, name): (AnalogInputLevel, String) in [
            (.mic, "Mic 1"), (.instrument, "Inst 1"), (.variable, "Line 1"),
            (.plus4dBu, "Line 1"), (.minus10dBV, "Line 1"),
        ] {
            let named = base.namingAnalogInputs(levels: [level, level], labels: [])
            #expect(named.analogChannelName(board: 0, channelOnCard: 0, isInput: true) == name)
            #expect(named.mixerChannels.first?.label == name)
            #expect(named.inputRoutingColumns.first?.stereoName == name + "/2")

            let custom = base.namingAnalogInputs(levels: [level, level], labels: ["Vocal"])
            #expect(custom.analogChannelName(board: 0, channelOnCard: 0, isInput: true) == "Vocal")
            #expect(custom.mixerChannels.first?.label == "Vocal")
            #expect(custom.inputRoutingColumns.first?.stereoName.hasPrefix("Vocal/") == true)
            #expect(custom.inputRoutingColumns.map(\.routingByte) == base.inputRoutingColumns.map(\.routingByte))
            #expect(custom.outputRoutingColumns == base.outputRoutingColumns)
        }
        let noMicPre = layout(.optical).namingAnalogInputs(levels: [.mic], labels: [])
        #expect(noMicPre.mixerChannels.first?.label == "Line 1")
    }

    @Test func eightByEightOpticalByRate() {
        #expect(layout(.optical, rate: 48000).digitalInputPairs.map(\.label)
                == ["ADAT 1/2", "ADAT 3/4", "ADAT 5/6", "ADAT 7/8"])
        // Two ports carry four SMUX channels each: all eight are live.
        #expect(layout(.optical, rate: 96000).digitalOutputPairs.map(\.label)
                == ["SMUX 1/2", "SMUX 3/4", "SMUX 5/6", "SMUX 7/8"])
        #expect(layout(.optical, rate: 192000).digitalInputPairs.map(\.label)
                == ["N.A.", "N.A.", "N.A.", "N.A."])
        // Unknown rate names as the hardware starts: 44.1/48 kHz.
        #expect(layout(.optical).digitalInputPairs.first?.label == "ADAT 1/2")
    }

    @Test func spdifFormat() {
        #expect(layout(.optical, rate: 44100, spdif: [true, nil]).digitalInputPairs.map(\.label)
                == ["SPDIF Opt 1/2", "N.A.", "N.A.", "N.A."])
        #expect(layout(.optical, rate: 176400, spdif: [true, nil]).digitalInputPairs.first?.label == "N.A.")
        // DA16 inputs: two per eight-channel port (channels 1-2 and 9-10).
        #expect(layout(.analogDA16, rate: 48000, spdif: [true, nil]).digitalInputPairs.map(\.label)
                == ["SPDIF Opt 1/2", "N.A.", "N.A.", "N.A.", "SPDIF Opt 3/4", "N.A.", "N.A.", "N.A."])
        // AD16 outputs: the output stream tests against all 16 channels, so
        // only the first pair (`OpticalOut_SymphonyIO_Stream.cpp:188`).
        #expect(layout(.analogAD16, rate: 48000, spdif: [true, nil]).digitalOutputPairs.map(\.label)
                == ["SPDIF Opt 1/2"] + Array(repeating: "N.A.", count: 7))
    }

    @Test func twoBySixHasOneSMUXPort() {
        #expect(layout(.twoBySix, rate: 96000).digitalInputPairs.map(\.label)
                == ["AES 1/2", "SMUX 1/2", "SMUX 3/4", "N.A.", "N.A."])
        // AES is named the same at every rate.
        #expect(layout(.twoBySix, rate: 192000).digitalOutputPairs.map(\.label)
                == ["AES 1/2", "N.A.", "N.A.", "N.A.", "N.A."])
    }

    @Test func secondSlotNumbersOn() {
        #expect(layout(.optical, .optical, rate: 48000).digitalInputPairs[4].label == "ADAT 9/10")
        #expect(layout(.optical, .optical, rate: 88200).digitalInputPairs[4].label == "SMUX 9/10")
        #expect(layout(.optical, .optical, rate: 48000, spdif: [nil, true]).digitalInputPairs[4].label
                == "SPDIF Opt 3/4")
        // Owner's unit, combo on optical + A16 IP: the A16's outputs continue
        // after the combo's eight optical outputs.
        #expect(layout(.optical, .analogAD16, rate: 96000).digitalOutputPairs[4].label == "SMUX 9/10")
    }

    @Test func routingHeadersAndMixerFollowTheNames() {
        let l = layout(.optical, .analogAD16, rate: 192000)
        let digital = l.outputRoutingColumns.filter(\.isDigital)
        #expect(digital.allSatisfy { $0.type == "N.A." && $0.channels.isEmpty })
        // Same columns and bytes as at 48 kHz: only the names change.
        #expect(l.outputRoutingColumns.map(\.routingByte)
                == layout(.optical, .analogAD16, rate: 48000).outputRoutingColumns.map(\.routingByte))
        #expect(layout(.optical, rate: 96000).mixerChannels.map(\.label).suffix(8)
                == (1...8).map { "SMUX \($0)" })
        let smux = layout(.optical, rate: 96000).inputRoutingColumns.filter(\.isDigital)
        #expect(smux.map { "\($0.type) \($0.channels)" } == ["SMUX 1/2", "SMUX 3/4", "SMUX 5/6", "SMUX 7/8"])
    }

    /// S/PDIF Coax Replaces renames the replaced input pair "SPDIF Cx n";
    /// outputs are never renamed (`SymphonyIO_IOBoard.cpp:1317-1318`).
    @Test func coaxReplaceRenamesTheInputPair() {
        // Combo on AES, Replaces = AES 1-2 (wire 5).
        let aes = layout(.analogAES, .analogAD16, replace: [5, 0])
        #expect(aes.digitalInputPairs.map(\.label) == ["SPDIF Cx 1/2", "AES 3/4", "AES 5/6", "AES 7/8"])
        #expect(aes.digitalOutputPairs.first?.label == "AES 1/2")
        #expect(aes.mixerChannels.first { $0.label.hasPrefix("SPDIF") }?.label == "SPDIF Cx 1")
        // Slot 2 (A16 IP) replacing Analog 1-2 of that board: coax 3-4.
        let a16 = layout(.analogAES, .analogAD16, replace: [0, 1])
        let column = a16.inputRoutingColumns.first { $0.boardIndex == 1 }
        #expect(column.map { "\($0.type) \($0.channels)" } == "SPDIF Cx 3/4")
        #expect(a16.inputRoutingColumns.first.map { "\($0.type) \($0.channels)" } == "Line 1/2")
        // 2x6: wire 2 is its AES pair, wire 3 its first optical pair.
        #expect(layout(.twoBySix, replace: [2, 0]).digitalInputPairs.first?.label == "SPDIF Cx 1/2")
        #expect(layout(.twoBySix, replace: [3, 0]).digitalInputPairs[1].label == "SPDIF Cx 1/2")
    }

    /// Menus Apogee named statically stay static.
    @Test func menusDoNotFollowTheRate() {
        let l = layout(.optical, rate: 192000, spdif: [true, nil])
        #expect(l.headphoneSources.last?.name == "Optical 7-8")
        #expect(l.spdifOptions(slot: 0, isInput: true).last?.name == "Optical 7-8")
    }

    /// `APUtilities.m:323-400`.
    @Test func stereoNames() {
        #expect(CardLayout.stereoName(left: "ADAT 1", right: "ADAT 2") == "ADAT 1/2")
        #expect(CardLayout.stereoName(left: "N.A.", right: "N.A.") == "N.A.")
        #expect(CardLayout.stereoName(left: "SPDIF Opt 1", right: "SPDIF Opt 2") == "SPDIF Opt 1/2")
        #expect(CardLayout.stereoName(left: "SMUX 3", right: "N.A.") == "SMUX 3/N.A.")
    }

    /// Software pair names: the prefix letter in front of the routed pair's
    /// name, a bare "N.A." when both channels are N.A. (`APUtilities.m:323-400`).
    @Test func softwarePairNamesCarryThePrefix() {
        #expect(CardLayout.softwarePairName(hardwarePair: "Line 1/2", prefix: "A") == "A Line 1/2")
        #expect(CardLayout.softwarePairName(hardwarePair: "SPDIF Opt 1/2", prefix: "C") == "C SPDIF Opt 1/2")
        #expect(CardLayout.softwarePairName(hardwarePair: "N.A.", prefix: "A") == "N.A.")
        // A letter the unit has not been given reads as the daemon's default.
        #expect(CardLayout.softwarePairName(hardwarePair: "Line 1/2", prefix: "") == "A Line 1/2")
        #expect(CardLayout.peripheralPrefix("z") == "A")
        #expect(CardLayout.peripheralPrefix("Q") == "Q")
        #expect(CardLayout.peripheralPrefixByte("B") == 0x42)
        #expect(CardLayout.peripheralPrefixByte("b") == nil)
        #expect(CardLayout.peripheralPrefixByte(nil) == nil)
    }

    /// The reported unit (8x8 on optical, S/PDIF, + A16 IP, 48 kHz): software
    /// input rows follow what is routed to them, not their position. The
    /// original named each host input after its routed hardware source
    /// (`SymphonyCard.cpp:828-866`, bound in `APInputRoutingTabRowViewController.m:178-205`).
    @Test func softwareInputRowsFollowTheirRoutes() {
        let l = layout(.optical, .analogAD16, rate: 48000, spdif: [true, nil])
        let cols = l.inputRoutingColumns
        func col(_ name: String) -> Int { cols.firstIndex { $0.stereoName == name }! }
        let routes = [0: col("Line 1/2"), 4: col("SPDIF Opt 1/2"), 8: col("Line 9/10"),
                      12: col("Line 1/2")]
        let rows = CardLayout.softwareInputRowNames(rowCount: 16, routes: routes, columns: cols, prefix: "A")
        #expect(rows[0] == "A Line 1/2")
        #expect(rows[4] == "A SPDIF Opt 1/2")
        #expect(rows[8] == "A Line 9/10")
        #expect(rows[12] == "A Line 1/2")            // one input feeding two pairs
        #expect(rows[1] == "N.A.")                   // nothing routed
        #expect(rows[15] == "N.A.")
        // An N.A. column routed to a row names it N.A., and the column is marked.
        let na = cols.firstIndex { $0.isNotApplicable }!
        #expect(cols[na].stereoName == "N.A.")
        #expect(CardLayout.softwareInputRowNames(rowCount: 1, routes: [0: na], columns: cols, prefix: "A") == ["N.A."])
        // Live: the same route renames with the format and the prefix.
        let adat = layout(.optical, .analogAD16, rate: 48000, spdif: [false, nil]).inputRoutingColumns
        #expect(CardLayout.softwareInputRowNames(rowCount: 5, routes: routes, columns: adat, prefix: "B")[4]
                == "B ADAT 1/2")
        let high = layout(.optical, .analogAD16, rate: 192000, spdif: [true, nil]).inputRoutingColumns
        #expect(CardLayout.softwareInputRowNames(rowCount: 5, routes: routes, columns: high, prefix: "A")[4]
                == "N.A.")
        // Out-of-range routes are N.A., never a crash.
        #expect(CardLayout.softwareInputRowNames(rowCount: 2, routes: [0: 99, 1: -1], columns: cols, prefix: "A")
                == ["N.A.", "N.A."])
    }
}

@Suite("Analog strip names under S/PDIF Coax Replaces")
struct AnalogStripCoaxNameTests {
    @Test func replacedAnalogPairIsNamedSPDIFCx() {
        // Combo + A16 IP; slot 1 replaces Analog 3-4 (wire 2), slot 2 Analog 1-2 (wire 1).
        let layout = CardLayout(slot1: .analogAES, slot2: .analogAD16,
                                naming: .init(spdifReplace: [2, 1]))
        #expect(layout.coaxNameForAnalogInputStrip(1) == nil)
        #expect(layout.coaxNameForAnalogInputStrip(2) == "SPDIF Cx 1")
        #expect(layout.coaxNameForAnalogInputStrip(3) == "SPDIF Cx 2")
        #expect(layout.coaxNameForAnalogInputStrip(8) == "SPDIF Cx 3")   // slot 2 Line 9
        #expect(layout.coaxNameForAnalogInputStrip(9) == "SPDIF Cx 4")
        #expect(layout.coaxNameForAnalogInputStrip(10) == nil)
        // A digital replacement leaves every analog strip alone.
        let digital = CardLayout(slot1: .optical, naming: .init(spdifReplace: [5, 0]))
        #expect((0..<8).allSatisfy { digital.coaxNameForAnalogInputStrip($0) == nil })
    }
}
