import Foundation

/// Validation for the raw `0x30` TDM meter payload, and the software model used
/// for output meters when the hardware payload is proven not to contain any.
///
/// ## Why this exists (measured on hardware, 2026-09-10)
///
/// The XMOS EP0 vendor handler answers a device-to-host request from a local,
/// uninitialised stack buffer (`data_buffer[128]`,
/// `SymphonyIOVendorSpecifics.xc:15`). The Core3 fills only as many bytes as it
/// chose to return (`:109-113`), but `XUD_DoGetRequest` always ships the HOST's
/// `wLength` bytes (`:60`). Anything past what the Core3 supplied is whatever that
/// stack region last held.
///
/// On the dev unit every read command -- `0x26`, `0x36`, `0x54`, `0x31`, and
/// `0x30` for groups 1, 2 and even the invalid group 3 -- returns the identical
/// bytes at offsets 12-31, and bytes 32-39 are literally the request's own USB
/// setup packet: `C0 30 01 00 00 00 40 00` for a group-1 meter read. Group 0
/// (input) comes back as 64 bytes the Core3 did fill (all zero when silent, the
/// residue overwritten), so the transport itself is fine; the firmware simply
/// returns no output/mixer meter data over USB EP0.
///
/// A payload whose bytes 32-39 are the setup packet of the request that produced
/// it is therefore not meter data, and must never be drawn. The fingerprint is
/// eight exact bytes tied to the request, so a genuine payload cannot match it
/// by accident in practice (word 16 would have to read exactly 0x30C0, word 17
/// exactly the group number, word 18 exactly 0 and word 19 exactly 0x0040).
public enum TDMMeterPayload {

    /// Byte offset at which the XMOS stack residue carries the setup packet.
    public static let setupPacketOffset = 32

    /// Vendor request code for TDM meter data (`SymphonyIOCommands_TDMMeterData`).
    public static let meterRequest: UInt8 = 0x30

    /// `bmRequestType` of a vendor device-to-host request.
    public static let vendorReadRequestType: UInt8 = 0xC0

    /// True when bytes 32-39 of `data` are the USB setup packet of the `0x30`
    /// read that produced it: `{0xC0, 0x30, group, 0x00, wIndex=0, wLength}`.
    ///
    /// Returns false for payloads shorter than 40 bytes -- the fingerprint is
    /// simply not visible in a 32-byte mixer reply, so the caller must decide
    /// the mixer group's fate from the output group's verdict (both come from
    /// the same firmware path).
    public static func isSetupPacketEcho(_ data: Data,
                                         group: UInt8,
                                         requestLength: UInt16) -> Bool {
        let base = data.startIndex + setupPacketOffset
        guard data.count >= setupPacketOffset + 8 else { return false }
        let expected: [UInt8] = [
            vendorReadRequestType,
            meterRequest,
            group, 0x00,                                   // wValue, little-endian
            0x00, 0x00,                                    // wIndex
            UInt8(requestLength & 0xFF), UInt8(requestLength >> 8)  // wLength
        ]
        for (i, byte) in expected.enumerated() where data[base + i] != byte {
            return false
        }
        return true
    }

    /// True when every byte is zero. The firmware returns a zeroed buffer on
    /// the first read after a meter-routing change (`SymphonyIOMeterManager.cpp:204-207`),
    /// which means "no fresh data", not "silence".
    public static func isAllZero(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0 }
    }
}

/// Software model of the firmware's own output-meter taps.
///
/// The firmware meters an output by tapping the SOURCE currently routed to it
/// (`SymphonyIOAudioRouteManager.cpp:672-715`, via `m_acIOBoardOutputRouteMap`).
/// When the hardware payload is unusable we do the same thing in software: an
/// output's level is the level of whatever the app routed to it, and the only
/// sources whose level we can measure host-side are the USB playback channels
/// the proxy renders (it sees every sample it sends to the device) and, through
/// them, the mixer outputs the proxy feeds from USB 0/1.
///
/// This is exact for the proxy's default routing and for any user routing whose
/// sources are USB playback or the mixers' software return. It cannot see a
/// hardware input that the FPGA mixer folds into an output -- that reads as
/// silence here and is documented as such.
public enum SoftwareOutputMeterMap {

