import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// A fake unit that keeps what it is told and answers reads with it, the way
/// the firmware does (`XPCDeviceConnection.readCompareRequest(for:)`); what it
/// was never told reads as a power-cycled unit's start values (a mixer fader
/// at 48, 0 dB, a pan at 64, centre; everything else 0).
///
/// Like the XMOS control endpoint it answers from one buffer shared by every
/// transfer and always sends the full length asked for
/// (SymphonyIOVendorSpecifics.xc:15-35): a read of an opcode in `unanswered`
/// comes back with status 0 and whatever the transfer before it left there.
private final class HoldingUnit: XPCTransport, @unchecked Sendable {
    struct Key: Hashable { let request: UInt8, value: UInt16, index: UInt16 }
    struct Write: Equatable { let request: UInt8, value: UInt16, index: UInt16, data: [UInt8] }

    private let lock = NSLock()
    private var held: [Key: [UInt8]] = [:]
    private var routeTable: [UInt8: UInt8] = [:]
    /// 0x20: per (wValue, wIndex) of the write, the type and trim.
    private var analog: [Key: (type: UInt8, trim: UInt8)] = [:]
    private var recorded: [Write] = []
    private var resetReads = 0
    private var readCount = 0

    /// 0xDB; nil: the read fails (older firmware).
    var resetRequest: UInt8? = SymphonyIOResetRequest.none.rawValue
    /// A 0xDB write is taken but does not change the request.
    var refuseResetClear = false
    /// Answers to 0xDB before `resetRequest` (a unit still starting).
    var startingAnswers: [UInt8] = []
    /// Every read fails (an older helper or firmware).
    var readsFail = false
    /// Read opcodes the firmware leaves unanswered: their replies are the
    /// shared buffer's residue.
    var unanswered: Set<UInt8> = []
    private var buffer = [UInt8](repeating: 0, count: 64)
    private var otherTransfers = false
    var shadow: USBWriteShadow?
    func writeShadow() async -> USBWriteShadow? { shadow }
    var isConnected: Bool { true }

    var writes: [Write] { lock.withLock { recorded } }
    /// 0xDB reads before any other transfer (the restore's start; the read
    /// checks use it later as a decoy).
    var resetRequestReads: Int { lock.withLock { resetReads } }
    var reads: Int { lock.withLock { readCount } }
    func clearWrites() { lock.withLock { recorded.removeAll(); readCount = 0; resetReads = 0; otherTransfers = false } }
    func value(_ request: UInt8, _ value: UInt16 = 0, _ index: UInt16 = 0) -> [UInt8]? {
        lock.withLock { held[Key(request: request, value: value, index: index)] }
    }
    func route(_ destination: UInt8) -> UInt8? { lock.withLock { routeTable[destination] } }
    func set(_ request: UInt8, _ value: UInt16 = 0, _ index: UInt16 = 0, _ data: [UInt8]) {
        lock.withLock { held[Key(request: request, value: value, index: index)] = data }
    }
    /// A power cycle of the mixers: every strip back at the firmware's start
    /// values (fader 48, pan 64, mute and solo off).
    func powerCycleMixers() {
        lock.withLock { for key in held.keys where (0xB0...0xB3).contains(key.request) { held[key] = nil } }
    }
    /// What a helper's configure does on every attach: every output and both
    /// headphones on the direct table (MaestroVolumeProxy.c direct_route_table).
    func configure() {
        lock.withLock {
            for destination in UInt8(32)...63 { routeTable[destination] = 192 + (destination - 32) % 16 }
            for destination in UInt8(224)...227 { routeTable[destination] = 192 + (destination - 224) % 2 }
        }
    }
    static var helperDirectTable: USBWriteShadow {
        var routes: [UInt8: UInt8] = [:]
        for destination in UInt8(32)...63 { routes[destination] = 192 + (destination - 32) % 16 }
        for destination in UInt8(224)...227 { routes[destination] = 192 + (destination - 224) % 2 }
        return USBWriteShadow(routes: routes, digital: [0x3400: 0, 0x3401: 0], configures: 1)
    }

    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        let bytes = Array(data)
        lock.withLock {
            for (i, byte) in bytes.prefix(buffer.count).enumerated() { buffer[i] = byte }
            otherTransfers = true
            recorded.append(Write(request: bRequest, value: wValue, index: wIndex, data: bytes))
            switch bRequest {
            case 0x31:
                for i in stride(from: 0, to: bytes.count - 1, by: 2) { routeTable[bytes[i]] = bytes[i + 1] }
            case 0x20 where bytes.count == 2:
                analog[Key(request: 0x20, value: wValue, index: wIndex)] = (bytes[0], bytes[1])
            case SymphonyIOResetRequest.command:
                if !refuseResetClear { resetRequest = bytes.first }
            default:
                held[Key(request: bRequest, value: wValue, index: wIndex)] = bytes
            }
        }
    }

    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        try lock.withLock {
            readCount += 1
            if bRequest != SymphonyIOResetRequest.command { otherTransfers = true }
            if readsFail { throw DeviceConnectionError.transportError("no reads") }
            let length = Int(dataLength)
            if unanswered.contains(bRequest) { return XPCPropertyReply(status: 0, data: Data(buffer.prefix(length))) }
            func reply(_ bytes: [UInt8]) -> XPCPropertyReply {
                let sent = Array((bytes + Array(repeating: 0, count: length)).prefix(length))
                for (i, byte) in sent.prefix(buffer.count).enumerated() { buffer[i] = byte }
                return XPCPropertyReply(status: 0, data: Data(sent))
            }
            switch bRequest {
            case SymphonyIOResetRequest.command:
                if !otherTransfers { resetReads += 1 }
                if !startingAnswers.isEmpty { return reply([startingAnswers.removeFirst()]) }
                guard let resetRequest else { throw DeviceConnectionError.transportError("unanswered") }
                return reply([resetRequest])
            case 0x31:
                return reply([routeTable[UInt8(truncatingIfNeeded: wIndex)] ?? 0])
            case 0x20:
                let stored = analog[Key(request: 0x20, value: wValue & 0xFF00, index: wIndex)]
                let type = UInt8(wValue & 0xFF)
                return reply([stored?.type == type ? 1 : 0, stored?.trim ?? 0])
            case 0x60:
                return reply([analog[Key(request: 0x20, value: wValue, index: wIndex)]?.type ?? 0])
            case 0xDE:
                let bank0 = held[Key(request: 0x10, value: 0, index: 0)]?.first ?? 0
                let bank1 = held[Key(request: 0x10, value: 0, index: 1)]?.first ?? 0
                let over = held[Key(request: 0x12, value: 0, index: 0)]?.first ?? 0
                let peak = held[Key(request: 0x11, value: 0, index: 0)]?.first ?? 0
                return reply([bank0, bank1, over, peak])
            case 0xB0, 0xB1:
                return reply(held[Key(request: bRequest, value: wValue, index: wIndex)] ?? [bRequest == 0xB0 ? 48 : 64])
            default:
                return reply(held[Key(request: bRequest, value: wValue, index: wIndex)] ?? [])
            }
        }
    }
    func getSoftwareMeterLevels() async -> (Float, Float)? { (0, 0) }
    func setSwReturnMute(_ muted: Bool) {}
    func setSwReturnLevel(_ dB: Double) {}
    func setSwReturnProcessing(_ enabled: Bool) {}
    func resetAudioOutput() {}
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {}
}

