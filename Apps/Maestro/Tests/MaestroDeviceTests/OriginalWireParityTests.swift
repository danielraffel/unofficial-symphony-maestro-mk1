import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

/// What Maestro sends for the controls touched in 0.8.38, checked against the
/// values in Apogee's original source. Reordering a menu or remembering a
/// selection must never change these.
@Suite("Wire parity with the original")
struct OriginalWireParityTests {

    /// `SymphonyIOCommands_AnalogReferenceLevel = 0x20`, pData[0] a
    /// `SymphonyIOAnalogIOType`: Variable 0, +4 dBu 1, -10 dBV 2, Mic 3,
    /// Instrument 4 (`SymphonyIOVendorSpecific.h:66-74, 718-726`).
    @Test("each Analog Level choice sends the original's value, whatever its place in the menu")
    func analogLevelValues() throws {
        let expected: [(AnalogInputLevel, UInt8)] = [
            (.variable, 0), (.plus4dBu, 1), (.minus10dBV, 2), (.mic, 3), (.instrument, 4),
        ]
        for (level, byte) in expected {
            #expect(level.rawValue == UInt32(byte))
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .analogIOType, scope: .input, element: 2),
                value: .uint32(level.rawValue | (0x7F << 8)))
            #expect(request.request == 0x20)
            #expect(request.data.first == byte)
        }
        // The menu order is the original's (AnalogIn_SymphonyIO_Stream.cpp:18).
        #expect(InputChannelLogic.analogLevelOptions(number: 1, micPreBacked: false)
                == [.plus4dBu, .minus10dBV, .variable])
        #expect(InputChannelLogic.analogLevelOptions(number: 1, micPreBacked: true)
                == [.plus4dBu, .minus10dBV, .variable, .mic, .instrument])
    }

    /// `SymphonyIOCommands_PhaseInverse = 0xC5`, nValue the channel, pData
    /// On(1) / Off(0) (`SymphonyIOVendorSpecific.h:417-419`).
    @Test("polarity sends 0xC5 with 1 or 0 for the channel")
    func polarity() throws {
        for (on, byte): (Bool, UInt8) in [(true, 1), (false, 0)] {
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .phaseReverse, element: 3), value: .bool(on))
            #expect(request.request == 0xC5)
            #expect(request.index == 3)
            #expect(Array(request.data) == [byte])
        }
    }

    /// `SymphonyIOCommands_MixerFaderLevel = 0xB0`: nValue[23:16] the mixer ID,
    /// 1-based; nValue[15:0] the channel; pData[0] the level from -48 to +6 dB
    /// as 0-54 (`SymphonyIOVendorSpecific.h:364-370`). Mix 2 is mixer ID 2.
    @Test("Mix 1 and Mix 2 fader writes carry mixer IDs 1 and 2")
    func mixerIDs() throws {
        for mixerID: UInt32 in [1, 2] {
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .mixerChannelLevel, element: (mixerID << 16) | 5),
                value: .float64(-12))
            #expect(request.request == 0xB0)
            #expect(request.value == UInt16(mixerID))
            #expect(request.index == 5)
            #expect(Array(request.data) == [36])   // -12 dB + 48
        }
    }

    /// `SymphonyIOVersion = 0xA0`, nValue a `SymphonyIOVersionType`: 5 slot 1
    /// board hardware, 6 slot 2; 3 bytes back (`SymphonyIOControl.cpp:1120-1142`).
    /// Over USB nValue travels in wIndex.
    @Test("board hardware version reads 0xA0 with type 5 or 6, 3 bytes")
    func boardHardwareVersion() async {
        let transport = MockXPCTransport()
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([6, 0, 0]))
        let id = USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID, productID: 0x0010, deviceUID: "parity")!
        let conn = XPCDeviceConnection(identifier: id, transport: transport)
        #expect(await conn.readBoardHardwareMajor(slot: 0) == 6)
        #expect(await conn.readBoardHardwareMajor(slot: 1) == 6)
        #expect(transport.getPropertyCalls.map { [$0.bRequest, UInt8($0.wValue), UInt8($0.wIndex), UInt8($0.dataLength)] }
                == [[0xA0, 0, 5, 3], [0xA0, 0, 6, 3]])
        transport.nextReply = XPCPropertyReply(status: -1, data: Data())
        #expect(await conn.readBoardHardwareMajor(slot: 0) == nil)
    }

    // MARK: Clock source over ThunderBridge, per card

    /// Symphony mode lists Internal, Word Clock, then each board's sources; an
    /// Analog-AES board's are SPDIF Coax then AES 1-2..7-8
    /// (`SymphonyIO.cpp:1750-1766`, `SymphonyIO_IOBoard.cpp:79-90`,
    /// `AESIn_SymphonyIO_Stream.cpp:40-44`). Choosing one sends ClockMode 0x50
    /// with `[IOBoard1 = 4, master 1, loop sync 0, input]`, the input an
    /// `SymphonyIOAnalogAESOptBoardClockSourceIdx`: AES pairs 0-3, coax 6
    /// (`AESIn_SymphonyIO_Stream.cpp:57-93`, `SymphonyIO_IOBoard.cpp:57-77`,
    /// `SymphonyIOControl.cpp:958-1011`, `SymphonyIOVendorSpecific.h:879-888`).
    /// The coax is named "SPDIF Coax n-m" (`SymphonyIO_IOBoard.cpp:1296-1303`).
    @Test("an AES card in slot 1 is offered as its coax and AES pairs, sent as the original sent them")
    func aesSlotClockSources() throws {
        let menu = ClockSourceMenu.thunderbolt(slot1: .analogAES, slot2: .none)
        #expect(menu.map(\.name) == ["Internal", "Word Clock",
                                      "SPDIF Coax 1-2", "AES 1-2", "AES 3-4", "AES 5-6", "AES 7-8"])
        // No Loop Sync: the original listed it only in Pro Tools HD mode
        // (`SymphonyIO.cpp:1726-1767`).
        let expectedBytes: [String: [UInt8]] = [
            "Internal": [1, 1, 0, 0],
            "Word Clock": [2, 1, 0, 0],
            "SPDIF Coax 1-2": [4, 1, 0, 6],
            "AES 1-2": [4, 1, 0, 0],
            "AES 3-4": [4, 1, 0, 1],
            "AES 5-6": [4, 1, 0, 2],
            "AES 7-8": [4, 1, 0, 3],
        ]
        for choice in menu {
            let decoded = try #require(ClockSourceMenu.decode(choice.id))
            #expect(decoded.source == choice.source)
            #expect(decoded.boardInput == choice.boardInput)
            let request = ThunderboltDeviceConnection.clockModeRequest(
                source: decoded.source, boardInput: decoded.boardInput ?? 0)
            #expect(request.request == 0x50)
            #expect(request.direction == .write)
            #expect(Array(request.data) == expectedBytes[choice.name], "\(choice.name)")
        }
        // The plain sources keep the numbers the driver's clock control uses.
        #expect(menu.filter { $0.boardInput == nil }.map(\.id) == [1, 2])
        #expect(!menu.contains { $0.source == 3 })
    }

    /// Slot 2 numbers on from slot 1 (`SymphonyIO_IOBoard.cpp:1533-1541`): after
    /// an AES board, AES 9-10..15-16 and coax 3-4, with IOBoard2 = 5 as source.
    @Test("an AES card in slot 2 numbers on from slot 1 and clocks from board 2")
    func secondAESSlot() {
        let menu = ClockSourceMenu.thunderbolt(slot1: .analogAES, slot2: .analogAES)
        let slot2 = menu.filter { $0.source == 5 }
        #expect(slot2.map(\.name) == ["SPDIF Coax 3-4", "AES 9-10", "AES 11-12", "AES 13-14", "AES 15-16"])
        #expect(slot2.map { $0.boardInput } == [6, 0, 1, 2, 3])
        let afterOptical = ClockSourceMenu.thunderbolt(slot1: .optical, slot2: .analogAES)
        #expect(afterOptical.filter { $0.source == 5 }.map(\.name)
                == ["SPDIF Coax 3-4", "AES 1-2", "AES 3-4", "AES 5-6", "AES 7-8"])
    }

    /// Every other card's own inputs: coax (6) first, then its AES and optical
    /// input streams' sources (`SymphonyIO_IOBoard.cpp:79-90`,
    /// `NonCADeviceObject.cpp:326-370`). The optical source is input 4
    /// (`OpticalIn_SymphonyIO_Stream.cpp:106-129`), on a DA16 0 in S/PDIF and 2
    /// in ADAT/SMUX (`DA16OpticalIn_SymphonyIO_Stream.cpp:24-45`). AD16 and
    /// ADDA16 have no digital inputs, so only the coax. An 8MicPre or empty
    /// slot lists nothing.
    @Test("each card is offered as its own inputs with the original's input bytes",
          arguments: [
            (IOCardType.optical, ["SPDIF Coax 1-2", "ADAT 1-8"], [UInt8(6), 4]),
            // The daemon names the single optical source "ADAT n-(n+7)" on
            // every card, the 16-channel DA16 included
            // (`OpticalIn_SymphonyIO_Stream.cpp:285-288`).
            (.analogDA16, ["SPDIF Coax 1-2", "ADAT 1-8"], [6, 2]),
            (.twoBySix, ["SPDIF Coax 1-2", "AES 1-2", "ADAT 1-8"], [6, 0, 4]),
            (.analogAD16, ["SPDIF Coax 1-2"], [6]),
            (.analogADDA16, ["SPDIF Coax 1-2"], [6]),
            (.micPre8, [], []),
            (.none, [], []),
          ])
    func cardClockSources(card: IOCardType, names: [String], inputs: [UInt8]) {
        let rows = ClockSourceMenu.thunderbolt(slot1: card, slot2: .none).filter { $0.source == 4 }
        #expect(rows.map(\.name) == names)
        #expect(rows.map { $0.boardInput } == inputs.map { Optional($0) })
    }

    /// The optical source's name follows the rate and the format
    /// (`OpticalIn_SymphonyIO_Stream.cpp:257-295`); on a DA16 the S/PDIF format
    /// also changes the byte sent.
    @Test("the optical clock row follows the rate and format")
    func opticalClockRowFollowsRateAndFormat() {
        func optical(_ card: IOCardType, slot1: IOCardType = .none, rate: Double?, spdif: Bool?)
            -> ClockSourceChoice? {
            let menu = slot1 == .none
                ? ClockSourceMenu.thunderbolt(slot1: card, slot2: .none, sampleRate: rate,
                                              opticalIsSPDIF: [spdif, nil])
                : ClockSourceMenu.thunderbolt(slot1: slot1, slot2: card, sampleRate: rate,
                                              opticalIsSPDIF: [nil, spdif])
            return menu.last
        }
        #expect(optical(.optical, rate: 48000, spdif: false)?.name == "ADAT 1-8")
        #expect(optical(.optical, rate: 96000, spdif: false)?.name == "SMUX 1-4")
        #expect(optical(.optical, rate: 192000, spdif: false)?.name == "N.A.")
        #expect(optical(.optical, rate: 44100, spdif: true)?.name == "SPDIF Opt 1-2")
        #expect(optical(.optical, rate: 176400, spdif: true)?.name == "N.A.")
        // Slot 2 after an 8x8 optical: ADAT 9-16, SPDIF Opt 3-4.
        #expect(optical(.optical, slot1: .optical, rate: 48000, spdif: false)?.name == "ADAT 9-16")
        #expect(optical(.optical, slot1: .optical, rate: 48000, spdif: true)?.name == "SPDIF Opt 3-4")
        // An A16 IP has no optical inputs, so slot 2 optical starts at 1.
        #expect(optical(.optical, slot1: .analogAD16, rate: 48000, spdif: false)?.name == "ADAT 1-8")
        #expect(optical(.analogDA16, rate: 48000, spdif: true)?.boardInput == 0)
        #expect(optical(.analogDA16, rate: 48000, spdif: false)?.boardInput == 2)
        #expect(optical(.optical, rate: 48000, spdif: true)?.boardInput == 4)
    }

    /// The owner's unit: an 8x8 AES/OPT in slot 1 and an A16 IP in slot 2.
    @Test("AES/OPT combo + A16 IP: the menu in each DIG I/O position")
    func ownersUnit() {
        #expect(ClockSourceMenu.thunderbolt(slot1: .analogAES, slot2: .analogAD16).map(\.name)
                == ["Internal", "Word Clock", "SPDIF Coax 1-2",
                    "AES 1-2", "AES 3-4", "AES 5-6", "AES 7-8", "SPDIF Coax 3-4"])
        #expect(ClockSourceMenu.thunderbolt(slot1: .optical, slot2: .analogAD16).map(\.name)
                == ["Internal", "Word Clock", "SPDIF Coax 1-2", "ADAT 1-8", "SPDIF Coax 3-4"])
        #expect(ClockSourceMenu.usb.map(\.id) == [1])
    }

    /// The board input byte is the enum value, not the ClockMode comment's
    /// numbering (`SymphonyIOVendorSpecific.h:879-888` vs `:234-247`).
    @Test("board clock inputs carry the SymphonyIOAnalogAESOptBoardClockSourceIdx values")
    func boardInputWireIndex() {
        #expect(BoardClockSource.allCases.map(\.wireIndex) == [0, 1, 2, 3, 4, 5, 6])
        #expect(BoardClockSource.spdifCoax.wireIndex == 6)
    }

    /// The unit reports the source and input in the front panel read (0x28,
    /// bytes 5 and 6, as the daemon read them at `SymphonyIO.cpp:6811`).
    @Test("a reported board input selects its row, or the board's single row")
    func reportedClockSourceRow() {
        let aes = ClockSourceMenu.thunderbolt(slot1: .analogAES, slot2: .optical)
        let reportedAES56 = ThunderboltDeviceConnection.clockSourceKey(reportedSource: 4, boardInput: 2)
        #expect(reportedAES56.flatMap { ClockSourceMenu.row(for: $0, in: aes) }
                == ClockSourceMenu.key(source: 4, boardInput: 2))
        // Board 2 is an optical card: its optical input (4) is its own row.
        let reportedOptical = ThunderboltDeviceConnection.clockSourceKey(reportedSource: 5, boardInput: 4)
        #expect(reportedOptical.flatMap { ClockSourceMenu.row(for: $0, in: aes) }
                == ClockSourceMenu.key(source: 5, boardInput: 4))
        // A plain 5 (the driver's control, input 0) has no row on an optical board.
        #expect(ClockSourceMenu.row(for: 5, in: aes) == nil)
        // The driver's control reports a plain 4: on an AES board that is AES 1-2.
        #expect(ClockSourceMenu.row(for: 4, in: aes) == ClockSourceMenu.key(source: 4, boardInput: 0))
        #expect(ThunderboltDeviceConnection.clockSourceKey(reportedSource: 2, boardInput: 3) == 2)
        #expect(ThunderboltDeviceConnection.clockSourceKey(reportedSource: 0, boardInput: 0) == nil)
        #expect(ThunderboltDeviceConnection.clockSourceKey(reportedSource: 6, boardInput: 0) == nil)
        #expect(ClockSourceMenu.decode(ClockSourceMenu.key(source: 1, boardInput: 0)) == nil)
        // Nothing above the coax input (6) is ever sent or shown.
        #expect(ClockSourceMenu.decode(0x0804) == nil)
        #expect(ClockSourceMenu.decode(0xFF04) == nil)
        #expect(ClockSourceMenu.decode(0x0704)?.boardInput == 6)
        #expect(ThunderboltDeviceConnection.clockSourceKey(reportedSource: 4, boardInput: 7) == nil)
        #expect(ClockSourceMenu.row(for: 0, in: aes) == nil)
    }

    // MARK: ThunderBridge clock readback

    @Test("clock readback: a fresh unit report wins, then a board input written while the control is unchanged")
    func clockStateOrder() {
        let state = ThunderboltClockState()
        let t0 = Date(timeIntervalSince1970: 1000)
        let aes34 = ClockSourceMenu.key(source: 4, boardInput: 1)
        #expect(state.current(control: 1, now: t0) == nil)
        // Written through the vendor path; the control still says Internal.
        state.wroteBoardInput(aes34, control: 1, now: t0)
        #expect(state.current(control: 1, now: t0) == aes34)
        // Audio MIDI Setup moved the control: the control wins.
        #expect(state.current(control: 2, now: t0) == nil)
        // The unit's own report wins while it is recent.
        let coax = ClockSourceMenu.key(source: 4, boardInput: 6)
        state.reported(coax, now: t0)
        #expect(state.current(control: 2, now: t0.addingTimeInterval(1)) == coax)
        #expect(state.current(control: 2, now: t0.addingTimeInterval(10)) == nil)
        // A plain write clears both.
        state.reported(coax, now: t0)
        state.wrotePlain()
        #expect(state.current(control: 1, now: t0) == nil)
    }

    // MARK: S/PDIF coax Replaces / Mirrors

    /// `SymphonyIOCommands_SPDIFCoaxReplaceInput = 0x35` and
    /// `..._SPDIFCoaxMirrorOutput = 0x36`: nValue the board index, pData[0] a
    /// `SymphonyIOBoardSPDIFCoaxReplace` (Off 0, then pairs 1-8;
    /// `SymphonyIOVendorSpecific.h:190-216, 940-951`). The daemon's menu IDs are
    /// the wire value plus one (`SymphonyIO_IOBoard.cpp:536-562`); the app's
    /// option IDs are the wire values themselves.
    @Test("S/PDIF Replaces and Mirrors send 0x35 / 0x36 with the board as nValue on both slots",
          arguments: [UInt32(0), 1])
    func spdifCoaxBothSlots(board: UInt32) throws {
        for (selector, command) in [(AudioPropertySelector.spdifReplaceID, UInt8(0x35)),
                                    (.spdifMirrorID, UInt8(0x36))] {
            for wire: UInt32 in 0...8 {
                let request = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: selector, element: board), value: .uint32(wire))
                #expect(request.request == command)
                #expect((UInt32(request.value) << 16) | UInt32(request.index) == board)
                #expect(Array(request.data) == [UInt8(wire)])
            }
        }
    }

    /// The Output tab once wrote slot 2's Mirrors as 'AEsJ', which maps to no
    /// command on either transport; slot 2 is 0x36 with nValue 1.
    @Test("'AEsJ' is not a Symphony command; slot 2 Mirrors is AEs7 element 1")
    func spdifMirror2IsNotACommand() {
        #expect(throws: (any Error).self) {
            try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .spdifMirror2ID), value: .uint32(1))
        }
    }
}

