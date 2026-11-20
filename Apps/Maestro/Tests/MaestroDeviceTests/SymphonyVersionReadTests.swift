import Foundation
import Testing
@testable import MaestroDevice
import MaestroCore

@Suite("ThunderBridge version reads")
struct SymphonyVersionReadTests {
    private func link(_ state: LinkState.State, suspended: Bool) -> LinkState {
        LinkState(state: state, clockPresent: true, ioRunning: true, irqCount: 0, recoveryCount: 0,
                  hwSuspended: suspended, linkConfigured: true, lastClockReg: 0, watchTicks: 0, audioWraps: 0)
    }

    /// Sleep (hardware access suspended) and recovery send no version read.
    @Test func onlyAnUpUnsuspendedLinkIsRead() {
        let up = ThunderboltDeviceConnection.versionReadAllowed(link: link(.up, suspended: false))
        let asleep = ThunderboltDeviceConnection.versionReadAllowed(link: link(.up, suspended: true))
        let recovering = ThunderboltDeviceConnection.versionReadAllowed(link: link(.recovering, suspended: false))
        let down = ThunderboltDeviceConnection.versionReadAllowed(link: link(.down, suspended: false))
        #expect(up)
        #expect(!asleep)
        #expect(!recovering)
        #expect(!down)
    }

    /// Without a driver nothing is sent and every component is unknown.
    @Test func noDriverNoRead() async {
        let conn = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                               audioDeviceID: 0, settingsStore: DeviceSettingsStore())
        let versions = await conn.readSymphonyVersions([.overall, .mainFPGA])
        #expect(versions.replies.isEmpty)
    }

    /// The wire request is the original's: 0xA0, the component as nValue, 3 bytes.
    @Test func wireRequestMatchesTheOriginal() {
        #expect(SymphonyIOCommand.symphonyIOVersion.rawValue == 0xA0)
        #expect(SymphonyVersionReply.byteCount == 3)
        #expect(SymphonyVersionComponent.secondaryFPGA.rawValue == 3)
    }
}
