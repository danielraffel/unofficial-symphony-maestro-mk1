/// EXPERIMENT (64 channels, stage 2): the ThunderBridge port selection.
///
/// A two-port build of the driver publishes Apogee's original data-source
/// selector on the Core Audio device, on the input and the output side: Audio
/// MIDI Setup shows it as "Source", and macOS also offers it in Sound settings.
/// The two entries, their order and their names are the original's
/// (`og_source/symphonymk1/ext/Symphony64/SymphonyAPI/SymphonyCommon.h:182`,
/// `Driver/Symphony64AudioEngine.cpp:38-93`), and the raw value is the entry's
/// index, which is the Core Audio data-source ID
/// (`kSymphonyPortSource*` in `SymphonyThunderbridgeShared.h`). The names are
/// under review; everything Maestro shows of them comes from `name`, which a
/// test checks against the driver's header. Inside Maestro the picker uses
/// plain labels (`pickerLabel`).
///
/// A released driver publishes no such selector, so none of this is shown.
public enum PortSelection: UInt32, CaseIterable, Sendable, Identifiable {
    /// One Symphony I/O (or converter chain) on port 1: channels 1-32.
    case port1 = 0
    /// Both ports: channels 1-32 are port 1, 33-64 are port 2.
    case ports1And2 = 1

    public var id: UInt32 { rawValue }

    /// The name the driver publishes and Audio MIDI Setup and the Sound menu
    /// show (`kSymphonyPortSourceName32` / `kSymphonyPortSourceName64`).
    public var name: String {
        switch self {
        case .port1: return "Port 1: 32ch"
        case .ports1And2: return "Port 1-2: 64ch"
        }
    }

    /// What Maestro's own Ports picker says.
    public var pickerLabel: String {
        switch self {
        case .port1: return "32 channels"
        case .ports1And2: return "64 channels (two units)"
        }
    }

    /// The two grey lines under the picker.
    public static let explanationLines = [
        "32 channels: one Symphony I/O on ThunderBridge port 1.",
        "64 channels: adds a second unit on port 2 as channels 33–64.",
    ]

    /// The ⓘ popover next to the picker. Whether a DAW keeps the device across
    /// a switch has not been tried yet, hence "should".
    public static var infoText: String {
        "In Audio MIDI Setup (Source) and the macOS Sound menu, these choices are named:\n"
            + "• \(PortSelection.port1.name) — 32 channels\n"
            + "• \(PortSelection.ports1And2.name) — 64 channels (two units)\n"
            + "Your DAW should keep the same device either way."
    }

    /// The Help answer for the two-unit test build (HelpView).
    public static var helpText: [String] {
        [
            "This is a test build of the two-unit (64-channel) setup. It has not been tried on hardware yet.",
            "Connect the first Symphony I/O to ThunderBridge port 1 and the second unit to port 2. "
                + "Choose **64 channels (two units)** under **Ports** in System Setup › Device Info, "
                + "or pick **\(PortSelection.ports1And2.name)** in Audio MIDI Setup's **Source** menu "
                + "or the macOS Sound menu. **\(PortSelection.port1.name)** is the usual 32 channels. "
                + "Channels 33–64 are the unit on port 2.",
            "If no second unit is found on port 2, the driver refuses 64 channels and stays at 32; "
                + "Device Info says why. Your DAW should keep the same device either way.",
        ]
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
        // The driver's explanation is only worth showing while 32 is what runs,
        // in plain words (the copied details keep the driver's own).
        if selection == .port1, let state, !state.audioActive {
            notice = state.plainProblemText
            // A refusal is the answer to the pending request.
            if state.audioRefused || state.audioFellBack { pending = nil }
        } else {
            notice = nil
        }
    }
}

/// What Device Info shows around the Ports picker. At 32 channels port 2 is
/// off and nothing is looked at, so there is nothing to report about it: the
/// picker, its explanation, one "Two-unit test build" row and, after a refused
/// request, the plain reason once under the picker. The port-2 detail rows
/// appear only while 64 channels are selected and actually running. The copied
/// details keep everything (`SecondPortState.reportLines`).
public struct PortsPresentation: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var label: String
        public var value: String
    }

    public static let testBuildRow = Row(label: "Two-unit test build", value: "Installed")
    public static let switchingText = "Switching to 64 channels…"

    /// The grey line under the picker: switching, or why 64 is not running.
    public var statusLine: String?
    /// The rows after the picker.
    public var rows: [Row]

    public init(model: PortSelectionModel, state: SecondPortState) {
        let selection = model.selection
        let switching = model.pending == .ports1And2
            || (selection == .ports1And2 && model.pending == nil && !state.audioActive)
        let running = selection == .ports1And2 && model.pending == nil && state.audioActive
        if switching {
            statusLine = Self.switchingText
        } else if selection == .port1 {
            statusLine = model.notice
        } else {
            statusLine = nil
        }
        rows = [Self.testBuildRow]
        if running {
            rows += state.port2DetailRows.map { Row(label: $0.label, value: $0.value) }
        }
    }
}
