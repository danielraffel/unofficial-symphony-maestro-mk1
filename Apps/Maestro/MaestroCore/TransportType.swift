/// Transport type for a connected Symphony IO device.
///
/// The same physical hardware can be accessed through different transports:
/// - USB: via usbaudiod + MaestroVolumeProxy XPC daemon
/// - Thunderbolt: via ThunderBridge DriverKit dext (AudioDriverKit)
///
/// The app prefers Thunderbolt when available (lower latency PCIe DMA).
public enum TransportType: String, Sendable, Equatable, Hashable {
    /// USB Audio Class device (via usbaudiod).
    case usb = "USB"
    /// Thunderbolt via ThunderBridge PCIe adapter (via DriverKit dext).
    case thunderbolt = "Thunderbolt"

    /// Human-readable display name for the transport.
    public var displayName: String {
        switch self {
        case .usb: return "USB"
        case .thunderbolt: return "ThunderBridge"
        }
    }
}

/// The two connection layers shown by Maestro.
///
/// A transport can remain present while the downstream Symphony endpoint is
/// powered off. Keeping these states separate prevents the sidebar from
/// claiming that ThunderBridge disappeared when only the attached interface
/// stopped responding.
public enum SymphonyEndpointState: String, Sendable, Equatable {
    case connected
    case disconnected
}

/// Pure presentation logic for the sidebar transport badge and the detail
/// status area. USB has no independently observable transport in this app, so
/// a USB endpoint loss falls back to the generic disconnected label. The PCIe
/// Symphony card uses the same ThunderBridge transport path and therefore the
/// same presentation rules.
public struct ConnectionPresentation: Sendable, Equatable {
    public let transportType: TransportType?
    public let transportPresent: Bool
    public let endpointState: SymphonyEndpointState

    public init(transportType: TransportType?, transportPresent: Bool,
                endpointState: SymphonyEndpointState) {
        self.transportType = transportType
        self.transportPresent = transportPresent
        self.endpointState = endpointState
    }

    public var transportLabel: String {
        guard transportPresent, let transportType else { return "Disconnected" }
        return "\(transportType.displayName) Connected"
    }

    public var endpointLabel: String {
        endpointState == .connected ? "Connected" : "Symphony Disconnected"
    }
}
