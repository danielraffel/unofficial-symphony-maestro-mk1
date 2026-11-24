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
        /// (0x31 to 228-231 is a mixer's Software Return source.)
        var isMixer: Bool { (0xB0...0xB4).contains(request) || (request == 0x31 && (data.first ?? 0) >= 228) }
        /// An output route: 0x31 [destination, source], outputs are 32-63.
        var isOutputRoute: Bool { request == 0x31 && (32..<64).contains(data.first ?? 0) }
        /// A headphone crosspoint: 0x31 to 224/225 (headphone 1) or 226/227.
        var isHeadphoneRoute: Bool { request == 0x31 && (224...227).contains(data.first ?? 0) }
        /// Anything a listener hears: an output or a headphone.
        var isAudibleRoute: Bool { isOutputRoute || isHeadphoneRoute }
        var isMixerFedRoute: Bool { isOutputRoute && data.count > 1 && (64..<128).contains(data[1]) }
        var isMixerFedHeadphone: Bool { isHeadphoneRoute && data.count > 1 && (64..<128).contains(data[1]) }
        var isInputRoute: Bool { request == 0x31 && !isOutputRoute && (data.first ?? 0) < 0xE0 }
        /// The mixer (0 or 1) a mixer write belongs to.
        var mixer: Int? {
            if (0xB0...0xB4).contains(request) { return (1...2).contains(value) ? Int(value) - 1 : nil }
            guard request == 0x31, let destination = data.first, destination >= 228 else { return nil }
            return destination < 230 ? 0 : 1
        }
        var isSpeakerMode: Bool { request == 0x25 }
    }
    private let lock = NSLock()
    private var recorded: [Write] = []
    private var helper: [String] = []
    /// What the helper answers to "helperVersion"; nil for one that predates
    /// the question (it still answers the meter read).
    var version: UInt64? = XPCDeviceConnection.requiredHelperVersion
    func helperVersion() async -> UInt64? { version }
    /// What the helper says the unit holds; nil: an older helper, nothing said.
    var shadow: USBWriteShadow?
    func writeShadow() async -> USBWriteShadow? { shadow }
    /// What a helper's configure leaves on the unit: both I/O boards on USB
    /// 1-16, both headphones on USB 1-2 (MaestroVolumeProxy.c direct_route_table).
    static var helperDirectTable: USBWriteShadow {
        var routes: [UInt8: UInt8] = [:]
        for destination in UInt8(32)...63 { routes[destination] = 192 + (destination - 32) % 16 }
        for destination in UInt8(224)...227 { routes[destination] = 192 + (destination - 224) % 2 }
        return USBWriteShadow(routes: routes, digital: [0x3400: 0, 0x3401: 0])
    }
    var shouldFail: (@Sendable (Write) -> Bool)?
    var onWrite: (@Sendable (Write) async -> Void)?

    private var epoch: UInt64 = 0
    var helperEpoch: UInt64 { lock.withLock { epoch } }
    /// The helper restarted under the app.
    func restartHelper() { lock.withLock { epoch += 1 } }

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
    func getSoftwareMeterLevels() async -> (Float, Float)? { (0, 0) }
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

/// Replays a recording unit's write log from what the unit held before it and
/// reports every point at which the rule was broken, for the outputs (32-63)
/// and the headphones (224-227) alike:
///
/// * a route was written that plays a mixer which had not been written in
///   full (every strip, Software Return and Master);
/// * a control of a mixer was written while an output or a headphone was
///   playing that mixer and it had not been written in full (this is what put
///   live inputs in a headphone left on Mixer 1);
/// * at the end, something still plays a mixer that was not written in full.
private enum USBWriteLogChecker {
    static func mixer(ofSource source: UInt8) -> Int? {
        source == 64 || source == 65 ? 0 : source == 96 || source == 97 ? 1 : nil
    }

