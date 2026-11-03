import Testing
@testable import MaestroCore

// MARK: - DeviceDescriptor Tests

/// Tests derived from known values in:
/// - `og_source/maestro2/App/Resources/deviceDescriptions.plist`
/// - `og_source/maestro2/App/MaestroDefines.h`

@Suite("DeviceDescriptor")
struct DeviceDescriptorTests {

    // MARK: - Symphony IO USB identity

    @Test func symphonyIOUSBIdentity() {
        let d = DeviceDescriptor.symphonyIOUSB
        #expect(d.name == "Symphony IO")
        #expect(d.modelUID == "AppleUSBAudioDevice:Symphony I/O : USB Audio")
        #expect(d.imageName == "SymphonyIO")
        #expect(d.imageType == "png")
        #expect(d.aimImageName == "AIM_SymphonyIO_USB")
        #expect(d.hiddenInMaestro == false)
    }

    // MARK: - Tab capabilities

    @Test func symphonyIOUSBTabCapabilities() {
        let tabs = DeviceDescriptor.symphonyIOUSB.tabs
        #expect(tabs.input == true)
        #expect(tabs.output == true)
        #expect(tabs.deviceSettings == true)
        #expect(tabs.standaloneRouting == false)
        #expect(tabs.inputRouting == true)
        #expect(tabs.outputRouting == true)
        #expect(tabs.mixer == true)
        #expect(tabs.systemSetup == true)
    }

    // MARK: - Device settings segments

    @Test func symphonyIOUSBDeviceSettingsSegments() {
        let seg = DeviceDescriptor.symphonyIOUSB.deviceSettingsSegments
        #expect(seg.peripheralPrefix == true)
        #expect(seg.audioInterfaceMode == true)
        #expect(seg.meters == true)
        #expect(seg.opticalFormat == true)
        #expect(seg.uv22HR == false)
        #expect(seg.proToolsHD == false)
    }

    // MARK: - System setup segments

    @Test func symphonyIOUSBSystemSetupSegments() {
        let seg = DeviceDescriptor.symphonyIOUSB.systemSetupSegments
        #expect(seg.clocking == true)
        #expect(seg.meters == true)
        #expect(seg.keyboardVolumeControl == true)
        #expect(seg.symphonySystem == false)
    }

    // MARK: - Registry lookup

    @Test func registryFindsSymhonyIOUSBByModelUID() {
        let found = DeviceRegistry.descriptor(
            forModelUID: "AppleUSBAudioDevice:Symphony I/O : USB Audio"
        )
        #expect(found == .symphonyIOUSB)
    }

    @Test func registryReturnsNilForUnknownModelUID() {
        let found = DeviceRegistry.descriptor(forModelUID: "bogus:device")
        #expect(found == nil)
    }

    // MARK: - Static defaults

    @Test func tabCapabilitiesNoneIsAllFalse() {
        let none = TabCapabilities.none
        #expect(none.input == false)
        #expect(none.output == false)
        #expect(none.deviceSettings == false)
        #expect(none.standaloneRouting == false)
        #expect(none.inputRouting == false)
        #expect(none.outputRouting == false)
        #expect(none.mixer == false)
        #expect(none.systemSetup == false)
    }

    @Test func deviceSettingsSegmentsNoneIsAllFalse() {
        let none = DeviceSettingsSegments.none
        #expect(none.peripheralPrefix == false)
        #expect(none.audioInterfaceMode == false)
        #expect(none.meters == false)
        #expect(none.opticalFormat == false)
        #expect(none.uv22HR == false)
        #expect(none.proToolsHD == false)
    }

    @Test func systemSetupSegmentsNoneIsAllFalse() {
        let none = SystemSetupSegments.none
        #expect(none.clocking == false)
        #expect(none.meters == false)
        #expect(none.keyboardVolumeControl == false)
        #expect(none.symphonySystem == false)
    }

    // MARK: - Equatable / Hashable

    @Test func descriptorsAreEquatable() {
        let a = DeviceDescriptor.symphonyIOUSB
        let b = DeviceDescriptor.symphonyIOUSB
        #expect(a == b)
    }

    @Test func descriptorsAreHashable() {
        let set: Set<DeviceDescriptor> = [.symphonyIOUSB, .symphonyIOUSB]
        #expect(set.count == 1)
    }
}
