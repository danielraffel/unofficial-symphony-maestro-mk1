import Testing
@testable import MaestroCore

/// EXPERIMENT (64 channels): decoding of the driver's port-2 state (user-client
/// selector 8, `SymphonyPort2StateOutput`) and what it adds to Device Info and
/// the copied details. The layout and flag values are those in
/// `Drivers/Thunderbolt/Source/SymphonyThunderbridgeShared.h`.
@Suite("SecondPortState")
struct SecondPortStateTests {
    private static let inquireOK: UInt32 = 0x0001_0000
    private static let xtdOK: UInt32 = 0x0002_0000
    private static let addressed: UInt32 = 0x0004_0000

    /// status, portCount, flags, xlink2Status, xlinkClocking, gcsr2, unitCount,
    /// unit[4], probeCount, rateHz, rateChanges, reserved[2].
    private func words(portCount: UInt32 = 2, flags: UInt32 = 0, status2: UInt32 = 0,
                       clocking: UInt32 = 0, gcsr2: UInt32 = 0, units: [UInt32] = [],
                       probes: UInt32 = 0, status: UInt32 = 0) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: 16)
        w[0] = status; w[1] = portCount; w[2] = flags; w[3] = status2; w[4] = clocking; w[5] = gcsr2
        w[6] = UInt32(units.count)
        for (index, unit) in units.prefix(4).enumerated() { w[7 + index] = unit }
        w[11] = probes
        return w
    }

    private let fullReport = DeviceInfoReport(
        deviceName: "Symphony I/O", connection: "Thunderbolt (ThunderBridge)",
        firmwareVersion: "1.6.72", fpgaVersion: "v73", hardwareID: "ABC123", xmosVersion: "5.4c",
        board1: .detected(.optical), board1Version: "v33",
        board2: .detected(.analogAD16), board2Version: "v12",
        deviceModel: "Symphony I/O", mode: "32-Channel", channelCount: 32)

    @Test("the struct is sixteen words, and anything else is not an answer")
    func size() {
        #expect(SecondPortState.wordCount == 16)
        #expect(SecondPortState.decode(words()) != nil)
        #expect(SecondPortState.decode([UInt32](repeating: 0, count: 12)) == nil)
        #expect(SecondPortState.decode([UInt32](repeating: 0, count: 17)) == nil)
        #expect(SecondPortState.decode([]) == nil)
        // A nonzero status word is the driver saying the read failed.
        #expect(SecondPortState.decode(words(status: 0xE00002BC)) == nil)
    }

    @Test("fields come from the documented word positions")
    func fields() throws {
        let unit1 = Self.inquireOK | Self.addressed | 0x30
        let unit2 = Self.inquireOK | Self.addressed | 0xC0
        let state = try #require(SecondPortState.decode(words(
            flags: 0x0F, status2: 0x0010_0000, clocking: 0x4102_4102, gcsr2: 0x0000_0040,
            units: [unit1, unit2], probes: 3)))
        #expect(state.portCount == 2 && state.experimentOn)
        #expect(state.probed && state.clockDetected && state.dataLinkUp && state.locked && !state.txTimedOut)
        #expect(state.xlink2Status == 0x0010_0000)
        #expect(state.xlinkClocking == 0x4102_4102)
        #expect(state.gcsr2 == 0x40)
        #expect(state.units == [unit1, unit2])
        #expect(state.probeCount == 3)
        #expect(state.detectedRate == 48_000)
    }

    @Test("the unit count is bounded by the four slots, and unfilled slots are ignored")
    func unitCount() throws {
        var w = words(flags: 1, units: [1, 2, 3, 4])
        w[6] = 9
        #expect(try #require(SecondPortState.decode(w)).units.count == 4)
        w[6] = 1
        #expect(try #require(SecondPortState.decode(w)).units == [1])
    }

    @Test("port 2's detected rate is read from bits 16-21")
    func rate() {
        let rates: [(UInt32, Int)] = [(0x01, 44_100), (0x02, 48_000), (0x04, 88_200),
                                      (0x08, 96_000), (0x10, 176_400), (0x20, 192_000)]
        for (bit, rate) in rates {
            let state = SecondPortState(portCount: 2, flags: 3, xlinkClocking: 0x0100_0000 | (bit << 16))
            #expect(state.detectedRate == rate)
            #expect(state.clockText == "\(rate) Hz")
        }
        // Port 1's rate bits (0-5) are not port 2's.
        #expect(SecondPortState(portCount: 2, flags: 1, xlinkClocking: 0x0000_0102).detectedRate == nil)
        #expect(SecondPortState(portCount: 2, flags: 1, xlinkClocking: 0x0000_0102).clockText == "None")
        #expect(SecondPortState(portCount: 2, flags: 1, xlinkClocking: 0x0103_0000).clockText
                == "Unclear (rate bits 0x3)")
        #expect(SecondPortState(portCount: 2).clockText == "Unknown")
    }

    @Test("the link line follows the probe flags")
    func link() {
        #expect(SecondPortState(portCount: 2).linkText == SecondPortState.notLookedAtText)
        #expect(SecondPortState(portCount: 2, flags: 0x01).linkText == "Nothing found (no unit clock on port 2)")
        #expect(SecondPortState(portCount: 2, flags: 0x03).linkText == "Unit clock found, data link down")
        #expect(SecondPortState(portCount: 2, flags: 0x07).linkText == "Data link up, not locked (still slipping)")
        #expect(SecondPortState(portCount: 2, flags: 0x0F).linkText == "Data link up and locked")
        #expect(SecondPortState(portCount: 2, flags: 0x1F).linkText
                == "Data link up and locked; the port stopped accepting commands")
    }

    @Test("units are named the way a port-1 converter is, with the replies alongside")
    func unitNames() {
        let ok = Self.inquireOK | Self.addressed
        #expect(SecondPortState.unitText(ok | 0x3A) == "AD-16X (16 inputs) [replies 0x3a, none]")
        #expect(SecondPortState.unitText(ok | 0xC1) == "DA-16X (16 outputs) [replies 0xc1, none]")
        #expect(SecondPortState.unitText(ok | Self.xtdOK | 0xF2)
                == "DD-16X (16 inputs, 16 outputs) [replies 0xf2, 0x00]")
        #expect(SecondPortState.unitText(ok | 0x52) == "Rosetta 800 (8 inputs, 8 outputs) [replies 0x52, none]")
        // All eight channel groups: the original's "Symphony" type (0xFF).
        #expect(SecondPortState.unitText(ok | Self.xtdOK | 0xF0F1)
                == "32-channel unit, probably a Symphony I/O (32 inputs, 32 outputs) [replies 0xf1, 0xf0]")
        // Sixteen-channel banks plus some of the upper ones: no known unit.
        #expect(SecondPortState.unitText(ok | Self.xtdOK | 0x30F0) == "Not recognised [replies 0xf0, 0x30]")
        // The first position answered with no channel bits: kept as evidence.
        #expect(SecondPortState.unitText(Self.inquireOK | 0x02)
                == "Not recognised (identification reply 0x2) [replies 0x02, none]")
        #expect(SecondPortState.unitText(0) == "No answer")
        // A unit that identified itself but could not be given an address.
        #expect(SecondPortState.unitText(Self.inquireOK | 0xC0)
                == "DA-16X (16 outputs) [replies 0xc0, none], could not be addressed")
    }

    @Test("Device Info rows with the experiment on")
    func rows() {
        let ok = Self.inquireOK | Self.addressed
        let state = SecondPortState(portCount: 2, flags: 0x0F, xlinkClocking: 0x4102_4102,
                                    units: [ok | 0x30, ok | 0xC0], probeCount: 1)
        #expect(state.deviceInfoRows.map(\.label)
                == ["Two-port driver", "Port 2 Link", "Port 2 Clock", "Port 2 Unit 1", "Port 2 Unit 2"])
        #expect(state.deviceInfoRows[3].value == "AD-16X (16 inputs) [replies 0x30, none]")
        // The experiment line is there even when port 2 is empty.
        let empty = SecondPortState(portCount: 2, flags: 0x01)
        #expect(empty.deviceInfoRows.first?.label == SecondPortState.experimentLabel)
        #expect(empty.deviceInfoRows.last?.label == "Port 2 Units")
        #expect(empty.deviceInfoRows.last?.value == "None found")
    }

    @Test("the copied details carry the rows and the raw status words")
    func copy() {
        let ok = Self.inquireOK | Self.addressed
        var report = fullReport
        report.port2Lines = SecondPortState(
            portCount: 2, flags: 0x0F, xlink2Status: 0x0010_0000, xlinkClocking: 0x4102_4102,
            gcsr2: 0x40, units: [ok | 0x30, ok | 0xC0], probeCount: 2).reportLines
        let expected = fullReport.clipboardText + "\n" + """
        Two-port driver: On. Port 2 is identified only and carries no audio.
        Port 2 Link: Data link up and locked
        Port 2 Clock: 48000 Hz
        Port 2 Unit 1: AD-16X (16 inputs) [replies 0x30, none]
        Port 2 Unit 2: DA-16X (16 outputs) [replies 0xc0, none]
        Port 2 Raw: ports=2 flags=0x0000000f xlink2Status=0x00100000 xlinkClocking=0x41024102 \
        gcsr2=0x00000040 units=[0x00050030, 0x000500c0] probes=2
        """
        #expect(report.clipboardText == expected)
    }

    /// The guarantee for everyone not running the experiment: a released driver
    /// (no selector 8, so no state at all) and this driver with the experiment
    /// off (portCount 1) both leave the copied text exactly as it was.
    @Test("no port-2 state, or the experiment off, leaves the copied details unchanged")
    func unchangedWhenOff() {
        let before = fullReport.clipboardText
        #expect(before == """
        Device Name: Symphony I/O
        Connection: Thunderbolt (ThunderBridge)
        Firmware: 1.6.72
        FPGA version: v73
        Hardware ID: ABC123
        IOBoard1: 8x8 OPT (detected), Version: v33
        IOBoard2: 16 Analog In / 16 Digital Out (detected), Version: v12
        XMOS Version: 5.4c
        Device Model: Symphony I/O
        Mode: 32-Channel
        Channel Count: 32
        """)

        // A driver without the selector: the app has no state.
        let none: SecondPortState? = nil
        var report = fullReport
        report.port2Lines = none?.reportLines ?? []
        #expect(report.clipboardText == before)
        #expect(report == fullReport)

        // This driver, experiment off: portCount 1, everything else zero.
        let off = SecondPortState.decode(words(portCount: 1))
        #expect(off != nil && off?.experimentOn == false)
        #expect(off?.deviceInfoRows.isEmpty == true)
        #expect(off?.reportLines.isEmpty == true)
        report.port2Lines = off?.reportLines ?? []
        #expect(report.clipboardText == before)

        // Anything but 2 is off, whatever else the words say.
        for count: UInt32 in [0, 1, 3] {
            let odd = SecondPortState(portCount: count, flags: 0x0F, units: [0x0005_0030])
            #expect(odd.reportLines.isEmpty && odd.deviceInfoRows.isEmpty)
        }

        // The same holds for a converter report.
        var converter = DeviceInfoReport(deviceName: "Apogee DA-16X", connection: "Thunderbolt (ThunderBridge)",
                                         connectedUnit: ConnectedUnit.da16x.displayName)
        let converterBefore = converter.clipboardText
        converter.port2Lines = off?.reportLines ?? []
        #expect(converter.clipboardText == converterBefore)
    }

    @Test("rate-change words 12 and 13: shown only once a change has gone to port 2")
    func rateChange() throws {
        // None yet: no row, raw text as before.
        let none = try #require(SecondPortState.decode(words(flags: 0x0F, units: [0x0005_0030], probes: 1)))
        #expect(none.rateChanges == 0 && none.rateChangeText == nil)
        #expect(!none.deviceInfoRows.contains { $0.label == "Port 2 Rate Change" })
        #expect(!none.rawText.contains("rateChanges"))

        // Followed: word 12 is the rate, word 13 the count, flag 0x20 clear.
        var w = words(flags: 0x0F, units: [0x0005_0030], probes: 1)
        w[12] = 96_000; w[13] = 2
        let ok = try #require(SecondPortState.decode(w))
        #expect(ok.rateHz == 96_000 && ok.rateChanges == 2 && !ok.rateChangeFailed)
        #expect(ok.deviceInfoRows.contains { $0 == ("Port 2 Rate Change", "Followed the last change (96000 Hz)") })
        #expect(ok.rawText.hasSuffix(" rate=96000 rateChanges=2"))

        // Failed: flag 0x20 set, rate 0.
        w[2] = 0x2F; w[12] = 0; w[13] = 3
        let failed = try #require(SecondPortState.decode(w))
        #expect(failed.rateChangeFailed)
        #expect(failed.rateChangeText == "Did not follow the last change")

        // Port 2 looked at again since (re-probe): flag clear, rate 0, count kept.
        // No verdict either way.
        w[2] = 0x0F; w[12] = 0; w[13] = 3
        let reprobed = try #require(SecondPortState.decode(w))
        #expect(reprobed.rateChangeText == nil)
        #expect(!reprobed.deviceInfoRows.contains { $0.label == "Port 2 Rate Change" })
    }
}
