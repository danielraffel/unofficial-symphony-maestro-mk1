import CoreAudio
import Testing
@testable import MaestroCore
@testable import MaestroDevice

/// EXPERIMENT (64 channels, stage 2): the Core Audio side of the port selector.
/// No hardware: these use an object ID that is not a device, which is what
/// every device without the selector looks like to this code.
@Suite("PortSelectionProperty")
struct PortSelectionPropertyTests {
    private let noDevice = AudioDeviceID(kAudioObjectUnknown)

    @Test("the selector is the data source of the main element, output then input")
    func addresses() {
        #expect(PortSelectionProperty.scopes == [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput])
        for scope in PortSelectionProperty.scopes {
            let address = PortSelectionProperty.address(scope: scope)
            #expect(address.mSelector == kAudioDevicePropertyDataSource)
            #expect(address.mScope == scope)
            // Elements 1 and 2 on the output side are the optical-format selectors.
            #expect(address.mElement == kAudioObjectPropertyElementMain)
        }
    }

    @Test("a device without the selector reads as nil and refuses a write")
    func absent() {
        #expect(PortSelectionProperty.read(deviceID: noDevice) == nil)
        #expect(throws: DeviceConnectionError.self) {
            try PortSelectionProperty.write(deviceID: noDevice, selection: .ports1And2)
        }
        #expect(throws: DeviceConnectionError.self) {
            _ = try PortSelectionObservation(deviceID: noDevice)
        }
    }
}
