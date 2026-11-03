import Testing
@testable import MaestroCore

struct ConnectionPresentationTests {
    @Test func thunderBridgeCanRemainPresentWhileSymphonyIsOff() {
        let presentation = ConnectionPresentation(
            transportType: .thunderbolt,
            transportPresent: true,
            endpointState: .disconnected
        )

        #expect(presentation.transportLabel == "ThunderBridge Connected")
        #expect(presentation.endpointLabel == "Symphony Disconnected")
    }

    @Test func usbLossFallsBackToGenericDisconnectedTransportLabel() {
        let presentation = ConnectionPresentation(
            transportType: .usb,
            transportPresent: false,
            endpointState: .disconnected
        )

        #expect(presentation.transportLabel == "Disconnected")
        #expect(presentation.endpointLabel == "Symphony Disconnected")
    }

    @Test func pcieUsesTheThunderBridgeTransportPresentation() {
        let presentation = ConnectionPresentation(
            transportType: .thunderbolt,
            transportPresent: true,
            endpointState: .connected
        )

        #expect(presentation.transportLabel == "ThunderBridge Connected")
        #expect(presentation.endpointLabel == "Connected")
    }
}
