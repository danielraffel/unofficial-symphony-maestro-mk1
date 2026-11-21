import Foundation

/// Device Settings › VBus: Apogee's "virtual buses".
///
/// VBus adds channels to the Symphony's Core Audio device that never reach
/// the hardware: what one application plays to a VBus output is what another
/// (or the same one) records from the VBus input with the same number. The
/// original offered it on the card connections only (Symphony 64 PCIe and
/// ThunderBridge), with a Symphony I/O or with converters alone.
///
/// The entries and their labels are the original Maestro's pop-up, in its
/// order (`og_source/symphonymk1/ext/maestro2/App/Views/
/// APSystemSymphonySetupView.xib:131-230`: None, 2/4/8/16/32/48/64 Channels;
/// the menu item's tag is the channel count, bound to `symphonyVBusChannels`,
/// `App/Controllers/APSystemSymphonySetupViewController.m:43-46`). They are
/// the sizes the driver offered for one card
/// (`og_source/symphonymk1/ext/Symphony64/SymphonyAPI/
/// SymphonyBaseAudioEngine.cpp:1061-1075`: 2, 4, 8, 16, then steps of 16
/// below cards × 64 + 1). The raw value is the channel count the driver is
/// sent (selector 16).
public enum VBusChannels: UInt32, CaseIterable, Sendable, Identifiable {
    /// No VBus channels: the default
    /// (`SymphonyBaseAudioEngine.cpp:956`, `SymphonyDeviceServer.cpp:331`).
    case none = 0
    case two = 2
    case four = 4
    case eight = 8
    case sixteen = 16
    case thirtyTwo = 32
    case fortyEight = 48
    case sixtyFour = 64

    public var id: UInt32 { rawValue }

    /// The pop-up entry, as the original's.
    public var label: String {
        self == .none ? "None" : "\(rawValue) Channels"
    }

    /// The first driver build with VBus (selector 16).
    public static let requiredDriverBuild: UInt32 = 143

    /// Whether the driver serving the card has VBus. An older or unread one
    /// is never sent the request.
    public static func driverSupports(_ servingBuild: ServingDextBuild?) -> Bool {
        guard case .build(let build) = servingBuild else { return false }
        return build >= requiredDriverBuild
    }

    /// Why the pop-up cannot be used; nil when it can. `servingBuild` nil:
    /// the running driver's build is not read yet (nothing to say).
    public static func unavailableReason(servingBuild: ServingDextBuild?) -> String? {
        guard let servingBuild, !driverSupports(servingBuild) else { return nil }
        return "VBus needs the driver that comes with this version of Maestro, and an older one is still running. "
            + "Restart the Mac to finish the driver update."
    }

    /// The names applications show for VBus channel `number` (1-based), as
    /// the original's daemon named every channel after the physical ones
    /// (`og_source/symphonymk1/ext/maestrolink/Software/
    /// SymphonyController.cpp:3145-3158`). The driver publishes the same.
    public static func outputName(_ number: Int) -> String { "VBout \(number)" }
    public static func inputName(_ number: Int) -> String { "VBin \(number)" }

    /// The ⓘ popover next to the pop-up's label.
    public static let infoTitle = "About VBus"
    public static var infoParagraphs: [String] {
        [
            "Extra channels for sending audio from one application to another, or within one. "
                + "What an application plays to \(outputName(1)) is what you record from \(inputName(1)), "
                + "and so on. They don't reach the hardware.",
            "VBus is off by default. It is available on ThunderBridge and PCIe.",
            "Some applications show these as numbered inputs and outputs after the hardware channels, "
                + "unless set to use the driver's names.",
        ]
    }
    /// The popover's link: Apogee's own article.
    public static let apogeeArticleTitle = "Apogee: What is VBus and how do you use it?"
    public static let apogeeArticleURL =
        URL(string: "https://knowledge.apogeedigital.com/what-is-vbus-and-how-do-you-use-it")!

    /// The "Device channels" row: where the VBus channels are, after the
    /// hardware channels, as a range ("33–40"). nil with VBus off.
    public static func deviceChannelsRange(channels: VBusChannels, hardwareChannels: Int) -> String? {
        guard channels != .none else { return nil }
        return "\(hardwareChannels + 1)–\(hardwareChannels + Int(channels.rawValue))"
    }

    /// The note under the rows once the size has been changed in this
    /// session of Maestro (not at launch, and not when Maestro sends the
    /// saved size again): an application that was open may need reopening.
    /// In testing with Logic and Reaper, open applications followed the
    /// change by themselves.
    public static func reopenNote(changedThisSession: Bool, channels: VBusChannels) -> String? {
        guard changedThisSession else { return nil }
        return channels == .none
            ? "If an open audio application still shows the VBus channels, quit and reopen it."
            : "If an open audio application doesn't show the new channels, quit and reopen it."
    }

