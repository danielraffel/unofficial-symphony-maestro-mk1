import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

private final class MixerRestoreTransport: XPCTransport, @unchecked Sendable {
    struct Capture {
        var writes: [(UInt8, UInt16, UInt16, Data)] = []
        var mutes: [(UInt8, UInt16, UInt16, UInt8)] = []
        var helperMutes: [Bool] = []
        var helperProcessing: [Bool] = []
    }
    private let lock = NSLock()
    private var captured = Capture()
    var snapshot: Capture { lock.withLock { captured } }
    var isConnected: Bool { true }
    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        lock.withLock { captured.writes.append((bRequest, wValue, wIndex, data)) }
    }
    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        throw DeviceConnectionError.transportError("identity unavailable")
    }
    func getSoftwareMeterLevels() async -> (Float, Float)? { nil }
    func setSwReturnMute(_ muted: Bool) { lock.withLock { captured.helperMutes.append(muted) } }
    func setSwReturnLevel(_ dB: Double) {}
    func setSwReturnProcessing(_ enabled: Bool) { lock.withLock { captured.helperProcessing.append(enabled) } }
    func resetAudioOutput() {}
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {
        lock.withLock { captured.mutes.append((usbCmd, mixer, channel, value)) }
    }
}

/// Writes of one complete USB mixer restore: every input strip of both
/// mixers (level, pan, mute, solo), then per mixer the Software Return
/// source, Master, return level, mute and solo.
@MainActor private func restoreWriteCount(_ state: AppState) -> Int {
    state.cardLayout.mixerChannels.filter { (0...31).contains($0.hardwareIndex) }.count * 8 + 10
}

/// The speaker mode (0x25) goes out with every restore, saved or Stereo; the
/// counts below are of the mixer writes.
private func mixerWrites(_ capture: MixerRestoreTransport.Capture) -> [(UInt8, UInt16, UInt16, Data)] {
    capture.writes.filter { $0.0 != 0x25 }
}

extension StandardDefaultsSuites {
@Suite("Mixer identity completion", .serialized)
@MainActor
struct MixerIdentityRestoreTests {
    @Test func cancelledViewStillDiscoversCards() async {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        let state = AppState()
        let connection = SimulatedDevice.symphonyIO32ch()
        connection.applyCardConfiguration(CardConfiguration(slot1: .analogADDA16, slot2: .analogADDA16))
        state.device = connection
        state.primaryBoardSource = .unknown
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await state.readCardTypes()
        }
        await operation.value
        #expect(state.primaryBoardSource == .detected)
    }

    @Test func discoveryFinishesWhenItsOwnFindingChangesTheConnectedUnit() async {
        // A Symphony that answered .silent earlier (switched off) now reports
        // probe 0: discovery's own connectedUnit change must not cancel it.
        let state = AppState()
        let connection = SimulatedDevice.symphonyIO32ch()
        connection.applyCardConfiguration(CardConfiguration(slot1: .analogADDA16, slot2: .analogADDA16))
        state.device = connection
        state.connectedUnit = .silent
        state.primaryBoardSource = .unknown
        await state.readCardTypes()
        let source = state.primaryBoardSource
        let unit = state.connectedUnit
        #expect(unit == nil)
        #expect(source == .detected)
    }

    @Test func failedAndDisconnectedKeepUnitScopeAndLoadedStrips() async throws {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        let state = AppState()
        state.connectionMode = .hardware
        state.device = SimulatedDevice.symphonyIO32ch()
        state.primaryBoardType = .optical
        state.primaryBoardSource = .detected
        state.secondaryBoardType = .analogAD16
        state.secondaryBoardSource = .detected
        state.unitAIdentity = 0xF170
        let store = state.channelStateStore
        let strip = MixerChannelState(level: -34, pan: 0.2, isMuted: true, isSoloed: false)
        store.save([strip], for: ChannelStateStore.mixerKey(0))
        defaults.set(store.scope, forKey: "\(ChannelStateStore.mixerKey(0)).\(state.cardLayout.savedStateScope!).migratedTo")
        let preferences = state.mixerPreferences
        defaults.set(store.scope, forKey: "mixerWideState.migratedTo")
        preferences.set(-28.0, forKey: "mixerMasterLevel_0")
        state.unitAIdentityState = .failed
        let failed = MixerEditorState(appState: state, selectedMixer: 0)
        #expect(failed.channels.first?.level == -34)
        #expect(failed.loadedChannelCount == 1)
        #expect(failed.loadedMaster)
        #expect(failed.masterLevel == -28)
        let edited = MixerChannelState(level: -39, pan: 0, isMuted: true, isSoloed: false)
        state.channelStateStore.save([edited], for: ChannelStateStore.mixerKey(0))
        let saved: [MixerChannelState]? = store.load(ChannelStateStore.mixerKey(0))
        #expect(saved?.first?.level == -39)
        state.connectionMode = .disconnected
        #expect(state.mixerPreferences.storageKey == preferences.storageKey)
        state.mixerPreferences.set(-30.0, forKey: "mixerMasterLevel_0")
        #expect(preferences.object(forKey: "mixerMasterLevel_0") as? Double == -30)
    }

