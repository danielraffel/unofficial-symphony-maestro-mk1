/// USB device identification for Apogee audio interfaces.
///
/// Defines vendor ID, product IDs, and USB mode mappings for
/// Symphony IO MKI hardware. Used by device discovery and
/// IOUSBHost connection code.
///
/// Evidence: `og_source/generic/ApogeeUSBProductID.h`
/// - VID 0x0C60 (Apogee Electronics Corporation)
/// - PIDs 0x10, 0x11, 0x12 (Symphony IO USB modes)

import MaestroCore

// MARK: - USB Vendor & Product IDs

/// Apogee USB vendor and product identifiers.
///
/// Evidence: `og_source/generic/ApogeeUSBProductID.h` lines 7–30
public enum ApogeeUSB: Sendable {
    /// Apogee Electronics USB Vendor ID.
    public static let vendorID: UInt16 = 0x0C60

    /// Symphony IO MKI USB product IDs by channel mode.
    public enum SymphonyIO: Sendable {
        /// 16-channel mode (44.1–96 kHz). PID 0x10.
        public static let pid16ch: UInt16 = 0x0010
        /// 8-channel mode (44.1–192 kHz). PID 0x11.
        public static let pid8ch: UInt16 = 0x0011
        /// 32-channel mode (44.1–48 kHz). PID 0x12.
        public static let pid32ch: UInt16 = 0x0012

        /// All known Symphony IO MKI product IDs.
        public static let allProductIDs: Set<UInt16> = [pid16ch, pid8ch, pid32ch]
    }

    /// Symphony IO MKI bootloader/DFU product IDs.
    ///
    /// Evidence: `og_source/generic/ApogeeUSBProductID.h` lines 32–37
    public enum SymphonyIOBootloader: Sendable {
        /// DFU mode PID.
        public static let pidDFU: UInt16 = 0x0013
        /// Bootloader mode PID.
        public static let pidBootloader: UInt16 = 0x0014
    }
}

// MARK: - USB Mode

/// The USB operating mode of a Symphony IO MKI, determined by product ID.
///
/// Each mode trades channel count for maximum sample rate.
/// The device presents as a different USB product ID for each mode.
///
/// Evidence: `og_source/generic/ApogeeUSBProductID.h`
public enum USBMode: Sendable, Equatable, Hashable {
    /// 32 channels at 44.1/48 kHz (PID 0x12).
    case channels32
    /// 16 channels at 44.1–96 kHz (PID 0x10).
    case channels16
    /// 8 channels at 44.1–192 kHz (PID 0x11).
    case channels8

    /// Initialize from a USB product ID, or nil if not a Symphony IO MKI.
    public init?(productID: UInt16) {
        switch productID {
        case ApogeeUSB.SymphonyIO.pid32ch: self = .channels32
        case ApogeeUSB.SymphonyIO.pid16ch: self = .channels16
        case ApogeeUSB.SymphonyIO.pid8ch:  self = .channels8
        default: return nil
        }
    }

    /// The USB product ID for this mode.
    public var productID: UInt16 {
        switch self {
        case .channels32: return ApogeeUSB.SymphonyIO.pid32ch
        case .channels16: return ApogeeUSB.SymphonyIO.pid16ch
        case .channels8:  return ApogeeUSB.SymphonyIO.pid8ch
        }
    }

    /// Maximum number of audio channels in this mode.
    public var channelCount: Int {
        switch self {
        case .channels32: return 32
        case .channels16: return 16
        case .channels8:  return 8
        }
    }

    /// Available sample rates for this USB mode.
    ///
    /// Evidence: cross-references `SampleRateAvailability` in MaestroCore.
    public var availableSampleRates: [SampleRate] {
        switch self {
        case .channels32: return SampleRateAvailability.mode32ch
        case .channels16: return SampleRateAvailability.mode16ch
        case .channels8:  return SampleRateAvailability.mode8ch
        }
    }

    /// Human-readable description.
    public var displayName: String {
        switch self {
        case .channels32: return "32-Channel (44.1/48 kHz)"
        case .channels16: return "16-Channel (up to 96 kHz)"
        case .channels8:  return "8-Channel (up to 192 kHz)"
        }
    }
}

// MARK: - Device Identification

/// Identifies a connected Apogee USB device.
///
/// Created during device discovery and used to establish connections.
public struct USBDeviceIdentifier: Sendable, Equatable, Hashable {
    /// USB vendor ID.
    public let vendorID: UInt16
    /// USB product ID.
    public let productID: UInt16
    /// The USB mode (channel/rate trade-off), derived from product ID.
    public let mode: USBMode
    /// Unique device identifier (e.g., USB location ID or serial number).
    public let deviceUID: String

    /// Create an identifier for a Symphony IO MKI.
    ///
    /// Returns nil if the product ID doesn't match a known Symphony IO mode.
    public init?(vendorID: UInt16, productID: UInt16, deviceUID: String) {
        guard vendorID == ApogeeUSB.vendorID,
              let mode = USBMode(productID: productID) else {
            return nil
        }
        self.vendorID = vendorID
        self.productID = productID
        self.mode = mode
        self.deviceUID = deviceUID
    }

    /// Whether this is a Symphony IO MKI device.
    public var isSymphonyIO: Bool { true }

    /// Display name for the device.
    public var displayName: String {
        "Symphony I/O (\(mode.displayName))"
    }
}
