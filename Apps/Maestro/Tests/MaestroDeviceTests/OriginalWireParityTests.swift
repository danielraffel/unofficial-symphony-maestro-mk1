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

    // MARK: Clock source over ThunderBridge with an AES board

    /// Symphony mode lists Internal, Word Clock, then each board's sources; an
    /// Analog-AES board's are S/PDIF Coax then AES 1-2..7-8
    /// (`SymphonyIO.cpp:1750-1766`, `SymphonyIO_IOBoard.cpp:79-90`,
    /// `AESIn_SymphonyIO_Stream.cpp:40-44`). Choosing one sends ClockMode 0x50
    /// with `[IOBoard1 = 4, master 1, loop sync 0, input]`, the input an
    /// `SymphonyIOAnalogAESOptBoardClockSourceIdx`: AES pairs 0-3, coax 6
    /// (`AESIn_SymphonyIO_Stream.cpp:57-93`, `SymphonyIO_IOBoard.cpp:57-77`,
    /// `SymphonyIOControl.cpp:958-1011`, `SymphonyIOVendorSpecific.h:879-888`).
    @Test("an AES card in slot 1 is offered as its coax and AES pairs, sent as the original sent them")
    func aesSlotClockSources() throws {
        let menu = ClockSourceMenu.thunderbolt(slot1: .analogAES, slot2: .none)
        #expect(menu.map(\.name) == ["Internal", "Word Clock", "Loop Sync",
                                      "S/PDIF Coax 1-2", "AES 1-2", "AES 3-4", "AES 5-6", "AES 7-8",
                                      "IO Board 2"])
        // Internal, Word Clock and the AES card's rows are the original's. Loop
        // Sync and the plain "IO Board 2" row predate this menu and are not
        // (the original listed Loop Sync only in Pro Tools HD mode and each
        // board's own inputs instead of an IO Board row); they are pinned here
        // to what the driver's own clock control sends, so they do not drift.
        let expectedBytes: [String: [UInt8]] = [
            "Internal": [1, 1, 0, 0],
            "Word Clock": [2, 1, 0, 0],
            "Loop Sync": [3, 0, 1, 0],
            "S/PDIF Coax 1-2": [4, 1, 0, 6],
            "AES 1-2": [4, 1, 0, 0],
            "AES 3-4": [4, 1, 0, 1],
            "AES 5-6": [4, 1, 0, 2],
            "AES 7-8": [4, 1, 0, 3],
            "IO Board 2": [5, 1, 0, 0],
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
        #expect(menu.filter { $0.boardInput == nil }.map(\.id) == [1, 2, 3, 5])
    }

    /// Slot 2 numbers on from slot 1 (`SymphonyIO_IOBoard.cpp:1533-1541`): after
    /// an AES board, AES 9-10..15-16 and coax 3-4, with IOBoard2 = 5 as source.
    @Test("an AES card in slot 2 numbers on from slot 1 and clocks from board 2")
    func secondAESSlot() {
        let menu = ClockSourceMenu.thunderbolt(slot1: .analogAES, slot2: .analogAES)
        let slot2 = menu.filter { $0.source == 5 }
        #expect(slot2.map(\.name) == ["S/PDIF Coax 3-4", "AES 9-10", "AES 11-12", "AES 13-14", "AES 15-16"])
        #expect(slot2.map { $0.boardInput } == [6, 0, 1, 2, 3])
        let afterOptical = ClockSourceMenu.thunderbolt(slot1: .optical, slot2: .analogAES)
        #expect(afterOptical.filter { $0.source == 5 }.map(\.name)
                == ["S/PDIF Coax 3-4", "AES 1-2", "AES 3-4", "AES 5-6", "AES 7-8"])
        #expect(afterOptical.contains { $0.id == 4 && $0.name == "IO Board 1" })
    }

    @Test("without an AES card the ThunderBridge menu is unchanged; USB stays Internal only")
    func nonAESMenusUnchanged() {
        for card in IOCardType.allCases where card != .analogAES {
            let menu = ClockSourceMenu.thunderbolt(slot1: card, slot2: card)
            #expect(menu.map(\.id) == [1, 2, 3, 4, 5])
            #expect(menu.map(\.name) == ["Internal", "Word Clock", "Loop Sync", "IO Board 1", "IO Board 2"])
        }
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
        // Board 2 is an optical card shown as one row.
        let reportedOptical = ThunderboltDeviceConnection.clockSourceKey(reportedSource: 5, boardInput: 4)
        #expect(reportedOptical.flatMap { ClockSourceMenu.row(for: $0, in: aes) } == 5)
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
}