    @Test func pendingRecoveryWritesNothingAndRetryDoesNotRestoreTwice() async throws {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        defaults.removeObject(forKey: "mixerWideState.migratedTo")
        let state = AppState()
        state.usbMixerStripSpacing = .zero
        state.connectionMode = .hardware
        let transport = MixerRestoreTransport()
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "fix17-pending"))
        let usb = XPCDeviceConnection(identifier: id, transport: transport)
        state.device = usb
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
        #expect(transport.snapshot.writes.isEmpty)
        #expect(transport.snapshot.mutes.isEmpty)
        await state.resolveUnitIdentity(for: .a, connection: usb) { nil }
        let count = restoreWriteCount(state)
        #expect(mixerWrites(transport.snapshot).count == count)
        #expect(transport.snapshot.mutes.isEmpty)
        state.retryFailedIdentityOnRecovery()
        await state.resolveUnitIdentity(for: .a, connection: usb) { nil }
        #expect(mixerWrites(transport.snapshot).count == count)
    }

    /// The reported gap: a recovery (unit power-cycled while connected) put
    /// back Master and Software Return only. Output routing came from the
    /// helper, which forced Line 1/2 through Mixer 1; now the helper programs
    /// the direct default and the saved routes must come from here.
    @Test func recoveryRestoresSavedOutputRoutingAndSetsTheHelperByIt() async throws {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        defaults.removeObject(forKey: "mixerWideState.migratedTo")
        for routed in [false, true] {
            let state = AppState()
            state.usbMixerStripSpacing = .zero
            state.connectionMode = .hardware
            state.transportType = .usb
            let transport = MixerRestoreTransport()
            let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
                productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "recovery-routing-\(routed)"))
            let usb = XPCDeviceConnection(identifier: id, transport: transport)
            state.device = usb
            state.primaryBoardType = .optical
            state.primaryBoardSource = .detected
            state.secondaryBoardType = .none
            state.secondaryBoardSource = .detected
            let identity = UInt64(0xF190_0000) + UInt64(routed ? 1 : 0)
            state.unitAIdentity = identity
            state.unitAIdentityState = .known(identity)
            let cache = state.peripheralRoutingCache(direction: "output")
            // 16-channel mode: 8 software pairs, so row 8 is Mixer 1. Column 0 is Line 1/2.
            if routed { cache.save([8: Set([0])]) }
            var muted = MixerChannelState(level: 0, pan: 0, isMuted: true, isSoloed: false)
            muted.isMuted = true
            MixerStateSnapshot.saveSoftwareReturn(muted, mixer: 0, preferences: state.mixerPreferences)
            #expect(state.mixersRoutedToOutput() == [routed, false])

            await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0)
            let result = transport.snapshot
            // Output routes are 0x31 writes of [destination, source]; Line 1/2 is 32/33, Mixer 1 out 64/65.
            let outputRoutes = result.writes.filter { $0.0 == 0x31 && ($0.3.first ?? 0) < 64 }.map { Array($0.3) }
            #expect(outputRoutes == (routed ? [[32, 64], [33, 65]] : []))
            // The mixer follows: strips, source, Master and return, on the unit.
            #expect(mixerWrites(result).filter { $0.0 != 0x31 || ($0.3.first ?? 0) >= 0xE0 }.count == restoreWriteCount(state))
            // ...and before the route: no mixer is routed until its strips are written.
            if routed {
                let firstRoute = result.writes.firstIndex { $0.0 == 0x31 && ($0.3.first ?? 0) < 64 } ?? -1
                let lastStrip = result.writes.lastIndex { (0xB0...0xB4).contains($0.0) } ?? Int.max
                #expect(lastStrip < firstRoute)
            }
            // Strip 32 of mixer 1 is muted on the unit either way...
            #expect(result.writes.last { $0.0 == 0xB3 && $0.1 == 1 && $0.2 == 32 }?.3 == Data([1]))
            // ...but the helper only mutes "Maestro USB" while that mixer feeds an output.
            #expect(result.helperMutes.last == routed)
            #expect(result.helperProcessing.last == routed)
            // No input strip is muted: nothing was saved muted.
            #expect(result.writes.filter { $0.0 == 0xB3 && $0.2 < 32 }.allSatisfy { $0.3 == Data([0]) })
        }
    }

    @Test func openingUnsavedMixerDoesNotQualifyDefaultsForReplay() {
        let defaults = UserDefaults.standard
        let owner = defaults.object(forKey: "mixerWideState.migratedTo")
        defaults.set("unit:v3:another-unit", forKey: "mixerWideState.migratedTo")
        defer { defaults.set(owner, forKey: "mixerWideState.migratedTo") }
        let state = AppState()
        state.connectionMode = .hardware
        state.device = SimulatedDevice.symphonyIO32ch()
        state.unitAIdentity = UInt64.random(in: 1...UInt64.max)
        let editor = MixerEditorState(appState: state, selectedMixer: 0)
        #expect(editor.loadedChannelCount == 0)
        #expect(!editor.loadedMaster)
        #expect(!editor.loadedReturn)
    }

    @Test(arguments: [0, 1], ["nil", "cancel", "callerCancel", "success"])
    func connectAndReconnect(staleMode: Int, outcome: String) async throws {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        defaults.removeObject(forKey: "mixerWideState.migratedTo")
        // A leftover of the removed Input Monitoring setting (0 was "DAW",
        // which muted all 64 input strips on connect). It must change nothing.
        defaults.set(staleMode, forKey: "routingMode")
        defaults.set(-12.0, forKey: "mixerMasterLevel_0")
        defaults.set(true, forKey: "mixerMasterFadersLinked")
        defaults.set(true, forKey: "mixerSWReturnFadersLinked")
        defaults.set(-17.0, forKey: "mixerSWReturnLeftLevel_0")
        let state = AppState()
        state.usbMixerStripSpacing = .zero
        state.connectionMode = .hardware
        state.transportType = .usb
        let identity: UInt64 = 0xF1501234
        let scoped = ChannelStateStore(layout: state.cardLayout, isSimulatingCards: false,
            identity: identity, allowLegacyMigration: false).mixerPreferences
        scoped.set(-24.0, forKey: "mixerMasterLevel_0")
        scoped.set(-29.0, forKey: "mixerSWReturnLeftLevel_0")
        scoped.set(staleMode, forKey: "routingMode")
        let legacyBefore = MixerPreferences.legacyKeys.map { defaults.object(forKey: $0) as? NSObject }
        let ownerBefore = defaults.object(forKey: "mixerWideState.migratedTo") as? NSObject
        for _ in 0..<2 { // initial connection, then a new connection to the same unit
            let transport = MixerRestoreTransport()
            let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
                productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "fix15-restore"))
            let usb = XPCDeviceConnection(identifier: id, transport: transport)
            state.device = usb
            let operation = Task {
                await state.resolveUnitIdentity(for: .a, connection: usb) {
                    if outcome == "cancel" {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return identity
                    }
                    return outcome == "success" ? identity : nil
                }
            }
            if outcome == "callerCancel" { operation.cancel() }
            await operation.value
            await state.resolveUnitIdentity(for: .a, connection: usb) {
                Issue.record("Discovery must not repeat on the same connection")
                return nil
            }
            let result = transport.snapshot
            #expect(mixerWrites(result).count == restoreWriteCount(state))
            // No speaker mode is saved: Stereo is sent, once.
            #expect(result.writes.filter { $0.0 == 0x25 }.map { $0.3 } == [Data([2])])
            // Every input strip of both mixers is written, and none is muted:
            // nothing was saved muted, and no setting forces a mute.
            let stripMutes = result.writes.filter { $0.0 == 0xB3 && $0.2 < 32 }
            #expect(stripMutes.count == (restoreWriteCount(state) - 10) / 4)
            #expect(stripMutes.allSatisfy { $0.3 == Data([0]) })
            #expect(result.mutes.isEmpty)
            // Default routing: no mixer feeds an output, so the helper is neutral.
            #expect(!result.helperMutes.isEmpty && result.helperMutes.allSatisfy { !$0 })
            #expect(!result.helperProcessing.isEmpty && result.helperProcessing.allSatisfy { !$0 })
            let master = result.writes.first { $0.0 == 0xB0 && $0.1 == 1 && $0.2 == 33 }?.3
            let softwareReturn = result.writes.first { $0.0 == 0xB0 && $0.1 == 1 && $0.2 == 32 }?.3
            #expect(master == Data([outcome == "success" ? 24 : 36]))
            #expect(softwareReturn == Data([outcome == "success" ? 19 : 31]))
            if outcome != "success" {
                let tbSnapshot = MixerStateSnapshot(channelCount: 32, mixer: 0,
                    store: state.channelStateStore, preferences: state.mixerPreferences)
                #expect(tbSnapshot.masterLevel == -12)
                // Unidentified unit: the legacy keys are read and written, as
                // before per-unit scoping, so the pages stay editable.
                #expect(state.mixerPreferences.isWritable)
                state.mixerPreferences.set(-3.0, forKey: "mixerMasterLevel_1")
                #expect(defaults.object(forKey: "mixerMasterLevel_1") as? Double == -3)
                defaults.removeObject(forKey: "mixerMasterLevel_1")
                #expect(defaults.object(forKey: "mixerWideState.migratedTo") as? NSObject == ownerBefore)
            }
        }
        let legacyAfter = MixerPreferences.legacyKeys.map { defaults.object(forKey: $0) as? NSObject }
        #expect(legacyBefore == legacyAfter)
    }
}
}
