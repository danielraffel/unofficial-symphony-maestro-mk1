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

    /// Evidence: og_source/maestrolink/Software/SymphonyIO.cpp:2961-2968;
    /// SymphonyController.cpp:1328-1343. No reconnect instructions are added.
    public static func clock(locked: Bool, link: Link = .other) -> String {
        if link != .other { return "Bus Error" }
        return locked ? "Ready" : "Clock Mismatch"
    }

    /// The Clock Status info pop-up in Device Settings › Clock. The two states
    /// are the original's (`SymphonyIO.cpp:2961-2968`); when each is shown is
    /// `ClockSourceMenu.isLocked`.
    public static let clockInfoParagraphs: [String] = [
        "Clock Status shows whether the Symphony I/O is locked to the clock source chosen above.",
        "**Ready**: the clock source is Internal, or the Symphony I/O has locked to the external source you chose.",
        "**Clock Mismatch**: the source you chose has no usable signal, or it runs at a different sample rate "
            + "from the one set here. Check the cable and the source's sample rate, or choose Internal.",
    ]

    /// Status bar, while routing or mixer state saved on this Mac is being
    /// put on the unit (a mixer-fed output is silent until its mixer is set).
    public static let restoringMixerAndRouting = "Restoring mixer and routing…"
    /// Status bar, while that cannot happen yet: the I/O cards, the unit's
    /// identity or its saved mixer state are not available.
    public static let mixerWaitsForIdentity = "Mixer changes will apply when the Symphony I/O is identified."

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
        "No hardware has been detected on the \(name(port)) port of \(card).\n" + verify
    }

    public static func busError(port: Port, card: String = defaultCard) -> String {
        "A bus error has occurred on the \(port == .primary ? "Primary" : "Secondary") port of \(card).\n" + verify
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
        guard let end = message.range(of: ".\n") else { return message }
        return String(message[..<end.lowerBound]) + "."
    }
}
