/// Device capability descriptor.
///
/// Models the per-device feature flags from the legacy `deviceDescriptions.plist`.
/// Each Apogee product has a descriptor that defines which tabs and settings
/// segments the UI should expose.
///
/// Evidence: `og_source/maestro2/App/Resources/deviceDescriptions.plist`
/// Evidence: `og_source/maestro2/App/MaestroDefines.h` (TAB_ID_*, SEGMENT_ID_*)
public struct DeviceDescriptor: Sendable, Equatable, Hashable {

    // MARK: - Identity

    /// Human-readable device name (e.g. "Symphony IO").
    public let name: String

    /// CoreAudio model UID used to match running devices.
    /// Example: "AppleUSBAudioDevice:Symphony I/O : USB Audio"
    public let modelUID: String

    /// Asset image name stem (e.g. "SymphonyIO").
    public let imageName: String

    /// Image file extension (e.g. "png").
    public let imageType: String

    /// AIM module image name, empty if device has no AIM support.
    public let aimImageName: String

    // MARK: - Tab Capabilities

    /// Which top-level tabs this device supports.
    public let tabs: TabCapabilities

    // MARK: - Segment Capabilities

    /// Which Device Settings sub-sections this device supports.
    public let deviceSettingsSegments: DeviceSettingsSegments

    /// Which System Setup sub-sections this device supports.
    public let systemSetupSegments: SystemSetupSegments

    /// Whether this device should be hidden in the Maestro sidebar.
    public let hiddenInMaestro: Bool

    public init(
        name: String,
        modelUID: String,
        imageName: String,
        imageType: String = "png",
        aimImageName: String = "",
        tabs: TabCapabilities,
        deviceSettingsSegments: DeviceSettingsSegments = .none,
        systemSetupSegments: SystemSetupSegments = .none,
        hiddenInMaestro: Bool = false
    ) {
        self.name = name
        self.modelUID = modelUID
        self.imageName = imageName
        self.imageType = imageType
        self.aimImageName = aimImageName
        self.tabs = tabs
        self.deviceSettingsSegments = deviceSettingsSegments
        self.systemSetupSegments = systemSetupSegments
        self.hiddenInMaestro = hiddenInMaestro
    }
}

// MARK: - Tab Capabilities

/// Top-level tab visibility flags.
///
/// Maps to `TAB_ID_*` constants in `MaestroDefines.h` and
/// `hasInput`, `hasOutput`, etc. keys in `deviceDescriptions.plist`.
public struct TabCapabilities: Sendable, Equatable, Hashable {
    public let input: Bool
    public let output: Bool
    public let deviceSettings: Bool
    public let standaloneRouting: Bool
    public let inputRouting: Bool
    public let outputRouting: Bool
    public let mixer: Bool
    public let systemSetup: Bool

    public init(
        input: Bool = false,
        output: Bool = false,
        deviceSettings: Bool = false,
        standaloneRouting: Bool = false,
        inputRouting: Bool = false,
        outputRouting: Bool = false,
        mixer: Bool = false,
        systemSetup: Bool = false
    ) {
        self.input = input
        self.output = output
        self.deviceSettings = deviceSettings
        self.standaloneRouting = standaloneRouting
        self.inputRouting = inputRouting
        self.outputRouting = outputRouting
        self.mixer = mixer
        self.systemSetup = systemSetup
    }

    /// No tabs supported.
    public static let none = TabCapabilities()
}

// MARK: - Device Settings Segments

/// Device Settings tab sub-section visibility flags.
///
/// Maps to `SEGMENT_ID_DEVICE_SETTINGS_*` in `MaestroDefines.h` and
/// `DeviceSettingsSegments` dict in `deviceDescriptions.plist`.
public struct DeviceSettingsSegments: Sendable, Equatable, Hashable {
    public let peripheralPrefix: Bool
    public let audioInterfaceMode: Bool
    public let meters: Bool
    public let opticalFormat: Bool
    public let uv22HR: Bool
    public let proToolsHD: Bool

    public init(
        peripheralPrefix: Bool = false,
        audioInterfaceMode: Bool = false,
        meters: Bool = false,
        opticalFormat: Bool = false,
        uv22HR: Bool = false,
        proToolsHD: Bool = false
    ) {
        self.peripheralPrefix = peripheralPrefix
        self.audioInterfaceMode = audioInterfaceMode
        self.meters = meters
        self.opticalFormat = opticalFormat
        self.uv22HR = uv22HR
        self.proToolsHD = proToolsHD
    }

    /// No device settings segments supported.
    public static let none = DeviceSettingsSegments()
}

// MARK: - System Setup Segments

/// System Setup tab sub-section visibility flags.
///
/// Maps to `SEGMENT_ID_SYSTEM_SETUP_*` in `MaestroDefines.h` and
/// `SystemSetupSegments` dict in `deviceDescriptions.plist`.
public struct SystemSetupSegments: Sendable, Equatable, Hashable {
    public let clocking: Bool
    public let meters: Bool
    public let keyboardVolumeControl: Bool
    public let symphonySystem: Bool

    public init(
        clocking: Bool = false,
        meters: Bool = false,
        keyboardVolumeControl: Bool = false,
        symphonySystem: Bool = false
    ) {
        self.clocking = clocking
        self.meters = meters
        self.keyboardVolumeControl = keyboardVolumeControl
        self.symphonySystem = symphonySystem
    }

    /// No system setup segments supported.
    public static let none = SystemSetupSegments()
}

// MARK: - I/O Card Type

/// Option board type installed in a Symphony I/O expansion slot.
///
/// The Symphony IO MKI has 2 expansion slots. Each slot holds one option board
/// providing 16 channels (8 stereo pairs) of I/O. The board type determines the
/// analog/digital split of those channels, and the split is **direction-dependent**:
///
/// - **Optical** — Apogee "8x8 OPT": 4 analog + 4 ADAT pairs in both directions
/// - **AnalogAES** — Apogee "8x8 AES": 4 analog + 4 AES pairs in both directions
/// - **AnalogAD16** — Apogee "16 Analog In / 16 Digital Out": 8 analog INPUT pairs / 8 ADAT OUTPUT pairs
/// - **AnalogDA16** — Apogee "16 Digital In / 16 Analog Out": 8 ADAT INPUT pairs / 8 analog OUTPUT pairs
/// - **AnalogADDA16** — Apogee "16x16 Analog In/Out": 8 analog pairs in both directions, no digital
/// - **MicPre8** — Apogee "8MicPre": a DELEGATE module with no converters of its own
/// - **TwoBySix** — Apogee "2x6": 2 analog in, 6 analog out
///
/// Two different counts live on this type and they are not interchangeable:
/// `*PairsPerBoard` describes the fixed 16-channel XLink bus slice the ROUTING
/// matrix addresses for a slot (always 8 pairs for any installed board);
/// `analog*Channels` / `digital*Channels` describe what the module physically
/// contributes, which for an 8MicPre is nothing at all.
///
/// Evidence: `og_source/symphonymk1/ext/SymphonyIO/generic/Products/SymphonyIO/SymphonyIOVendorSpecific.h`
/// Lines 800-810: `SymphonyIOOptionBoardType` enum.
/// Read via USB vendor command 0xA1 (wIndex=0 primary slot, wIndex=1 secondary slot).
/// Evidence: `og_source/maestrolink/Software/ControlProtocol/SimpleControlProtocolUSB.cpp:56-57`
/// — nValue splitting: `wValue = nValue >> 16`, `wIndex = nValue & 0xFFFF`.
public enum IOCardType: UInt8, Sendable, Equatable, CaseIterable {
    case none        = 0
    case micPre8     = 1
    case analogAES   = 2
    case optical     = 3
    case analogAD16  = 4
    case analogDA16  = 5
    case analogADDA16 = 6
    case twoBySix    = 7

