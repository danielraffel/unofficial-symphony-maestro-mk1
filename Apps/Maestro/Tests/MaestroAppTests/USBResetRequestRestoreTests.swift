import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// A fake unit that keeps what it is told and answers reads with it, the way
/// the firmware does (`XPCDeviceConnection.readCompareRequest(for:)`); what it
/// was never told reads as 0, as a power-cycled unit's start values.
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

    /// 0xDB; nil: the read fails (older firmware).
    var resetRequest: UInt8? = SymphonyIOResetRequest.none.rawValue
    /// Answers to 0xDB before `resetRequest` (a unit still starting).
    var startingAnswers: [UInt8] = []
    /// Every read fails (an older helper or firmware).
    var readsFail = false
    var shadow: USBWriteShadow?
    func writeShadow() async -> USBWriteShadow? { shadow }
    var isConnected: Bool { true }

    var writes: [Write] { lock.withLock { recorded } }
    var resetRequestReads: Int { lock.withLock { resetReads } }
    func clearWrites() { lock.withLock { recorded.removeAll() } }
    func value(_ request: UInt8, _ value: UInt16 = 0, _ index: UInt16 = 0) -> [UInt8]? {
        lock.withLock { held[Key(request: request, value: value, index: index)] }
    }
    func set(_ request: UInt8, _ value: UInt16 = 0, _ index: UInt16 = 0, _ data: [UInt8]) {
        lock.withLock { held[Key(request: request, value: value, index: index)] = data }
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
            recorded.append(Write(request: bRequest, value: wValue, index: wIndex, data: bytes))
            switch bRequest {
            case 0x31:
                for i in stride(from: 0, to: bytes.count - 1, by: 2) { routeTable[bytes[i]] = bytes[i + 1] }
            case 0x20 where bytes.count == 2:
                analog[Key(request: 0x20, value: wValue, index: wIndex)] = (bytes[0], bytes[1])
            case SymphonyIOResetRequest.command:
                resetRequest = bytes.first
            default:
                held[Key(request: bRequest, value: wValue, index: wIndex)] = bytes
            }
        }
    }

    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        try lock.withLock {
            if readsFail { throw DeviceConnectionError.transportError("no reads") }
            let length = Int(dataLength)
            func reply(_ bytes: [UInt8]) -> XPCPropertyReply {
                XPCPropertyReply(status: 0, data: Data((bytes + Array(repeating: 0, count: length)).prefix(length)))
            }
            switch bRequest {
            case SymphonyIOResetRequest.command:
                resetReads += 1
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
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
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

    @Test("the unit reports a front-panel reset: everything is written in the usual order, once, then the request is cleared")
    func frontPanelResetRestoresAllThenClears() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, usb, unit) = try makeState(uid: "reset-front-panel", identity: 0xF2B0_0003)
        try await firstRestore(state, usb, unit)
        // What a restore that cannot read the unit sends (today's full restore).
        unit.readsFail = true
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let full = unit.writes
        unit.clearWrites()
        unit.readsFail = false
        // Reset from the front panel while it started; it still holds every value.
        replug(state, unit)
        unit.resetRequest = SymphonyIOResetRequest.resetAll.rawValue
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        let writes = unit.writes
        // The digital reference levels and the inputs' analog types are read
        // first by the channel replay itself (as before this change), so they
        // are left out of the comparison.
        func sent(_ writes: [HoldingUnit.Write]) -> [HoldingUnit.Write] {
            writes.filter { $0.request != 0x21 && !($0.request == 0x20 && $0.value & 0x8000 != 0) }
        }
        #expect(sent(Array(writes.dropLast())) == sent(full), "the same writes, in the same order, as a full restore")
        #expect(writes.filter { (0xB0...0xB3).contains($0.request) }.count
                == full.filter { (0xB0...0xB3).contains($0.request) }.count)
        #expect(writes.last == HoldingUnit.Write(request: 0xDB, value: 0, index: 0, data: [SymphonyIOResetRequest.none.rawValue]))
        #expect(writes.filter { $0.request == 0xDB }.count == 1)
        #expect(unit.resetRequest == SymphonyIOResetRequest.none.rawValue)
        #expect(state.usbRestoreRuns == 3)
        // Cleared: the next restore writes nothing.
        unit.clearWrites()
        replug(state, unit)
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(unit.writes == [])
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
        await state.serviceHelperReconfigure(usb)
        #expect(state.usbRestoreOwed)
        state.serviceUSBRestore(usb)
        await state.usbRestoreServiceTask?.value
        #expect(unit.writes.suffix(2).map(\.data) == [[32, 64], [33, 65]])
        #expect(!state.usbRestoreOwed)
        #expect(state.usbRestoredHelperConfigures == 2)
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
        // Write-only and unreadable commands are always sent.
        #expect(XPCDeviceConnection.readCompareRequest(
            for: USBControlRequest(direction: .write, request: 0x50, data: Data([1, 1, 0, 0]))).map { _ in true } == nil)
    }
}
