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

    @Test("the badge and status bar name the Symphony 64 PCIe card when the driver is on it")
    func shortNameNamesTheCard() {
        #expect(ConnectionLabel.shortName(transport: .thunderbolt, pciIdentifier: "pci19c2,2200") == "ThunderBridge")
        #expect(ConnectionLabel.shortName(transport: .thunderbolt, pciIdentifier: "pci19c2,2100") == "Symphony 64 PCIe")
        #expect(ConnectionLabel.shortName(transport: .thunderbolt, pciIdentifier: nil) == "ThunderBridge")
        #expect(ConnectionLabel.shortName(transport: .usb, pciIdentifier: "pci19c2,2100") == "USB")
        #expect(ConnectionLabel.shortName(transport: nil, pciIdentifier: nil) == "USB")
    }
}
