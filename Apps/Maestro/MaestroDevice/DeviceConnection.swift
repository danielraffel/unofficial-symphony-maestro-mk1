/// Device connection protocol for reading/writing Apogee device properties.
///
/// Abstracts the transport layer — could be CoreAudio HAL properties,
/// IOUSBHost vendor-specific requests, or an in-memory simulator.
///
/// Evidence: `og_source/generic/CoreAudio/ApogeeCustomProperties.h`
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h`

import MaestroCore
import Foundation

// MARK: - Property Scope

/// Scope qualifier for property access, matching CoreAudio conventions.
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` — properties are
/// qualified by scope (global, input, output) and element (channel index).
public enum PropertyScope: Sendable, Equatable, Hashable {
    /// Device-global property.
    case global
    /// Input-side property.
    case input
    /// Output-side property.
    case output
}

// MARK: - Property Address

/// Identifies a specific property on a device.
///
/// Combines a selector (four-char code), scope, and element index.
/// This mirrors CoreAudio's AudioObjectPropertyAddress.
public struct PropertyAddress: Sendable, Equatable, Hashable {
    /// The property selector (four-char code as UInt32).
    public let selector: AudioPropertySelector
    /// Property scope.
    public let scope: PropertyScope
    /// Element index (0 for master/global, channel index otherwise).
    public let element: UInt32

    public init(
        selector: AudioPropertySelector,
        scope: PropertyScope = .global,
        element: UInt32 = 0
    ) {
        self.selector = selector
        self.scope = scope
        self.element = element
    }
}

// MARK: - Property Value

/// Type-erased property value for transport across the device connection.
///
/// Wraps the various data types used by Apogee device properties.
/// Evidence: `mAEstroUtilities.c` — properties can be UInt32, Float64,
/// AudioValueRange, CFString, binary data, etc.
public enum PropertyValue: Sendable, Equatable {
    case uint32(UInt32)
    case int32(Int32)
    case float64(Float64)
    case string(String)
    case data(Data)
    case range(min: Float64, max: Float64)
    case bool(Bool)

    /// Extract as UInt32, or nil if not that type.
    public var asUInt32: UInt32? {
        if case .uint32(let v) = self { return v }
        return nil
    }

    /// Extract as Float64, or nil if not that type.
    public var asFloat64: Float64? {
        if case .float64(let v) = self { return v }
        return nil
    }

    /// Extract as String, or nil if not that type.
    public var asString: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Extract as Bool, or nil if not that type.
    public var asBool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Extract as Data, or nil if not that type.
    public var asData: Data? {
        if case .data(let v) = self { return v }
        return nil
    }
}

// MARK: - Device Connection Errors

/// Errors from device property operations.
public enum DeviceConnectionError: Error, Sendable, Equatable {
    /// The device is not connected or was disconnected.
    case notConnected
    /// The property selector is not supported by this device.
    case unsupportedProperty(AudioPropertySelector)
    /// The property is read-only.
    case readOnly(AudioPropertySelector)
    /// The value type doesn't match what the property expects.
    case typeMismatch(expected: String, got: String)
    /// A transport-level error (USB, CoreAudio, etc.).
    case transportError(String)
    /// The element index is out of range.
    case invalidElement(UInt32)
    /// The property is accepted but has no hardware opcode (or an unsafe one):
    /// the caller must cache the value and skip the hardware send entirely.
    /// Never send a sentinel opcode (e.g. 0xFF) for these — the device treats
    /// 0xFF as the connectivityVerification READ opcode and stray writes can
    /// wedge the XMOS EP0 controller.
    case cacheOnly(AudioPropertySelector)
}

// MARK: - Device Connection Protocol

/// Protocol for reading and writing properties on a connected device.
///
/// This is the core abstraction that allows the app to communicate
/// with real hardware (via IOUSBHost or CoreAudio HAL) or a simulator.
///
/// Evidence: `og_source/generic/CoreAudio/ApogeeCustomProperties.h`
/// - Property get/set with scope and element qualifiers.
public protocol DeviceConnection: AnyObject, Sendable {
    /// The identity of the connected device.
    var identifier: USBDeviceIdentifier { get }

    /// Whether the connection is currently active.
    var isConnected: Bool { get }

    /// Read a property value.
    func getProperty(_ address: PropertyAddress) async throws -> PropertyValue

    /// Write a property value.
    func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws

    /// Check whether a property is supported.
    func hasProperty(_ address: PropertyAddress) async -> Bool

    /// Check whether a property can be written.
    func isPropertySettable(_ address: PropertyAddress) async -> Bool

    /// Register a listener for property changes.
    func addListener(_ listener: PropertyListener, for address: PropertyAddress) async

    /// Remove a listener.
    func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async

    /// Disconnect from the device.
    func disconnect() async
}
