import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// A fake unit: records every write in order, can fail chosen writes, and can
/// run a hook when a chosen write arrives (an edit made mid-restore).
private final class RecordingUnit: XPCTransport, @unchecked Sendable {
    struct Write: Equatable {
        let request: UInt8, value: UInt16, index: UInt16, data: [UInt8]
        /// Input strips, Software Return and Master of the unit's mixers.
        var isMixer: Bool { (0xB0...0xB4).contains(request) || (request == 0x31 && (data.first ?? 0) >= 0xE0) }
        /// An output route: 0x31 [destination, source], outputs are 32-63.
        var isOutputRoute: Bool { request == 0x31 && (32..<64).contains(data.first ?? 0) }
        var isMixerFedRoute: Bool { isOutputRoute && data.count > 1 && (64..<128).contains(data[1]) }
        var isInputRoute: Bool { request == 0x31 && !isOutputRoute && (data.first ?? 0) < 0xE0 }
        var isSpeakerMode: Bool { request == 0x25 }
    }
    private let lock = NSLock()
    private var recorded: [Write] = []
    private var helper: [String] = []
    var shouldFail: (@Sendable (Write) -> Bool)?
    var onWrite: (@Sendable (Write) async -> Void)?

    var writes: [Write] { lock.withLock { recorded } }
    var helperEvents: [String] { lock.withLock { helper } }
    var isConnected: Bool { true }

    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        let write = Write(request: bRequest, value: wValue, index: wIndex, data: Array(data))
        if shouldFail?(write) == true { throw DeviceConnectionError.transportError("unit refused") }
        lock.withLock { recorded.append(write) }
        await onWrite?(write)
    }
    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        throw DeviceConnectionError.transportError("no reads")
    }
    func getSoftwareMeterLevels() async -> (Float, Float)? { nil }
    func setSwReturnMute(_ muted: Bool) { lock.withLock { helper.append("mute \(muted)") } }
    func setSwReturnLevel(_ dB: Double) {}
    func setSwReturnProcessing(_ enabled: Bool) { lock.withLock { helper.append("processing \(enabled)") } }
    func resetAudioOutput() {}
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {}

    /// What the unit holds for one mixer command at one strip: the last write.
    func last(_ request: UInt8, mixer: UInt16, strip: UInt16) -> [UInt8]? {
        writes.last { $0.request == request && $0.value == mixer && $0.index == strip }?.data
    }
}

extension StandardDefaultsSuites {
@Suite("USB restore order", .serialized)
@MainActor
struct USBRestoreOrderTests {
    private func restoringDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        return {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
    }