@Suite("Preset digital settings per slot")
struct PresetDigitalWritesTests {
    @Test("both slots' optical format, Replaces and Mirrors are written to the cards that have them")
    func bothSlots() {
        var preset = MaestroPreset()
        preset.opticalInFormat = 1
        preset.spdifReplaceID = 5
        preset.spdifMirrorID = 2
        preset.slot2OpticalFormat = 1
        preset.slot2SPDIFReplaceID = 1
        preset.slot2SPDIFMirrorID = 8
        // Combo on optical + A16 IP (optical outputs only).
        let writes = PresetDigitalWrites.writes(
            for: preset, layout: CardLayout(slot1: .optical, slot2: .analogAD16))
        #expect(writes.map { "\($0.address.selector)/\($0.address.element)=\($0.value)" } == [
            "'AEoi'/0=1", "'AEs0'/0=5", "'AEs7'/0=2",
            "'AEoo'/1=1", "'AEs0'/1=1", "'AEs7'/1=8",
        ])
        // On the wire: board index in nValue for both slots.
        for write in writes where write.address.selector != .opticalInFormat
            && write.address.selector != .opticalOutFormat {
            let request = try? SymphonyIOPropertyMapper.buildWriteRequest(
                for: write.address, value: .uint32(write.value))
            #expect(request.map { (UInt32($0.value) << 16) | UInt32($0.index) } == write.address.element)
        }
    }

    @Test("no optical format for an AES card, Mirrors never Off, unsaved slot 2 untouched")
    func skips() {
        var preset = MaestroPreset()          // spdifMirrorID 0 = an old preset's default
        preset.opticalInFormat = 1
        let writes = PresetDigitalWrites.writes(
            for: preset, layout: CardLayout(slot1: .analogAES, slot2: .micPre8))
        #expect(writes.map(\.address.selector) == [.spdifReplaceID])
    }

    @Test("a preset saved before the slot-2 fields loads")
    func oldPresetDecodes() throws {
        let old = MaestroPreset()
        var data = try PropertyListEncoder().encode(old)
        var dict = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        dict.removeValue(forKey: "slot2OpticalFormat")
        data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.slot2SPDIFReplaceID == nil)
    }
}