    /// Help's answer.
    public static var helpText: [String] {
        [
            "VBus adds virtual channels to the Symphony's audio device for sending audio from one application "
                + "to another, or from one place to another in the same application. What is played to "
                + "**\(outputName(1))** is recorded from **\(inputName(1))**, and so on; nothing on these channels "
                + "reaches the hardware. For example, in Logic set the output of several tracks to VBout 1-2 and "
                + "record a new track from VBin 1-2 to print a submix.",
            "Choose the number of channels in Device Settings › **VBus**. It is **None** until "
                + "you choose a size. VBus is available on ThunderBridge and the Symphony 64 PCIe card, with a "
                + "Symphony I/O or with converters, and not over USB. The VBus channels come after the hardware "
                + "channels: from channel 33, or from 65 when 64 channels are selected under Ports; "
                + "**Device channels** under the pop-up shows which.",
            "Applications that are open pick the channels up without being relaunched (tested with Logic and "
                + "Reaper). If an open audio application doesn't show them, quit and reopen it. Logic lists them "
                + "as numbered inputs and outputs after the hardware ones (for example Input 33–40), unless its "
                + "I/O Labels are set to the driver's names.",
        ]
    }

    // MARK: Persistence

    /// The choice is saved per card: under the Core Audio device UID, which
    /// the driver builds from the card's serial number, and which is also
    /// what macOS saves the Ports selection under. (The original saved one
    /// value for the whole system, `SymphonyController.cpp:3312-3314`; it
    /// had one device for every card.)
    public static func defaultsKey(deviceUID: String) -> String { "vbusChannels.\(deviceUID)" }

    /// The saved choice; None when nothing, or something that is no entry,
    /// is saved.
    public static func saved(in defaults: UserDefaults, deviceUID: String) -> VBusChannels {
        guard let number = defaults.object(forKey: defaultsKey(deviceUID: deviceUID)) as? NSNumber,
              number.int64Value >= 0, number.int64Value <= Int64(UInt32.max),
              let value = VBusChannels(rawValue: number.uint32Value) else { return .none }
        return value
    }

    public func save(in defaults: UserDefaults, deviceUID: String) {
        defaults.set(Int(rawValue), forKey: Self.defaultsKey(deviceUID: deviceUID))
    }

    // MARK: Hardware channels

    /// The hardware part of per-channel values read from the Core Audio
    /// device (the software meters' peaks): the VBus channels come after the
    /// hardware channels, and are not hardware inputs or outputs.
    public static func hardwareOnly<T>(_ values: [T], hardwareChannels: Int) -> [T] {
        values.count > hardwareChannels ? Array(values.prefix(max(0, hardwareChannels))) : values
    }
}

/// What the driver reports for VBus (`SymphonyVBusStateOutput`).
public struct VBusState: Sendable, Equatable {
    /// The VBus channels the device has now.
    public let published: UInt32
    /// What was last asked for; differs from `published` until Core Audio
    /// has made the change.
    public let requested: UInt32
    /// The 1-based device channel of VBus channel 1; 0 while off.
    public let firstChannel: UInt32
    public let flags: UInt32

    public static let wordCount = 4
    /// `kSymphonyVBusFlagPublishFailed`.
    public static let publishFailedFlag: UInt32 = 1

    public init(published: UInt32, requested: UInt32, firstChannel: UInt32, flags: UInt32) {
        self.published = published
        self.requested = requested
        self.firstChannel = firstChannel
        self.flags = flags
    }

    public init?(words: [UInt32]) {
        guard words.count == Self.wordCount else { return nil }
        self.init(published: words[0], requested: words[1], firstChannel: words[2], flags: words[3])
    }

    public var publishFailed: Bool { flags & Self.publishFailedFlag != 0 }

    /// The line under the pop-up when the device is not (yet) what was chosen.
    /// `retrying`: Maestro will still send the size again by itself.
    public func statusLine(chosen: VBusChannels, retrying: Bool = false) -> String? {
        if publishFailed {
            return retrying
                ? "The driver could not add the VBus channels. Maestro will try again."
                : "The driver could not add the VBus channels. Choose None, then the size again, or restart the Mac."
        }
        if published != chosen.rawValue { return "Changing…" }
        return nil
    }

    /// The diagnostics report's line.
    public static func reportLine(chosen: VBusChannels?, state: VBusState?, driverSupports: Bool) -> String {
        guard driverSupports else { return "VBus: not available (the running driver is older than build \(VBusChannels.requiredDriverBuild))" }
        let choice = chosen.map(\.label) ?? "?"
        guard let state else { return "VBus: \(choice) (driver state not read)" }
        var text = "VBus: \(choice) (driver: \(state.published) published, \(state.requested) requested"
        if state.published > 0 { text += ", first channel \(state.firstChannel)" }
        if state.flags != 0 { text += ", flags 0x\(String(state.flags, radix: 16))" }
        return text + ")"
    }

    /// A device's channel count for the diagnostics' Core Audio list, from
    /// the channels of each of its streams: "32" for one stream, and
    /// "40 (streams 32+8)" when VBus adds a second one, so the hardware
    /// channels can still be told from the total.
    public static func channelCountText(streams: [Int]) -> String {
        let total = streams.reduce(0, +)
        guard streams.count > 1 else { return "\(total)" }
        return "\(total) (streams \(streams.map(String.init).joined(separator: "+")))"
    }
}