    /// Human-readable label for the digital I/O portion of this card.
    public var digitalLabel: String {
        switch self {
        case .none:         return "None"
        case .micPre8:      return "Mic Pre"
        case .analogAES:    return "AES"
        case .optical:      return "ADAT"
        case .analogAD16:   return "Analog In"
        case .analogDA16:   return "Analog Out"
        case .analogADDA16: return "Analog I/O"
        case .twoBySix:     return "2x6"
        }
    }

    /// Whether this card has analog I/O channels of its own.
    ///
    /// Derived from the converter counts rather than hand-listed: the hand-listed
    /// version said `.optical` had no analog (it has 8 in and 8 out) and that a
    /// `.twoBySix` had no digital.
    public var hasAnalog: Bool { analogInputChannels + analogOutputChannels > 0 }

    /// Whether this card has digital I/O channels (AES or ADAT) of its own.
    /// S/PDIF coax is a separate question — see ``hasSPDIFCoax``.
    public var hasDigital: Bool { digitalInputChannels + digitalOutputChannels > 0 }

    /// Whether the module carries the S/PDIF coax RCA pair.
    ///
    /// Every I/O module does — the 8x8, 16x16, A16 IP/OP and 2x6 module photos all
    /// show `SPDIF IN` / `OUT` RCA jacks (user guide pp. 10-12,
    /// `og_source/public_downloads/Symphony-IO-users-guide-july-2018.pdf`). The
    /// 8MicPre has only instrument jacks and insert DB-25s (p. 13).
    public var hasSPDIFCoax: Bool { self != .none && self != .micPre8 }

    /// Whether this module has optical (TOSLINK) ports whose format — ADAT/SMUX
    /// or S/PDIF — is selectable in Device Settings.
    ///
    /// `.analogAES` is included because an 8x8 **AES/OPT** combo module reports
    /// `.analogAES` when its `DIG I/O` switch is on AES (see
    /// ``mayBeAESOpticalCombo``) and still has the optical ports. The 16x16 and
    /// the 8MicPre have no optical hardware at all (user guide pp. 11, 13).
    public var hasOpticalPorts: Bool {
        switch self {
        case .none, .micPre8, .analogADDA16: return false
        case .analogAES, .optical, .analogAD16, .analogDA16, .twoBySix: return true
        }
    }

    /// Whether the selectable optical format is represented by the input
    /// property. Output-only optical cards such as AD16 use the output
    /// property instead.
    public var opticalFormatUsesInput: Bool { digitalInputChannels > 0 }

    /// Total routing stereo pairs per board (always 8 for installed cards, 0 for none).
    /// Evidence: SymphonyIORoutingController.h — cstSymphonyIORoutingController_SourcesPerBoard = 16 channels = 8 pairs
    public var totalPairsPerBoard: Int { self == .none ? 0 : 8 }

    /// Stereo pairs in a slot's XLink bus slice, card-independent.
    public static let busPairsPerBoard = 8
    /// Channels in a slot's XLink bus slice, card-independent.
    public static let busChannelsPerBoard = 16

    // MARK: - Input direction pair counts

    /// Analog (Line) INPUT stereo pairs per board.
    /// AD cards have all-analog inputs; DA cards have all-digital inputs.
    public var analogInputPairsPerBoard: Int {
        switch self {
        case .none: return 0
        case .optical: return 4       // 8 analog + 8 ADAT
        case .analogAES: return 4     // 8 analog + 8 AES
        case .analogDA16: return 0    // DA = digital-to-analog, input side is all digital
        default: return 8             // micPre8, analogAD16, analogADDA16, twoBySix
        }
    }

    /// Digital INPUT stereo pairs per board.
    public var digitalInputPairsPerBoard: Int {
        switch self {
        case .none: return 0
        case .optical: return 4       // 8 ADAT input channels
        case .analogAES: return 4     // 8 AES input channels
        case .analogDA16: return 8    // DA card: input side is all digital (ADAT)
        default: return 0
        }
    }

    // MARK: - Output direction pair counts

    /// Analog (Line) OUTPUT stereo pairs per board.
    /// DA cards have all-analog outputs; AD cards have all-digital outputs.
    public var analogOutputPairsPerBoard: Int {
        switch self {
        case .none: return 0
        case .optical: return 4       // 8 analog + 8 ADAT
        case .analogAES: return 4     // 8 analog + 8 AES
        case .analogAD16: return 0    // AD = analog-to-digital, output side is all digital
        default: return 8             // micPre8, analogDA16, analogADDA16, twoBySix
        }
    }

    /// Digital OUTPUT stereo pairs per board.
    public var digitalOutputPairsPerBoard: Int {
        switch self {
        case .none: return 0
        case .optical: return 4       // 8 ADAT output channels
        case .analogAES: return 4     // 8 AES output channels
        case .analogAD16: return 8    // AD card: output side is all digital (ADAT)
        default: return 0
        }
    }

    /// Label for digital channels in the routing matrix ("ADAT" or "AES").
    /// Different from `digitalLabel` which is the card's human name.
    public var digitalRoutingLabel: String {
        switch self {
        case .analogAES: return "AES"
        default: return "ADAT"
        }
    }

    /// Label of the n-th digital stereo pair (0-based) this module contributes,
    /// in the order the pairs sit inside the board's channel region.
    ///
    /// Every module has one digital plug type except the 2x6, whose digital
    /// channels are AES 1-2 followed by optical 1-8 on both the input and the
    /// output side (`SymphonyIOBoard_2x6.cpp:31-58`: AnalogIn(2), AESIn(2),
    /// OpticalIn(8); AnalogOut(6), AESOut(2), OpticalOut(8), each stream taking
    /// the next channels). For every other module this is `digitalRoutingLabel`.
    public func digitalLabel(forPair pair: Int) -> String {
        if self == .twoBySix { return pair == 0 ? "AES" : "ADAT" }
        return digitalRoutingLabel
    }

    /// Label of the n-th digital channel (0-based) this module contributes.
    public func digitalLabel(forChannel channel: Int) -> String {
        digitalLabel(forPair: channel / 2)
    }

    /// 1-based number of a digital channel within the channels that share its
    /// label (the 2x6's optical 1 is its digital channel 2).
    public func digitalChannelNumber(forChannel channel: Int) -> Int {
        if self == .twoBySix && channel >= 2 { return channel - 2 + 1 }
        return channel + 1
    }

    /// How many digital channels of this module carry `label`.
    public func digitalChannelCount(label: String, isInput: Bool) -> Int {
        let total = isInput ? digitalInputChannels : digitalOutputChannels
        return (0..<total).filter { digitalLabel(forChannel: $0) == label }.count
    }

    // MARK: - Product Naming