    /// A 16-channel USB unit (8 software pairs: row 8 is Mixer 1) with an
    /// Optical card, identity known, and Mixer 1 saved onto Line 1/2.
    private func makeState(uid: String, identity: UInt64, routeMixer1ToLine12: Bool = true)
        throws -> (AppState, XPCDeviceConnection, RecordingUnit) {
        UserDefaults.standard.removeObject(forKey: "mixerWideState.migratedTo")
        let state = AppState()
        state.usbMixerStripSpacing = .zero
        state.connectionMode = .hardware
        state.transportType = .usb
        state.isHardwareInitialized = true
        let unit = RecordingUnit()
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: uid))
        let usb = XPCDeviceConnection(identifier: id, transport: unit)
        state.device = usb
        state.primaryBoardType = .optical
        state.primaryBoardSource = .detected
        state.secondaryBoardType = .none
        state.secondaryBoardSource = .detected
        state.unitAIdentity = identity
        state.unitAIdentityState = .known(identity)
        if routeMixer1ToLine12 {
            state.peripheralRoutingCache(direction: "output").save([8: Set([0])])
        }
        return (state, usb, unit)
    }

    /// Strips, Software Return and Master of both mixers; then the input
    /// routing; then the device settings, speaker mode first; then the output
    /// routing, last.
    private func expectOrder(_ writes: [RecordingUnit.Write], sourceLocation: SourceLocation = #_sourceLocation) {
        let lastMixer = writes.lastIndex { $0.isMixer } ?? -1
        let firstInput = writes.firstIndex { $0.isInputRoute } ?? -1
        let lastInput = writes.lastIndex { $0.isInputRoute } ?? -1
        let speaker = writes.firstIndex { $0.isSpeakerMode } ?? -1
        let firstOutput = writes.firstIndex { $0.isOutputRoute } ?? -1
        let firstMixerRoute = writes.firstIndex { $0.isMixerFedRoute } ?? -1
        let mixerRoutes = writes.filter { $0.isMixerFedRoute }.map { $0.data }
        let mixerWrites = writes.filter { $0.isMixer }.count
        let endsOnOutput = writes.last?.isOutputRoute == true
        #expect(lastMixer >= 0 && firstInput >= 0 && speaker >= 0 && firstOutput >= 0 && firstMixerRoute >= 0,
                "every step wrote something", sourceLocation: sourceLocation)
        #expect(lastMixer < firstInput, "mixers before input routing", sourceLocation: sourceLocation)
        #expect(lastInput < speaker, "input routing before device settings", sourceLocation: sourceLocation)
        #expect(speaker < firstOutput, "device settings before output routing", sourceLocation: sourceLocation)
        // The safety rule itself: every strip of both mixers, Software Return
        // and Master are on the unit before any mixer is routed to an output.
        #expect(lastMixer < firstMixerRoute, sourceLocation: sourceLocation)
        #expect(mixerRoutes == [[32, 64], [33, 65]], sourceLocation: sourceLocation)
        #expect(endsOnOutput, "output routing is written last", sourceLocation: sourceLocation)
        // 16 strips x 4 writes x 2 mixers, plus 5 return and Master writes each.
        #expect(mixerWrites == 16 * 8 + 10, sourceLocation: sourceLocation)
    }

    @Test("recovery: mixers, input routing, device settings, then output routing")
    func recoveryOrder() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-recovery", identity: 0xF2A0_0001)
        // The reset's default input table is still owed, so step 2 has writes.
        UserDefaults.standard.set(true, forKey: "routingMixerReset.pending.usbInputRouting")
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        expectOrder(unit.writes)
        // Consumed only now that every input route was written.
        #expect(!RoutingMixerReset.isPending(.usbInputRouting))
    }

    @Test("connect: identity discovery runs the same order, once")
    func connectOrder() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let identity: UInt64 = 0xF2A0_0002
        let (state, usb, unit) = try makeState(uid: "order-connect", identity: identity)
        UserDefaults.standard.set(true, forKey: "routingMixerReset.pending.usbInputRouting")
        // A fresh connection: identity not read yet.
        state.unitAIdentityState = .pending
        await state.resolveUnitIdentity(for: .a, connection: usb) { identity }
        expectOrder(unit.writes)
        // Launch and reconnect call this next; the restore is not repeated.
        let count = unit.writes.count
        await state.syncSavedStateToHardware()
        #expect(unit.writes.count == count)
    }

    @Test("no setting makes the recovery restore optional")
    func alwaysRestores() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        // Leftovers of the removed switch and of the removed Input Monitoring.
        UserDefaults.standard.set(false, forKey: "autoRecoverMixerState")
        UserDefaults.standard.set(0, forKey: "routingMode")
        let (state, usb, unit) = try makeState(uid: "order-always", identity: 0xF2A0_0003)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.filter { $0.isMixer }.count == 16 * 8 + 10)
        #expect(unit.writes.filter { $0.isMixerFedRoute }.count == 2)
        // Nothing saved muted, nothing forced: every input strip is unmuted.
        #expect(unit.writes.filter { $0.request == 0xB3 && $0.index < 32 }.allSatisfy { $0.data == [0] })
    }

    @Test("a mixer whose strips did not all reach the unit is not routed to an output")
    func failedMixerIsNotRouted() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-failed", identity: 0xF2A0_0004)
        // Mixer 1, strip 5: the unit refuses its mute.
        unit.shouldFail = { $0.request == 0xB3 && $0.value == 1 && $0.index == 5 }
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.filter { $0.isMixerFedRoute }.isEmpty)
        #expect(!state.usbMixerIsWritten(0))
        #expect(state.usbMixerIsWritten(1))
        // Nor by a click in Output Routing while that is so.
        var refused = false
        do {
            try await state.writeOutputRoute(destination: 32, source: SymphonyIORoutingAddress.mixer0Base, device: usb)
        } catch { refused = true }
        #expect(refused)
        #expect(unit.writes.filter { $0.isMixerFedRoute }.isEmpty)
    }

    @Test("a power cycle un-writes the mixers: nothing routes one until the restore has run again")
    func recoveryInvalidates() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-invalidate", identity: 0xF2A0_0005)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(state.usbMixerIsWritten(0))
        // What the meter poll does when the unit comes back.
        state.usbMixersWritten = nil
        let before = unit.writes.count
        await state.syncOutputRoutingToHardware()
        #expect(unit.writes[before...].filter { $0.isMixerFedRoute }.isEmpty)
    }

    @Test("a mute made while the strips are being restored is what the unit ends on")
    func editDuringRestoreWins() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-edit", identity: 0xF2A0_0006)
        let key = ChannelStateStore.mixerKey(0)
        let strips = Array(repeating: MixerChannelState(level: -6, pan: 0, isMuted: false, isSoloed: false), count: 16)
        state.channelStateStore.save(strips, for: key)
        // While strip 4's level is going out the user mutes strip 4 and drops
        // strip 9 to -30 dB: the page saves both at once.
        unit.onWrite = { @MainActor [weak state] write in
            guard let state, write.request == 0xB0, write.value == 1, write.index == 4, write.data == [42] else { return }
            var edited: [MixerChannelState] = state.channelStateStore.load(key) ?? []
            guard !edited[4].isMuted else { return }
            edited[4].isMuted = true
            edited[9].level = -30
            state.channelStateStore.save(edited, for: key)
        }
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.last(0xB3, mixer: 1, strip: 4) == [1])
        #expect(unit.last(0xB0, mixer: 1, strip: 9) == [18])
        #expect(unit.last(0xB3, mixer: 1, strip: 3) == [0])
        // And the store still says what the user chose.
        let saved: [MixerChannelState] = state.channelStateStore.load(key) ?? []
        #expect(saved[4].isMuted && saved[9].level == -30)
    }

    @Test("a Master change made while Master and Software Return are being restored is what the unit ends on")
    func masterEditDuringRestoreWins() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-master", identity: 0xF2A0_0007)
        let preferences = state.mixerPreferences
        preferences.set(-10.0, forKey: "mixerMasterLevel_0")
        unit.onWrite = { write in
            // Mixer 2's Master going out: Mixer 1's was written a moment ago.
            guard write.request == 0xB0, write.value == 2, write.index == 33 else { return }
            if preferences.object(forKey: "mixerMasterLevel_0") as? Double == -10 {
                preferences.set(-20.0, forKey: "mixerMasterLevel_0")
            }
        }
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.last(0xB0, mixer: 1, strip: 33) == [28])
    }

    @Test("two restores of one connection never overlap: the later one starts over and finishes in order")
    func oneRestoreAtATime() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-serial", identity: 0xF2A0_0008)
        let first = Task { @MainActor in await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0) }
        // Let the first get into its strip writes, then start the second.
        while unit.writes.count < 20 { await Task.yield() }
        let second = Task { @MainActor in await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0) }
        await first.value
        await second.value
        let writes = unit.writes
        // The first was stopped before it routed anything; the second wrote
        // every strip and only then the routes.
        let lastMixer = try #require(writes.lastIndex { $0.isMixer })
        let firstMixerRoute = try #require(writes.firstIndex { $0.isMixerFedRoute })
        #expect(lastMixer < firstMixerRoute)
        #expect(writes.filter { $0.isMixerFedRoute }.count == 2)
        #expect(writes.filter { $0.isMixer }.count > 16 * 8 + 10)
        #expect(state.usbRestoreTask == nil)
    }

    @Test("speaker mode: the saved one, or Stereo when none is saved, on every restore")
    func speakerMode() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-speaker", identity: 0xF2A0_0009, routeMixer1ToLine12: false)
        let address = PropertyAddress(selector: .speakerOutputMode)
        #expect(usb.settingsStore.value(for: address) == nil)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.filter { $0.isSpeakerMode }.map { $0.data } == [[2]])
        #expect(state.speakerOutputMode == 2)
        // A default is sent, not saved.
        #expect(usb.settingsStore.value(for: address) == nil)
        // The user picks 5.1; the next recovery puts that back.
        try await usb.setProperty(address, value: .uint32(6))
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.last { $0.isSpeakerMode }?.data == [6])
        #expect(state.speakerOutputMode == 6)
    }

    @Test("the input routing reset flag survives a failed write and is consumed by the next complete one")
    func inputRoutingFlagConsumedOnSuccess() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-flag", identity: 0xF2A0_000A, routeMixer1ToLine12: false)
        UserDefaults.standard.set(true, forKey: "routingMixerReset.pending.usbInputRouting")
        let failing = AtomicFlag()
        failing.set(true)
        unit.shouldFail = { $0.isInputRoute && failing.value }
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(RoutingMixerReset.isPending(.usbInputRouting))
        failing.set(false)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(!RoutingMixerReset.isPending(.usbInputRouting))
        #expect(unit.writes.contains { $0.isInputRoute })
        // With the flag consumed and nothing saved, no input route is sent again.
        let count = unit.writes.filter { $0.isInputRoute }.count
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.filter { $0.isInputRoute }.count == count)
    }
}
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ new: Bool) { lock.withLock { stored = new } }
}
