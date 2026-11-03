/// Tests for the app-side ThunderBridge endpoint verdict and the bounded
/// DriverKit upgrade grace. Bit values come from the legacy register map
/// (og_source/symphonymk1/ext/maestrolink/SymphonyAPI/pci2k5_sys.h:79-99).

import Foundation
import Testing
@testable import MaestroDevice

@Suite("ThunderboltEndpointHealth")
struct ThunderboltEndpointHealthTests {

    private func health(xlink: UInt32) -> TimingHealth {
        TimingHealth(clkCtrl: 0x11, intStatus: 0, xlinkStatus: xlink, gcsr: 0,
                     frameReadback: 32, expectedFrame: 32, sampleRate: 48000,
                     inputLatency: 0, outputLatency: 0, inputSafety: 0, outputSafety: 0)
    }

    private func linkState(_ state: LinkState.State, clockReg: UInt32 = 0x4702) -> LinkState {
        LinkState(state: state, clockPresent: state == .up, ioRunning: false, irqCount: 0,
                  recoveryCount: 0, hwSuspended: false, linkConfigured: state == .up,
                  lastClockReg: clockReg, watchTicks: 1, audioWraps: 0)
    }

    @Test("dext 113 link watch: up is live, down is NO_CLOCK, recovering is RECOVERING")
    func linkWatchMapping() {
        #expect(ThunderboltEndpointHealth.evaluate(linkState: linkState(.up)).isLive)
        #expect(ThunderboltEndpointHealth.evaluate(linkState: linkState(.down)).label == "linkDown[NO_CLOCK]")
        #expect(ThunderboltEndpointHealth.evaluate(linkState: linkState(.recovering)).label == "linkDown[RECOVERING]")
        #expect(ThunderboltEndpointHealth.evaluate(linkState: linkState(.unknown)) == .unavailable)
        #expect(ThunderboltEndpointHealth.evaluate(linkState: nil) == .unavailable)
    }

    @Test("link-watch verdict keeps the register value for the lifecycle log")
    func linkWatchCarriesClockRegister() {
        let v = ThunderboltEndpointHealth.evaluate(linkState: linkState(.up, clockReg: 0x7000010c))
        #expect(v.health?.clkCtrl == 0x7000010c)
    }

    @Test("link-watch fault cases never derive from a status word")
    func watchFaultsHaveNoMask() {
        #expect(ThunderboltEndpointHealth.faults(in: 0xFFFF_FFFF).contains(.noClock) == false)
        #expect(ThunderboltEndpointHealth.faults(in: 0xFFFF_FFFF).contains(.recovering) == false)
    }

    @Test("decode rejects a nonzero status word and a short buffer")
    func decodeRejects() {
        #expect(LinkState.decode([UInt32](repeating: 0, count: 11)) == nil)
        var words = [UInt32](repeating: 0, count: 12); words[0] = 0xE00002BE
        #expect(LinkState.decode(words) == nil)
        words[0] = 0; words[1] = 2; words[9] = 0x4702
        #expect(LinkState.decode(words)?.state == .down)
        #expect(LinkState.decode(words)?.lastClockReg == 0x4702)
    }

    @Test("dext 117 answers 16 words with the sampled registers and the re-init count")
    func decodeExtended() {
        var words = [UInt32](repeating: 0, count: 16)
        words[1] = 1; words[9] = 0x4702; words[12] = 0x2db8011b; words[13] = 0x3e0; words[14] = 2
        let ls = LinkState.decode(words)
        #expect(ls?.lastGcsr == 0x2db8011b)
        #expect(ls?.lastXlinkStatus == 0x3e0)
        #expect(ls?.cardReinitCount == 2)
        let v = ThunderboltEndpointHealth.evaluate(linkState: ls)
        #expect(v.health?.gcsr == 0x2db8011b)
        #expect(v.health?.xlinkStatus == 0x3e0)
        #expect(LinkState.decode([UInt32](repeating: 0, count: 14)) == nil)
    }

    @Test("bit values match the legacy pci2k5_sys.h register map")
    func legacyBitValues() {
        #expect(XLinkStatusBit.rx1_8DownCurrent == 0x000400)
        #expect(XLinkStatusBit.dataDownCurrent  == 0x004000)
        #expect(XLinkStatusBit.rx1_8SlipCurrent == 0x008000)
        #expect(XLinkStatusBit.dataSlipCurrent  == 0x080000)
        #expect(XLinkStatusBit.slaveMode        == 0x100000)
    }

    @Test("a clean status word has no faults")
    func cleanStatus() {
        #expect(ThunderboltEndpointHealth.faults(in: 0).isEmpty)
        #expect(ThunderboltEndpointHealth.evaluate(health(xlink: 0)) == .live(health(xlink: 0)))
    }