    /// The name Apogee prints on the module and uses in its documentation.
    ///
    /// This is what the user sees. The old labels ("16ch AD Optical") were
    /// ambiguous: there are THREE different 16-channel modules and three 8x8
    /// variants, so a channel count alone identifies nothing.
    ///
    /// Evidence: `og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/SymphonyIO/src/generic/ApogeeRegistrationConstants.h:45-71`
    /// gives Apogee's own product codes and descriptions per module:
    ///   A8MP "8 Mic Preamp", A8AE "8 Analog I/O + 8 AES I/O",
    ///   A8OP "8 Analog I/O + 8 Optical I/O", A8X8 "8 Analog I/O + 8 AES-Optical I/O",
    ///   AO16 "16 Analog IN + 16 Optical OUT", AI16 "16 Analog OUT + 16 Optical IN",
    ///   A16X16 "16 Analog IN + 16 Analog OUT", A2X6 "2x6 Analog I/O".
    public var productName: String {
        switch self {
        case .none:         return "None"
        case .micPre8:      return "8MicPre"
        case .analogAES:    return "8x8 AES"
        case .optical:      return "8x8 OPT"
        case .analogAD16:   return "16 Analog In / 16 Digital Out"
        case .analogDA16:   return "16 Digital In / 16 Analog Out"
        case .analogADDA16: return "16x16 Analog In/Out"
        case .twoBySix:     return "2x6"
        }
    }

    /// Short technical descriptor, shown alongside the product name where the
    /// UI has room. Derived from Apogee's own product descriptions.
    ///
    /// Evidence: `ApogeeRegistrationConstants.h:45-71` (descriptions) and
    /// `Bulldog/HAL/SymphonyIOHAL/Board/AnalogBoard/SymphonyIOAnalogBoard.cpp:9-23`
    /// (per-board converter chip counts, which fix the analog channel counts).
    public var technicalDescriptor: String {
        switch self {
        case .none:         return "No board installed"
        case .micPre8:      return "8 mic preamps — delegate module, no converters"
        case .analogAES:    return "8 analog I/O + 8 AES I/O + 2 S/PDIF"
        case .optical:      return "8 analog I/O + 8 ADAT optical I/O + 2 S/PDIF"
        case .analogAD16:   return "16 analog in + 16 optical out"
        case .analogDA16:   return "16 optical in + 16 analog out"
        case .analogADDA16: return "16 analog in + 16 analog out, no digital"
        case .twoBySix:     return "2 analog in + 6 analog out + AES + optical"
        }
    }

    /// Human-readable display name for the board type.
    ///
    /// Now the Apogee product name — the technical split is available separately
    /// as `technicalDescriptor`.
    public var displayName: String { productName }

    /// Product name plus technical descriptor, e.g.
    /// `"8x8 OPT (8 analog I/O + 8 ADAT optical I/O + 2 S/PDIF)"`.
    /// Used where the panel has room for both.
    public var detailedName: String {
        self == .none ? productName : "\(productName) (\(technicalDescriptor))"
    }

    // MARK: - The eighth module: 8x8 AES/OPT

    /// True for the two board values that an **8x8 AES/OPT** combo module can
    /// report, depending on its front-panel `OPT / AES / DIG I/O` switch.
    ///
    /// Apogee markets eight modules but the firmware enum has only seven values
    /// plus None. The missing one is the 8x8 AES/OPT combo, and it does not have
    /// its own enum value: the FPGA board-ID nibble only encodes `0x1 = AES` and
    /// `0x2 = Optical`
    /// (`Bulldog/HAL/SymphonyIOHAL/HWPeripheral/SymphonyIOMainFPGA/SymphonyIOMainFPGA.cpp:322-346`),
    /// so a combo module reports `.analogAES` or `.optical` according to the switch.
    ///
    /// Legacy resolved the ambiguity out of band, by the board's HARDWARE major
    /// version: `>= 6` means the module is the combo
    /// (`og_source/maestrolink/Software/SymphonyIOBoard_AnalogOptical.cpp:262-284`
    /// and `SymphonyIOBoard_AnalogAES.cpp:259-282`, both commented
    /// "The Analog-AES/Optical combo board when in optical/AES mode has HW rev 6
    /// or above"). Both then register the same product code, A8X8.
    public var mayBeAESOpticalCombo: Bool {
        self == .analogAES || self == .optical
    }

    /// Hardware major version at and above which an `.analogAES` / `.optical`
    /// board is actually the 8x8 AES/OPT combo module.
    ///
    /// Evidence: `SymphonyIOBoard_AnalogOptical.cpp:268-270`, `SymphonyIOBoard_AnalogAES.cpp:266-268`
    /// (`if(HWRev.m_cMajorVersion>=0x6) fIsAESAndOptical=true;`). The version comes
    /// from vendor opcode `0xA0` `SymphonyIOVersion` with
    /// `eSymphonyIOVersionType_PrimaryBoardHardware = 5` /
    /// `..._SecondaryBoardHardware = 6` (`SymphonyIOVendorSpecific.h:339`, `:792-801`).
    public static let aesOpticalComboHardwareMajorVersion: UInt8 = 6

    /// Product name refined by the board's hardware major version, when known.
    ///
    /// Pass the value read from `0xA0` for this slot. A combo module resolves to
    /// `"8x8 AES/OPT"`; anything else falls back to `productName`. Pass `nil` when
    /// the version has not been read — the plain product name is then used, which
    /// is the graceful degradation: for a combo module in optical mode we say
    /// "8x8 OPT", which is what the module is currently doing, rather than
    /// asserting a name we cannot support.
    public func productName(boardHardwareMajorVersion: UInt8?) -> String {
        guard mayBeAESOpticalCombo,
              let major = boardHardwareMajorVersion,
              major >= IOCardType.aesOpticalComboHardwareMajorVersion
        else { return productName }
        return "8x8 AES/OPT"
    }

    // MARK: - True Channel Contribution

    /// Analog INPUT channels this module physically contributes.
    ///
    /// NOT the same thing as `analogInputPairsPerBoard`, which describes the
    /// 16-channel XLink bus slice the routing matrix addresses. A MicPre8
    /// contributes **zero** channels of its own — it is a delegate that installs
    /// preamps in front of the *other* board's analog inputs
    /// (`og_source/maestrolink/Software/SymphonyIO.cpp:955-961` →
    /// `SymphonyIO_IOBoard.cpp:606-627`). Do not copy `SymphonyIO.cpp:975-978`,
    /// which adds 16 in/out for every non-None board including MicPre8; that is
    /// bus allocation, not channel count.
    ///
    /// Evidence for the analog counts:
    /// `Bulldog/HAL/SymphonyIOHAL/Board/AnalogBoard/SymphonyIOAnalogBoard.cpp:9-23`
    /// (converter chip counts) and `:74-78`
    /// (`inputs = DS1882 count`, `outputs = ES9018 count * 8`, 2x6 hard-coded to 6 out).
    public var analogInputChannels: Int {
        switch self {
        case .none:         return 0
        case .micPre8:      return 0   // delegate module — contributes no channels
        case .analogAES:    return 8   // AES_BOARD_NUMBER_OF_DS1882 = 8
        case .optical:      return 8   // same analog board as AES
        case .analogAD16:   return 16  // AD16_BOARD_NUMBER_OF_DS1882 = 16
        case .analogDA16:   return 0   // DA16_BOARD_NUMBER_OF_DS1882 = 0
        case .analogADDA16: return 16  // uses AD16 input chip count
        case .twoBySix:     return 2   // A2x6_BOARD_NUMBER_OF_DS1882 = 2
        }
    }

