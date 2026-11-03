/// USB control transfer types for vendor-specific Apogee device communication.
///
/// Encodes the USB control transfer structure used by Symphony IO MKI:
/// - bmRequestType: 0x40 (write) or 0xC0 (read) — vendor-specific, device target
/// - bRequest: command opcode (SymphonyIOCommand)
/// - wValue/wIndex: command parameters (from 32-bit nValue split)
/// - wLength: payload size (max 64 bytes)
///
/// Evidence: `og_source/generic/USB/ApoUSB.h` — SendRequest(fWrite, bRequest, nValue, nLength, pData, reserved)
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp` — usage patterns

import Foundation

// MARK: - USB Transfer Direction

/// Direction of a USB control transfer.
///
/// Evidence: `og_source/generic/USB/ApoUSB.h`
/// - bmRequestType 0xC0 = device-to-host (read)
/// - bmRequestType 0x40 = host-to-device (write)
public enum USBTransferDirection: UInt8, Sendable {
    /// Host → Device (bmRequestType 0x40): vendor-specific, host-to-device, device target.
    case write = 0x40
    /// Device → Host (bmRequestType 0xC0): vendor-specific, device-to-host, device target.
    case read = 0xC0
}

// MARK: - USB Control Request

/// A USB vendor-specific control transfer request.
///
/// Maps to the legacy `SendRequest(fWrite, bRequest, nValue, nLength, pData, reserved)`.
///
/// Evidence: `og_source/generic/USB/ApoUSB.h` lines 47-52
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp` lines 54-59
public struct USBControlRequest: Sendable {
    /// Transfer direction (read from device or write to device).
    public let direction: USBTransferDirection

    /// Command opcode (bRequest field). Maps to SymphonyIOCommand raw value.
    public let request: UInt8

    /// Primary parameter (wValue) — the HIGH half of legacy's 32-bit nValue.
    ///
    /// Read this carefully before adding a builder: legacy composes one 32-bit
    /// `nValue` and the USB transport splits it as
    /// `wValue = nValue >> 16; wIndex = nValue & 0xFFFF`
    /// (og_source/maestrolink/Software/ControlProtocol/SimpleControlProtocolUSB.cpp:56-57).
    ///
    /// So wValue is **0 for every command whose nValue fits in 16 bits**, which is
    /// most of them — plain channel indices, bank numbers, board numbers, meter
    /// groups and mode selectors all belong in ``index``, not here. wValue is
    /// nonzero only for genuinely composite values, e.g. the mixer commands'
    /// mixerID in bits[23:16] (see ``USBValueEncoding/mixerValue(mixerID:channel:)``).
    ///
    /// The og_source per-command comments say "nValue : ..." and mean the
    /// pre-split value. Reading one of those as wValue is what sent front-panel
    /// bank 1 to the firmware as 0x00010000 and wedged EP0 (Docs/Learnings.md
    /// 2026-09-11). When in doubt, build the nValue and call
    /// ``USBValueEncoding/split(_:)`` rather than assigning either field by hand.
    public let value: UInt16

    /// Secondary parameter (wIndex) — the LOW half of legacy's 32-bit nValue,
    /// and therefore where most Symphony IO parameters actually go. See ``value``.
    public let index: UInt16

    /// Payload data (pData). Max 64 bytes per USB spec for control transfers.
    /// For writes, this is the data sent to the device.
    /// For reads, this will be filled with the device's response.
    public let data: Data

    public init(
        direction: USBTransferDirection,
        request: UInt8,
        value: UInt16 = 0,
        index: UInt16 = 0,
        data: Data = Data()
    ) {
        self.direction = direction
        self.request = request
        self.value = value
        self.index = index
        self.data = data
    }

    /// bmRequestType byte for this transfer.
    public var bmRequestType: UInt8 { direction.rawValue }

    /// Maximum payload size for USB control transfers.
    public static let maxPayloadSize = 64
}

// MARK: - USB Control Response

/// Response from a USB vendor-specific control transfer.
public struct USBControlResponse: Sendable {
    /// Data returned by the device (for read requests).
    public let data: Data

    /// Number of bytes actually transferred.
    public let bytesTransferred: Int

    public init(data: Data, bytesTransferred: Int) {
        self.data = data
        self.bytesTransferred = bytesTransferred
    }
}

// MARK: - USB Transport Protocol