    @Test("sticky history bits and slave mode do not fail the link")
    func stickyBitsIgnored() {
        let historical = XLinkStatusBit.rx1_8DownSticky | XLinkStatusBit.dataDownSticky
            | XLinkStatusBit.rx1_8SlipSticky | XLinkStatusBit.dataSlipSticky
            | XLinkStatusBit.slaveMode
        #expect(ThunderboltEndpointHealth.faults(in: historical).isEmpty)
        #expect(ThunderboltEndpointHealth.evaluate(health(xlink: historical)).isLive)
    }

    @Test("each current fault bit is reported",
          arguments: ThunderboltLinkFault.allCases.filter { $0.mask != 0 })   // NO_CLOCK/RECOVERING come from the link watch, not a status word
    func eachCurrentBit(fault: ThunderboltLinkFault) {
        #expect(ThunderboltEndpointHealth.faults(in: fault.mask) == [fault])
        let verdict = ThunderboltEndpointHealth.evaluate(health(xlink: fault.mask))
        #expect(verdict == .linkDown(health(xlink: fault.mask), faults: [fault]))
        #expect(!verdict.isLive)
        #expect(verdict.label == "linkDown[\(fault.rawValue)]")
    }

    @Test("multiple faults are listed in a stable order")
    func multipleFaults() {
        let word = XLinkStatusBit.dataSlipCurrent | XLinkStatusBit.rx1_8DownCurrent
        #expect(ThunderboltEndpointHealth.faults(in: word) == [.rx1_8Down, .dataSlip])
    }

    @Test("a failed dext read is unavailable, not live")
    func unavailable() {
        let verdict = ThunderboltEndpointHealth.evaluate(nil)
        #expect(verdict == .unavailable)
        #expect(!verdict.isLive)
        #expect(verdict.health == nil)
        #expect(verdict.label == "unavailable")
    }

    @Test("verdict carries the snapshot for logging")
    func verdictCarriesHealth() {
        let h = health(xlink: XLinkStatusBit.dataDownCurrent)
        #expect(ThunderboltEndpointHealth.evaluate(h).health == h)
    }
}

@Suite("ExtensionSwapGrace")
struct ExtensionSwapGraceTests {

    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("a single registration never opens the window")
    func singleRegistration() {
        var grace = ExtensionSwapGrace(interval: 15)
        #expect(grace.update(registrationCount: 1, now: t0) == false)
        #expect(grace.update(registrationCount: 0, now: t0) == false)
        #expect(!grace.isPending)
    }

    @Test("a second registration opens a window that closes after the interval")
    func boundedWindow() {
        var grace = ExtensionSwapGrace(interval: 15)
        #expect(grace.update(registrationCount: 2, now: t0) == true)
        #expect(grace.update(registrationCount: 2, now: t0.addingTimeInterval(14.9)) == true)
        #expect(grace.update(registrationCount: 2, now: t0.addingTimeInterval(15)) == false)
        #expect(grace.update(registrationCount: 2, now: t0.addingTimeInterval(3_600)) == false)
        // Still pending (the stale record is still listed), just no longer excused.
        #expect(grace.isPending)
        #expect(grace.pendingSince == t0)
    }

    @Test("the window restarts only after the extra registration goes away")
    func restartsAfterClear() {
        var grace = ExtensionSwapGrace(interval: 15)
        grace.update(registrationCount: 2, now: t0)
        #expect(grace.update(registrationCount: 2, now: t0.addingTimeInterval(20)) == false)
        #expect(grace.update(registrationCount: 1, now: t0.addingTimeInterval(21)) == false)
        #expect(!grace.isPending)
        let t1 = t0.addingTimeInterval(100)
        #expect(grace.update(registrationCount: 2, now: t1) == true)
        #expect(grace.pendingSince == t1)
    }

    @Test("reset closes the window so it re-anchors at the next failure")
    func resetReanchors() {
        var grace = ExtensionSwapGrace(interval: 15)
        // Second registration listed for a long time while probes were live.
        grace.update(registrationCount: 2, now: t0)
        grace.reset()
        #expect(!grace.isPending)
        // The handoff finally happens 30 min later: first failed probe opens a fresh window.
        let t1 = t0.addingTimeInterval(1_800)
        #expect(grace.update(registrationCount: 2, now: t1) == true)
        #expect(grace.update(registrationCount: 2, now: t1.addingTimeInterval(10)) == true)
        #expect(grace.update(registrationCount: 2, now: t1.addingTimeInterval(16)) == false)
    }

    @Test("default interval is fifteen seconds")
    func defaultInterval() {
        #expect(ExtensionSwapGrace().interval == 15)
    }
}
