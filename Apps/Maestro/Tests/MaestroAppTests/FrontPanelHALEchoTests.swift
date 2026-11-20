import Foundation
import Testing
@testable import MaestroApp
import MaestroDevice
import MaestroCore

/// 0.9.10 final review, finding 1: a ThunderBridge/PCIe driver older than
/// build 132 does not consume the front panel's 0x28 report, so the app must
/// still push a front-panel speaker level and Mute All to the Mac's controls
/// (0.9.9 behaviour). Build 132 and newer must get no push.
@Suite("Front-panel HAL echo by serving driver build", .serialized)
@MainActor
struct FrontPanelHALEchoTests {
    func state(_ connection: EchoConnection, build: ServingDextBuild?) -> AppState {
        let state = AppState()
        state.device = connection
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.servingDextBuild = build
        state.frontPanelPushQuietInterval = .milliseconds(1)
        return state
    }

    /// Let the unstructured push tasks run.
    func settle(_ connection: EchoConnection, expecting count: Int) async {
        for _ in 0..<200 where connection.writes.count < count {
            try? await Task.sleep(for: .milliseconds(2))
        }
        // A little longer, so an unexpected extra write would show up too.
        try? await Task.sleep(for: .milliseconds(20))
    }

    nonisolated static let legacy: [ServingDextBuild] = [.build(131), .build(0), .olderThanBuildReporting]
    nonisolated static let current: [ServingDextBuild?] = [.build(132), .build(137), .build(138), nil]

    @Test(arguments: legacy)
    func olderDriverGetsSpeakerLevelAndMuteEcho(build: ServingDextBuild) async {
        let connection = EchoConnection()
        let state = state(connection, build: build)
        await state.applyFrontPanelChange(.level(.speaker, -40, settled: true))
        await state.applyFrontPanelChange(.muteAll(true))
        await settle(connection, expecting: 2)
        #expect(state.speakerLevel == -40)
        #expect(state.speakerMuted)
        let writes = connection.writes
        #expect(writes.contains { $0.selector == .outputMute && $0.value.asBool == true })
        #expect(writes.contains { $0.selector == .outputLevel && $0.value.asUInt32 == 40 })
        #expect(writes.count == 2)
    }

    @Test(arguments: current)
    func driver132AndNewerGetNoEcho(build: ServingDextBuild?) async {
        let connection = EchoConnection()
        let state = state(connection, build: build)
        await state.applyFrontPanelChange(.level(.speaker, -40, settled: true))
        await state.applyFrontPanelChange(.muteAll(true))
        await settle(connection, expecting: 0)
        #expect(state.speakerLevel == -40)
        #expect(state.speakerMuted)
        #expect(connection.writes.isEmpty)
    }

    @Test func driverHandoverDuringTheWaitCancelsTheLevelPush() async {
        let connection = EchoConnection()
        let state = state(connection, build: .build(131))
        state.frontPanelPushQuietInterval = .milliseconds(30)
        await state.applyFrontPanelChange(.level(.speaker, -40, settled: true))
        state.servingDextBuild = .build(138)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(connection.writes.isEmpty)
    }
}

final class EchoConnection: DeviceConnection, @unchecked Sendable {
    struct Write { let selector: AudioPropertySelector; let value: PropertyValue }
    let identifier = SimulatedDevice.symphonyIO32ch().identifier
    let isConnected = true
    let hardwareWriteGate: HardwareWriteGate? = HardwareWriteGate()
    private let lock = NSLock()
    private var recorded: [Write] = []
    var writes: [Write] { lock.withLock { recorded } }

    func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        throw DeviceConnectionError.unsupportedProperty(address.selector)
    }
    func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        try hardwareWriteGate?.check()
        lock.withLock { recorded.append(Write(selector: address.selector, value: value)) }
    }
    func hasProperty(_ address: PropertyAddress) async -> Bool { true }
    func isPropertySettable(_ address: PropertyAddress) async -> Bool { true }
    func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
    func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
    func disconnect() async {}
}
