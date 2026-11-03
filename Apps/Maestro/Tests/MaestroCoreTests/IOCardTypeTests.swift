import Testing
@testable import MaestroCore

/// Comprehensive tests for IOCardType — the option board model that drives
/// routing labels, channel counts, and analog/digital splits throughout the app.
///
/// Every card type is tested for every property to ensure routing matrices,
/// channel strips, and System Setup all show correct information.
///
/// Evidence: og_source/symphonymk1/ext/SymphonyIO/generic/Products/SymphonyIO/SymphonyIOVendorSpecific.h
/// Lines 800-810: SymphonyIOOptionBoardType enum (raw values 0-7).
/// Evidence: og_source/maestrolink/Software/SymphonyIO.cpp GetVersionDict() — display labels.
/// Evidence: og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp — USB 0xA1 reads.

@Suite("IOCardType")
struct IOCardTypeTests {

    // MARK: - Enum Completeness

    @Test func allCasesCount() {
        #expect(IOCardType.allCases.count == 8)
    }

    // MARK: - Raw Values (must match firmware SymphonyIOOptionBoardType enum)

    @Test func rawValues() {
        #expect(IOCardType.none.rawValue == 0)
        #expect(IOCardType.micPre8.rawValue == 1)
        #expect(IOCardType.analogAES.rawValue == 2)
        #expect(IOCardType.optical.rawValue == 3)
        #expect(IOCardType.analogAD16.rawValue == 4)
        #expect(IOCardType.analogDA16.rawValue == 5)
        #expect(IOCardType.analogADDA16.rawValue == 6)
        #expect(IOCardType.twoBySix.rawValue == 7)
    }

    @Test func rawValueRoundTrip() {
        for card in IOCardType.allCases {
            #expect(IOCardType(rawValue: card.rawValue) == card)
        }
    }

    @Test func invalidRawValueReturnsNil() {
        #expect(IOCardType(rawValue: 8) == nil)
        #expect(IOCardType(rawValue: 255) == nil)
    }

    // MARK: - Digital Label (human-readable name for UI display)

    @Test func digitalLabels() {
        #expect(IOCardType.none.digitalLabel == "None")
        #expect(IOCardType.micPre8.digitalLabel == "Mic Pre")
        #expect(IOCardType.analogAES.digitalLabel == "AES")
        #expect(IOCardType.optical.digitalLabel == "ADAT")
        #expect(IOCardType.analogAD16.digitalLabel == "Analog In")
        #expect(IOCardType.analogDA16.digitalLabel == "Analog Out")
        #expect(IOCardType.analogADDA16.digitalLabel == "Analog I/O")
        #expect(IOCardType.twoBySix.digitalLabel == "2x6")
    }

    // MARK: - hasAnalog / hasDigital / hasSPDIFCoax

    /// Both flags now derive from the converter counts. The hand-listed versions
    /// were wrong in both directions: `.optical` claimed no analog (it has 8 in
    /// and 8 out) and the AD16/DA16 claimed no digital (they have 16).
    @Test func hasAnalogFlags() {
        #expect(IOCardType.none.hasAnalog == false)
        #expect(IOCardType.micPre8.hasAnalog == false)   // delegate, no converters
        #expect(IOCardType.analogAES.hasAnalog == true)
        #expect(IOCardType.optical.hasAnalog == true)    // 8 analog I/O
        #expect(IOCardType.analogAD16.hasAnalog == true)
        #expect(IOCardType.analogDA16.hasAnalog == true)
        #expect(IOCardType.analogADDA16.hasAnalog == true)
        #expect(IOCardType.twoBySix.hasAnalog == true)
    }

    @Test func hasDigitalFlags() {
        #expect(IOCardType.none.hasDigital == false)
        #expect(IOCardType.micPre8.hasDigital == false)
        #expect(IOCardType.analogAES.hasDigital == true)
        #expect(IOCardType.optical.hasDigital == true)
        #expect(IOCardType.analogAD16.hasDigital == true)   // 16 optical out
        #expect(IOCardType.analogDA16.hasDigital == true)   // 16 optical in
        #expect(IOCardType.analogADDA16.hasDigital == false) // 16x16: none at all
        #expect(IOCardType.twoBySix.hasDigital == true)     // 2 AES + 8 optical
    }

    /// Every I/O module carries the S/PDIF coax RCA pair — user guide pp. 10-12
    /// show it on the 8x8, 16x16, A16 IP/OP and 2x6. The 8MicPre (p. 13) has
    /// only instrument jacks and insert DB-25s.
    @Test func spdifCoaxPresence() {
        #expect(IOCardType.none.hasSPDIFCoax == false)
        #expect(IOCardType.micPre8.hasSPDIFCoax == false)
        for card in IOCardType.allCases where card != .none && card != .micPre8 {
            #expect(card.hasSPDIFCoax, "\(card) should have S/PDIF coax")
        }
    }

