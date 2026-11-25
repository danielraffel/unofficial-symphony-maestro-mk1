import Testing
import Foundation
import MaestroCore
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

    @Test("an unknown selection index still carries the clock and mute fields")
    func unknownSelectionKept() throws {
        let u = try #require(reading("00 00 bb 80 01 02 00 00 0b 14 00 00"))
        #expect(u.selection == nil)
        #expect(u.clockSource == 2)
        #expect(u.externalClockLocked)
    }

    @Test("selection indices are headphone 1, headphone 2, speaker")
    func selections() {
        #expect(reading("00 00 bb 80 01 01 00 00 01 33 01 00")?.selection == .headphone2)
        #expect(reading("00 00 bb 80 01 01 00 00 02 08 01 00")?.selection == .speaker)
        #expect(reading("00 00 bb 80 01 01 00 00 03 08 01 00")?.selection == .micPre1)
    }

    @Test("follows MicPre encoder gain without treating it as monitor attenuation")
    func micPreGain() throws {
        var sync = FrontPanelSync()
        let turning = try #require(reading("00 00 bb 80 01 01 00 00 05 2a 01 00"))
        let stopped = try #require(reading("00 00 bb 80 01 01 00 00 05 2a 00 00"))
        let moving = sync.changes(for: turning)
        let settled = sync.changes(for: stopped)
        #expect(moving == [.micPreGain(channel: 2, 42, settled: false)])
        #expect(settled == [.micPreGain(channel: 2, 42, settled: true)])
    }

    @Test("per-unit gain observations preserve group offsets and publish each affected lane")
    func unitGroupObservation() {
        let a = [InputChannelState(gain: 10, inputType: AnalogInputLevel.mic.rawValue, group: 1)]
        var b = [InputChannelState(gain: 20, inputType: AnalogInputLevel.mic.rawValue, group: 1),
                 InputChannelState(gain: 60, inputType: AnalogInputLevel.instrument.rawValue, group: 1),
                 InputChannelState(gain: 30, inputType: AnalogInputLevel.mic.rawValue)]
        let changes = FrontPanelSync.applyGain(40, channel: 0, to: &b)
        #expect(a[0].gain == 10)
        #expect(b.map(\.gain) == [25, 65, 30])
        #expect(changes.map(\.channel) == [0, 1])
        #expect(changes.map(\.lane) == [0, 1])
        #expect(changes.map(\.gain) == [25, 65])
        let invalid = FrontPanelSync.applyGain(42, channel: 8, to: &b)
        #expect(invalid.isEmpty)
    }

    @Test("separate A and B change trackers do not share settling state")
    func unitTrackers() throws {
        var a = FrontPanelSync(), b = FrontPanelSync()
        let turning = try #require(reading("00 00 bb 80 01 01 00 00 03 2a 01 00"))
        let idle = try #require(reading("00 00 bb 80 01 01 00 00 03 2a 00 00"))
        let aMoving = a.changes(for: turning)
        let bIdle = b.changes(for: idle)
        #expect(aMoving.count == 1)
        #expect(bIdle.isEmpty)
        b.reset()
        let bAfterReset = b.changes(for: idle)
        #expect(bAfterReset.isEmpty)
    }

    @Test("a dead or short reply is not a reading")
    func rejectsGarbage() {
        #expect(reading("ff ff ff ff ff ff ff ff ff ff ff ff") == nil)
        #expect(reading("00 00 00 00 00 00 00 00 00 00 00 00") == nil)   // no sample rate
        #expect(reading("00 00 bb 80 01 01 00 00 02 41 01 00") == nil)   // attenuation 65
        #expect(reading("00 00 bb 80 01 01 00 03 02 08 01 00") == nil)   // unknown mute state
        #expect(reading("00 00 bb 80 01 01") == nil)
    }

    /// The unit's front panel stops at -64 dB for the headphones as well as the
    /// speaker (measured 2026-11-13), and the on-screen knobs use that range. A
    /// larger headphone value is legal on the wire and is shown at the bottom.
    @Test("levels run 0 to -64 dB for every output")
    func ranges() throws {
        var sync = FrontPanelSync()
        let hpBottom = try #require(reading("00 00 bb 80 01 01 00 00 00 40 01 00"))
        let bottomChanges = sync.changes(for: hpBottom)
        #expect(bottomChanges == [.level(.headphone1, -64, settled: false)])
        let hpBeyond = try #require(reading("00 00 bb 80 01 01 00 00 01 7f 01 00"))
        let beyondChanges = sync.changes(for: hpBeyond)
        #expect(beyondChanges == [.level(.headphone2, -64, settled: false)])
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
            let changes = sync.changes(for: try #require(reading("00 00 bb 80 01 01 00 00 00 14 00 00")))
            #expect(changes.isEmpty)
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

    @Test("a front panel meter clear is reported once")
    func metersCleared() throws {
        var sync = FrontPanelSync()
        let cleared = "00 00 bb 80 01 01 00 00 01 34 01 01"
        let idle = "00 00 bb 80 01 01 00 00 01 34 00 00"
        var count = 0
        for hex in [idle, cleared, cleared, idle, cleared] {
            count += sync.changes(for: try #require(reading(hex))).filter { $0 == .metersCleared }.count
        }
        #expect(count == 2)
    }

    @Test("reset forgets a change in progress")
    func reset() throws {
        var sync = FrontPanelSync()
        _ = sync.changes(for: try #require(reading("00 00 bb 80 01 01 00 00 02 05 01 00")))
        sync.reset()
        let changes = sync.changes(for: try #require(reading("00 00 bb 80 01 01 00 00 02 0b 00 00")))
        #expect(changes.isEmpty)
    }
}
