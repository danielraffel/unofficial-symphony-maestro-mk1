/// Static registry of known Apogee device descriptors.
///
/// Entries are derived from `og_source/maestro2/App/Resources/deviceDescriptions.plist`.
/// Only devices relevant to the current build target are included.
/// Phase 3+ may add more devices; for now we focus on Symphony MKI USB.
public enum DeviceRegistry: Sendable {

    /// All known device descriptors.
    public static let all: [DeviceDescriptor] = [
        .symphonyIOUSB,
    ]

    /// Look up a descriptor by its CoreAudio model UID.
    public static func descriptor(forModelUID modelUID: String) -> DeviceDescriptor? {
        all.first { $0.modelUID == modelUID }
    }
}

// MARK: - Symphony MKI USB

/// Evidence: `og_source/maestro2/App/Resources/deviceDescriptions.plist` lines 510–564
/// Evidence: `og_source/generic/ApogeeUSBProductID.h` (VID 0x0C60, PIDs 16/17/18)
extension DeviceDescriptor {

    /// Symphony IO via USB — the primary target device for this rebuild.
    public static let symphonyIOUSB = DeviceDescriptor(
        name: "Symphony IO",
        modelUID: "AppleUSBAudioDevice:Symphony I/O : USB Audio",
        imageName: "SymphonyIO",
        imageType: "png",
        aimImageName: "AIM_SymphonyIO_USB",
        tabs: TabCapabilities(
            input: true,
            output: true,
            deviceSettings: true,
            standaloneRouting: false,
            inputRouting: true,
            outputRouting: true,
            mixer: true,
            systemSetup: true
        ),
        deviceSettingsSegments: DeviceSettingsSegments(
            peripheralPrefix: true,
            audioInterfaceMode: true,
            meters: true,
            opticalFormat: true,
            uv22HR: false,
            proToolsHD: false
        ),
        systemSetupSegments: SystemSetupSegments(
            clocking: true,
            meters: true,
            keyboardVolumeControl: true,
            symphonySystem: false
        )
    )
}