    /// Analog OUTPUT channels this module physically contributes.
    /// See `analogInputChannels` for evidence.
    public var analogOutputChannels: Int {
        switch self {
        case .none:         return 0
        case .micPre8:      return 0   // delegate module — contributes no channels
        case .analogAES:    return 8   // AES_BOARD_NUMBER_OF_ES9018 = 1 → 1 * 8
        case .optical:      return 8
        case .analogAD16:   return 0   // AD16_BOARD_NUMBER_OF_ES9018 = 0
        case .analogDA16:   return 16  // DA16_BOARD_NUMBER_OF_ES9018 = 2 → 2 * 8
        case .analogADDA16: return 16  // uses DA16 output chip count
        case .twoBySix:     return 6   // hard-coded at SymphonyIOAnalogBoard.cpp:54
        }
    }

    /// Digital INPUT channels this module contributes (AES / ADAT).
    ///
    /// The 2x6 is not enumerated in `og_source`, so its complement comes from
    /// Apogee's own spec instead: "2-channels of AES digital audio input via XLR
    /// … Up to 8-channels of digital audio input via Optical" (user guide p. 12,
    /// `og_source/public_downloads/Symphony-IO-users-guide-july-2018.pdf`). Ten
    /// is the ADAT-rate maximum; S/PDIF and SMUX optical formats carry fewer, and
    /// no read models the current optical format per board.
    public var digitalInputChannels: Int {
        switch self {
        case .analogAES, .optical: return 8
        case .analogDA16:          return 16
        case .twoBySix:            return 10  // 2 AES + 8 optical
        default:                   return 0
        }
    }

    /// Digital OUTPUT channels this module contributes (AES / ADAT).
    /// See `digitalInputChannels` on the 2x6.
    public var digitalOutputChannels: Int {
        switch self {
        case .analogAES, .optical: return 8
        case .analogAD16:          return 16
        case .twoBySix:            return 10  // 2 AES + 8 optical
        default:                   return 0
        }
    }

    /// Total input channels contributed by this module.
    public var totalInputChannels: Int { analogInputChannels + digitalInputChannels }

    /// Total output channels contributed by this module.
    public var totalOutputChannels: Int { analogOutputChannels + digitalOutputChannels }

    // MARK: - Pair counts for the UI
    //
    // These are the **only** pair counts a view may use. They are the converter
    // counts above, halved — not `*PairsPerBoard`, which is the fixed 16-channel
    // bus slice and reports 8 pairs for an 8MicPre that has no converters at all.
    // Every strip, column, popup entry and mixer channel the user sees is counted
    // through these; `CardLayout` is where that happens.

    /// Analog INPUT stereo pairs this module physically contributes.
    public var analogInputPairsForUI: Int { analogInputChannels / 2 }

    /// Analog OUTPUT stereo pairs this module physically contributes.
    public var analogOutputPairsForUI: Int { analogOutputChannels / 2 }

    /// Digital INPUT stereo pairs this module physically contributes.
    public var digitalInputPairsForUI: Int { digitalInputChannels / 2 }

    /// Digital OUTPUT stereo pairs this module physically contributes.
    public var digitalOutputPairsForUI: Int { digitalOutputChannels / 2 }

    /// True for a module that has no converters of its own and instead delegates
    /// onto another slot's analog inputs. Only the 8MicPre does this.
    public var isDelegateOnly: Bool { self == .micPre8 }

    /// True when this module supplies analog INPUTS that an 8MicPre could sit in
    /// front of — the precondition for a MicPre being usable at all.
    ///
    /// Apogee requires an **8x8 or 16x16** module, i.e. at least eight analog
    /// inputs for the eight preamps: "The Mic Preamp Module upgrades the
    /// functionality of any 8x8 or 16x16 module by adding mic preamps to the
    /// existing line inputs" (user guide p. 13) and "Mic Pre Modules must be
    /// installed in this slot when you have an 8x8 or 16x16 module in slot 1"
    /// (p. 9). That excludes the 2x6, whose two analog inputs cannot host eight
    /// preamps, as well as the DA16, which has none.
    ///
    /// Evidence: the MicPre installs as a delegate on the primary board's analog
    /// input stream (`SymphonyIO.cpp:955-961`), so the primary board must have
    /// analog inputs. The FPGA agrees: the PRIMARY slot's board-ID switch has no
    /// `0x5` (MicPre) case at all, while the secondary slot's does
    /// (`SymphonyIOMainFPGA.cpp:322-346` vs `:348-375`).
    public var canHostMicPreDelegate: Bool {
        !isDelegateOnly && analogInputChannels >= IOCardType.micPreChannelCount
    }

    /// Preamps on an 8MicPre module, and therefore the analog inputs a host
    /// module must have. Evidence: `SymphonyIOBoard_MicPre8ch.cpp:914-961`.
    public static let micPreChannelCount = 8

    // MARK: - Routing Byte Mapping

    /// The routing grid's hardware columns for a card pair.
    ///
    /// Delegates to ``CardLayout`` so the grid the user clicks and the byte the
    /// click writes can never disagree. `.none` in **both** slots is read as
    /// "not detected yet" and keeps the historical full-width fallback; `.none`
    /// in one slot alongside a real card is read as an empty slot and
    /// contributes no columns, because a click on a column for an absent board
    /// writes a real routing byte into an empty XLink region.
    private static func routingColumns(
        isInput: Bool,
        board1: IOCardType,
        board2: IOCardType,
        ioBoard0Base: UInt8,
        ioBoard1Base: UInt8
    ) -> [CardLayout.RoutingColumn] {
        CardLayout(slot1: board1, slot2: board2,
                   isKnown: !(board1 == .none && board2 == .none))
            .routingColumns(isInput: isInput,
                            ioBoard0Base: ioBoard0Base,
                            ioBoard1Base: ioBoard1Base)
    }

    /// Map a routing grid column index to the USB routing left-channel byte for the given direction.
    ///
    /// Column order: Board1 analog, Board2 analog, Board1 digital, Board2 digital.
    /// Returns the left-channel byte; right channel is always leftByte + 1.
    ///
    /// - Parameters:
    ///   - col: Column index in the routing grid (0-based).
    ///   - isInput: true for input direction, false for output direction.
    ///   - board1: Primary board type.
    ///   - board2: Secondary board type.
    ///   - ioBoard0Base: Routing byte base for board 0 (default 32).
    ///   - ioBoard1Base: Routing byte base for board 1 (default 48).
    /// - Returns: The left-channel routing byte, or nil if col is out of range.
    public static func columnToRoutingByte(
        col: Int,
        isInput: Bool,
        board1: IOCardType,
        board2: IOCardType,
        ioBoard0Base: UInt8 = 32,
        ioBoard1Base: UInt8 = 48
    ) -> UInt8? {
        let columns = routingColumns(isInput: isInput, board1: board1, board2: board2,
                                     ioBoard0Base: ioBoard0Base, ioBoard1Base: ioBoard1Base)
        guard col >= 0, col < columns.count else { return nil }
        return columns[col].routingByte
    }

