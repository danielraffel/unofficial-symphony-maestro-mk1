import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// A USB unit that answers headphone mute reads (0x24, wIndex = headphone)
/// and the restore's decoy read (0xDB, "none" = 2), and takes mute writes.
private final class MuteUnit: XPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var mutes: [UInt16: UInt8] = [0: 0, 1: 0]
    private var sets: [(index: UInt16, value: UInt8)] = []
    var failWrites = false
    var answer: UInt8?
    /// Runs once, during the first mute read (the user acting mid-step).
    var duringFirstRead: (@Sendable () async -> Void)?

    var muteWrites: [(index: UInt16, value: UInt8)] { lock.withLock { sets } }
    func setUnit(_ index: UInt16, muted: Bool) { lock.withLock { mutes[index] = muted ? 1 : 0 } }
    var isConnected: Bool { true }

    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        guard bRequest == 0x24 else { return }
        if failWrites { throw DeviceConnectionError.transportError("refused") }
        lock.withLock { sets.append((wIndex, data.first ?? 0)); mutes[wIndex] = data.first ?? 0 }
    }
    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        if bRequest == 0x24, let hook = lock.withLock({ () -> (@Sendable () async -> Void)? in defer { duringFirstRead = nil }; return duringFirstRead }) {
            await hook()
        }
        var data = Data(count: Int(dataLength))
        if bRequest == 0x24, !data.isEmpty { data[0] = lock.withLock { answer ?? mutes[wIndex] ?? 0 } }
        if bRequest == SymphonyIOResetRequest.command, !data.isEmpty { data[0] = 2 }
        return XPCPropertyReply(status: 0, data: data)
    }
    func getSoftwareMeterLevels() async -> (Float, Float)? { (0, 0) }
    func setSwReturnMute(_ muted: Bool) {}
    func setSwReturnLevel(_ dB: Double) {}
    func setSwReturnProcessing(_ enabled: Bool) {}
    func resetAudioOutput() {}
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {}
}

@MainActor
@Suite("USB: headphone mutes at connect (app)")
struct USBMutesAtConnectAppTests {
    private func make() throws -> (AppState, XPCDeviceConnection, MuteUnit) {
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = .usb
        state.isHardwareInitialized = true
        let unit = MuteUnit()
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "usb-mutes-\(UUID())"))
        let usb = XPCDeviceConnection(identifier: id, transport: unit)
        state.device = usb
        state.unitAIdentity = 0x4D55_5445_0001
        state.unitAIdentityState = .known(0x4D55_5445_0001)
        return (state, usb, unit)
    }

    /// The step as the restore runs it: inside the restore's read checks.
    private func step(_ state: AppState, _ usb: XPCDeviceConnection) async -> Bool {
        _ = await usb.beginRestoreElision()
        defer { usb.endRestoreElision() }
        return await state.applyMonitorMutesAtConnect(usb)
    }

    @Test("a saved mute is put back on a unit that came back unmuted, and a view read before the step does not erase it")
    func restores() async throws {
        let (state, usb, unit) = try make()
        usb.recordSavedMonitorMute(.headphone1, muted: true)
        usb.recordSavedMonitorMute(.headphone2, muted: false)
        // A view reads the power-cycled unit before the step: real changes.
        state.hp1Muted = true
        state.hp1Muted = false
        #expect(usb.savedMonitorMute(.headphone1) == true)
        let owed = await step(state, usb)
        #expect(!owed)
        #expect(unit.muteWrites.map(\.index) == [0] && unit.muteWrites.first?.value == 1)
        #expect(state.hp1Muted && !state.hp2Muted)
        #expect(usb.savedMonitorMute(.headphone1) == true && usb.savedMonitorMute(.headphone2) == false)
        // From here on changes are saved.
        state.hp1Muted = false
        #expect(usb.savedMonitorMute(.headphone1) == false)
        state.hp2Muted = true
        #expect(usb.savedMonitorMute(.headphone2) == true)
    }

    @Test("an unmuted saved state never unmutes the unit, and the unit's mute is saved")
    func neverUnmutes() async throws {
        let (state, usb, unit) = try make()
        usb.recordSavedMonitorMute(.headphone1, muted: false)
        unit.setUnit(0, muted: true)
        unit.setUnit(1, muted: true)   // nothing saved for headphone 2
        _ = await step(state, usb)
        #expect(unit.muteWrites.isEmpty)
        #expect(state.hp1Muted && state.hp2Muted)
        #expect(usb.savedMonitorMute(.headphone1) == true && usb.savedMonitorMute(.headphone2) == true)
    }

    @Test("the shown mute changing while the step runs (a view or the Mac's control reading 'unmuted') never unmutes the unit or erases the saved mute")
    func shownMuteChangesDuringStep() async throws {
        let (state, usb, unit) = try make()
        usb.recordSavedMonitorMute(.headphone1, muted: true)
        state.hp1Muted = true
        unit.duringFirstRead = { await MainActor.run { state.hp1Muted = false } }
        #expect(!(await step(state, usb)))
        #expect(unit.muteWrites.map(\.value) == [1], "muted once, never unmuted")
        #expect(state.hp1Muted, "the unit's own answer is shown")
        #expect(usb.savedMonitorMute(.headphone1) == true)
    }

    @Test("nothing saved and an unmuted unit: nothing is written")
    func nothingSaved() async throws {
        let (state, usb, unit) = try make()
        _ = await step(state, usb)
        #expect(unit.muteWrites.isEmpty && !state.hp1Muted && !state.hp2Muted)
    }

    @Test("a refused write stays owed: the saved mute is kept and nothing is recorded as unmuted")
    func failedWrite() async throws {
        let (state, usb, unit) = try make()
        usb.recordSavedMonitorMute(.headphone1, muted: true)
        unit.failWrites = true
        #expect(await step(state, usb))
        state.hp1Muted = true
        state.hp1Muted = false         // not settled for this output: not saved
        #expect(usb.savedMonitorMute(.headphone1) == true)
        unit.failWrites = false
        #expect(!(await step(state, usb)))
        #expect(state.hp1Muted && unit.muteWrites.count == 1)
    }

    @Test("a reply that is neither 0 nor 1 is not believed: owed, nothing written, saved mute kept")
    func residueRead() async throws {
        let (state, usb, unit) = try make()
        usb.recordSavedMonitorMute(.headphone1, muted: true)
        unit.answer = 0x30
        #expect(await step(state, usb))
        #expect(unit.muteWrites.isEmpty && usb.savedMonitorMute(.headphone1) == true)
    }

    @Test("not connected, identity unknown or hardware not ready: nothing is read, written or saved")
    func guards() async throws {
        for refuse in 0..<3 {
            let (state, usb, unit) = try make()
            usb.recordSavedMonitorMute(.headphone1, muted: true)
            switch refuse {
            case 0: state.connectionMode = .disconnected
            case 1: state.unitAIdentity = nil
            default: state.isHardwareInitialized = false
            }
            _ = await step(state, usb)
            #expect(unit.muteWrites.isEmpty, "case \(refuse)")
            state.hp1Muted = true
            state.hp1Muted = false
            #expect(usb.savedMonitorMute(.headphone1) == true, "case \(refuse)")
        }
    }
}
