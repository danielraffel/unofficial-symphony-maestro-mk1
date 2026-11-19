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
        lock.withLock { captured.mutes.append((usbCmd, mixer, channel, value)) }
    }
}

extension StandardDefaultsSuites {
@Suite("Mixer identity completion", .serialized)
@MainActor
struct MixerIdentityRestoreTests {
    @Test(arguments: [0, 1], ["nil", "cancel", "callerCancel", "success"])
    func connectAndReconnect(mode: Int, outcome: String) async throws {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
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
