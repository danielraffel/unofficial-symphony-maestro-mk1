/// Device discovery protocol for detecting connected Apogee audio interfaces.
///
/// Abstracts the mechanism used to find devices — CoreAudio HAL enumeration,
/// IOUSBHost matching, or simulated devices for testing.
///
/// Evidence: `og_source/maestrolink/Software/ApogeeServices/ApogeeAudioDeviceManager.h`
/// Evidence: `og_source/generic/CoreAudio/ApogeeCustomProperties.h` (kApogeeCustomProperty_DeviceList)

import MaestroCore

// MARK: - Device Info

/// Snapshot of a discovered device's identity and capabilities.
///
/// Created by DeviceDiscovery and consumed by the app layer to
/// present device selection UI and establish connections.
public struct DiscoveredDevice: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    /// USB device identifier (VID, PID, mode, UID).
    public let usbIdentifier: USBDeviceIdentifier
    /// Human-readable device name.
    public let name: String
    /// The device descriptor from MaestroCore (capabilities, features).
    public let descriptor: DeviceDescriptor?

    public init(
        usbIdentifier: USBDeviceIdentifier,
        name: String,
        descriptor: DeviceDescriptor? = nil
    ) {
        self.id = usbIdentifier.deviceUID
        self.usbIdentifier = usbIdentifier
        self.name = name
        self.descriptor = descriptor
    }
}

// MARK: - Discovery Events

/// Events emitted by device discovery.
public enum DeviceDiscoveryEvent: Sendable {
    /// A new device was connected.
    case deviceAdded(DiscoveredDevice)
    /// A device was disconnected.
    case deviceRemoved(deviceUID: String)
}

// MARK: - DeviceDiscovery Protocol

/// Protocol for discovering connected Apogee audio devices.
///
/// Implementations provide both one-shot scanning and continuous
/// monitoring via an AsyncStream of events.
///
/// Evidence: `og_source/maestrolink/Software/ApogeeServices/ApogeeAudioDeviceManager.h`
/// - `getDeviceList` → `scan()`
/// - device add/remove notifications → `events`
public protocol DeviceDiscovery: Sendable {
    /// Scan for currently connected devices.
    func scan() async throws -> [DiscoveredDevice]

    /// Stream of device add/remove events for continuous monitoring.
    var events: AsyncStream<DeviceDiscoveryEvent> { get }

    /// Start monitoring for device connections/disconnections.
    func startMonitoring() async throws

    /// Stop monitoring.
    func stopMonitoring() async
}
