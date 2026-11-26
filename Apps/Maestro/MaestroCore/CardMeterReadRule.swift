/// When Maestro reads the ThunderBridge / PCIe card's own meters, and what it
/// shows when a read gives nothing.
///
/// The card meters whether or not an application is using the device: the
/// original stopped input and output DMA with the audio engine but left meter
/// DMA running (og_source/symphonymk1/ext/Symphony64/Driver/Symphony64Card.cpp
/// :749 and :1847, `StartMeteringDMA` at :1763), and our driver's StopDevice
/// leaves it running too. So the read does not wait for Core Audio to start
/// the device; before 0.9.33 it did, and the Input and Mixer meters were dark
/// until a DAW was open.
///
/// A Symphony that is switched off leaves its last meter frame on the card.
/// The health probe is what notices that (within about 7 s with no audio
/// client, about 12 s while one is streaming) and stops the read.
public enum CardMeterReadRule {
    /// Whether to read the card's meter words on this poll.
    /// - Parameters:
    ///   - hardwareResponsive: the last health probe found the unit live.
    ///   - extensionSwapGrace: a driver replacement is in its bounded window,
    ///     where probes fail although the outgoing driver still carries audio.
    ///   - audioRunning: Core Audio has an I/O cycle on the device. Needed only
    ///     for the swap window, which must not keep meters once audio stops.
    public static func readsCard(hardwareResponsive: Bool, extensionSwapGrace: Bool,
                                 audioRunning: Bool) -> Bool {
        hardwareResponsive || (extensionSwapGrace && audioRunning)
    }

    /// Polls a missing frame is ridden over (about 1 s at 20 fps).
    public static let heldPolls = 20

    /// A read that was due returned nothing (the driver refuses a frame the
    /// card rewrote mid-copy). With no audio client there is no host-side
    /// level to fall back on, so the last levels are kept for a few polls
    /// rather than dropping every meter and peak hold to silence for one.
    /// - Parameter missedPolls: consecutive due reads that returned nothing,
    ///   counting this one.
    public static func holdsLastLevels(readDue: Bool, audioRunning: Bool, missedPolls: Int) -> Bool {
        readDue && !audioRunning && missedPolls <= heldPolls
    }
}
