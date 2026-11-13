import Testing
import Foundation
@testable import MaestroDevice

/// Readings below are bytes captured from a Symphony I/O MK I over USB on
/// 2026-11-13 while its encoder was turned and pressed.
@Suite("FrontPanelSync")
struct FrontPanelSyncTests {
    private func reading(_ hex: String) -> SymphonyIOParameterUpdates? {
        SymphonyIOParameterUpdates(data: Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! }))
    }

    @Test("decodes an idle reading")
    func decodesIdle() throws {
        let u = try #require(reading("00 00 bb 80 01 01 00 00 00 14 00 00"))
        #expect(u.measuredSampleRate == 48000)
        #expect(u.externalClockLocked)
        #expect(u.clockSource == 1)
        #expect(u.selection == .headphone1)
        #expect(u.selectionAttenuation == 20)
        #expect(!u.popupNeedsUpdate)
        #expect(u.muteAll == .none)
        #expect(!u.metersCleared)
    }

    @Test("selection indices are headphone 1, headphone 2, speaker")
    func selections() {
        #expect(reading("00 00 bb 80 01 01 00 00 01 33 01 00")?.selection == .headphone2)
        #expect(reading("00 00 bb 80 01 01 00 00 02 08 01 00")?.selection == .speaker)
        // A mic pre is selected: a valid reading with nothing to move.
        #expect(reading("00 00 bb 80 01 01 00 00 03 08 01 00")?.selection == nil)
    }

    @Test("a dead or short reply is not a reading")
    func rejectsGarbage() {
        #expect(reading("ff ff ff ff ff ff ff ff ff ff ff ff") == nil)
        #expect(reading("00 00 00 00 00 00 00 00 00 00 00 00") == nil)   // no sample rate
        #expect(reading("00 00 bb 80 01 01 00 00 02 41 01 00") == nil)   // attenuation 65
        #expect(reading("00 00 bb 80 01 01 00 03 02 08 01 00") == nil)   // unknown mute state
        #expect(reading("00 00 bb 80 01 01") == nil)
    }

    /// The on-screen knobs run 0 to -64 dB for the speaker and 0 to -127 dB for
    /// the headphones; the readings must cover the same ranges.
    @Test("headphone levels run to -127 dB, the speaker to -64 dB")
    func ranges() throws {
        var sync = FrontPanelSync()
        let hp = try #require(reading("00 00 bb 80 01 01 00 00 00 7f 01 00"))
        #expect(sync.changes(for: hp) == [.level(.headphone1, -127, settled: false)])
        let hp2 = try #require(reading("00 00 bb 80 01 01 00 00 01 41 01 00"))
        #expect(sync.changes(for: hp2) == [.level(.headphone2, -65, settled: false)])
        #expect(reading("00 00 bb 80 01 01 00 00 02 40 01 00")?.selectionAttenuation == 64)
        #expect(reading("00 00 bb 80 01 01 00 00 00 80 01 00") == nil)   // headphone 128
    }

    @Test("request is vendor read 0x28, wValue 0, wIndex 1, 12 bytes")
    func request() {
        let r = SymphonyIOParameterUpdates.readRequest
        #expect(r.direction == .read)
        #expect(r.request == 0x28)
        #expect(r.value == 0)
        #expect(r.index == 1)
        #expect(r.data.count == 12)
    }

    /// The speaker encoder turned up and stopped: every step is followed, and
    /// the reading after the flag drops still carries the final value.
    @Test("follows the encoder while it turns and takes the value it stops on")
    func followsEncoder() throws {
        var sync = FrontPanelSync()
        let captured = [
            "00 00 bb 80 01 01 00 00 02 08 00 00",   // idle
            "00 00 bb 80 01 01 00 00 02 05 01 00",
            "00 00 bb 80 01 01 00 00 02 00 01 00",
            "00 00 bb 80 01 01 00 00 02 0b 01 00",
            "00 00 bb 80 01 01 00 00 02 0b 00 00",   // stopped
            "00 00 bb 80 01 01 00 00 02 0b 00 00",   // idle again
        ]
        let changes = try captured.map { sync.changes(for: try #require(reading($0))) }
        #expect(changes == [
            [], [.level(.speaker, -5, settled: false)], [.level(.speaker, 0, settled: false)],
            [.level(.speaker, -11, settled: false)], [.level(.speaker, -11, settled: true)], [],
        ])
    }

    /// An idle reading never moves a control: it may be older than a level the
    /// user is setting on screen.
    @Test("an idle reading changes nothing")
    func idleChangesNothing() throws {
        var sync = FrontPanelSync()
        for _ in 0..<5 {
            #expect(sync.changes(for: try #require(reading("00 00 bb 80 01 01 00 00 00 14 00 00"))).isEmpty)
        }
    }

    @Test("mute-all and unmute-all pulses are applied once each")
    func mutePulses() throws {
        var sync = FrontPanelSync()
        let idle = "00 00 bb 80 01 01 00 00 02 0b 00 00"
        let mute = "00 00 bb 80 01 01 00 02 02 0b 01 00"
        let unmute = "00 00 bb 80 01 01 00 01 02 0b 01 00"
        var all: [FrontPanelSync.Change] = []
        for hex in [idle, mute, mute, idle, unmute, idle] {
            all += sync.changes(for: try #require(reading(hex))).filter {
                if case .muteAll = $0 { return true } else { return false }
            }
        }
        #expect(all == [.muteAll(true), .muteAll(false)])
    }

    @Test("reset forgets a change in progress")
    func reset() throws {
        var sync = FrontPanelSync()
        _ = sync.changes(for: try #require(reading("00 00 bb 80 01 01 00 00 02 05 01 00")))
        sync.reset()
        #expect(sync.changes(for: try #require(reading("00 00 bb 80 01 01 00 00 02 0b 00 00"))).isEmpty)
    }
}