    /// The format switch only exists on modules with optical ports. `.analogAES`
    /// counts because an 8x8 AES/OPT combo reports `.analogAES` in AES mode.
    @Test func opticalPortPresence() {
        #expect(IOCardType.none.hasOpticalPorts == false)
        #expect(IOCardType.micPre8.hasOpticalPorts == false)
        #expect(IOCardType.analogADDA16.hasOpticalPorts == false)  // 16x16: analog only
        #expect(IOCardType.optical.hasOpticalPorts)
        #expect(IOCardType.analogAES.hasOpticalPorts)
        #expect(IOCardType.analogAD16.hasOpticalPorts)
        #expect(IOCardType.analogDA16.hasOpticalPorts)
        #expect(IOCardType.twoBySix.hasOpticalPorts)
    }

    @Test func opticalFormatPropertyFollowsCardDirection() {
        #expect(IOCardType.optical.opticalFormatUsesInput)
        #expect(IOCardType.analogAES.opticalFormatUsesInput)
        #expect(IOCardType.twoBySix.opticalFormatUsesInput)
        #expect(!IOCardType.analogAD16.opticalFormatUsesInput)
        #expect(IOCardType.analogDA16.opticalFormatUsesInput)
    }

    // MARK: - Total Pairs Per Board

    @Test func totalPairsPerBoard() {
        // Every installed card has 8 stereo pairs (16 channels).
        // Evidence: SymphonyIORoutingController.h — cstSymphonyIORoutingController_SourcesPerBoard = 16
        #expect(IOCardType.none.totalPairsPerBoard == 0)
        for card in IOCardType.allCases where card != .none {
            #expect(card.totalPairsPerBoard == 8,
                    "\(card) should have 8 pairs, got \(card.totalPairsPerBoard)")
        }
    }

    // MARK: - Direction-Specific Pair Counts

    /// Every installed card's input analog + digital pairs must sum to 8 (the board total).
    @Test func inputPairsSumToTotal() {
        for card in IOCardType.allCases {
            let sum = card.analogInputPairsPerBoard + card.digitalInputPairsPerBoard
            #expect(sum == card.totalPairsPerBoard,
                    "\(card) input: \(card.analogInputPairsPerBoard) analog + \(card.digitalInputPairsPerBoard) digital = \(sum), expected \(card.totalPairsPerBoard)")
        }
    }

    /// Every installed card's output analog + digital pairs must sum to 8.
    @Test func outputPairsSumToTotal() {
        for card in IOCardType.allCases {
            let sum = card.analogOutputPairsPerBoard + card.digitalOutputPairsPerBoard
            #expect(sum == card.totalPairsPerBoard,
                    "\(card) output: \(card.analogOutputPairsPerBoard) analog + \(card.digitalOutputPairsPerBoard) digital = \(sum), expected \(card.totalPairsPerBoard)")
        }
    }

    // MARK: - Input Pair Counts (per card type)

    /// none: no board installed, 0 pairs.
    @Test func noneInputPairs() {
        #expect(IOCardType.none.analogInputPairsPerBoard == 0)
        #expect(IOCardType.none.digitalInputPairsPerBoard == 0)
    }

    /// micPre8: 8 pairs of BUS SLICE, not of channels.
    ///
    /// `*PairsPerBoard` is the fixed 16-channel XLink region a slot owns, which
    /// is 8 pairs for every installed board whatever the board actually carries.
    /// An 8MicPre has NO converters (`analogInputChannels == 0`); reading this
    /// number as "8 analog mic preamp inputs" is what put eight phantom strips,
    /// columns and mixer channels on screen. UI counts come from
    /// `analogInputPairsForUI` / `CardLayout`.
    @Test func micPre8InputPairs() {
        #expect(IOCardType.micPre8.analogInputPairsPerBoard == 8)
        #expect(IOCardType.micPre8.digitalInputPairsPerBoard == 0)
    }

    /// analogAES (8ch Analog-AES): 4 analog + 4 AES input pairs.
    @Test func analogAESInputPairs() {
        #expect(IOCardType.analogAES.analogInputPairsPerBoard == 4)
        #expect(IOCardType.analogAES.digitalInputPairsPerBoard == 4)
    }

    /// optical (8ch Analog-Optical): 4 analog + 4 ADAT input pairs.
    @Test func opticalInputPairs() {
        #expect(IOCardType.optical.analogInputPairsPerBoard == 4)
        #expect(IOCardType.optical.digitalInputPairsPerBoard == 4)
    }

    /// analogAD16 (16ch AD Optical): AD = analog-to-digital.
    /// Input side is ALL analog (8 pairs). Output side is all digital.
    @Test func analogAD16InputPairs() {
        #expect(IOCardType.analogAD16.analogInputPairsPerBoard == 8)
        #expect(IOCardType.analogAD16.digitalInputPairsPerBoard == 0)
    }

    /// analogDA16 (16ch DA Optical): DA = digital-to-analog.
    /// Input side is ALL digital/ADAT (8 pairs). Output side is all analog.
    @Test func analogDA16InputPairs() {
        #expect(IOCardType.analogDA16.analogInputPairsPerBoard == 0)
        #expect(IOCardType.analogDA16.digitalInputPairsPerBoard == 8)
    }

    /// analogADDA16 (16ch AD/DA): bidirectional analog, all 8 input pairs are analog.
    @Test func analogADDA16InputPairs() {
        #expect(IOCardType.analogADDA16.analogInputPairsPerBoard == 8)
        #expect(IOCardType.analogADDA16.digitalInputPairsPerBoard == 0)
    }

    /// twoBySix: 8 pairs of BUS SLICE. The module carries 2 analog + 2 AES +
    /// up to 8 optical inputs (user guide p. 12); the UI counts come from
    /// `analogInputPairsForUI` / `digitalInputPairsForUI`.
    @Test func twoBySixInputPairs() {
        #expect(IOCardType.twoBySix.analogInputPairsPerBoard == 8)
        #expect(IOCardType.twoBySix.digitalInputPairsPerBoard == 0)
    }

    // MARK: - Output Pair Counts (per card type)

    @Test func noneOutputPairs() {
        #expect(IOCardType.none.analogOutputPairsPerBoard == 0)
        #expect(IOCardType.none.digitalOutputPairsPerBoard == 0)
    }

    /// micPre8: 8 pairs of BUS SLICE again — it has no analog outputs at all
    /// (`analogOutputChannels == 0`). See `micPre8InputPairs`.
    @Test func micPre8OutputPairs() {
        #expect(IOCardType.micPre8.analogOutputPairsPerBoard == 8)
        #expect(IOCardType.micPre8.digitalOutputPairsPerBoard == 0)
    }

    /// analogAES: 4 analog + 4 AES output pairs (symmetric with input).
    @Test func analogAESOutputPairs() {
        #expect(IOCardType.analogAES.analogOutputPairsPerBoard == 4)
        #expect(IOCardType.analogAES.digitalOutputPairsPerBoard == 4)
    }

    /// optical: 4 analog + 4 ADAT output pairs (symmetric with input).
    @Test func opticalOutputPairs() {
        #expect(IOCardType.optical.analogOutputPairsPerBoard == 4)
        #expect(IOCardType.optical.digitalOutputPairsPerBoard == 4)
    }

    /// analogAD16: AD = analog-to-digital.
    /// Output side is ALL digital/ADAT (8 pairs). Input side is all analog.
    @Test func analogAD16OutputPairs() {
        #expect(IOCardType.analogAD16.analogOutputPairsPerBoard == 0)
        #expect(IOCardType.analogAD16.digitalOutputPairsPerBoard == 8)
    }

    /// analogDA16: DA = digital-to-analog.
    /// Output side is ALL analog (8 pairs). Input side is all digital.
    @Test func analogDA16OutputPairs() {
        #expect(IOCardType.analogDA16.analogOutputPairsPerBoard == 8)
        #expect(IOCardType.analogDA16.digitalOutputPairsPerBoard == 0)
    }

    /// analogADDA16: bidirectional analog, all 8 output pairs are analog.
    @Test func analogADDA16OutputPairs() {
        #expect(IOCardType.analogADDA16.analogOutputPairsPerBoard == 8)
        #expect(IOCardType.analogADDA16.digitalOutputPairsPerBoard == 0)
    }

    /// twoBySix: 8 pairs of BUS SLICE. The module carries 6 analog + 2 AES +
    /// up to 8 optical outputs. See `twoBySixInputPairs`.
    @Test func twoBySixOutputPairs() {
        #expect(IOCardType.twoBySix.analogOutputPairsPerBoard == 8)
        #expect(IOCardType.twoBySix.digitalOutputPairsPerBoard == 0)
    }

    // MARK: - Direction Asymmetry

    /// AD16 and DA16 are direction-asymmetric: one direction is all-analog, the other all-digital.
    @Test func adCardIsAsymmetric() {
        let ad = IOCardType.analogAD16
        // Input: all analog (AD converts analog input to digital output)
        #expect(ad.analogInputPairsPerBoard == 8)
        #expect(ad.digitalInputPairsPerBoard == 0)
        // Output: all digital
        #expect(ad.analogOutputPairsPerBoard == 0)
        #expect(ad.digitalOutputPairsPerBoard == 8)
    }

    @Test func daCardIsAsymmetric() {
        let da = IOCardType.analogDA16
        // Input: all digital (DA converts digital input to analog output)
        #expect(da.analogInputPairsPerBoard == 0)
        #expect(da.digitalInputPairsPerBoard == 8)
        // Output: all analog
        #expect(da.analogOutputPairsPerBoard == 8)
        #expect(da.digitalOutputPairsPerBoard == 0)
    }

    /// Optical and AES are symmetric: same split in both directions.
    @Test func opticalIsSymmetric() {
        let card = IOCardType.optical
        #expect(card.analogInputPairsPerBoard == card.analogOutputPairsPerBoard)
        #expect(card.digitalInputPairsPerBoard == card.digitalOutputPairsPerBoard)
    }

    @Test func analogAESIsSymmetric() {
        let card = IOCardType.analogAES
        #expect(card.analogInputPairsPerBoard == card.analogOutputPairsPerBoard)
        #expect(card.digitalInputPairsPerBoard == card.digitalOutputPairsPerBoard)
    }

    // MARK: - Digital Routing Label

    @Test func digitalRoutingLabels() {
        // AES cards use "AES" in routing; everything else uses "ADAT".
        #expect(IOCardType.analogAES.digitalRoutingLabel == "AES")
        #expect(IOCardType.optical.digitalRoutingLabel == "ADAT")
        #expect(IOCardType.analogAD16.digitalRoutingLabel == "ADAT")
        #expect(IOCardType.analogDA16.digitalRoutingLabel == "ADAT")
        #expect(IOCardType.analogADDA16.digitalRoutingLabel == "ADAT")
        #expect(IOCardType.micPre8.digitalRoutingLabel == "ADAT")
        #expect(IOCardType.twoBySix.digitalRoutingLabel == "ADAT")
        #expect(IOCardType.none.digitalRoutingLabel == "ADAT")
    }

    // MARK: - Real-World Board Configurations

    /// User's hardware: Board 1 = optical (8ch Analog-Optical), Board 2 = analogAD16 (16ch AD Optical).
    /// Input routing should show: 12 Line + 4 ADAT = 16 columns.
    @Test func realWorldInputRouting_OpticalPlusAD16() {
        let board1 = IOCardType.optical     // 4 analog + 4 ADAT input
        let board2 = IOCardType.analogAD16  // 8 analog + 0 digital input

        let totalAnalog = board1.analogInputPairsPerBoard + board2.analogInputPairsPerBoard
        let totalDigital = board1.digitalInputPairsPerBoard + board2.digitalInputPairsPerBoard

        #expect(totalAnalog == 12, "Expected 12 Line columns (4 + 8)")
        #expect(totalDigital == 4, "Expected 4 ADAT columns (4 + 0)")
        #expect(totalAnalog + totalDigital == 16)
    }

    /// Same hardware: Output routing should show: 4 Line + 12 ADAT = 16 columns.
    @Test func realWorldOutputRouting_OpticalPlusAD16() {
        let board1 = IOCardType.optical     // 4 analog + 4 ADAT output
        let board2 = IOCardType.analogAD16  // 0 analog + 8 ADAT output

        let totalAnalog = board1.analogOutputPairsPerBoard + board2.analogOutputPairsPerBoard
        let totalDigital = board1.digitalOutputPairsPerBoard + board2.digitalOutputPairsPerBoard

        #expect(totalAnalog == 4, "Expected 4 Line columns (4 + 0)")
        #expect(totalDigital == 12, "Expected 12 ADAT columns (4 + 8)")
        #expect(totalAnalog + totalDigital == 16)
    }

    /// Two optical boards: both directions should be 8 Line + 8 ADAT.
    @Test func dualOpticalRouting() {
        let board1 = IOCardType.optical
        let board2 = IOCardType.optical

        // Input
        #expect(board1.analogInputPairsPerBoard + board2.analogInputPairsPerBoard == 8)
        #expect(board1.digitalInputPairsPerBoard + board2.digitalInputPairsPerBoard == 8)

        // Output
        #expect(board1.analogOutputPairsPerBoard + board2.analogOutputPairsPerBoard == 8)
        #expect(board1.digitalOutputPairsPerBoard + board2.digitalOutputPairsPerBoard == 8)
    }

    /// Two ADDA16 boards: all 16 pairs are analog in both directions.
    @Test func dualADDA16Routing() {
        let board1 = IOCardType.analogADDA16
        let board2 = IOCardType.analogADDA16

        #expect(board1.analogInputPairsPerBoard + board2.analogInputPairsPerBoard == 16)
        #expect(board1.digitalInputPairsPerBoard + board2.digitalInputPairsPerBoard == 0)
        #expect(board1.analogOutputPairsPerBoard + board2.analogOutputPairsPerBoard == 16)
        #expect(board1.digitalOutputPairsPerBoard + board2.digitalOutputPairsPerBoard == 0)
    }

    /// AD16 + DA16: complementary boards.
    /// Input: AD16 has 8 analog, DA16 has 8 digital = 8 Line + 8 ADAT.
    /// Output: AD16 has 8 digital, DA16 has 8 analog = 8 Line + 8 ADAT.
    @Test func ad16PlusDA16Routing() {
        let board1 = IOCardType.analogAD16
        let board2 = IOCardType.analogDA16

        // Input
        #expect(board1.analogInputPairsPerBoard + board2.analogInputPairsPerBoard == 8)
        #expect(board1.digitalInputPairsPerBoard + board2.digitalInputPairsPerBoard == 8)

        // Output
        #expect(board1.analogOutputPairsPerBoard + board2.analogOutputPairsPerBoard == 8)
        #expect(board1.digitalOutputPairsPerBoard + board2.digitalOutputPairsPerBoard == 8)
    }

    // MARK: - Routing Byte Mapping (columnToRoutingByte / routingByteToColumn)

    /// Dual optical boards (4 analog + 4 digital per board, symmetric).
    /// Input columns: [0-3]=Board0 analog, [4-7]=Board1 analog, [8-11]=Board0 digital, [12-15]=Board1 digital.
    @Test func dualOptical_inputColumnToRoutingByte() {
        let b1 = IOCardType.optical
        let b2 = IOCardType.optical
        // Board 0 analog: bytes 32-39 (pairs at 32,34,36,38)
        #expect(IOCardType.columnToRoutingByte(col: 0, isInput: true, board1: b1, board2: b2) == 32)
        #expect(IOCardType.columnToRoutingByte(col: 3, isInput: true, board1: b1, board2: b2) == 38)
        // Board 1 analog: bytes 48-55
        #expect(IOCardType.columnToRoutingByte(col: 4, isInput: true, board1: b1, board2: b2) == 48)
        #expect(IOCardType.columnToRoutingByte(col: 7, isInput: true, board1: b1, board2: b2) == 54)
        // Board 0 digital: bytes 40-47
        #expect(IOCardType.columnToRoutingByte(col: 8, isInput: true, board1: b1, board2: b2) == 40)
        #expect(IOCardType.columnToRoutingByte(col: 11, isInput: true, board1: b1, board2: b2) == 46)
        // Board 1 digital: bytes 56-63
        #expect(IOCardType.columnToRoutingByte(col: 12, isInput: true, board1: b1, board2: b2) == 56)
        #expect(IOCardType.columnToRoutingByte(col: 15, isInput: true, board1: b1, board2: b2) == 62)
        // Out of range
        #expect(IOCardType.columnToRoutingByte(col: 16, isInput: true, board1: b1, board2: b2) == nil)
    }

    /// Reverse mapping: source byte → column for dual optical input.
    @Test func dualOptical_inputRoutingByteToColumn() {
        let b1 = IOCardType.optical
        let b2 = IOCardType.optical
        // Board 0 analog pair 0: byte 32 → col 0
        #expect(IOCardType.routingByteToColumn(byte: 32, isInput: true, board1: b1, board2: b2) == 0)
        // Board 0 digital pair 0: byte 40 → col 8
        #expect(IOCardType.routingByteToColumn(byte: 40, isInput: true, board1: b1, board2: b2) == 8)
        // Board 1 analog pair 0: byte 48 → col 4
        #expect(IOCardType.routingByteToColumn(byte: 48, isInput: true, board1: b1, board2: b2) == 4)
        // Board 1 digital pair 0: byte 56 → col 12
        #expect(IOCardType.routingByteToColumn(byte: 56, isInput: true, board1: b1, board2: b2) == 12)
        // Out of range
        #expect(IOCardType.routingByteToColumn(byte: 64, isInput: true, board1: b1, board2: b2) == nil)
    }

    /// Round-trip: every column maps to a byte and back to the same column.
    @Test func routingByteRoundTrip_dualOptical() {
        let b1 = IOCardType.optical
        let b2 = IOCardType.optical
        for col in 0..<16 {
            guard let byte = IOCardType.columnToRoutingByte(col: col, isInput: true, board1: b1, board2: b2) else {
                Issue.record("col \(col) returned nil byte")
                continue
            }
            let roundTripped = IOCardType.routingByteToColumn(byte: byte, isInput: true, board1: b1, board2: b2)
            #expect(roundTripped == col, "col \(col) → byte \(byte) → col \(String(describing: roundTripped))")
        }
    }

    /// Optical + AD16: output direction test.
    /// Board1 = optical (4 analog out + 4 digital out), Board2 = AD16 (0 analog out + 8 digital out).
    @Test func opticalPlusAD16_outputColumnToRoutingByte() {
        let b1 = IOCardType.optical
        let b2 = IOCardType.analogAD16
        // Board 1 analog out: cols 0-3 → bytes 32,34,36,38
        #expect(IOCardType.columnToRoutingByte(col: 0, isInput: false, board1: b1, board2: b2) == 32)
        #expect(IOCardType.columnToRoutingByte(col: 3, isInput: false, board1: b1, board2: b2) == 38)
        // Board 2 analog out: 0 pairs → skip
        // Board 1 digital out: cols 4-7 → bytes 40,42,44,46
        #expect(IOCardType.columnToRoutingByte(col: 4, isInput: false, board1: b1, board2: b2) == 40)
        #expect(IOCardType.columnToRoutingByte(col: 7, isInput: false, board1: b1, board2: b2) == 46)
        // Board 2 digital out: cols 8-15 → bytes 48,50,52,54,56,58,60,62
        #expect(IOCardType.columnToRoutingByte(col: 8, isInput: false, board1: b1, board2: b2) == 48)
        #expect(IOCardType.columnToRoutingByte(col: 15, isInput: false, board1: b1, board2: b2) == 62)
    }

    /// Dual routing: output columns 0-7 (IOBoard0) and 8-15 (IOBoard1) for dual optical.
    /// Each USB pair drives both boards — all 16 output columns should have valid bytes.
    @Test func dualOptical_allOutputColumnsValid() {
        let b1 = IOCardType.optical
        let b2 = IOCardType.optical
        for col in 0..<16 {
            let byte = IOCardType.columnToRoutingByte(col: col, isInput: false, board1: b1, board2: b2)
            #expect(byte != nil, "output col \(col) should map to a valid routing byte")
        }
    }

    /// Dual routing round-trip: output column → byte → column for both IOBoard0 and IOBoard1.
    @Test func dualOptical_outputRoutingByteRoundTrip() {
        let b1 = IOCardType.optical
        let b2 = IOCardType.optical
        for col in 0..<16 {
            guard let byte = IOCardType.columnToRoutingByte(col: col, isInput: false, board1: b1, board2: b2) else {
                Issue.record("col \(col) has no byte mapping")
                continue
            }
            let roundTripped = IOCardType.routingByteToColumn(byte: byte, isInput: false, board1: b1, board2: b2)
            #expect(roundTripped == col, "col \(col) → byte \(byte) → col \(String(describing: roundTripped))")
        }
    }

    /// Dual routing default pattern: each DAW pair maps to primary (col i) + secondary (col 8+i).
    @Test func dualRoutingDefaultPattern() {
        let hwPairCount = 16
        let swPairCount = 8
        let halfHw = hwPairCount / 2
        var defaultRoutes: [Int: Set<Int>] = [:]
        for i in 0..<swPairCount {
            var cols: Set<Int> = [i]
            let secondary = halfHw + i
            if secondary < hwPairCount { cols.insert(secondary) }
            defaultRoutes[i] = cols
        }
        // Each row should have exactly 2 columns (primary + secondary)
        for i in 0..<swPairCount {
            #expect(defaultRoutes[i]?.count == 2, "row \(i) should map to 2 columns")
            #expect(defaultRoutes[i]?.contains(i) == true, "row \(i) should contain primary col \(i)")
            #expect(defaultRoutes[i]?.contains(halfHw + i) == true, "row \(i) should contain secondary col \(halfHw + i)")
        }
    }

    /// Analog output pairs per board type match expected values.
    @Test func analogOutputPairsPerBoardType() {
        #expect(IOCardType.none.analogOutputPairsPerBoard == 0)
        #expect(IOCardType.optical.analogOutputPairsPerBoard == 4)    // 8 analog
        #expect(IOCardType.analogAES.analogOutputPairsPerBoard == 4)  // 8 analog
        #expect(IOCardType.analogAD16.analogOutputPairsPerBoard == 0) // AD = input only
        #expect(IOCardType.analogDA16.analogOutputPairsPerBoard == 8) // 16 analog out
        #expect(IOCardType.analogADDA16.analogOutputPairsPerBoard == 8)
    }

    /// Digital output pairs per board type match expected values.
    @Test func digitalOutputPairsPerBoardType() {
        #expect(IOCardType.none.digitalOutputPairsPerBoard == 0)
        #expect(IOCardType.optical.digitalOutputPairsPerBoard == 4)    // 8 ADAT
        #expect(IOCardType.analogAES.digitalOutputPairsPerBoard == 4)  // 8 AES
        #expect(IOCardType.analogAD16.digitalOutputPairsPerBoard == 8) // 16 ADAT (output side is digital)
        #expect(IOCardType.analogDA16.digitalOutputPairsPerBoard == 0) // DA = output analog only
    }

    /// Row label logic: first N pairs are "A Line", rest are "A ADAT".
    @Test func rowLabelLogic_dualOptical() {
        let board1 = IOCardType.optical
        let board2 = IOCardType.optical
        let analogPairs = board1.analogOutputPairsPerBoard + board2.analogOutputPairsPerBoard
        // Dual optical: 4+4 = 8 analog pairs → rows 0-7 are "A Line", none are "A ADAT"
        #expect(analogPairs == 8)
        // With 8 sw output pairs, all would be "A Line" for dual optical (all analog)
    }

    /// Row label logic: optical + AD16 has mixed analog/digital.
    @Test func rowLabelLogic_opticalPlusAD16() {
        let board1 = IOCardType.optical
        let board2 = IOCardType.analogAD16
        let analogPairs = board1.analogOutputPairsPerBoard + board2.analogOutputPairsPerBoard
        // Optical: 4 analog out, AD16: 0 analog out → 4 total analog
        #expect(analogPairs == 4)
        // With 8 sw output pairs: rows 0-3 = "A Line", rows 4-7 = "A ADAT"
        let swPairs = 8
        for i in 0..<swPairs {
            if i < analogPairs {
                // This row is analog
                #expect(i < 4, "row \(i) should be analog (A Line)")
            } else {
                // This row is digital
                #expect(i >= 4, "row \(i) should be digital (A ADAT)")
            }
        }
    }

    // MARK: - Apogee Product Naming

    /// The name Apogee prints on the module. This is what the user sees, because
    /// "16ch AD Optical" describes three different modules and identifies none.
    /// Evidence: `ApogeeRegistrationConstants.h:45-71`.
    @Test func productNames() {
        #expect(IOCardType.none.productName == "None")
        #expect(IOCardType.micPre8.productName == "8MicPre")
        #expect(IOCardType.analogAES.productName == "8x8 AES")
        #expect(IOCardType.optical.productName == "8x8 OPT")
        #expect(IOCardType.analogAD16.productName == "16 Analog In / 16 Digital Out")
        #expect(IOCardType.analogDA16.productName == "16 Digital In / 16 Analog Out")
        #expect(IOCardType.analogADDA16.productName == "16x16 Analog In/Out")
        #expect(IOCardType.twoBySix.productName == "2x6")
    }

    /// `displayName` is now the product name — the technical split moved to
    /// `technicalDescriptor` and stays available for UI that wants it.
    @Test func displayNameIsProductName() {
        for card in IOCardType.allCases {
            #expect(card.displayName == card.productName)
        }
    }

    @Test func productNamesAreUnique() {
        let names = Set(IOCardType.allCases.map(\.productName))
        #expect(names.count == IOCardType.allCases.count)
    }

    @Test func technicalDescriptorsPresentAndDistinct() {
        for card in IOCardType.allCases {
            #expect(!card.technicalDescriptor.isEmpty)
        }
        #expect(Set(IOCardType.allCases.map(\.technicalDescriptor)).count == 8)
        #expect(IOCardType.micPre8.technicalDescriptor.contains("delegate"))
        #expect(IOCardType.analogADDA16.technicalDescriptor.contains("no digital"))
    }

    @Test func detailedNameCombinesBoth() {
        #expect(IOCardType.none.detailedName == "None")
        #expect(IOCardType.optical.detailedName
                == "8x8 OPT (8 analog I/O + 8 ADAT optical I/O + 2 S/PDIF)")
    }

    // MARK: - The eighth module: 8x8 AES/OPT

    /// Apogee markets eight modules; the firmware enum has seven plus None.
    /// The combo 8x8 AES/OPT has no value of its own — the FPGA board-ID nibble
    /// only encodes AES (0x1) and Optical (0x2), so a combo module reports as
    /// whichever its front-panel switch selects.
    /// Evidence: `SymphonyIOMainFPGA.cpp:322-346`.
    @Test func onlyAESAndOpticalCanBeTheCombo() {
        #expect(IOCardType.analogAES.mayBeAESOpticalCombo)
        #expect(IOCardType.optical.mayBeAESOpticalCombo)
        for card in IOCardType.allCases where card != .analogAES && card != .optical {
            #expect(card.mayBeAESOpticalCombo == false, "\(card) is not an 8x8 combo candidate")
        }
    }

    /// Legacy disambiguated by board HARDWARE major version >= 6.
    /// Evidence: `SymphonyIOBoard_AnalogOptical.cpp:268-270`, `SymphonyIOBoard_AnalogAES.cpp:266-268`.
    @Test func comboResolvesOnHardwareRevision6() {
        #expect(IOCardType.aesOpticalComboHardwareMajorVersion == 6)
        #expect(IOCardType.optical.productName(boardHardwareMajorVersion: 6) == "8x8 AES/OPT")
        #expect(IOCardType.analogAES.productName(boardHardwareMajorVersion: 7) == "8x8 AES/OPT")
        #expect(IOCardType.optical.productName(boardHardwareMajorVersion: 5) == "8x8 OPT")
        #expect(IOCardType.analogAES.productName(boardHardwareMajorVersion: 5) == "8x8 AES")
    }

    /// Degrades gracefully: with no hardware revision read, we report what the
    /// module is currently doing rather than asserting a name we cannot support.
    @Test func comboDegradesGracefullyWithoutHardwareRevision() {
        #expect(IOCardType.optical.productName(boardHardwareMajorVersion: nil) == "8x8 OPT")
        #expect(IOCardType.analogAES.productName(boardHardwareMajorVersion: nil) == "8x8 AES")
        // Non-candidates ignore the revision entirely.
        #expect(IOCardType.analogADDA16.productName(boardHardwareMajorVersion: 9)
                == "16x16 Analog In/Out")
    }

    // MARK: - True Channel Contribution

    /// Physical channel contribution per module, from converter chip counts.
    /// Evidence: `SymphonyIOAnalogBoard.cpp:9-23` (chip counts), `:74-78` (derivation).
    @Test func analogChannelContribution() {
        #expect(IOCardType.none.analogInputChannels == 0)
        #expect(IOCardType.none.analogOutputChannels == 0)
        #expect(IOCardType.analogAES.analogInputChannels == 8)
        #expect(IOCardType.analogAES.analogOutputChannels == 8)
        #expect(IOCardType.optical.analogInputChannels == 8)
        #expect(IOCardType.optical.analogOutputChannels == 8)
        #expect(IOCardType.analogAD16.analogInputChannels == 16)
        #expect(IOCardType.analogAD16.analogOutputChannels == 0)
        #expect(IOCardType.analogDA16.analogInputChannels == 0)
        #expect(IOCardType.analogDA16.analogOutputChannels == 16)
        #expect(IOCardType.analogADDA16.analogInputChannels == 16)
        #expect(IOCardType.analogADDA16.analogOutputChannels == 16)
        #expect(IOCardType.twoBySix.analogInputChannels == 2)
        #expect(IOCardType.twoBySix.analogOutputChannels == 6)
    }

    /// The legacy bug we must not copy: `SymphonyIO.cpp:975-978` adds 16 in/out
    /// for every non-None board including MicPre8. A MicPre8 has NO converters —
    /// it is a delegate that sits in front of another board's analog inputs.
    @Test func micPreContributesZeroChannels() {
        #expect(IOCardType.micPre8.analogInputChannels == 0)
        #expect(IOCardType.micPre8.analogOutputChannels == 0)
        #expect(IOCardType.micPre8.digitalInputChannels == 0)
        #expect(IOCardType.micPre8.digitalOutputChannels == 0)
        #expect(IOCardType.micPre8.totalInputChannels == 0)
        #expect(IOCardType.micPre8.totalOutputChannels == 0)
        #expect(IOCardType.micPre8.isDelegateOnly)
    }

    @Test func digitalChannelContribution() {
        #expect(IOCardType.analogAES.digitalInputChannels == 8)
        #expect(IOCardType.analogAES.digitalOutputChannels == 8)
        #expect(IOCardType.optical.digitalInputChannels == 8)
        #expect(IOCardType.optical.digitalOutputChannels == 8)
        // AD = analog in, digital out.
        #expect(IOCardType.analogAD16.digitalInputChannels == 0)
        #expect(IOCardType.analogAD16.digitalOutputChannels == 16)
        // DA = digital in, analog out.
        #expect(IOCardType.analogDA16.digitalInputChannels == 16)
        #expect(IOCardType.analogDA16.digitalOutputChannels == 0)
        // The 16x16 has no digital at all.
        #expect(IOCardType.analogADDA16.digitalInputChannels == 0)
        #expect(IOCardType.analogADDA16.digitalOutputChannels == 0)
        // 2x6: 2 AES + up to 8 optical, each way (user guide p. 12).
        #expect(IOCardType.twoBySix.digitalInputChannels == 10)
        #expect(IOCardType.twoBySix.digitalOutputChannels == 10)
    }

    /// Only a module with **eight** analog inputs of its own can host a MicPre
    /// delegate: "The Mic Preamp Module upgrades the functionality of any 8x8 or
    /// 16x16 module" (user guide p. 13), echoed at p. 9.
    @Test func micPreHostEligibility() {
        #expect(IOCardType.analogAES.canHostMicPreDelegate)
        #expect(IOCardType.optical.canHostMicPreDelegate)
        #expect(IOCardType.analogAD16.canHostMicPreDelegate)
        #expect(IOCardType.analogADDA16.canHostMicPreDelegate)
        // Two analog inputs cannot host eight preamps — and a 2x6 is neither an
        // 8x8 nor a 16x16.
        #expect(IOCardType.twoBySix.canHostMicPreDelegate == false)
        // No analog inputs → nothing for the preamps to feed.
        #expect(IOCardType.analogDA16.canHostMicPreDelegate == false)
        #expect(IOCardType.none.canHostMicPreDelegate == false)
        // A MicPre cannot host another MicPre.
        #expect(IOCardType.micPre8.canHostMicPreDelegate == false)
    }

    // MARK: - Legacy Label Mapping

    @Test func legacyLabelsMapBack() {
        #expect(IOCardType.fromLegacyLabel("8ch Analog-Optical") == .optical)
        #expect(IOCardType.fromLegacyLabel("16ch AD Optical") == .analogAD16)
        #expect(IOCardType.fromLegacyLabel("8ch Mic Pre") == .micPre8)
        #expect(IOCardType.fromLegacyLabel("16ch AD/DA") == .analogADDA16)
        #expect(IOCardType.fromLegacyLabel("None") == IOCardType.none)
        #expect(IOCardType.fromLegacyLabel("nonsense") == nil)
    }

    /// Display name for board types (the user's dev unit pairing).
    @Test func displayNames() {
        #expect(IOCardType.none.displayName == "None")
        #expect(IOCardType.optical.displayName == "8x8 OPT")
        #expect(IOCardType.analogAD16.displayName == "16 Analog In / 16 Digital Out")
        #expect(IOCardType.micPre8.displayName == "8MicPre")
    }
}