    /// Reverse-map a USB routing source byte to a routing grid column index.
    ///
    /// - Parameters:
    ///   - byte: The routing source byte from USB (e.g. 32-63 for IOBoard channels).
    ///   - isInput: true for input direction, false for output direction.
    ///   - board1: Primary board type.
    ///   - board2: Secondary board type.
    /// - Returns: The column index, or nil if the byte doesn't map to a column
    ///   that exists on these cards.
    public static func routingByteToColumn(
        byte: UInt8,
        isInput: Bool,
        board1: IOCardType,
        board2: IOCardType,
        ioBoard0Base: UInt8 = 32,
        ioBoard1Base: UInt8 = 48
    ) -> Int? {
        // A right-channel byte belongs to its pair's column.
        let left = byte - (byte % 2)
        let columns = routingColumns(isInput: isInput, board1: board1, board2: board2,
                                     ioBoard0Base: ioBoard0Base, ioBoard1Base: ioBoard1Base)
        return columns.firstIndex { $0.routingByte == left }
    }
}

// MARK: - Board Detection Provenance

/// Where a reported option-board type actually came from.
///
/// The Device Info panel must not present a cached guess as a measurement.
/// Card detection is `0xA1`, issued as a `0xC0` vendor EP0 read, and that read
/// currently fails on USB (`kIOReturnNotResponding`; `MaestroVolumeProxy.c` has no
/// `0xA1` handler at all), so on a USB unit the value on screen has in practice
/// always come from `UserDefaults`, never from the hardware.
public enum BoardDetectionSource: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Read back from the hardware during this session.
    case detected
    /// Restored from the local cache; the live read did not succeed this session.
    case cached
    /// Neither a live read nor a cache — we genuinely do not know.
    case unknown
    /// Forced by the debug card-simulation harness; not hardware at all.
    case simulated

    /// Parenthetical shown after the product name.
    public var qualifier: String {
        switch self {
        case .detected:  return "detected"
        case .cached:    return "cached — not detected this session"
        case .unknown:   return "not detected"
        case .simulated: return "simulated — not real hardware"
        }
    }

    /// True when the value can be treated as a fact about the attached hardware.
    public var isTrustworthy: Bool { self == .detected }
}

/// One slot's board type together with how we came to believe it.
public struct BoardTypeReading: Sendable, Equatable, Hashable {
    public let card: IOCardType
    public let source: BoardDetectionSource

    public init(card: IOCardType, source: BoardDetectionSource) {
        self.card = card
        self.source = source
    }

    /// Nothing is known about this slot.
    public static let unknown = BoardTypeReading(card: .none, source: .unknown)

    /// A live read that came back with a board type.
    public static func detected(_ card: IOCardType) -> BoardTypeReading {
        BoardTypeReading(card: card, source: .detected)
    }

    /// A value restored from the cache because the live read failed.
    public static func cached(_ card: IOCardType) -> BoardTypeReading {
        BoardTypeReading(card: card, source: .cached)
    }

    /// Decide what a slot may honestly claim.
    ///
    /// - `live`: the value a `0xA1` read returned this session, or nil if the
    ///   read failed / was never attempted.
    /// - `cached`: the value restored from `UserDefaults`, or nil when no cache
    ///   entry exists at all. A cached `.none` is still a cached value, not an
    ///   unknown one.
    /// - `isSimulated`: the debug card-simulation harness is driving this slot.
    public static func resolve(
        live: IOCardType?,
        cached: IOCardType?,
        isSimulated: Bool = false
    ) -> BoardTypeReading {
        if isSimulated, let card = live ?? cached {
            return BoardTypeReading(card: card, source: .simulated)
        }
        if let live { return .detected(live) }
        if let cached { return .cached(cached) }
        return .unknown
    }

    /// The single string shown in Device Info and copied to the clipboard.
    ///
    /// The Apogee product name always leads; the provenance is a parenthetical.
    /// An unknown slot says so instead of naming a card.
    public var displayText: String {
        switch source {
        case .unknown:
            return "Unknown (\(source.qualifier))"
        case .detected, .cached, .simulated:
            return "\(card.productName) (\(source.qualifier))"
        }
    }

    /// `displayText` with the technical descriptor folded in, for wider layouts.
    public var detailedText: String {
        switch source {
        case .unknown:
            return "Unknown (\(source.qualifier))"
        case .detected, .cached, .simulated:
            return "\(card.detailedName) (\(source.qualifier))"
        }
    }
}

// MARK: - Card Configuration

/// A complete two-slot option-board configuration, with the real hardware
/// placement rules enforced.
///
/// Slot numbering here follows the user-facing panel: `slot1` is the primary
/// board (`0xA1` wIndex 0, "IOBoard 1"), `slot2` is the secondary board
/// (wIndex 1, "IOBoard 2").
public struct CardConfiguration: Sendable, Equatable, Hashable {
    public let slot1: IOCardType
    public let slot2: IOCardType

    public init(slot1: IOCardType, slot2: IOCardType) {
        self.slot1 = slot1
        self.slot2 = slot2
    }

    /// Why a configuration cannot exist in hardware.
    public enum ValidationError: Sendable, Equatable, Hashable, Error, CustomStringConvertible {
        /// An 8MicPre was placed in slot 1. The legacy daemon treats this as a
        /// hard init failure with a user alert
        /// (`og_source/maestrolink/Software/SymphonyIO.cpp:933-948`), and the FPGA
        /// primary-slot board-ID switch has no MicPre case at all
        /// (`SymphonyIOMainFPGA.cpp:322-346`) — only the secondary switch does (`:348-375`).
        case micPreInSlot1
        /// An 8MicPre in slot 2 with nothing in slot 1 to delegate onto.
        case micPreWithoutHostBoard
        /// An 8MicPre in slot 2 whose slot-1 companion cannot host its eight
        /// preamps — fewer than eight analog inputs (a DA16 has none; a 2x6 has
        /// two), which is why Apogee requires an 8x8 or 16x16 there
        /// (user guide pp. 9, 13).
        case micPreHostHasNoAnalogInputs(host: IOCardType)

        public var description: String {
            switch self {
            case .micPreInSlot1:
                return "An 8MicPre cannot go in slot 1 — it is a delegate module and must sit in slot 2."
            case .micPreWithoutHostBoard:
                return "An 8MicPre in slot 2 needs an analog-input board in slot 1 to delegate onto."
            case .micPreHostHasNoAnalogInputs(let host):
                return "An 8MicPre in slot 2 needs at least "
                    + "\(IOCardType.micPreChannelCount) analog inputs in slot 1; "
                    + "\(host.productName) has \(host.analogInputChannels)."
            }
        }
    }

    /// Throws when this pairing cannot exist in real hardware.
    public func validate() throws {
        if slot1 == .micPre8 { throw ValidationError.micPreInSlot1 }
        if slot2 == .micPre8 {
            if slot1 == .none { throw ValidationError.micPreWithoutHostBoard }
            guard slot1.canHostMicPreDelegate else {
                throw ValidationError.micPreHostHasNoAnalogInputs(host: slot1)
            }
        }
    }

    /// True when this pairing can exist in real hardware.
    public var isValid: Bool { (try? validate()) != nil }

    /// True when an 8MicPre's preamps are in the signal path.
    public var hasMicPre: Bool { slot2 == .micPre8 }

    /// The board whose analog inputs the 8MicPre delegates onto, if any.
    public var micPreHostCard: IOCardType? { hasMicPre ? slot1 : nil }

    /// Analog input channels across the whole device.
    /// An 8MicPre adds none — it replaces the front end of its host's inputs.
    public var analogInputChannels: Int {
        slot1.analogInputChannels + slot2.analogInputChannels
    }