    /// Where a metered output's signal comes from.
    public enum Source: Equatable, Sendable {
        /// A USB playback channel (0-based) rendered by the proxy.
        case usbChannel(Int)
        /// A mixer output channel; only 0/1 (L/R) are measurable.
        case mixerOut(mixer: Int, channel: Int)
        /// A source we cannot measure host-side (hardware input, XLink, ...).
        case unknown
    }

    /// Routing-byte layout, identical to the firmware's FPGA route table
    /// (`SymphonyIOMainFPGA.h:13-24`) and `SymphonyIORoutingAddress`.
    public static let ioBoard0Base = 32
    public static let ioBoard1Base = 48
    public static let mixer0Base   = 64
    public static let mixer1Base   = 96
    public static let usbBase      = 192
    public static let usbChannels  = 16   // MAESTRO_SHM_CHANNELS

    /// Destination routing byte for a TDM output word. Words 0-15 are card
    /// slot 0 (`IOBoard0`, bytes 32-47) and 16-31 slot 1 (`IOBoard1`, 48-63):
    /// the two blocks are contiguous, so the byte is simply `32 + word`.
    public static func destinationByte(forWord word: Int) -> UInt8? {
        guard (0..<32).contains(word) else { return nil }
        return UInt8(ioBoard0Base + word)
    }

    /// Source feeding TDM output word `word`, given the app's cached output
    /// routing (`destinationByte -> sourceByte`).
    ///
    /// With no cached route for a destination the proxy's boot routing applies
    /// (`configure_fpga_routing`): `IOBoard0 ch n <- USB n` for n >= 2,
    /// `IOBoard0 ch 0/1 <- Mixer0 out <- USB 0/1`, and `IOBoard1 ch n <- USB n`.
    /// The proxy measures USB 0/1 after its software gain/pan/mute, i.e. at the
    /// level the mixer actually delivers to the DAC, so both collapse to
    /// `usbChannel(n % 16)`.
    public static func source(forWord word: Int, routes: [UInt8: UInt8]) -> Source {
        guard let dest = destinationByte(forWord: word) else { return .unknown }
        guard let src = routes[dest] else {
            return .usbChannel(word % usbChannels)
        }
        let s = Int(src)
        switch s {
        case usbBase ..< (usbBase + usbChannels):
            return .usbChannel(s - usbBase)
        case mixer0Base ..< mixer1Base:
            return .mixerOut(mixer: 0, channel: s - mixer0Base)
        case mixer1Base ..< (mixer1Base + 32):
            return .mixerOut(mixer: 1, channel: s - mixer1Base)
        default:
            return .unknown
        }
    }

    /// dBFS for a linear peak from the proxy's render callback, floored at -60.
    public static func dBFS(linearPeak: Float) -> Double {
        guard linearPeak > 0.00001 else { return -60.0 }
        return max(20.0 * log10(Double(linearPeak)), -60.0)
    }

    /// Level in dBFS for `source`, from the proxy's per-USB-channel peaks.
    /// Mixer outputs use the selected Software Return pair for that mixer;
    /// hardware-input contributions remain unmeasurable host-side.
    public static func level(
        for source: Source,
        usbPeaks: [Float],
        mixerSoftwareReturnSources: [Int] = [0, 0]
    ) -> Double {
        switch source {
        case .usbChannel(let ch):
            guard ch < usbPeaks.count else { return -60.0 }
            return dBFS(linearPeak: usbPeaks[ch])
        case .mixerOut(let mixer, let ch) where ch < 2:
            let pair = mixer >= 0 && mixer < mixerSoftwareReturnSources.count
                ? max(0, min(7, mixerSoftwareReturnSources[mixer]))
                : 0
            let usbChannel = pair * 2 + ch
            guard usbChannel < usbPeaks.count else { return -60.0 }
            return dBFS(linearPeak: usbPeaks[usbChannel])
        case .mixerOut, .unknown:
            return -60.0
        }
    }
}
