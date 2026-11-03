/// MaestroPreset — complete snapshot of device-writeable settings.
///
/// Saved as an XML property list to `.mst2` files. The file name comes from
/// the legacy Maestro 2 document format (`.mst2` = Maestro Setup 2). Our format
/// is a flat plist rather than the legacy Core Data bundle, but uses the same
/// file extension for workflow familiarity.
///
/// Property selector mapping documented in:
///   `og_source/maestro2/App/Model/CoreAudioPropertyKeys.plist` (selector → name)
///   `og_source/maestro2/App/Model/audioObjectModelPropertyKeys.plist` (name → selector)
///
/// Evidence: `og_source/maestro2/App/APDocument.m` — storeMaestroPreferenceFile:
/// Evidence: `og_source/maestro2/App/Views/APMaestroFullViewWindow.m` lines 444-570

import Foundation

// MARK: - MaestroPreset

/// A complete snapshot of device settings that can be saved to and loaded from disk.
///
/// Fields use dB-domain values (negative = attenuation) to match AppState/view conventions.
/// Conversion to the wire format (UInt32 attenuation, 0=max volume) happens in
/// `AppState.applyPreset(_:)`.
public struct MaestroPreset: Codable, Sendable, Equatable {

    // MARK: - Metadata

    /// Format version for compatibility checking. Increment when adding required fields.
    public var version: Int = 1

    /// When the preset was captured (informational only; not applied on load).
    public var createdAt: Date = Date()

    // MARK: - Main Output / Monitor

    /// Main output level in dB (range −64..0). Maps to 'AEl3' (outputLevel).
    /// Wire format: UInt32 attenuation = UInt32(max(0, -outputLevel)).
    public var outputLevel: Double = -20

    /// Main output mute. Maps to 'AEm3' (outputMute).
    public var outputMuted: Bool = false

    /// Main output dim. Maps to 'AEm4' (outputDim).
    public var outputDimmed: Bool = false

    /// Main output sum to mono. Maps to 'AEm5' (outputSumToMono).
    public var outputSumToMono: Bool = false

    // MARK: - Headphone 1

    /// HP1 level in dB (range −64..0). Maps to 'AEl1' (headphone1Level).
    public var hp1Level: Double = -20

    /// HP1 mute. Maps to 'AEm1' (headphone1Mute).
    public var hp1Muted: Bool = false

    /// HP1 routing source ID. Maps to 'AEsB' (headphone1RoutingID).
    public var hp1RoutingID: UInt32 = 0

    // MARK: - Headphone 2

    /// HP2 level in dB (range −64..0). Maps to 'AEl2' (headphone2Level).
    public var hp2Level: Double = -20

    /// HP2 mute. Maps to 'AEm2' (headphone2Mute).
    public var hp2Muted: Bool = false

    /// HP2 routing source ID. Maps to 'AEsE' (headphone2RoutingID).
    public var hp2RoutingID: UInt32 = 0

    // MARK: - Input Channels

    /// Per-channel input settings (gain, phantom, phase, HPF, soft limit, type).
    /// Per-channel device reads are blocked on Symphony IO MKI (see P3G-31).
    /// Sourced from UserDefaults on save; written to UserDefaults on load.
    public var inputChannelStates: [InputChannelState] = []

    // MARK: - Output Channels

    /// Per-channel output settings (analog ref, digital ref, trim).
    /// Per-channel device reads are blocked on Symphony IO MKI (see P3G-31).
    /// Sourced from UserDefaults on save; written to UserDefaults on load.
    public var outputChannelStates: [OutputChannelState] = []

    // MARK: - Mixer Channel Names (P3F-39)

    /// User-assigned display names for each mixer channel strip.
    ///
    /// An empty string means "use default" (e.g., "Ch 1"). The array is indexed by
    /// zero-based channel position in the mixer view. Stored in UserDefaults on the
    /// app side; this field syncs them to/from `.mst2` preset files.
    ///
    /// Evidence: `og_source/maestro2/App/APDocument.m` — documents save all UI state.
    public var channelNames: [String] = []

    // MARK: - Device Settings (optical, S/PDIF, meters)

    /// Optical input format: 0=ADAT, 1=S/PDIF. Maps to 'AEoi' (opticalInFormat).
    public var opticalInFormat: UInt32 = 0

    /// S/PDIF replace assignment ID. Maps to 'AEs0' (spdifReplaceID).
    public var spdifReplaceID: UInt32 = 0

    /// S/PDIF mirror assignment ID. Maps to 'AEs7' (spdifMirrorID).
    public var spdifMirrorID: UInt32 = 0

    /// Peak hold mode. Maps to 'AEs6' (peakHoldMode).
    /// Wire values are `eSymphonyIOMeteringLEDPeakHold`
    /// (`SymphonyIOVendorSpecific.h:698-703`): 0=Off, 1=2 Seconds, 2=Infinite.
    /// The previous comment here read "1=hold, 2=2s", which had 1 and 2 swapped.
    public var peakHoldMode: UInt32 = 1

    /// Over hold mode. Maps to 'AEs5' (oversHoldMode).
    /// Wire values are `eSymphonyIOMeteringLEDOverHold`
    /// (`SymphonyIOVendorSpecific.h:706-712`): 0=Off, 1=2 Seconds, 2=Infinite,
    /// 3=Auto Clear -- one more mode than the peak enum carries.
    public var overHoldMode: UInt32 = 1

    /// Front panel meter bank 1 source. Maps to 'AEmi' element=1 (metersShowInput).
    public var meterBank1Source: UInt32 = 0

    /// Front panel meter bank 2 source. Maps to 'AEmi' element=2 (metersShowInput).
    public var meterBank2Source: UInt32 = 4

    public init() {}
}

// MARK: - File I/O

public extension MaestroPreset {

    /// Write this preset as an XML property list to a file.
    ///
    /// - Parameter url: Destination file path. Typical extension: `.mst2`.
    /// - Throws: `PropertyListEncoder` encoding errors or file I/O errors.
    func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Read a preset from an XML or binary property list file.
    ///
    /// - Parameter url: Source `.mst2` file path.
    /// - Returns: Decoded `MaestroPreset`.
    /// - Throws: `PropertyListDecoder` decoding errors or file I/O errors.
    static func load(from url: URL) throws -> MaestroPreset {
        let data = try Data(contentsOf: url)
        let decoder = PropertyListDecoder()
        return try decoder.decode(MaestroPreset.self, from: data)
    }
}