    /// Analog output channels across the whole device.
    public var analogOutputChannels: Int {
        slot1.analogOutputChannels + slot2.analogOutputChannels
    }

    /// Digital input channels across the whole device.
    public var digitalInputChannels: Int {
        slot1.digitalInputChannels + slot2.digitalInputChannels
    }

    /// Digital output channels across the whole device.
    public var digitalOutputChannels: Int {
        slot1.digitalOutputChannels + slot2.digitalOutputChannels
    }

    /// Total input channels across the whole device.
    public var totalInputChannels: Int { analogInputChannels + digitalInputChannels }

    /// Total output channels across the whole device.
    public var totalOutputChannels: Int { analogOutputChannels + digitalOutputChannels }

    /// The number of channels that carry a mic preamp (0 when no 8MicPre).
    ///
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:914-961` — the delegate names
    /// channels 1-8 of the host board's analog input stream.
    public var micPreChannelCount: Int { hasMicPre ? min(8, slot1.analogInputChannels) : 0 }

    /// Channels that can take an instrument input — only the first four, because
    /// only four physical 1/4" jacks exist.
    /// Evidence: `cstNumInputsWithInstrument = 4` (`SymphonyIOBoard_MicPre8ch.cpp:26`, `:965-980`).
    public var instrumentChannelCount: Int { min(4, micPreChannelCount) }

    /// Meter payload slots: `0-15` belong to slot 1, `16-31` to slot 2, rigid and
    /// card-independent. Within a board's 16, analog comes first, then digital.
    /// Evidence: `Docs/issue-1-research.md` "Metering — slot map".
    public static let meterSlotsPerBoard = 16
    /// Total meter words in an I/O meter payload (`0x30`, `wLength` 64).
    public static let meterWordCount = 32

    // MARK: - Well-known configurations

    /// The dev unit: 8x8 OPT in slot 1, 16 Analog In / 16 Digital Out in slot 2.
    public static let devUnit = CardConfiguration(slot1: .optical, slot2: .analogAD16)

    /// The configuration from GitHub issue #1: 16x16 analog with an 8MicPre.
    public static let sixteenBySixteenPlusMicPre =
        CardConfiguration(slot1: .analogADDA16, slot2: .micPre8)
}

// MARK: - Device Info Report

/// The Device Info panel's content, as data.
///
/// Rendering it is a pure function of these fields, so the exact text the Copy
/// button puts on the clipboard is testable without hardware.
public struct DeviceInfoReport: Sendable, Equatable {
    public var deviceName: String
    public var connection: String
    public var firmwareVersion: String?
    public var fpgaVersion: String?
    public var hardwareID: String?
    public var xmosVersion: String?
    public var board1: BoardTypeReading
    public var board1Version: String?
    public var board2: BoardTypeReading
    public var board2Version: String?
    public var deviceModel: String?
    public var mode: String?
    public var channelCount: Int?

    public init(
        deviceName: String = "Symphony I/O",
        connection: String,
        firmwareVersion: String? = nil,
        fpgaVersion: String? = nil,
        hardwareID: String? = nil,
        xmosVersion: String? = nil,
        board1: BoardTypeReading = .unknown,
        board1Version: String? = nil,
        board2: BoardTypeReading = .unknown,
        board2Version: String? = nil,
        deviceModel: String? = nil,
        mode: String? = nil,
        channelCount: Int? = nil
    ) {
        self.deviceName = deviceName
        self.connection = connection
        self.firmwareVersion = firmwareVersion
        self.fpgaVersion = fpgaVersion
        self.hardwareID = hardwareID
        self.xmosVersion = xmosVersion
        self.board1 = board1
        self.board1Version = board1Version
        self.board2 = board2
        self.board2Version = board2Version
        self.deviceModel = deviceModel
        self.mode = mode
        self.channelCount = channelCount
    }

    /// Slot line text, e.g. `"8x8 OPT (detected), Version: v33"`.
    public static func boardLine(_ reading: BoardTypeReading, version: String?) -> String {
        guard let version, !version.isEmpty, reading.source != .unknown else {
            return reading.displayText
        }
        return "\(reading.displayText), Version: \(version)"
    }

    /// The exact text the Device Info Copy button places on the clipboard.
    public var clipboardText: String {
        var lines: [String] = []
        lines.append("Device Name: \(deviceName)")
        lines.append("Connection: \(connection)")
        if let firmwareVersion { lines.append("Firmware: \(firmwareVersion)") }
        if let fpgaVersion { lines.append("FPGA version: \(fpgaVersion)") }
        if let hardwareID { lines.append("Hardware ID: \(hardwareID)") }
        lines.append("IOBoard1: \(DeviceInfoReport.boardLine(board1, version: board1Version))")
        lines.append("IOBoard2: \(DeviceInfoReport.boardLine(board2, version: board2Version))")
        if let xmosVersion { lines.append("XMOS Version: \(xmosVersion)") }
        if let deviceModel { lines.append("Device Model: \(deviceModel)") }
        if let mode { lines.append("Mode: \(mode)") }
        if let channelCount { lines.append("Channel Count: \(channelCount)") }
        return lines.joined(separator: "\n")
    }

    /// True when either slot is showing something we did not actually measure.
    /// The panel uses this to raise a "not detected" notice.
    public var hasUnverifiedBoardTypes: Bool {
        !board1.source.isTrustworthy || !board2.source.isTrustworthy
    }
}

// MARK: - Card Simulation (debug only)

/// Debug-only forcing of the two option-board slots, so the app can be driven
/// and screenshotted with card configurations we do not physically own —
/// an 8MicPre above all, to check the mic-pre UI against the original Maestro
/// screenshots.
///
/// This is deliberately not reachable from any UI. It activates only when the
/// launch argument or the `UserDefaults` key below is present, and it is inert
/// otherwise. `MaestroDevice.SimulatedDevice` supplies the process-level
/// plumbing (`SimulatedDevice.simulationRequest()`).
public enum CardSimulation: Sendable {

    /// `UserDefaults` key / launch-argument name for slot 1.
    /// e.g. `MaestroApp -MaestroSimulatePrimaryBoard analogADDA16`
    public static let primaryKey = "MaestroSimulatePrimaryBoard"
    /// `UserDefaults` key / launch-argument name for slot 2.
    /// e.g. `MaestroApp -MaestroSimulateSecondaryBoard micPre8`
    public static let secondaryKey = "MaestroSimulateSecondaryBoard"

    /// `UserDefaults` key / launch-argument name that presets analog input levels,
    /// so a Mic / Instrument strip can be screenshotted without driving the popup.
    /// Comma-separated, one token per channel starting at channel 1; an empty
    /// token or `-` leaves that channel alone. An optional `@gain` suffix seeds
    /// the preamp gain in dB.
    /// e.g. `MaestroApp -MaestroSimulateAnalogLevels "mic@35,mic,inst@20,-,line"`
    public static let analogLevelsKey = "MaestroSimulateAnalogLevels"

    /// One preset analog level from `analogLevelsKey`.
    public struct AnalogLevelPreset: Sendable, Equatable {
        public let level: AnalogInputLevel
        /// Preamp gain in dB, or nil to leave the default.
        public let gain: Double?
        public init(level: AnalogInputLevel, gain: Double? = nil) {
            self.level = level
            self.gain = gain
        }
    }

    /// Parse one analog-level token, case-insensitively. Accepts the Swift case
    /// name, the display name, the raw wire value, and the usual shorthands
    /// (`mic`, `inst`, `line`, `+4`, `-10`, `var`).
    public static func parseAnalogLevel(_ token: String) -> AnalogInputLevel? {
        let needle = token.trimmingCharactersInSimpleWhitespace().lowercased()
        if needle.isEmpty { return nil }
        // Digits only: `UInt32("+4")` would otherwise parse as 4 (Instrument).
        if needle.allSatisfy(\.isNumber), let raw = UInt32(needle),
           let level = AnalogInputLevel(rawValue: raw) { return level }
        switch needle {
        case "mic", "microphone":                   return .mic
        case "inst", "instrument":                  return .instrument
        case "line", "+4", "+4dbu", "plus4dbu":     return .plus4dBu
        case "-10", "-10dbv", "minus10dbv":         return .minus10dBV
        case "var", "variable":                     return .variable
        default:                                    return nil
        }
    }

    /// Parse the whole `analogLevelsKey` value. Index i is channel i+1; `nil`
    /// entries mean "leave that channel alone". Unrecognised tokens are nil too,
    /// so a typo cannot silently set a level.
    public static func parseAnalogLevels(_ value: String) -> [AnalogLevelPreset?] {
        value.split(separator: ",", omittingEmptySubsequences: false).map { piece in
            let parts = piece.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            let levelToken = String(parts[0]).trimmingCharactersInSimpleWhitespace()
            guard levelToken != "-", let level = parseAnalogLevel(levelToken) else { return nil }
            var gain: Double? = nil
            if parts.count == 2 {
                gain = Double(String(parts[1]).trimmingCharactersInSimpleWhitespace())
            }
            return AnalogLevelPreset(level: level, gain: gain)
        }
    }

    /// Parse one slot token. Accepts the Swift case name (`"micPre8"`), the raw
    /// firmware value (`"1"`), or the Apogee product name (`"8MicPre"`),
    /// case-insensitively. Returns nil for anything unrecognised.
    public static func parseCard(_ token: String) -> IOCardType? {
        let trimmed = token.trimmingCharactersInSimpleWhitespace()
        if trimmed.isEmpty { return nil }
        if let raw = UInt8(trimmed), let card = IOCardType(rawValue: raw) { return card }
        let needle = trimmed.lowercased()
        for card in IOCardType.allCases {
            if card.caseName.lowercased() == needle { return card }
            if card.productName.lowercased() == needle { return card }
        }
        return nil
    }

    /// Resolve a simulation request from raw slot tokens.
    ///
    /// Returns `nil` when neither slot was requested — the normal, inert case.
    /// Throws when the requested pairing cannot exist in hardware, so a typo
    /// produces a loud failure rather than a screenshot of an impossible unit.
    public static func resolve(
        primaryToken: String?,
        secondaryToken: String?
    ) throws -> CardConfiguration? {
        guard primaryToken != nil || secondaryToken != nil else { return nil }
        let slot1 = primaryToken.flatMap(parseCard) ?? .none
        let slot2 = secondaryToken.flatMap(parseCard) ?? .none
        let config = CardConfiguration(slot1: slot1, slot2: slot2)
        try config.validate()
        return config
    }
}

extension IOCardType {
    /// Map the label the legacy daemon puts in its `AEt1` version XML
    /// (`"IOBoard1 Type"`) onto a board type, so the daemon path can still be
    /// rendered with the correct Apogee product name.
    ///
    /// These are the strings the old Maestro showed; they are also the labels this
    /// app used before the rename, so pre-existing cached strings resolve too.
    public static func fromLegacyLabel(_ label: String) -> IOCardType? {
        switch label.lowercased() {
        case "none", "":                                    return IOCardType.none
        case "8ch mic pre", "mic pre", "8 mic preamp":       return .micPre8
        case "8ch analog-aes", "8 analog i/o + 8 aes i/o":   return .analogAES
        case "8ch analog-optical",
             "8 analog i/o + 8 optical i/o":                 return .optical
        case "16ch ad optical", "16 analog in + 16 optical out": return .analogAD16
        case "16ch da optical", "16 analog out + 16 optical in": return .analogDA16
        case "16ch ad/da", "16 analog in + 16 analog out":   return .analogADDA16
        case "2x6", "2x6 analog i/o":                        return .twoBySix
        default:                                             return nil
        }
    }

    /// The Swift case name, used by the debug card-simulation token parser.
    public var caseName: String {
        switch self {
        case .none:         return "none"
        case .micPre8:      return "micPre8"
        case .analogAES:    return "analogAES"
        case .optical:      return "optical"
        case .analogAD16:   return "analogAD16"
        case .analogDA16:   return "analogDA16"
        case .analogADDA16: return "analogADDA16"
        case .twoBySix:     return "twoBySix"
        }
    }
}

extension String {
    /// Foundation-free whitespace trim — `MaestroCore` imports no system frameworks.
    func trimmingCharactersInSimpleWhitespace() -> String {
        var chars = Array(self)
        let isWS: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        while let f = chars.first, isWS(f) { chars.removeFirst() }
        while let l = chars.last, isWS(l) { chars.removeLast() }
        return String(chars)
    }
}

// MARK: - Software Info Report

/// The Software Info panel's content, as data.
///
/// Device Info answers "what hardware am I talking to". This answers "what code is
/// doing the talking" — which is the half a bug report needs and the half that was
/// previously only discoverable by reading the About box and running
/// `systemextensionsctl list` in a terminal.
///
/// Like `DeviceInfoReport`, rendering is a pure function of these fields so the exact
/// clipboard text is testable without hardware.
public struct SoftwareInfoReport: Sendable, Equatable {
    /// Marketing version, e.g. `0.8.4`.
    public var appVersion: String
    /// Commit count at build time. Zero in a `swift run` build, where it is omitted.
    public var buildNumber: Int
    /// Short commit hash at build time. Empty in a `swift run` build.
    public var gitHash: String
    /// Where the running bundle actually lives. Catches the "I updated it but I'm
    /// launching an old copy" case, which looks identical to "the fix didn't work".
    public var appPath: String
    /// `ProcessInfo.operatingSystemVersionString`, trimmed of its "Version " prefix.
    public var osVersion: String
    /// Which transport is carrying audio right now, in words.
    public var audioPath: String
    /// The enabled driver extension's version, e.g. `0.10.0 (54)`. Nil when none is
    /// registered — the normal state for a USB-only user, who never needs one.
    public var installedDextVersion: String?
    /// How many copies of the dext `sysextd` has registered. More than one means an
    /// upgrade is half-applied: the outgoing version cannot exit until it releases the
    /// PCI device.
    public var registeredDextCount: Int
    /// CFBundleVersion of the dext inside this app bundle — what a relaunch would
    /// activate. Nil when the app carries no dext.
    public var bundledDextBuild: String?
    /// CFBundleVersion of the registered dext, for comparison against
    /// `bundledDextBuild`. Kept separate from `installedDextVersion` because only the
    /// build number decides anything: `sysextd` compares CFBundleVersion and nothing
    /// else when deciding whether an activation is an upgrade.
    public var installedDextBuild: String?
    /// True when the query to `sysextd` failed outright. "We could not ask" is a
    /// different claim from "nothing is installed", and the panel must not turn the
    /// first into the second.
    public var dextLookupFailed: Bool
    /// Whether the selected registered copy is enabled by macOS.
    public var dextEnabled: Bool
    /// Whether macOS is waiting for the user to approve the selected copy.
    public var dextAwaitingApproval: Bool
    /// Whether macOS has deferred activation until the next restart.
    public var dextAwaitingReboot: Bool
    /// True when IOKit currently exposes a ThunderBridge PCI device.
    public var thunderBridgePresent: Bool
    /// Raw IOKit PCI personality, e.g. `pci19c2,2200` or `pci19c2,2100`.
    public var pciDeviceIdentifier: String?

    public init(
        appVersion: String,
        buildNumber: Int = 0,
        gitHash: String = "",
        appPath: String,
        osVersion: String,
        audioPath: String,
        installedDextVersion: String? = nil,
        registeredDextCount: Int = 0,
        bundledDextBuild: String? = nil,
        installedDextBuild: String? = nil,
        dextLookupFailed: Bool = false,
        dextEnabled: Bool = false,
        dextAwaitingApproval: Bool = false,
        dextAwaitingReboot: Bool = false,
        thunderBridgePresent: Bool = false,
        pciDeviceIdentifier: String? = nil
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.gitHash = gitHash
        self.appPath = appPath
        self.osVersion = osVersion
        self.audioPath = audioPath
        self.installedDextVersion = installedDextVersion
        self.registeredDextCount = registeredDextCount
        self.bundledDextBuild = bundledDextBuild
        self.installedDextBuild = installedDextBuild
        self.dextLookupFailed = dextLookupFailed
        self.dextEnabled = dextEnabled
        self.dextAwaitingApproval = dextAwaitingApproval
        self.dextAwaitingReboot = dextAwaitingReboot
        self.thunderBridgePresent = thunderBridgePresent
        self.pciDeviceIdentifier = pciDeviceIdentifier
    }

    /// The version line, e.g. `0.8.4 (build 585 · 483d8e7)`.
    public var versionLine: String {
        guard buildNumber > 0 else { return appVersion }
        let suffix = gitHash.isEmpty ? "build \(buildNumber)" : "build \(buildNumber) · \(gitHash)"
        return "\(appVersion) (\(suffix))"
    }

    /// What to show for the driver extension row.
    public var dextLine: String {
        if dextLookupFailed { return "Unknown — could not query the system" }
        guard let installedDextVersion else { return "Not installed" }
        if dextCleanupPending {
            return "\(installedDextVersion) — active; older copy finishing cleanup"
        }
        guard registeredDextCount > 1 else { return installedDextVersion }
        return "\(installedDextVersion) — \(registeredDextCount) versions registered"
    }

    /// Concise status for Settings. Hardware presence is deliberately part of the
    /// status so USB-only users are not told to install a driver they do not need.
    public var dextStatusLine: String {
        if dextLookupFailed { return "Status unavailable — could not query macOS" }
        guard bundledDextBuild != nil else { return "Not included — reinstall Maestro" }
        guard let installedDextVersion else {
            return thunderBridgePresent
                ? "Not registered — install or approve the driver"
                : "Ready — no ThunderBridge connected"
        }
        if dextAwaitingReboot { return "Installed — restart required" }
        if dextAwaitingApproval { return "Installed — approval required" }
        if dextUpgradePending { return "Upgrade pending — \(installedDextVersion)" }
        if dextCleanupPending { return "Enabled — \(installedDextVersion) (cleanup finishing)" }
        if !dextEnabled { return "Installed — disabled" }
        return "Enabled — \(installedDextVersion)"
    }

    /// Whether an explicit activation/approval action is useful now.
    public var dextNeedsAction: Bool {
        guard thunderBridgePresent, !dextLookupFailed, bundledDextBuild != nil else { return false }
        // More than one registered copy means sysextd is in the middle of an
        // upgrade. The enabled incoming copy can look healthy while the old
        // copy still owns the card, so this remains actionable until the
        // reconnect completes the swap.
        return dextUpgradePending
            || installedDextVersion == nil
            || !dextEnabled
            || bundledDextBuild != installedDextBuild
    }

    /// Whether the persistent in-app recovery banner is allowed to be shown.
    ///
    /// Keep this separate from `dextNeedsAction`: the banner is a hardware-context
    /// affordance, not a generic driver-status warning. A USB-only user must never
    /// see it, and a failed status lookup must not be presented as an install prompt.
    /// The persistent fallback is intentionally limited to missing, approval,
    /// disabled, and upgrade states. Restart-required is delivered through the
    /// dedicated activation alert/status row instead of adding another persistent
    /// banner the user cannot resolve without rebooting.
    public var shouldShowThunderBridgeBanner: Bool {
        thunderBridgePresent
            && !dextLookupFailed
            && dextNeedsAction
            && !dextAwaitingReboot
    }

    /// A registered extension that is not the build carried by this app needs
    /// the hardware to be released before sysextd can complete the swap. Do
    /// not submit another activation request in this state: macOS can return
    /// OSSystemExtensionErrorDomain code 4 even though the active extension is
    /// enabled and healthy.
    public var dextUpgradePending: Bool {
        if registeredDextCount > 1 && !dextCleanupPending { return true }
        guard let bundledDextBuild, let installedDextBuild else { return false }
        return bundledDextBuild != installedDextBuild
    }

    /// The bundled build is already active and enabled; an older registered
    /// copy is only finishing sysextd cleanup and no longer blocks audio.
    public var dextCleanupPending: Bool {
        registeredDextCount > 1
            && dextEnabled
            && bundledDextBuild != nil
            && bundledDextBuild == installedDextBuild
    }

    /// One honest line about the driver extension, or nil when there is nothing to say.
    ///
    /// Two situations are worth naming, because both leave the user running code they
    /// did not think they were running, and both are fixed the same way:
    ///
    /// * more than one version registered — an upgrade that could not finish, because
    ///   the outgoing dext still holds the PCI device;
    /// * the app carrying a different build than the one registered — the next launch
    ///   will try to swap it, and until the card is released it cannot.
    public var dextNotice: String? {
        if dextLookupFailed { return nil }
        // A USB-only user does not need the ThunderBridge extension activated. Do not
        // instruct them to replug a Thunderbolt cable when the PCI card is absent.
        guard thunderBridgePresent else { return nil }
        if registeredDextCount > 1 && !dextCleanupPending {
            return "More than one version of the driver extension is registered. "
                + "An upgrade cannot finish while the old one still holds the card — "
                + "disconnect and reconnect the ThunderBridge."
        }
        if let bundledDextBuild, let installedDextBuild, bundledDextBuild != installedDextBuild {
            return "This app carries driver extension build \(bundledDextBuild) but "
                + "build \(installedDextBuild) is what is registered. Unplug the "
                + "ThunderBridge and reconnect it to let the swap finish."
        }
        return nil
    }

    /// The exact text the Software Info Copy button places on the clipboard.
    public var clipboardText: String {
        var lines: [String] = []
        lines.append("Maestro: \(versionLine)")
        lines.append("macOS: \(osVersion)")
        lines.append("App path: \(appPath)")
        lines.append("Audio path: \(audioPath)")
        if let pciDeviceIdentifier { lines.append("PCI device: \(pciDeviceIdentifier)") }
        lines.append("Driver extension: \(dextLine)")
        if let bundledDextBuild { lines.append("Bundled driver extension: build \(bundledDextBuild)") }
        return lines.joined(separator: "\n")
    }
}