extension StandardDefaultsSuites {
@Suite("USB restore: reset request and read-before-write", .serialized)
@MainActor
struct USBResetRequestRestoreTests {
    private func restoringDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        return {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
    }

    /// A 16-channel USB unit with a 16-channel analog card, identity known,
    /// with saved speaker mode, dim, meter settings, per-channel levels and
    /// soft limits, and a mixer strip, on the default (direct) routing.
    private func makeState(uid: String, identity: UInt64) throws -> (AppState, XPCDeviceConnection, HoldingUnit) {
        UserDefaults.standard.removeObject(forKey: "mixerWideState.migratedTo")
        let state = AppState()
        state.usbMixerStripSpacing = .zero
        state.connectionMode = .hardware
        state.transportType = .usb
        state.isHardwareInitialized = true
        let unit = HoldingUnit()
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: uid))
        let usb = XPCDeviceConnection(identifier: id, transport: unit)
        state.device = usb
        state.primaryBoardType = .analogADDA16
        state.primaryBoardSource = .detected
        state.secondaryBoardType = .none
        state.secondaryBoardSource = .detected
        state.unitAIdentity = identity
        state.unitAIdentityState = .known(identity)
        let store = usb.settingsStore
        store.record(.uint32(2), for: PropertyAddress(selector: .speakerOutputMode))
        store.record(.bool(true), for: PropertyAddress(selector: .outputDim))
        store.record(.uint32(2), for: PropertyAddress(selector: .peakHoldMode))
        var input = InputChannelState()
        input.softLimit = 1
        input.digitalRefLevel = 2
        var output = OutputChannelState()
        output.trim = -1.5
        state.channelStateStore.save(Array(repeating: input, count: 4), for: ChannelStateStore.inputKey)
        state.channelStateStore.save(Array(repeating: output, count: 4), for: ChannelStateStore.outputKey)
        state.channelStateStore.save([MixerChannelState(level: -12, pan: 0.5, isMuted: true, isSoloed: false)],
                                     for: ChannelStateStore.mixerKey(0))
        unit.configure()
        unit.shadow = HoldingUnit.helperDirectTable
        return (state, usb, unit)
    }

    /// A power-cycled unit: its first restore writes everything that differs
    /// from its start values. Returns those writes.
    @discardableResult
    private func firstRestore(_ state: AppState, _ usb: XPCDeviceConnection, _ unit: HoldingUnit) async throws -> [HoldingUnit.Write] {
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let writes = unit.writes
        try #require(!state.usbRestoreOwed)
        try #require(writes.contains { $0.request == 0x25 } && writes.contains { $0.request == 0x20 }
                     && writes.contains { $0.request == 0x22 } && writes.contains { $0.request == 0xE7 }
                     && writes.contains { $0.request == 0x11 } && writes.contains { (0xB0...0xB3).contains($0.request) })
        unit.clearWrites()
        return writes
    }

    /// The USB cable out and back in: the helper configures the unit again
    /// and the app gets a new connection generation.
    private func replug(_ state: AppState, _ unit: HoldingUnit) {
        unit.configure()
        state.unitAGeneration = UUID()
    }

    @Test("a plain replug (the unit reports no reset and holds every setting): Maestro writes nothing")
    func plainReplugWritesNothing() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-replug", identity: 0xF2B0_0001)
        // The saved routing is the helper's direct table.
        for (destination, source) in state.cachedOutputRouteMap() {
            try #require(HoldingUnit.helperDirectTable.routes[destination] == source)
        }
        try await firstRestore(state, usb, unit)
        // Unplugged and plugged back in: the helper configures it again.
        replug(state, unit)
        let started = Date()
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        print("[test] plain replug restore: \(unit.reads) reads, \(unit.writes.count) writes, \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        #expect(unit.writes == [], "\(unit.writes)")
        #expect(usb.restoreReadComparedSkips > 0)
        #expect(!state.usbRestoreOwed)
        #expect(state.usbRestoredGeneration == state.unitAGeneration)
        #expect(state.usbMixerIsWritten(0) && state.usbMixerIsWritten(1))
    }

    @Test("a plain replug with a mixer on Line 1/2: only that route is put back, after the mixers, as before")
    func plainReplugRewritesOnlyMixerRoutes() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-replug-mixer", identity: 0xF2B0_0002)
        state.peripheralRoutingCache(direction: "output").save([8: Set([0])])
        try await firstRestore(state, usb, unit)
        // The helper's configure put Line 1/2 back on USB 1-2.
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let none = SymphonyIORoutingAddress.none
        #expect(unit.writes.map(\.data) == [[32, none], [33, none], [32, 64], [33, 65]],
                "the pair is taken off USB, the strips are already there, then routed: \(unit.writes)")
    }

    /// A front-panel reset of `type` on a unit with non-default saved state
    /// (a mixer on Line 1/2, a muted strip at -12 dB, dim on, soft limit,
    /// digital reference level and output trim set). The speaker and
    /// Headphone 2 report 0 dB attenuation (louder than the reset's -20 dB),
    /// Headphone 1 reports -40 dB. Returns the restore's writes.
    private func frontPanelReset(_ type: SymphonyIOResetRequest, uid: String, identity: UInt64)
        async throws -> (AppState, XPCDeviceConnection, HoldingUnit, [HoldingUnit.Write]) {
        let (state, usb, unit) = try makeState(uid: uid, identity: identity)
        state.peripheralRoutingCache(direction: "output").save([8: Set([0])])
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        unit.set(0x26, 0, 0, [0])
        unit.set(0x23, 0, 0, [40])
        unit.set(0x23, 0, 1, [0])
        unit.resetRequest = type.rawValue
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        return (state, usb, unit, unit.writes)
    }

    @Test("a front-panel Reset All: Maestro's saved state for the unit goes to defaults, is written in full, then the request is cleared")
    func frontPanelResetAll() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit, writes) = try await frontPanelReset(.resetAll, uid: "reset-all", identity: 0xF2B0_0003)
        // Saved state: defaults.
        let inputs: [InputChannelState] = try #require(state.channelStateStore.load(ChannelStateStore.inputKey))
        let outputs: [OutputChannelState] = try #require(state.channelStateStore.load(ChannelStateStore.outputKey))
        #expect(inputs.allSatisfy { $0.softLimit == InputResetDefaults.softLimit && $0.digitalRefLevel == InputResetDefaults.digitalRefLevel })
        // Outputs: the defaults, except nothing louder: the saved -1.5 dB
        // trim is below the default 0 dB and stays (`frontPanelResetOutput`).
        #expect(outputs.allSatisfy { $0.analogRefLevel == 1 && $0.digitalRefLevel == 2 && $0.trim == -1.5 })
        let strips: [MixerChannelState] = state.channelStateStore.load(ChannelStateStore.mixerKey(0)) ?? []
        #expect(strips.isEmpty)
        #expect(state.peripheralRoutingCache(direction: "output").loadMulti() == nil)
        #expect(usb.settingsStore.value(for: PropertyAddress(selector: .peakHoldMode))?.asUInt32 == 0)
        #expect(usb.settingsStore.value(for: PropertyAddress(selector: .outputDim))?.asBool == true, "dim on is kept")
        // Written: the default strips, no mixer on any output, nothing
        // compared with the unit first.
        #expect(writes.contains(HoldingUnit.Write(request: 0xB0, value: 1, index: 0, data: [48])))
        #expect(writes.contains(HoldingUnit.Write(request: 0xB3, value: 1, index: 0, data: [0])))
        let routes = writes.filter { $0.request == 0x31 }.flatMap { write in
            stride(from: 0, to: write.data.count - 1, by: 2).map { (write.data[$0], write.data[$0 + 1]) } }
        #expect(!routes.contains { $0.0 < 228 && CardOutputTableOrder.mixer(ofSource: $0.1) != nil },
                "no output or headphone on a mixer: \(routes)")
        #expect(unit.route(32) == 192 && unit.route(33) == 193, "Line 1/2 back on USB 1-2")
        #expect(usb.restoreReadComparedSkips == 0)
        // Levels: only ever lowered, to -20 dB; mutes untouched.
        #expect(writes.contains(HoldingUnit.Write(request: 0x26, value: 0, index: 0, data: [20])), "speaker 0 dB -> -20 dB")
        #expect(writes.contains(HoldingUnit.Write(request: 0x23, value: 0, index: 1, data: [20])), "Headphone 2 0 dB -> -20 dB")
        #expect(!writes.contains { $0.request == 0x23 && $0.index == 0 }, "Headphone 1 at -40 dB is not raised")
        #expect(!writes.contains { $0.request == 0x27 }, "no mute written")
        // Cleared last, once.
        #expect(writes.last == HoldingUnit.Write(request: 0xDB, value: 0, index: 0, data: [SymphonyIOResetRequest.none.rawValue]))
        #expect(writes.filter { $0.request == 0xDB }.count == 1)
        #expect(unit.resetRequest == SymphonyIOResetRequest.none.rawValue)
        #expect(!state.usbRestoreOwed)
        // Cleared: the next restore writes nothing.
        unit.clearWrites()
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes == [], "\(unit.writes)")
    }

    @Test("a front-panel Reset All But Calibration keeps reference levels and trims, and resets the rest")
    func frontPanelResetKeepsCalibration() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, _, unit, writes) = try await frontPanelReset(.resetAllButCalibration, uid: "reset-calibration",
                                                                 identity: 0xF2B0_000B)
        let inputs: [InputChannelState] = try #require(state.channelStateStore.load(ChannelStateStore.inputKey))
        let outputs: [OutputChannelState] = try #require(state.channelStateStore.load(ChannelStateStore.outputKey))
        #expect(inputs.allSatisfy { $0.softLimit == InputResetDefaults.softLimit }, "soft limit reset in both")
        #expect(inputs.allSatisfy { $0.digitalRefLevel == 2 }, "digital reference level kept")
        #expect(outputs.allSatisfy { $0.trim == -1.5 }, "trims kept")
        #expect((state.channelStateStore.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?)?.isEmpty ?? true)
        #expect(writes.contains(HoldingUnit.Write(request: 0x26, value: 0, index: 0, data: [20])))
        #expect(unit.resetRequest == SymphonyIOResetRequest.none.rawValue)
    }

    @Test("a level the unit does not answer is not written after a front-panel reset")
    func frontPanelResetUnreadLevelsLeftAlone() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-levels-unread", identity: 0xF2B0_000C)
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        unit.unanswered = [0x26, 0x23]
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(!unit.writes.contains { $0.request == 0x26 || $0.request == 0x23 }, "\(unit.writes.filter { $0.request == 0x26 || $0.request == 0x23 })")
        #expect(unit.resetRequest == SymphonyIOResetRequest.none.rawValue)
    }

    @Test("a front-panel reset on a unit whose identity could not be read: saved state left alone, everything written")
    func frontPanelResetWithoutIdentity() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-no-identity", identity: 0xF2B0_000E)
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        state.unitAIdentityState = .failed
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        // Without an identity the channel store is another (shared) scope:
        // nothing in it, and nothing in the unit's own, was reset.
        #expect((state.channelStateStore.load(ChannelStateStore.outputKey) as [OutputChannelState]?) == nil)
        state.unitAIdentityState = .known(0xF2B0_000E)
        let outputs: [OutputChannelState] = try #require(state.channelStateStore.load(ChannelStateStore.outputKey))
        #expect(outputs.allSatisfy { $0.trim == -1.5 }, "the unit's own saved state is not reset")
        #expect(usb.settingsStore.value(for: PropertyAddress(selector: .peakHoldMode))?.asUInt32 == 2)
        #expect(usb.restoreReadComparedSkips == 0, "still written without asking")
        // That restore did not complete (no identity), so the request stays
        // for the one that does.
        #expect(state.usbRestoreOwed)
        #expect(unit.resetRequest == SymphonyIOResetRequest.resetAll.rawValue)
    }

    @Test("a front-panel reset is applied to the saved state once per connection")
    func frontPanelResetOncePerGeneration() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-once", identity: 0xF2B0_000D)
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        // The clear is refused: 0xDB still reads Reset All on the retry.
        unit.refuseResetClear = true
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.resetRequest == SymphonyIOResetRequest.resetAll.rawValue)
        // An edit made after the reset, then another restore of the same connection.
        let edited = MixerChannelState(level: -6, pan: 0, isMuted: false, isSoloed: false)
        state.channelStateStore.save([edited], for: ChannelStateStore.mixerKey(0))
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let strips: [MixerChannelState] = state.channelStateStore.load(ChannelStateStore.mixerKey(0)) ?? []
        #expect(strips == [edited], "the edit is not wiped by a second reset")
    }

    @Test("ThunderBridge: the front-panel reset is only read and applied over USB")
    func frontPanelResetIsUSBOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = root.appendingPathComponent("MaestroApp")
        let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
        var callers: [String] = []
        for file in files {
            let text = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            if text.contains("resetSavedStateForFrontPanelReset(reset") { callers.append(file) }
            #expect(!(file.localizedCaseInsensitiveContains("thunder") && text.contains("FrontPanelReset")), "\(file)")
        }
        #expect(callers == ["AppState+IdentityPersistence.swift"])
        let restore = try String(contentsOf: app.appendingPathComponent("AppState+IdentityPersistence.swift"), encoding: .utf8)
        let start = try #require(restore.range(of: "private func performUSBRestore(_ connection: XPCDeviceConnection"))
        let call = try #require(restore.range(of: "resetSavedStateForFrontPanelReset(reset"))
        let next = restore.range(of: "\n    func ", range: start.upperBound..<restore.endIndex)?.lowerBound ?? restore.endIndex
        #expect(call.lowerBound > start.upperBound && call.lowerBound < next, "only inside the USB restore")
    }

    @Test("the reset request cannot be read: only the settings the unit does not hold are written")
    func unreadableResetWritesOnlyDifferences() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-unreadable", identity: 0xF2B0_0004)
        try await firstRestore(state, usb, unit)
        unit.resetRequest = nil
        replug(state, unit)
        // The unit lost two settings: the speaker mode and one strip's mute.
        unit.set(0x25, 0, 0, [0])
        let muteKey = try #require(unit.value(0xB3, 1, 0))
        unit.set(0xB3, 1, 0, [muteKey == [1] ? 0 : 1])
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes == [
            HoldingUnit.Write(request: 0xB3, value: 1, index: 0, data: muteKey),
            HoldingUnit.Write(request: 0x25, value: 0, index: 0, data: [2]),
        ], "\(unit.writes)")
        #expect(unit.resetRequestReads >= 1)
    }

    @Test("a unit still starting is asked again every 200 ms before anything is written")
    func waitsForAStartingUnit() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-starting", identity: 0xF2B0_0005)
        unit.startingAnswers = [SymphonyIOResetRequest.waitForInit.rawValue,
                                SymphonyIOResetRequest.waitForUserSelection.rawValue]
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.resetRequestReads == 3)
        #expect(!unit.writes.isEmpty)
        #expect(!unit.writes.contains { $0.request == 0xDB })
    }

    @Test("reads that fail: every write is sent, as before")
    func readsFailingSendEverything() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-reads-fail", identity: 0xF2B0_0006)
        let first = try await firstRestore(state, usb, unit)
        unit.readsFail = true
        unit.shadow = nil
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.count >= first.count)
        #expect(usb.restoreReadComparedSkips == 0)
    }

    /// Strip writes of input strips (0-31), in order.
    private func stripWrites(_ writes: [HoldingUnit.Write]) -> [HoldingUnit.Write] {
        writes.filter { (0xB0...0xB3).contains($0.request) && $0.index < 32 }
    }

    @Test("mixer reads the firmware does not answer (residue of the write before): every strip is written, as with no reads")
    func residueMixerReadsWriteEveryStrip() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-residue", identity: 0xF2B0_0008)
        // The same values strip after strip: a residue reply of strip N+1 is
        // strip N's write, and looks right.
        let strip = MixerChannelState(level: -12, pan: 0.5, isMuted: true, isSoloed: false)
        state.channelStateStore.save(Array(repeating: strip, count: 16), for: ChannelStateStore.mixerKey(0))
        state.channelStateStore.save(Array(repeating: strip, count: 16), for: ChannelStateStore.mixerKey(1))
        try await firstRestore(state, usb, unit)
        // What a unit whose reads all fail gets after a power cycle.
        unit.powerCycleMixers()
        unit.readsFail = true
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let full = stripWrites(unit.writes)
        unit.clearWrites()
        unit.readsFail = false
        // The same power cycle, with the mixer reads left to residue.
        unit.powerCycleMixers()
        unit.unanswered = [0xB0, 0xB1, 0xB2, 0xB3]
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(full.count == state.cardLayout.mixerChannels.filter { (0...31).contains($0.hardwareIndex) }.count * 8)
        #expect(stripWrites(unit.writes) == full, "every strip written, none skipped on a residue reply")
        #expect(usb.restoreReadLiveness[0xB0] == false && usb.restoreReadLiveness[0xB3] == false)
        #expect(usb.restoreReadLiveness[0x25] == true, "the opcodes it answers are still compared")
        #expect(!state.usbRestoreOwed)
    }

    @Test("one strip read that cannot be real: every strip of that mixer is written, the other mixer is left alone")
    func implausibleStripWritesWholeMixer() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-implausible", identity: 0xF2B0_0009)
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        unit.set(0xB3, 2, 3, [7])
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let writes = stripWrites(unit.writes)
        #expect(!writes.isEmpty && writes.allSatisfy { $0.value == 2 }, "\(writes)")
        #expect(writes.count == state.cardLayout.mixerChannels.filter { (0...31).contains($0.hardwareIndex) }.count * 4)
    }

    @Test("routing reads the firmware does not answer: the routes the helper does not vouch for are written, nothing else")
    func residueRouteReads() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-residue-routes", identity: 0xF2B0_000A)
        try await firstRestore(state, usb, unit)
        unit.unanswered = [0x31]
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.allSatisfy { $0.request == 0x31 }, "\(unit.writes)")
        // Outputs and headphones are the helper's (its shadow); only the
        // mixers' Software Return inputs are sent again.
        let destinations = unit.writes.flatMap { write in stride(from: 0, to: write.data.count, by: 2).map { write.data[$0] } }
        #expect(destinations.allSatisfy { $0 >= 228 }, "\(destinations)")
        #expect(usb.restoreReadLiveness[0x31] == false)
    }

    @Test("the helper configured the unit again after the restore: the routing is owed")
    func helperReconfigureOwesRestore() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-reconfigure", identity: 0xF2B0_0007)
        state.peripheralRoutingCache(direction: "output").save([8: Set([0])])
        try await firstRestore(state, usb, unit)
        #expect(state.usbRestoredHelperConfigures == 1)
        await state.serviceHelperReconfigure(usb)
        #expect(!state.usbRestoreOwed, "the same configure: nothing owed")
        // A stale handle the helper recovered from by itself.
        unit.configure()
        unit.shadow?.configures = 2
        // Not while the unit is still settling after it appeared.
        state.symphonyAppearedAt = Date()
        await state.serviceHelperReconfigure(usb)
        #expect(!state.usbRestoreOwed, "inside the settle wait")
        state.symphonyAppearedAt = nil
        // Not while a restore runs: that one puts the routing back.
        state.usbRestoreTask = Task { @MainActor in }
        await state.serviceHelperReconfigure(usb)
        #expect(!state.usbRestoreOwed, "a restore is running")
        state.usbRestoreTask = nil
        await state.serviceHelperReconfigure(usb)
        #expect(state.usbRestoreOwed)
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        #expect(unit.writes.suffix(2).map(\.data) == [[32, 64], [33, 65]])
        #expect(!state.usbRestoreOwed)
        #expect(state.usbRestoredHelperConfigures == 2)
    }

    /// The same unit, after Maestro quit and was opened again: a new
    /// `AppState` and connection on the same saved settings, nothing seeded.
    private func relaunch(uid: String, identity: UInt64, unit: HoldingUnit) throws -> (AppState, XPCDeviceConnection) {
        let state = AppState()
        state.usbMixerStripSpacing = .zero
        state.connectionMode = .hardware
        state.transportType = .usb
        state.isHardwareInitialized = true
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: uid))
        let usb = XPCDeviceConnection(identifier: id, transport: unit)
        state.device = usb
        state.primaryBoardType = .analogADDA16
        state.primaryBoardSource = .detected
        state.secondaryBoardType = .none
        state.secondaryBoardSource = .detected
        state.unitAIdentity = identity
        state.unitAIdentityState = .known(identity)
        unit.configure()
        return (state, usb)
    }

    /// Put `byte` in the unit's shared reply buffer, as the transfer before
    /// the restore's first read would.
    private func leaveInBuffer(_ byte: UInt8, _ unit: HoldingUnit) async throws {
        try await unit.sendSetProperty(bRequest: 0x99, wValue: 0, wIndex: 0, data: Data([byte]))
        unit.clearWrites()
    }

    @Test("residue in the reply buffer reading 3 (0xDB unanswered) is not a front-panel reset: nothing is wiped or cleared")
    func residueResetRequestDoesNotWipe() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-residue-db", identity: 0xF2B0_0010)
        try await firstRestore(state, usb, unit)
        defer { FrontPanelResetMarker.clear(for: 0xF2B0_0010) }
        replug(state, unit)
        unit.unanswered = [SymphonyIOResetRequest.command]
        try await leaveInBuffer(SymphonyIOResetRequest.resetAll.rawValue, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let strips: [MixerChannelState] = state.channelStateStore.load(ChannelStateStore.mixerKey(0)) ?? []
        #expect(strips == [MixerChannelState(level: -12, pan: 0.5, isMuted: true, isSoloed: false)], "saved strip kept")
        #expect(usb.settingsStore.value(for: PropertyAddress(selector: .peakHoldMode))?.asUInt32 == 2)
        let outputs: [OutputChannelState] = try #require(state.channelStateStore.load(ChannelStateStore.outputKey))
        #expect(outputs.allSatisfy { $0.trim == -1.5 })
        #expect(!unit.writes.contains { $0.request == SymphonyIOResetRequest.command }, "0xDB not cleared")
        #expect(!unit.writes.contains { $0.request == 0x26 || $0.request == 0x23 }, "no level lowered")
        #expect(usb.restoreReadComparedSkips > 0, "the unit is asked before each write, as on a replug")
        #expect(FrontPanelResetMarker.stage(for: 0xF2B0_0010) == nil)
    }

    @Test("a reset request that answers differently on its two checks is not a front-panel reset")
    func resetRequestMustRepeat() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-disagree", identity: 0xF2B0_0011)
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        // The poll, then check 1 (read, read again), then check 2.
        unit.startingAnswers = [3, 3, 3, 4, 4]
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let strips: [MixerChannelState] = state.channelStateStore.load(ChannelStateStore.mixerKey(0)) ?? []
        #expect(strips.count == 1, "saved strip kept")
        #expect(!unit.writes.contains { $0.request == SymphonyIOResetRequest.command })
        #expect(usb.restoreReadComparedSkips > 0)
    }

    @Test("Reset All: an output on -10 dBV stays on -10 dBV; reference levels and trims only ever move the quieter way")
    func resetAllNeverRaisesOutputReferences() async throws {
        let quiet = OutputChannelState(analogRefLevel: OutputChannelLogic.minus10dBV, digitalRefLevel: 4, trim: -0.5)
        let kept = AppState.frontPanelResetOutput(quiet)
        #expect(kept.analogRefLevel == OutputChannelLogic.minus10dBV, "-10 dBV kept: +4 dBu would be about 12 dB louder")
        #expect(kept.digitalRefLevel == 4, "-12 dBFS kept: -16 dBFS would be louder")
        #expect(kept.trim == -0.5 && kept.trimMinus10 == -0.5)
        // Saved louder than the defaults: brought to them.
        var loud = OutputChannelState(analogRefLevel: OutputChannelLogic.plus4dBu, digitalRefLevel: 1, trim: 1.0)
        loud.trimMinus10 = 2.0
        let lowered = AppState.frontPanelResetOutput(loud)
        #expect(lowered == OutputChannelState(), "\(lowered)")

        // Through the restore: the saved -10 dBV is what is written.
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-minus10", identity: 0xF2B0_0012)
        defer { FrontPanelResetMarker.clear(for: 0xF2B0_0012) }
        state.channelStateStore.save(Array(repeating: quiet, count: 4), for: ChannelStateStore.outputKey)
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let outputs: [OutputChannelState] = try #require(state.channelStateStore.load(ChannelStateStore.outputKey))
        #expect(outputs.allSatisfy { $0.analogRefLevel == OutputChannelLogic.minus10dBV && $0.digitalRefLevel == 4 })
        #expect(unit.resetRequest == SymphonyIOResetRequest.none.rawValue)
    }

    @Test("after a front-panel reset the speaker and headphone levels come down before any other write")
    func resetLowersLevelsFirst() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, _, unit, writes) = try await frontPanelReset(.resetAll, uid: "reset-order", identity: 0xF2B0_0013)
        defer { FrontPanelResetMarker.clear(for: 0xF2B0_0013) }
        #expect(unit.resetRequest == SymphonyIOResetRequest.none.rawValue)
        _ = state
        let first = try #require(writes.firstIndex { $0.request != 0x26 && $0.request != 0x23 })
        #expect(first == 2, "\(writes.prefix(4))")
        #expect(writes.prefix(2).allSatisfy { ($0.request == 0x26 || $0.request == 0x23) && $0.data == [20] })
    }

    @Test("a USB front-panel reset leaves no ThunderBridge route on a mixer and marks ThunderBridge's mixers and input routing pending")
    func resetMakesThunderBridgeSafe() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let defaults = UserDefaults.standard
        let (state, usb, unit) = try makeState(uid: "reset-tb", identity: 0xF2B0_0014)
        defer { FrontPanelResetMarker.clear(for: 0xF2B0_0014) }
        try await firstRestore(state, usb, unit)
        // ThunderBridge (32 channels, PID 0x12) saved state for this unit:
        // Mixer 1 (row 16) on Line 1/2, a direct route on row 0; a unit B
        // table of a pair it is in; and another unit whose identity starts
        // with this one's.
        let tbKey = "cardRouting.v3.18.a=f2b00014.b=none.channels=32.a.analogADDA16+none_multi"
        let pairKey = "cardRouting.v3.18.a=abcd.b=f2b00014.channels=64.b.analogADDA16+none_multi"
        let otherKey = "cardRouting.v3.18.a=f2b000140.b=none.channels=32.a.analogADDA16+none_multi"
        defaults.set(["16": [0], "17": [2], "0": [4]], forKey: tbKey)
        defaults.set(["16": [0]], forKey: pairKey)
        defaults.set(["16": [0]], forKey: otherKey)
        RoutingMixerReset.clearPending(.thunderboltCardMixer)
        RoutingMixerReset.clearPending(.thunderboltInputRouting)
        replug(state, unit)
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(defaults.dictionary(forKey: tbKey) as? [String: [Int]] == ["0": [4]], "mixer rows gone, the direct route kept")
        #expect(defaults.object(forKey: pairKey) == nil, "unit B table removed")
        #expect(defaults.dictionary(forKey: otherKey) as? [String: [Int]] == ["16": [0]], "another unit is left alone")
        #expect(RoutingMixerReset.isPending(.thunderboltCardMixer))
        #expect(RoutingMixerReset.isPending(.thunderboltInputRouting))
        defaults.removeObject(forKey: tbKey)
        defaults.removeObject(forKey: otherKey)
        RoutingMixerReset.clearPending(.thunderboltCardMixer)
        RoutingMixerReset.clearPending(.thunderboltInputRouting)
    }

    @Test("a clear that does not land: a replug and a relaunch do not reset again or lower a raised level; acknowledged once the unit answers None")
    func failedClearDoesNotReWipe() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let identity: UInt64 = 0xF2B0_0015
        let (state, usb, unit) = try makeState(uid: "reset-failed-clear", identity: identity)
        defer { FrontPanelResetMarker.clear(for: identity) }
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        unit.set(0x26, 0, 0, [0])
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        unit.refuseResetClear = true
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes.contains(HoldingUnit.Write(request: 0x26, value: 0, index: 0, data: [20])))
        #expect(unit.writes.filter { $0.request == SymphonyIOResetRequest.command }.count == 3, "the clear is tried 3 times")
        #expect(unit.resetRequest == SymphonyIOResetRequest.resetAll.rawValue)
        #expect(FrontPanelResetMarker.stage(for: identity) == .levelsLowered)
        // Edits after the reset: a strip, and the speaker back up to 0 dB.
        let edited = MixerChannelState(level: -6, pan: 0, isMuted: false, isSoloed: false)
        state.channelStateStore.save([edited], for: ChannelStateStore.mixerKey(0))
        unit.set(0x26, 0, 0, [0])
        // Replug: the same app, a new connection.
        unit.clearWrites()
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect((state.channelStateStore.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?) == [edited])
        #expect(!unit.writes.contains { $0.request == 0x26 }, "the raised level is not lowered again")
        // Relaunch: a new app on the same saved settings.
        unit.clearWrites()
        let (again, usbAgain) = try relaunch(uid: "reset-failed-clear", identity: identity, unit: unit)
        await again.restoreUSBMixerAfterRecovery(usbAgain, helperMixer: 0)
        #expect((again.channelStateStore.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?) == [edited],
                "the edit is not wiped by the reset the unit still reports")
        #expect(!unit.writes.contains { $0.request == 0x26 })
        #expect(unit.writes.contains { $0.request == SymphonyIOResetRequest.command }, "the clear is tried again")
        // The clear lands: the marker goes.
        unit.refuseResetClear = false
        unit.clearWrites()
        again.unitAGeneration = UUID()
        await again.restoreUSBMixerAfterRecovery(usbAgain, helperMixer: 0)
        #expect(unit.resetRequest == SymphonyIOResetRequest.none.rawValue)
        #expect(FrontPanelResetMarker.stage(for: identity) == nil)
        #expect((again.channelStateStore.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?) == [edited])
    }

    @Test("a clear whose read-back the unit does not answer is not believed: the marker stays")
    func clearReadBackMustBeAnswered() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let identity: UInt64 = 0xF2B0_0016
        let (state, usb, unit) = try makeState(uid: "reset-clear-unanswered", identity: identity)
        defer { FrontPanelResetMarker.clear(for: identity) }
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        unit.refuseResetClear = true
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        // 0xDB stops answering: the write's own byte (None) comes back as residue.
        unit.unanswered = [SymphonyIOResetRequest.command]
        #expect(await usb.clearResetRequest(attempts: 1) == false)
        #expect(FrontPanelResetMarker.stage(for: identity) != nil)
    }

    @Test("a front-panel reset is not applied while the cards are not read this session")
    func resetWaitsForBoardDetection() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-no-boards", identity: 0xF2B0_0017)
        defer { FrontPanelResetMarker.clear(for: 0xF2B0_0017) }
        try await firstRestore(state, usb, unit)
        replug(state, unit)
        state.secondaryBoardSource = .cached
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect((state.channelStateStore.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?)?.count == 1)
        #expect(!unit.writes.contains { $0.request == SymphonyIOResetRequest.command })
        #expect(unit.resetRequest == SymphonyIOResetRequest.resetAll.rawValue)
        #expect(FrontPanelResetMarker.stage(for: 0xF2B0_0017) == nil)
    }

    @Test("a headphone whose source a mixer feeds counts as a mixer-fed destination (the restore is not paced)")
    func mixerFedHeadphoneCounted() throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, _) = try makeState(uid: "reset-hp-mixer", identity: 0xF2B0_0018)
        usb.settingsStore.record(.uint32(0), for: PropertyAddress(selector: .headphone1RoutingID))
        #expect(!state.mixerFeedsAudibleDestination(), "the headphone follows Line 1/2 on USB 1-2")
        // Mixer 2 (row 9) feeds Line 1/2, which Headphone 1 follows.
        state.peripheralRoutingCache(direction: "output").save([9: Set([0])])
        let sources = try #require(state.usbHeadphoneSources(.headphone1, cachedRoutes: state.cachedOutputRouteMap()))
        #expect(CardOutputTableOrder.mixer(ofSource: sources.left) == 1)
        #expect(state.mixerFeedsAudibleDestination())
    }

    @Test("the mixer strip reads stop as soon as the restore is superseded")
    func stripReadsStopWhenSuperseded() async throws {
        let unit = HoldingUnit()
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "reset-strip-cancel"))
        let usb = XPCDeviceConnection(identifier: id, transport: unit)
        await usb.beginRestoreElision(compareReads: true)
        await usb.verifyMixerStrips(mixer: 0, channels: Array(0..<16), isCurrent: { false })
        #expect(unit.reads == 0)
        usb.endRestoreElision()
    }

    @Test("a confirmed reset with a reset-request read at a board version of 3: another decoy is used")
    func resetDecoysSkipMatchingByte() async throws {
        let unit = HoldingUnit()
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "reset-decoys"))
        let usb = XPCDeviceConnection(identifier: id, transport: unit)
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        unit.set(0x26, 0, 0, [3])
        unit.set(0x23, 0, 0, [3])
        #expect(await usb.confirmFrontPanelReset(separation: .zero) == .resetAll)
        unit.unanswered = [SymphonyIOResetRequest.command]
        #expect(await usb.confirmFrontPanelReset(separation: .zero) == nil)
    }
}
}

