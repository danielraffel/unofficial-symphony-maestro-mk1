/// EXPERIMENT (64 channels, stage 2): the ThunderBridge port selection.
///
/// A two-port build of the driver publishes Apogee's original data-source
/// selector on the Core Audio device, on the input and the output side: Audio
/// MIDI Setup shows it as "Source", and macOS also offers it in Sound settings.
/// The two entries, their order and their names are the original's
/// (`og_source/symphonymk1/ext/Symphony64/SymphonyAPI/SymphonyCommon.h:182`,
/// `Driver/Symphony64AudioEngine.cpp:38-93`), and the raw value is the entry's
/// index, which is the Core Audio data-source ID
/// (`kSymphonyPortSource*` in `SymphonyThunderbridgeShared.h`).
///
/// A released driver publishes no such selector, so none of this is shown.
public enum PortSelection: UInt32, CaseIterable, Sendable, Identifiable {
    /// One Symphony I/O (or converter chain) on port 1: channels 1-32.
    case port1 = 0
    /// Both ports: channels 1-32 are port 1, 33-64 are port 2.
    case ports1And2 = 1

    public var id: UInt32 { rawValue }

    /// The name the driver publishes and Audio MIDI Setup shows.
    public var name: String {
        switch self {
        case .port1: return "Port 1: 32ch"
        case .ports1And2: return "Port 1-2: 64ch"
        }
    }

    public var channelCount: Int {
        switch self {
        case .port1: return 32
        case .ports1And2: return 64
        }
    }

    /// The selection a Core Audio data-source ID stands for. Nil for anything
    /// else, including the optical-format IDs of other elements.
    public init?(dataSourceID: UInt32?) {
        guard let dataSourceID, let value = PortSelection(rawValue: dataSourceID) else { return nil }
        self = value
    }
}

/// What Maestro shows for the port selection, kept in step with Core Audio.
///
/// The device is the only owner of the selection: Maestro writes the same
/// property Audio MIDI Setup writes and shows whatever the device reports,
/// whoever changed it. The driver may also change it by itself (a request for
/// 64 channels it has to refuse, or port 2 going away), which arrives here the
/// same way, together with the driver's reason.
public struct PortSelectionModel: Sendable, Equatable {
    /// The selection the device reports. Nil when it has no port selector
    /// (every released driver), and then nothing is shown.
    public private(set) var selection: PortSelection?
    /// Why 64 channels are not running although they were asked for, in the
    /// driver's words. Nil when there is nothing to say.
    public private(set) var notice: String?
    /// A choice made in Maestro that the device has not confirmed yet.
    public private(set) var pending: PortSelection?

    public init() {}

    /// True when the picker should be shown at all.
    public var isAvailable: Bool { selection != nil }

    /// The user picked an entry in Maestro. Returns the data-source ID to write
    /// to the device, or nil when there is nothing to write (no selector, or
    /// the entry is the one already selected).
    public mutating func userChose(_ choice: PortSelection) -> UInt32? {
        guard let selection, selection != choice else { return nil }
        pending = choice
        return choice.rawValue
    }

    /// The write to the device failed: nothing changed.
    public mutating func writeFailed() {
        pending = nil
    }

    /// The device's current data-source ID (read after a property-listener
    /// callback, or at connect) and the driver's port-2 state. Either can be
    /// nil: no selector, or a driver that does not report the state.
    public mutating func deviceReported(dataSourceID: UInt32?, state: SecondPortState?) {
        selection = PortSelection(dataSourceID: dataSourceID)
        guard let selection else {
            pending = nil
            notice = nil
            return
        }
        if pending == selection { pending = nil }
        // The driver's explanation is only worth showing while 32 is what runs.
        if selection == .port1, let state, !state.audioActive {
            notice = state.audioProblemText
            // A refusal is the answer to the pending request.
            if state.audioRefused || state.audioFellBack { pending = nil }
        } else {
            notice = nil
        }
    }
}
