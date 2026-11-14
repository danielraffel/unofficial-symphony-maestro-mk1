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
}
