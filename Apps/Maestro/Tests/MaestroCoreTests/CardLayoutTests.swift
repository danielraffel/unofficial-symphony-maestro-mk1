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
        #expect(layout.headphoneSources.first?.name == "ADAT 1-2")
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
        #expect(slot1In[5].name == "ADAT 1-2")

        // AD16: sixteen analog inputs, so all eight values are analog — and the
        // numbering continues past slot 1's eight analog inputs.
        let slot2In = dev.spdifOptions(slot: 1, isInput: true)
        #expect(slot2In.count == 9)
        #expect(slot2In[1].name == "Analog 9-10")
        #expect(slot2In[8].name == "Analog 23-24")

        // AD16 output side: all digital, numbered after slot 1's ADAT 1-8.
        let slot2Out = dev.spdifOptions(slot: 1, isInput: false)
        #expect(slot2Out[1].name == "ADAT 9-10")
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
                == ["Line 1-2", "Line 3-4", "Line 5-6", "AES 1-2", "ADAT 1-2", "ADAT 3-4", "ADAT 5-6", "ADAT 7-8"])
        // S/PDIF replace IDs are pair indices within the board's input channels,
        // which is what the daemon sent for the 2x6 too (SymphonyIOBoard_2x6.cpp:391-401).
        #expect(layout.spdifOptions(slot: 0, isInput: true).map(\.name)
                == ["Off", "Analog 1-2", "AES 1-2", "ADAT 1-2", "ADAT 3-4", "ADAT 5-6", "ADAT 7-8"])
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
        #expect(layout.spdifOptions(slot: 1, isInput: false).map(\.name).contains("ADAT 9-10"))
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
}