    /// - Parameters:
    ///   - onUnit: destination to source as the unit holds them before the
    ///     log (a unit that was not power-cycled keeps an earlier session's).
    ///   - written: mixers already written in full before the log.
    ///   - strips: the unit's strip numbers of the fitted cards' inputs.
    static func violations(_ writes: [RecordingUnit.Write], onUnit: [UInt8: UInt8] = [:],
                           written: Set<Int> = [], strips: [Int], settled: Bool = true) -> [String] {
        var required: Set<[UInt16]> = []
        for strip in strips { for command in 0xB0...0xB3 { required.insert([UInt16(command), UInt16(strip)]) } }
        required.formUnion([[0xB0, 33], [0xB0, 32], [0xB3, 32], [0xB2, 32]])
        var routes = onUnit
        var written = written
        var seen: [Int: Set<[UInt16]>] = [:]
        var problems: [String] = []
        func fed(_ mixer: Int) -> [UInt8] { routes.filter { self.mixer(ofSource: $0.value) == mixer }.keys.sorted() }
        for (index, write) in writes.enumerated() {
            if write.isAudibleRoute, write.data.count > 1 {
                if let mixer = mixer(ofSource: write.data[1]), !written.contains(mixer) {
                    problems.append("write \(index): destination \(write.data[0]) routed from mixer \(mixer + 1) before that mixer was written")
                }
                routes[write.data[0]] = write.data[1]
            } else if let mixer = write.mixer, !written.contains(mixer) {
                let playing = fed(mixer)
                if !playing.isEmpty {
                    problems.append("write \(index): mixer \(mixer + 1) control 0x\(String(write.request, radix: 16))/\(write.index) written while destination(s) \(playing) played it and it was not written")
                    seen[mixer] = []
                    continue
                }
                seen[mixer, default: []].insert([UInt16(write.request), write.index])
                if required.isSubset(of: seen[mixer] ?? []) { written.insert(mixer) }
            }
        }
        if settled {
            for (destination, source) in routes.sorted(by: { $0.key < $1.key }) {
                if let mixer = mixer(ofSource: source), !written.contains(mixer) {
                    problems.append("end: destination \(destination) is still on mixer \(mixer + 1), which was not written")
                }
            }
        }
        return problems
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

    /// What an earlier version left on a unit that was not power-cycled: Line
    /// 1/2 and a headphone following it on Mixer 1 (then the default).
    private static let staleMixer1: [UInt8: UInt8] = [32: 64, 33: 65, 224: 64, 225: 65]

    private func strips(_ state: AppState) -> [Int] {
        state.cardLayout.mixerChannels.map(\.hardwareIndex).filter { (0...31).contains($0) }
    }

    private func saveHeadphone1Source(_ id: UInt32, _ usb: XPCDeviceConnection) {
        usb.settingsStore.record(.uint32(id), for: PropertyAddress(selector: .headphone1RoutingID))
    }

    /// Every output and headphone a mixer feeds disabled first; then strips,
    /// Software Return and Master of both mixers; then the input routing;
    /// then the device settings, speaker mode first; then the mixer-fed
    /// routes, last.
    private func expectOrder(_ writes: [RecordingUnit.Write], strips: [Int],
                             sourceLocation: SourceLocation = #_sourceLocation) {
        // Whatever the unit held, also an earlier session's mixer routes.
        #expect(USBWriteLogChecker.violations(writes, onUnit: Self.staleMixer1, strips: strips) == [],
                sourceLocation: sourceLocation)
        let firstMixer = writes.firstIndex { $0.isMixer } ?? -1
        let disabled = writes.prefix(max(0, firstMixer)).filter { $0.isOutputRoute }.map { $0.data }
        #expect(disabled == [[32, SymphonyIORoutingAddress.none], [33, SymphonyIORoutingAddress.none]],
                "the mixer-fed pair is disabled before any strip is written", sourceLocation: sourceLocation)
        let lastMixer = writes.lastIndex { $0.isMixer } ?? -1
        let firstInput = writes.firstIndex { $0.isInputRoute } ?? -1
        let lastInput = writes.lastIndex { $0.isInputRoute } ?? -1
        let speaker = writes.firstIndex { $0.isSpeakerMode } ?? -1
        let firstOutput = writes.indices.first { $0 > firstMixer && writes[$0].isOutputRoute } ?? -1
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
        expectOrder(unit.writes, strips: strips(state))
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
        expectOrder(unit.writes, strips: strips(state))
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