@Suite("USB read-before-write requests")
struct USBReadCompareRequestTests {
    @Test("0x20 asks whether the saved type is current, with the type in wValue's low byte, and compares the trim")
    func analogLevelQuestion() throws {
        let write = SymphonyIORequestBuilder.setAnalogReferenceLevel(channel: 3, isOutput: true, type: 1, trimValue: 5)
        let (reads, matches) = try #require(XPCDeviceConnection.readCompareRequest(for: write))
        let read = try #require(reads.first)
        #expect(reads.count == 1)
        #expect(read.request == 0x20 && read.value == write.value | 1 && read.index == write.index)
        #expect(read.data.count == 2)
        #expect(matches([Data([1, 5])]))
        #expect(!matches([Data([1, 4])]))
        #expect(!matches([Data([0, 5])]))
        let noTrim = SymphonyIORequestBuilder.setAnalogReferenceLevel(
            channel: 3, isOutput: false, type: 2, trimValue: SymphonyIOConstants.doNotSetTrimValue)
        let (_, anyTrim) = try #require(XPCDeviceConnection.readCompareRequest(for: noTrim))
        #expect(anyTrim([Data([1, 9])]))
    }

    @Test("routes: one read per destination, held only when every destination plays its source")
    func routes() throws {
        let one = SymphonyIORequestBuilder.setAudioRoute(destination: 228, source: 192)
        let (reads, matches) = try #require(XPCDeviceConnection.readCompareRequest(for: one))
        #expect(reads.map(\.request) == [0x31] && reads.map(\.index) == [228])
        #expect(matches([Data([192])]) && !matches([Data([193])]))
        let pair = SymphonyIORequestBuilder.setAudioRoutes([(228, 192), (229, 193)])
        let (pairReads, pairMatches) = try #require(XPCDeviceConnection.readCompareRequest(for: pair))
        #expect(pairReads.map(\.index) == [228, 229])
        #expect(pairMatches([Data([192]), Data([193])]))
        #expect(!pairMatches([Data([192]), Data([192])]))
    }

    @Test("speaker mode, dim and mixer writes are read back with the same wValue and wIndex")
    func plainReads() throws {
        for write in [SymphonyIORequestBuilder.setSpeakerMode(.stereo),
                      SymphonyIORequestBuilder.setMonitorDim(output: .speaker, enabled: true)] {
            let (reads, matches) = try #require(XPCDeviceConnection.readCompareRequest(for: write))
            let read = try #require(reads.first)
            #expect(read.request == write.request && read.value == write.value && read.index == write.index)
            #expect(matches([write.data]))
        }
        // A strip the firmware has no read for is not asked.
        #expect(XPCDeviceConnection.readCompareRequest(
            for: USBControlRequest(direction: .write, request: 0xB3, value: 1, index: 33, data: Data([0]))).map { _ in true } == nil)
        // Write-only and unreadable commands are always sent.
        #expect(XPCDeviceConnection.readCompareRequest(
            for: USBControlRequest(direction: .write, request: 0x50, data: Data([1, 1, 0, 0]))).map { _ in true } == nil)
    }
}
