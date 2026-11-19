import Foundation

/// What Apogee's software said when the ThunderBridge or PCIe card's link to
/// the hardware failed (`og_source/maestrolink/Software/SymphonyController.cpp`
/// :2011-2075, `SetSymphonyStatusMessage`). Shown in the status bar in place of
/// a bare "Symphony Disconnected" when the driver's link watch says which it
/// is, and under the Ports picker when 64 channels found nothing on port 2.
public enum PortStatusMessage {
    /// The driver's link watch, reduced to what the message needs.
    public enum Link: Sendable, Equatable {
        /// No unit clock on the port: nothing connected, or it is off.
        case noHardware
        /// Clock present but the bus is being re-initialised or faulted.
        case busError
        /// Up, or nothing known.
        case other
    }

    public enum Port: Sendable {
        case primary, secondary
    }

    public static let verify = "Verify that the hardware is properly connected and powered on."
    public static let defaultCard = "the ThunderBridge"

    /// "the ThunderBridge", or "the Symphony 64 PCIe card" for `pci19c2,2100`
    /// (the same test as `ConnectionLabel`).
    public static func cardPhrase(pciIdentifier: String?) -> String {
        if let pciIdentifier, pciIdentifier.lowercased().hasSuffix(",2100") {
            return "the Symphony 64 PCIe card"
        }
        return defaultCard
    }

    static func name(_ port: Port) -> String { port == .primary ? "primary" : "secondary" }

    public static func noHardware(port: Port, card: String = defaultCard) -> String {
        "No hardware has been detected on the \(name(port)) port of \(card). " + verify
    }

    public static func busError(port: Port, card: String = defaultCard) -> String {
        "A bus error has occurred on the \(name(port)) port of \(card). " + verify
    }

    /// The port-1 message for a link state, nil when there is nothing to add.
    public static func primary(_ link: Link, card: String = defaultCard) -> String? {
        switch link {
        case .noHardware: return noHardware(port: .primary, card: card)
        case .busError: return busError(port: .primary, card: card)
        case .other: return nil
        }
    }

    /// The first sentence, for the one-line status bar (the whole message is
    /// its tooltip).
    public static func headline(_ message: String) -> String {
        guard let end = message.range(of: ". ") else { return message }
        return String(message[..<end.lowerBound]) + "."
    }
}