    @Test("a mixer whose strips did not all reach the unit is not routed: its output is disabled, the route owed and sent by the retry")
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
        // Not skipped: an earlier session's mixer route may still be on the
        // unit, so Line 1/2 is disabled until the mixer is written.
        let none = SymphonyIORoutingAddress.none
        #expect(unit.writes.filter { $0.isOutputRoute }.suffix(2).map { $0.data } == [[32, none], [33, none]])
        #expect(USBWriteLogChecker.violations(unit.writes, onUnit: Self.staleMixer1, strips: strips(state)) == [])
        // The connection does not count as restored, and it is said.
        #expect(state.usbRestoredGeneration != state.unitAGeneration)
        #expect(state.usbRestoreOwed)
        #expect(state.usbRestoreRetryAfter > Date())
        #expect(state.restoreStatusNote == PortStatusMessage.restoringMixerAndRouting)
        #expect(state.endpointStatusMessage == PortStatusMessage.restoringMixerAndRouting)
        // A click in Output Routing while that is so is owed too, not an error.
        let before = unit.writes.count
        #expect(try await state.writeOutputRoute(destination: 34, source: SymphonyIORoutingAddress.mixer0Base,
                                                 device: usb) == .deferred)
        #expect(unit.writes[before...].map { $0.data } == [[34, none]])
        // The meter loop retries with a pause: not inside it...
        state.usbRestoreRetryAfter = Date().addingTimeInterval(30)
        state.serviceUSBRestore(usb)
        #expect(state.usbRestoreServiceTask == nil)
        // ...and still failing, it stays owed, however often.
        for _ in 0..<4 {
            state.usbRestoreRetryAfter = .distantPast
            state.serviceUSBRestore(usb)
            await state.usbRestoreServiceTask?.value
            #expect(state.usbRestoreOwed)
            #expect(unit.writes.filter { $0.isMixerFedRoute }.isEmpty)
        }
        // The retry does not send the input routing or the speaker mode again.
        #expect(unit.writes.filter { $0.isSpeakerMode }.count == 1)
        // The unit takes the write: the mixer is written, then its route.
        unit.shouldFail = nil
        state.usbRestoreRetryAfter = .distantPast
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        #expect(state.usbMixerIsWritten(0))
        #expect(unit.writes.suffix(2).map { $0.data } == [[32, 64], [33, 65]])
        let lastMixer = try #require(unit.writes.lastIndex { $0.isMixer })
        let firstRoute = try #require(unit.writes.firstIndex { $0.isMixerFedRoute })
        #expect(lastMixer < firstRoute)
        #expect(!state.usbRestoreOwed)
        #expect(state.usbRestoredGeneration == state.unitAGeneration)
        #expect(state.restoreStatusNote == nil)
        // Nothing owed: the loop leaves the unit alone.
        let quiet = unit.writes.count
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        #expect(unit.writes.count == quiet)
        // With its mixer written a mixer route is immediate.
        #expect(try await state.writeOutputRoute(destination: 36, source: SymphonyIORoutingAddress.mixer1Base,
                                                 device: usb) == .written)
    }

    @Test("first launch after updating, unit not power-cycled: a headphone left on Mixer 1 is pointed away before any strip is written")
    func staleHeadphoneOnMixer() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-hp-stale", identity: 0xF2A0_0010, routeMixer1ToLine12: false)
        // The reset removed the saved routing; the headphone's source (Line
        // 1-2) is a device setting and was kept.
        for item in RoutingMixerReset.Pending.allCases { UserDefaults.standard.set(true, forKey: "routingMixerReset.pending.\(item.rawValue)") }
        saveHeadphone1Source(0, usb)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let writes = unit.writes
        #expect(USBWriteLogChecker.violations(writes, onUnit: Self.staleMixer1, strips: strips(state)) == [])
        let firstMixer = try #require(writes.firstIndex { $0.isMixer })
        let before = writes[..<firstMixer]
        // Headphone 1 on what feeds Line 1/2 now (USB 1-2); headphone 2,
        // which nobody chose a source for, on the firmware's default.
        #expect(before.filter { $0.isHeadphoneRoute }.map { $0.data } == [[224, 192], [225, 193], [226, 192], [227, 193]])
        // What the unit holds is unknown after the reset: every output direct.
        let direct: [[UInt8]] = (0..<32).map { (n: Int) -> [UInt8] in [UInt8(32 + n), UInt8(192 + n % 16)] }
        let outputs: [[UInt8]] = before.filter { $0.isOutputRoute }.map { $0.data }
        #expect(outputs == direct)
        #expect(!RoutingMixerReset.isPending(.usbOutputRouting))
        // Every strip came back unmuted, with nothing listening to it.
        #expect(writes.filter { $0.request == 0xB3 && $0.index < 32 }.allSatisfy { $0.data == [0] })
        #expect(writes.filter { $0.isMixer }.count == 16 * 8 + 10)
        // The headphone's saved source is written again last.
        #expect(writes.suffix(2).map { $0.data } == [[224, 192], [225, 193]])
        #expect(!state.usbRestoreOwed)
        #expect(state.restoreStatusNote == nil)
        // The next restore does not write the whole direct table again.
        let count = unit.writes.count
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes[count...].filter { $0.isOutputRoute }.isEmpty)
    }

    @Test("a headphone following a mixer-fed pair is disabled while the mixer is written and routed after it, last")
    func headphoneFollowsMixerFedPair() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-hp-follow", identity: 0xF2A0_0011)
        saveHeadphone1Source(0, usb)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let writes = unit.writes
        #expect(USBWriteLogChecker.violations(writes, onUnit: Self.staleMixer1, strips: strips(state)) == [])
        let none = SymphonyIORoutingAddress.none
        let firstMixer = try #require(writes.firstIndex { $0.isMixer })
        #expect(writes[..<firstMixer].filter { $0.isAudibleRoute }.map { $0.data }
                == [[224, none], [225, none], [226, 192], [227, 193], [32, none], [33, none]])
        // Outputs, then the headphone that follows them.
        #expect(writes.suffix(4).map { $0.data } == [[32, 64], [33, 65], [224, 64], [225, 65]])
        #expect(!state.usbRestoreOwed)
        // A retry of something owed does not silence a mixer that is written.
        state.usbRestoreOwed = true
        state.usbRestoreRetryAfter = .distantPast
        let count = writes.count
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        #expect(unit.writes[count...].filter { $0.isAudibleRoute && $0.data[1] == none }.isEmpty)
        #expect(unit.writes.suffix(2).map { $0.data } == [[224, 64], [225, 65]])
    }

    @Test("a headphone whose mixer is not written is disabled and owed, also when its source is picked, and sent by the retry")
    func headphoneDeferredThenSent() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-hp-deferred", identity: 0xF2A0_0012)
        saveHeadphone1Source(0, usb)
        unit.shouldFail = { $0.request == 0xB3 && $0.value == 1 && $0.index == 5 }
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let none = SymphonyIORoutingAddress.none
        #expect(unit.writes.filter { $0.isMixerFedRoute || $0.isMixerFedHeadphone }.isEmpty)
        #expect(unit.writes.suffix(2).map { $0.data } == [[224, none], [225, none]])
        #expect(USBWriteLogChecker.violations(unit.writes, onUnit: Self.staleMixer1, strips: strips(state)) == [])
        #expect(state.usbRestoreOwed)
        #expect(state.restoreStatusNote == PortStatusMessage.restoringMixerAndRouting)
        // Picking the source on the Output page meanwhile: the same gate.
        state.usbRestoreOwed = false
        let before = unit.writes.count
        #expect(await !HeadphoneCrosspoint.apply(.headphone2, sourceID: 0, device: usb,
                                                 cachedRoutes: state.cachedOutputRouteMap(), state: state))
        #expect(unit.writes[before...].map { $0.data } == [[226, none], [227, none]])
        #expect(state.usbRestoreOwed)
        // A headphone on a direct pair is not held back.
        #expect(await HeadphoneCrosspoint.apply(.headphone2, sourceID: 1, device: usb,
                                                cachedRoutes: state.cachedOutputRouteMap(), state: state))
        #expect(unit.writes.suffix(2).map { $0.data } == [[226, 194], [227, 195]])
        // The unit takes the write: the mixer, its routes, then the headphone.
        unit.shouldFail = nil
        state.usbRestoreRetryAfter = .distantPast
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        #expect(unit.writes.suffix(4).map { $0.data } == [[32, 64], [33, 65], [224, 64], [225, 65]])
        #expect(USBWriteLogChecker.violations(unit.writes, onUnit: Self.staleMixer1, strips: strips(state)) == [])
        #expect(!state.usbRestoreOwed)
        #expect(state.restoreStatusNote == nil)
        // With its mixer written a headphone takes the mixer at once.
        #expect(await HeadphoneCrosspoint.apply(.headphone2, sourceID: 0, device: usb,
                                                cachedRoutes: state.cachedOutputRouteMap(), state: state))
        #expect(unit.writes.suffix(2).map { $0.data } == [[226, 64], [227, 65]])
    }

    @Test("a route that cannot be taken off a mixer: that run writes no strip")
    func noStripWhileARouteCannotBeMoved() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-hp-refused", identity: 0xF2A0_0013)
        saveHeadphone1Source(0, usb)
        unit.shouldFail = { $0.isHeadphoneRoute }
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.filter { $0.isMixer }.isEmpty)
        #expect(unit.writes.filter { $0.isMixerFedRoute }.isEmpty)
        #expect(state.usbRestoreOwed)
        unit.shouldFail = nil
        state.usbRestoreRetryAfter = .distantPast
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        #expect(USBWriteLogChecker.violations(unit.writes, onUnit: Self.staleMixer1, strips: strips(state)) == [])
        #expect(unit.writes.suffix(2).map { $0.data } == [[224, 64], [225, 65]])
        #expect(!state.usbRestoreOwed)
    }

    @Test("an older USB helper under this app: no strip is written, the status bar asks for a reinstall, and a current helper is restored in full")
    func outdatedHelper() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-old-helper", identity: 0xF2A0_0014)
        // It does not know the version question but answers the meter read.
        unit.version = nil
        #expect(await usb.helperStatus() == .outdated)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.filter { $0.isMixer }.isEmpty)
        #expect(unit.writes.filter { $0.isMixerFedRoute }.isEmpty)
        #expect(state.restoreStatusNote == PortStatusMessage.usbHelperOutdated)
        #expect(state.endpointStatusMessage == PortStatusMessage.usbHelperOutdated)
        #expect(state.usbRestoreOwed)
        // The Mixer page sends nothing under it either (it would unmute
        // strips on the mixer the old helper keeps on Line 1/2), and every
        // output was written direct although nothing is saved for them.
        #expect(state.usbMixerEditsBlockedByOldHelper)
        #expect(!MixerEditorState(appState: state, selectedMixer: 0).canEdit(state))
        #expect(!state.usbMixerIsWritten(0))
        #expect(unit.writes.filter { !$0.isMixer && $0.data.count == 2 && (32..<64).contains($0.data[0]) }.count >= 32)
        // One that answers with an older number is old too.
        unit.version = XPCDeviceConnection.requiredHelperVersion - 1
        #expect(await usb.helperStatus() == .outdated)
        // Reinstalled with USB support: the retry writes the mixers and routes.
        unit.version = XPCDeviceConnection.requiredHelperVersion
        state.usbRestoreRetryAfter = .distantPast
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        #expect(unit.writes.filter { $0.isMixer }.count == 16 * 8 + 10)
        #expect(unit.writes.suffix(2).map { $0.data } == [[32, 64], [33, 65]])
        #expect(state.restoreStatusNote == nil)
        #expect(!state.usbRestoreOwed)
    }

    @Test("the helper source answers the version this app asks for")
    func helperSourceVersion() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Drivers/VolumeProxy/MaestroVolumeProxy.c")
        let text = try String(contentsOf: source, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("#define MAESTRO_HELPER_VERSION ") })
        let number = try #require(UInt64(line.split(separator: " ").last?.dropLast() ?? ""))
        // The helper this app ships has everything the app can ask for.
        #expect(number == XPCDeviceConnection.audioOutputHelperVersion)
        #expect(XPCDeviceConnection.requiredHelperVersion == 2)
        #expect(number >= XPCDeviceConnection.requiredHelperVersion)
        #expect(text.contains("strcmp(cmd, \"helperVersion\") == 0"))
    }

    @Test("a helper that restarts under the app: no mixer route until the restore has run again on it")
    func helperRestart() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-helper", identity: 0xF2A0_000B)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(state.usbRestoredGeneration == state.unitAGeneration)
        let generation = state.unitAGeneration
        // The helper that answers next programs every output direct.
        unit.restartHelper()
        let before = unit.writes.count
        state.serviceUSBRestore(usb)
        // The connection generation did not change, so only this notices.
        #expect(state.unitAGeneration == generation)
        #expect(!state.usbMixerIsWritten(0))
        await state.usbRestoreServiceTask?.value
        let again = Array(unit.writes[before...])
        #expect(again.filter { $0.isMixerFedRoute }.map { $0.data } == [[32, 64], [33, 65]])
        #expect(again.filter { $0.isMixer }.count == 16 * 8 + 10)
        let lastMixer = try #require(again.lastIndex { $0.isMixer })
        let firstRoute = try #require(again.firstIndex { $0.isMixerFedRoute })
        #expect(lastMixer < firstRoute)
        // A new helper gets the device settings too.
        #expect(again.contains { $0.isSpeakerMode })
        #expect(!state.usbRestoreOwed)
    }

    @Test("a second power cycle inside the recovery debounce still gets a restore")
    func secondPowerCycleInsideDebounce() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-debounce", identity: 0xF2A0_000C)
        let first = Date()
        #expect(state.usbRecoveryRestoreDueOrOwed(now: first))
        state.lastRecoveryTime = first
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(!state.usbRestoreOwed)
        // Two seconds later the unit is power-cycled again.
        state.usbMixersWritten = nil
        #expect(!state.usbRecoveryRestoreDueOrOwed(now: first.addingTimeInterval(2)))
        #expect(state.usbRestoreOwed)
        // Not before the debounce has passed...
        let before = unit.writes.count
        state.serviceUSBRestore(usb)
        #expect(state.usbRestoreServiceTask == nil)
        // ...then in full, mixers before the route.
        state.usbRestoreRetryAfter = .distantPast
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        let again = Array(unit.writes[before...])
        #expect(again.filter { $0.isMixerFedRoute }.count == 2)
        #expect(again.contains { $0.isSpeakerMode })
        #expect(!state.usbRestoreOwed)
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

    @Test("connect restore, saved routing equal to what the helper just wrote: no route of an output or headphone is written")
    func unchangedRoutesAreNotRewritten() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-elide", identity: 0xF2A0_000B, routeMixer1ToLine12: false)
        // USB 1-2 to the first output pair, 3-4 to the second, ... as the helper routes them.
        state.peripheralRoutingCache(direction: "output").save([0: Set([0]), 1: Set([1]), 2: Set([2]), 3: Set([3])])
        let saved = state.cachedOutputRouteMap()
        try #require(!saved.isEmpty)
        for (destination, source) in saved {
            try #require(RecordingUnit.helperDirectTable.routes[destination] == source, "saved equals the helper's table at \(destination)")
        }
        unit.shadow = RecordingUnit.helperDirectTable
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.filter { $0.isAudibleRoute }.map(\.data) == [])
        #expect(usb.restoreElidedWrites >= saved.count)
        // The mixers are still written in full; nothing else changed.
        #expect(unit.writes.filter { $0.isMixer }.count == 16 * 8 + 10)
        #expect(state.usbMixerIsWritten(0) && state.usbMixerIsWritten(1))
        // An older helper says nothing: every saved route is written, as before.
        unit.shadow = nil
        let before = unit.writes.count
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let routes = unit.writes.dropFirst(before).filter { $0.isOutputRoute }.map { $0.data[0] }
        #expect(Set(routes) == Set(saved.keys))
    }

    @Test("connect restore: a saved route the unit does not hold is written")
    func changedRouteIsWritten() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-elide-changed", identity: 0xF2A0_000C, routeMixer1ToLine12: false)
        // USB 3-4 to the first output pair: the helper put USB 1-2 there.
        state.peripheralRoutingCache(direction: "output").save([1: Set([0])])
        let saved = state.cachedOutputRouteMap()
        let changed = try #require(saved.min { $0.key < $1.key })
        try #require(RecordingUnit.helperDirectTable.routes[changed.key] != changed.value)
        unit.shadow = RecordingUnit.helperDirectTable
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let written = unit.writes.filter { $0.isOutputRoute }.map(\.data)
        #expect(written.contains([changed.key, changed.value]))
        #expect(written.count == saved.count)
    }

    @Test("connect restore with the helper's table on the unit and Mixer 1 saved on Line 1/2: the pair is disabled before the strips and routed after them")
    func elisionKeepsTheSafetyOrder() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "order-elide-mixer", identity: 0xF2A0_000D)
        unit.shadow = RecordingUnit.helperDirectTable
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let writes = unit.writes
        #expect(USBWriteLogChecker.violations(writes, onUnit: RecordingUnit.helperDirectTable.routes,
                                              strips: strips(state)) == [])
        let firstMixer = try #require(writes.firstIndex { $0.isMixer })
        let lastMixer = try #require(writes.lastIndex { $0.isMixer })
        let disabled = writes.prefix(firstMixer).filter { $0.isOutputRoute }.map(\.data)
        #expect(disabled == [[32, SymphonyIORoutingAddress.none], [33, SymphonyIORoutingAddress.none]])
        let mixerRoutes = writes.indices.filter { writes[$0].isMixerFedRoute }
        #expect(mixerRoutes.map { writes[$0].data } == [[32, 64], [33, 65]])
        #expect(mixerRoutes.allSatisfy { $0 > lastMixer })
        // The headphones were already on USB 1-2: not written.
        #expect(!writes.contains { $0.isHeadphoneRoute })
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
