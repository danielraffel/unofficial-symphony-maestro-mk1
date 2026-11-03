/// MaestroDevice — Hardware communication layer for Apogee devices.
///
/// This module contains:
/// - USB device identification (VID/PID, mode detection)
/// - Device discovery protocol + simulated implementation
/// - Device connection protocol (property get/set)
/// - Property change listeners (async streams)
/// - Simulated device for testing without hardware
/// - USB control transfer types + vendor-specific command opcodes
/// - USBDeviceConnection: property-to-USB bridge (production)
/// - IOUSBHostTransport: real hardware transport (macOS only)
/// - MockUSBTransport: testing transport
///
/// MaestroDevice depends on MaestroCore for model types.

import MaestroCore
import Foundation

public enum MaestroDevice {
    public static let version = MaestroCore.version
}