/// Protocol for sending USB vendor-specific control transfers.
///
/// Abstracts the transport layer so we can:
/// - Use IOUSBHost for real hardware
/// - Use a mock for testing
///
/// Evidence: `og_source/generic/USB/ApoUSB.h` — base class interface
public protocol USBTransport: Sendable {
    /// Send a USB control transfer and return the response.
    ///
    /// - Parameter request: The control transfer to send.
    /// - Returns: Response containing any data read from the device.
    /// - Throws: `USBTransportError` on failure.
    func send(_ request: USBControlRequest) async throws -> USBControlResponse

    /// Whether the transport is currently connected to a device.
    var isConnected: Bool { get }

    /// Close the transport connection.
    func close() async
}

// MARK: - USB Transport Errors

/// Errors from the USB transport layer.
///
/// Evidence: `og_source/generic/USB/ApoUSB.h` — IOReturn error codes
public enum USBTransportError: Error, Sendable, Equatable {
    /// No device is connected.
    case noDevice
    /// The device was disconnected during communication.
    case disconnected
    /// USB pipe stall (endpoint halt).
    case pipeStalled
    /// Timeout waiting for device response.
    case timeout
    /// USB transaction error — control endpoint not responding.
    /// Typically means the firmware's EP0 handler is stalled after power-cycle.
    /// Recovery requires USB cable reconnect or device power cycle.
    case transactionError
    /// The device returned fewer bytes than expected.
    case shortTransfer(expected: Int, actual: Int)
    /// IOUSBHost or IOKit error with the underlying code.
    case ioError(Int32)
    /// The request payload exceeds the maximum size.
    case payloadTooLarge(size: Int, max: Int)
}

extension USBTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No Symphony IO device found"
        case .disconnected:
            return "Device disconnected"
        case .pipeStalled:
            return "USB endpoint stalled"
        case .timeout:
            return "USB transfer timed out"
        case .transactionError:
            return "USB control endpoint not responding. Try disconnecting and reconnecting the USB cable."
        case .shortTransfer(let expected, let actual):
            return "Short transfer: expected \(expected) bytes, got \(actual)"
        case .ioError(let code):
            return "USB I/O error (code \(code))"
        case .payloadTooLarge(let size, let max):
            return "Payload too large: \(size) bytes (max \(max))"
        }
    }
}

// MARK: - Value Encoding Helpers

/// Helpers for encoding/decoding the legacy nValue parameter.
///
/// The legacy SendRequest uses a 32-bit nValue that gets split into
/// wValue (high 16 bits) and wIndex (low 16 bits) for the USB transfer.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// - SYMPHONYIO_AUDIO_CHANNEL_INPUT_MASK = 0x80000000
/// - SYMPHONYIO_AUDIO_CHANNEL_INDEX_MASK = 0x0000FFFF
public enum USBValueEncoding {
    /// Split a 32-bit value into wValue (high 16) and wIndex (low 16).
    public static func split(_ nValue: UInt32) -> (wValue: UInt16, wIndex: UInt16) {
        (UInt16((nValue >> 16) & 0xFFFF), UInt16(nValue & 0xFFFF))
    }

    /// Combine wValue and wIndex back into a 32-bit value.
    public static func combine(wValue: UInt16, wIndex: UInt16) -> UInt32 {
        (UInt32(wValue) << 16) | UInt32(wIndex)
    }

    /// Encode a channel index with input/output flag.
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h` line 11
    /// - `#define SYMPHONYIO_AUDIO_CHANNEL_INPUT_MASK 0x80000000`
    /// - Bit 31: 1 = INPUT (ADC), 0 = OUTPUT (DAC)
    /// - Bits 0-15: channel index
    ///
    /// Evidence: `SymphonyIOControl.cpp:620-621`
    /// - `nValue = (nChannel & INDEX_MASK) | (fInput ? INPUT_MASK : 0x0)`
    public static func channelValue(channel: UInt16, isOutput: Bool = false) -> UInt32 {
        var value = UInt32(channel)
        if !isOutput {
            value |= 0x8000_0000 // SYMPHONYIO_AUDIO_CHANNEL_INPUT_MASK — set for INPUT
        }
        return value
    }

    /// Encode a mixer command value.
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h` — mixer commands use
    /// bits[23:16] for mixer ID, bits[15:0] for channel.
    public static func mixerValue(mixerID: UInt8, channel: UInt16) -> UInt32 {
        (UInt32(mixerID) << 16) | UInt32(channel)
    }
}
