import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

private final class MixerRestoreTransport: XPCTransport, @unchecked Sendable {
    struct Capture {
        var writes: [(UInt8, UInt16, UInt16, Data)] = []
        var modes: [Int] = []
        var mutes: [(UInt8, UInt16, UInt16, UInt8)] = []
    }
    private let lock = NSLock()
    private var captured = Capture()
    var sendDelay: UInt64 = 0
    var snapshot: Capture { lock.withLock { captured } }
    var isConnected: Bool { true }
    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        lock.withLock { captured.writes.append((bRequest, wValue, wIndex, data)) }
    }
    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        throw DeviceConnectionError.transportError("identity unavailable")
    }
    func getSoftwareMeterLevels() async -> (Float, Float)? { nil }
    func setSwReturnMute(_ muted: Bool) {}
    func setSwReturnLevel(_ dB: Double) {}
    func setSwReturnPan(_ pan: Double) {}
    func setSwReturnProcessing(_ enabled: Bool) {}
    func resetAudioOutput() {}
    func setRoutingMode(_ mode: Int) { lock.withLock { captured.modes.append(mode) } }
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {
        if sendDelay > 0 { Thread.sleep(forTimeInterval: Double(sendDelay) / 1_000_000_000) }
        lock.withLock { captured.mutes.append((usbCmd, mixer, channel, value)) }
    }
}

extension StandardDefaultsSuites {
@Suite("Mixer identity completion", .serialized)
@MainActor
struct MixerIdentityRestoreTests {
    @Test func routingModeRaceCancelsStaleDawMuteLoop() async throws {
        let state = AppState()
        state.connectionMode = .hardware
        let transport = MixerRestoreTransport()
        transport.sendDelay = 2_000_000
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "fix18-route-race"))
        let usb = XPCDeviceConnection(identifier: id, transport: transport)
        state.device = usb
        state.unitAIdentity = 42
        state.unitAIdentityState = .known(42)
        state.mixerPreferences.set(0, forKey: "routingMode")
        let first = Task { await state.synchronizeUSBRoutingMode(usb, generation: state.unitAGeneration,
                                                                  preferences: state.mixerPreferences) }
        try await Task.sleep(for: .milliseconds(3))
        state.mixerPreferences.set(1, forKey: "routingMode")
        let second = Task { await state.synchronizeUSBRoutingMode(usb, generation: state.unitAGeneration,
                                                                   preferences: state.mixerPreferences) }
        await first.value
        await second.value
        let result = transport.snapshot
        // The stale DAW sync may be cancelled before it sends anything ([1]) or
        // after its mode write ([0, 1]); either way Direct Monitor wins and no
        // DAW mute lands after it.
        let finalMode = result.modes.last
        #expect(finalMode == 1)
        #expect(result.modes == [1] || result.modes == [0, 1])
        #expect(result.mutes.last?.3 == 0)
    }

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

    @Test func pendingRecoveryDoesNotMuteDirectMonitorAndRetryDoesNotRestoreTwice() async throws {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        defaults.removeObject(forKey: "mixerWideState.migratedTo")
        defaults.set(1, forKey: "routingMode")
        let state = AppState()
        state.connectionMode = .hardware
        let transport = MixerRestoreTransport()
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "fix17-pending"))
        let usb = XPCDeviceConnection(identifier: id, transport: transport)
        state.device = usb
        await state.restoreUSBMixerAfterRecovery(usb, helperMixer: 0, restoreRoutingMode: true)
        #expect(transport.snapshot.writes.isEmpty)
        #expect(transport.snapshot.modes.isEmpty)
        #expect(transport.snapshot.mutes.isEmpty)
        await state.resolveUnitIdentity(for: .a, connection: usb) { nil }
        #expect(transport.snapshot.writes.count == 8)
        #expect(transport.snapshot.modes == [1])
        #expect(transport.snapshot.mutes.isEmpty)
        state.retryFailedIdentityOnRecovery()
        await state.resolveUnitIdentity(for: .a, connection: usb) { nil }
        #expect(transport.snapshot.writes.count == 8)
        #expect(transport.snapshot.modes == [1])
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
    func connectAndReconnect(mode: Int, outcome: String) async throws {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        defaults.removeObject(forKey: "mixerWideState.migratedTo")
        defaults.set(mode, forKey: "routingMode")
        defaults.set(-12.0, forKey: "mixerMasterLevel_0")
        defaults.set(true, forKey: "mixerMasterFadersLinked")
        defaults.set(true, forKey: "mixerSWReturnFadersLinked")
        defaults.set(-17.0, forKey: "mixerSWReturnLeftLevel_0")
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = .usb
        let identity: UInt64 = 0xF1501234
        let scoped = ChannelStateStore(layout: state.cardLayout, isSimulatingCards: false,
            identity: identity, allowLegacyMigration: false).mixerPreferences
        scoped.set(-24.0, forKey: "mixerMasterLevel_0")
        scoped.set(-29.0, forKey: "mixerSWReturnLeftLevel_0")
        scoped.set(mode, forKey: "routingMode")
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
            #expect(result.writes.count == 8)
            #expect(result.modes == [mode])
            #expect(result.mutes.count == (mode == 0 ? 64 : 0))
            #expect(result.mutes.allSatisfy { $0.0 == 0xB3 && $0.2 < 32 && $0.3 == 1 })
            let master = result.writes.first { $0.0 == 0xB0 && $0.1 == 1 && $0.2 == 33 }?.3
            let softwareReturn = result.writes.first { $0.0 == 0xB0 && $0.1 == 1 && $0.2 == 32 }?.3
            #expect(master == Data([outcome == "success" ? 24 : 36]))
            #expect(softwareReturn == Data([outcome == "success" ? 19 : 31]))
            if outcome != "success" {
                state.mixerPreferences.set(1 - mode, forKey: "routingMode")
                let tbSnapshot = MixerStateSnapshot(channelCount: 32, mixer: 0,
                    store: state.channelStateStore, preferences: state.mixerPreferences)
                #expect(tbSnapshot.masterLevel == -12)
                // Unidentified unit: the legacy keys are read and written, as
                // before per-unit scoping, so the pages stay editable.
                #expect(state.mixerPreferences.isWritable)
                let written = state.mixerPreferences.integer(forKey: "routingMode")
                #expect(written == 1 - mode)
                state.mixerPreferences.set(mode, forKey: "routingMode")
                #expect(defaults.object(forKey: "mixerWideState.migratedTo") as? NSObject == ownerBefore)
            }
        }
        let legacyAfter = MixerPreferences.legacyKeys.map { defaults.object(forKey: $0) as? NSObject }
        #expect(legacyBefore == legacyAfter)
    }
}
}
