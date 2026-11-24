import SwiftUI
import AppKit
import MaestroCore

// MARK: - Help View

/// In-app rendered help. Deliberately succinct — the goal is to answer the
/// questions people actually ask (which USB device to pick, what Maestro controls,
/// how to uninstall) without reproducing the full user manual.
///
/// The text is data (`HelpSection.all`, below), so the page, the section list
/// and the search field all read the same strings.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    /// Whether the 8MicPre module is installed (or simulated) in either slot.
    /// The Mic Pre sections are the only conditional ones — everything else applies
    /// to every unit, and a wall of preamp instructions on a machine with no
    /// preamps is just noise.
    /// Shared with the Input tab -- see `InputChannelLogic.micPreIsUsable`.
    /// Keying this on board type alone once let the Help sheet advertise preamp
    /// controls the Input tab was correctly refusing to draw.
    private var micPreInstalled: Bool {
        InputChannelLogic.micPreIsUsable(
            primary: appState.primaryBoardType, secondary: appState.secondaryBoardType)
    }

    /// Drives the uninstall Copy button's checkmark. Same confirmation the About box gives.
    @State private var showCommandCopied = false
    @State private var query = ""
    /// The section to scroll to: one clicked in the list, or the one a pop-up asked for.
    @State private var jump: HelpSectionID?
    /// The section at the top of the page, marked in the list as you scroll.
    @State private var current: HelpSectionID?
    /// The last arrow press: Up (-1) or Down (+1), and a count that changes
    /// with every press so that two presses the same way are both seen.
    @State private var arrowStep = 0
    @State private var arrowPresses = 0
    @State private var arrowMonitor: Any?

    /// What is shown: everything, or what the search field matches.
    private var sections: [HelpSection] {
        HelpSearch.filter(HelpSection.all(micPreInstalled: micPreInstalled), query: query)
    }

    var body: some View {
        let sections = sections
        return VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sectionList(sections)
                Divider()
                GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        // Each section carries its own space above, so jumping to
                        // one leaves that space between it and the top edge.
                        VStack(alignment: .leading, spacing: 0) {
                            if sections.isEmpty {
                                Text("No results for \"\(query)\"")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 24)
                            }
                            ForEach(sections) { section in
                                sectionView(section)
                                    .padding(.top, 24)
                                    .id(section.id)
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: HelpSectionTops.self,
                                            value: [section.id: geometry.frame(in: .named("helpScroll")).minY])
                                    })
                            }
                            // Room below the last section, so it too can scroll
                            // to the top and be the one marked in the list.
                            Color.clear.frame(height: max(0, viewport.size.height - 96))
                        }
                        .padding([.horizontal, .bottom], 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Help is reference material people quote back in bug reports and forum
                        // posts, so every paragraph is selectable, not just the uninstall command.
                        .textSelection(.enabled)
                    }
                    .coordinateSpace(name: "helpScroll")
                    .onPreferenceChange(HelpSectionTops.self) { tops in
                        current = HelpSearch.currentSection(tops: tops, order: sections.map(\.id))
                    }
                    .onChange(of: jump) { _, section in
                        guard let section else { return }
                        proxy.scrollTo(section, anchor: .top)
                        jump = nil
                    }
                }
                }
            }
            // Opened from a pop-up's "See Help for more.": start at its section.
            .onAppear {
                jump = appState.helpSection
                appState.helpSection = nil
                // Up and Down move through the sections wherever the focus is
                // (the search field has it when Help opens).
                // Only in Help's own sheet, so an Open or Save panel, the
                // updater and input-method candidate lists keep their arrows.
                if let arrowMonitor { NSEvent.removeMonitor(arrowMonitor) }
                arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let plain = event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
                    guard plain, event.keyCode == 125 || event.keyCode == 126,
                          let window = event.window, window.isSheet,
                          (window.firstResponder as? NSTextView)?.hasMarkedText() != true
                    else { return event }
                    arrowStep = event.keyCode == 125 ? 1 : -1
                    arrowPresses &+= 1
                    return nil
                }
            }
            // a "See Help for more." while Help is open.
            .onChange(of: appState.helpSection) { _, section in
                guard let section else { return }
                jump = section
                appState.helpSection = nil
            }
            .onDisappear {
                if let arrowMonitor { NSEvent.removeMonitor(arrowMonitor) }
                arrowMonitor = nil
            }
            .onChange(of: arrowPresses) { _, _ in
                if let next = HelpSearch.neighbour(of: current, in: sections.map(\.id), step: arrowStep) {
                    jump = next
                }
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 620)
    }

    // MARK: Header / Footer

    private var header: some View {
        HStack(spacing: 12) {
            if let iconURL = Bundle.main.url(forResource: "AppIconRounded", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL) {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44)
            } else {
                Image(systemName: "hifispeaker.2").font(.system(size: 28)).foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Maestro Help").font(.title2).fontWeight(.semibold)
                Text("Symphony I/O MK I · v\(MaestroCore.version)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityLabel("Search Help")
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Report a Bug") { NSWorkspace.shared.open(appState.reportBugURL) }
                .font(.callout)
            Spacer()
            // Return closes Help, except while a search is typed.
            Button("Done") { dismiss() }.keyboardShortcut(query.isEmpty ? .defaultAction : nil)
        }
        .padding(16)
    }

    // MARK: Sections

    /// The section titles, each jumping to its section.
    private func sectionList(_ sections: [HelpSection]) -> some View {
        ScrollViewReader { list in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    Button {
                        jump = section.id
                    } label: {
                        Text(section.title)
                            .fontWeight(current == section.id ? .semibold : .regular)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(current == section.id ? Color.primary.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current == section.id ? .isSelected : [])
                    .id(section.id)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 16)
        }
        // Keep the marked section in view when the list is longer than the window.
        .onChange(of: current) { _, section in
            if let section { list.scrollTo(section) }
        }
        }
        .frame(width: 190)
    }

    /// A section: its heading, questions and answers as one selectable text
    /// (`HelpSearch.runs(_:)`), with commands, links and the removal steps
    /// as rows of their own between.
    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(HelpSearch.runs(section).enumerated()), id: \.offset) { _, run in
                Group {
                    switch run {
                    case .prose(let text):
                        Text(text).lineSpacing(3)
                    case .block(.command(let command)):
                        commandRow(command)
                    case .block(.link(let title, let url)):
                        Link(title, destination: url)
                    case .block(.manualApogeeRemoval):
                        ManualApogeeRemovalSteps()
                    case .block:
                        EmptyView()
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                showCommandCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    showCommandCopied = false
                }
            } label: {
                CopyGlyph(copied: showCommandCopied)
            }
            .buttonStyle(.borderless)
            .maestroHelp("Copy command")
            .accessibilityLabel("Copy uninstall command")
        }
    }
}

/// The last line of an info pop-up: closes it and opens Help at a section.
struct SeeHelpLink: View {
    static let title = "See Help for more."
    let section: HelpSectionID
    let appState: AppState
    @Binding var popover: Bool

    var body: some View {
        Button(Self.title) {
            popover = false
            appState.openHelp(at: section)
        }
        .buttonStyle(.link)
    }
}

// MARK: - Help content

extension HelpSection {
    /// Every section, in the order Help shows them. The Mic Pre sections are
    /// there only when an 8MicPre module is.
    static func all(micPreInstalled: Bool) -> [HelpSection] {
        [whatItDoes, connecting, controls, settings, clock, inputOutput, modules]
            + (micPreInstalled ? [micPreStrip, micPreQuestions] : [])
            + [routing, mixer, mixerUSB, volumeKeys, usbOutput, vbus, interfaceMode, twoUnits,
               troubleshooting, apogeeDrivers, uninstalling, about, feedback, donate]
    }

    private static let uninstallCommand =
        "sudo /Applications/Maestro.app/Contents/Resources/uninstall.sh"

    private static var whatItDoes: HelpSection {
        HelpSection(id: .whatItDoes, title: "About Maestro", items: [
            HelpItem(blocks: [
                .text("A modern native control app for the Apogee Symphony I/O MK I — volume, mute, clock source, sample rate, optical format, routing, and metering. Built for macOS 26 (Tahoe) on Apple Silicon."),
            ]),
            HelpItem(title: "Where do I find Apogee's own documentation and software?", blocks: [
                .text(apogeeDocsLink),
            ]),
        ])
    }

    private static var connecting: HelpSection {
        HelpSection(id: .connecting, title: "Connection types", items: [
            HelpItem(blocks: [
                .bullet("ThunderBridge", "Maestro's own driver gives 32 channels, or 64 with two Symphony I/Os, at the lowest latency and at any of the six sample rates from 44.1 up to 192 kHz. The driver loads only when the card is present."),
                .bullet("Symphony 64 PCIe", "The PCIe card, in a Mac with PCIe slots or a Thunderbolt expansion chassis, works the same way as ThunderBridge: the same driver, channels and sample rates."),
                .bullet("USB", "Works on any supported Mac. Shows up as an audio device you can select from the volume menu or Audio MIDI Setup. Over USB, Maestro gives you 16 channels at 44.1, 48, 88.2 or 96 kHz. For 176.4 or 192 kHz, use ThunderBridge or PCIe."),
            ]),
        ])
    }

    private static var controls: HelpSection {
        HelpSection(id: .controls, title: "What Maestro controls", items: [
            HelpItem(blocks: [
                .text("Volume, mute, clock source, sample rate, optical format (ADAT/S-PDIF), Input Routing and Output Routing, the two **low-latency mixers** (input strips with level, pan, mute and solo; Software Return with level, mute and solo; Master), and **hardware metering**. On Mixer, click a pan value to type 0, -13, +20, L13, R20 or C. Double-click a fader to reset it to 0 dB."),
                .text("**Output Routing** sends any software output pair or mixer to any hardware output. The page shows what Maestro last set."),
            ]),
        ])
    }

    private static var settings: HelpSection {
        HelpSection(id: .settings, title: "Settings & updates", items: [
            HelpItem(title: "Where do I find a setting?", blocks: [
                .text("Settings are on two pages. **Device Settings** is about the Symphony I/O: its clock, connection, VBus, volume keys, front panel, cards and naming."),
                .text("**App Settings** is about Maestro itself: appearance, what happens when a device connects, updates, and diagnostics and feedback."),
                .text("Per-channel settings are on the **Input** and **Output** pages, monitoring mixes on **Mixer**, and signal paths on **Input Routing** and **Output Routing**."),
                .text("⌘1 to ⌘7 open the pages in the sidebar's order: Input, Output, Mixer, Input Routing, Output Routing, Device Settings and App Settings. They are also in the **Navigate** menu."),
            ]),
            HelpItem(title: "Can I choose a light or dark appearance?", blocks: [
                .text("In **App Settings › General**, set **Appearance** to **Auto**, **Light**, or **Dark**. Auto is the default and follows your Mac’s appearance. Light and Dark apply only to Maestro. Your choice is saved and takes effect immediately."),
                .text("You can turn Maestro’s short control explanations on or off with **Show tooltips** in **App Settings › General**; they are on by default."),
            ]),
            HelpItem(title: "What are the Stable and Beta update channels?", blocks: [
                .text("Maestro normally offers stable versions only. In **App Settings › Updates** you can choose **Beta** to get versions that are still being tested. They may have bugs and can replace the ThunderBridge driver. Choose **Stable** again to stop getting them; Maestro then offers to reinstall the latest stable version. If you install a beta package yourself, Maestro sets that copy to Beta when it next reads the update feed, and it keeps getting betas until you choose Stable."),
            ]),
        ])
    }

    /// Device Settings › Clock. The Clock Status lines are the pop-up's own
    /// (`PortStatusMessage.clockInfoParagraphs`); the sources per connection
    /// are `ClockSourceMenu.usb`, `.thunderbolt` and `.converters`.
    private static var clock: HelpSection {
        HelpSection(id: .clock, title: "Clock", items: [
            HelpItem(title: "What is Use Loop Sync?", blocks: (LoopSyncInfo.paragraphs + [LoopSyncInfo.availability]).map { .text($0) }),
            HelpItem(title: "How do I set the sample rate and the clock source?", blocks: [
                .text("Both are in **Device Settings › Clock**. **Sample Rate** sets the rate of the Symphony's audio device, and the Symphony changes to it when it is set, from here, from Audio MIDI Setup or from an audio application."),
                .text("**Clock Source** is where the Symphony takes its clock from. Over USB it is **Internal** only. Over ThunderBridge and PCIe it is **Internal**, **Word Clock**, or a digital input of a card that has one (S/PDIF coax, AES or optical). With converters only it is **Internal** or **External**."),
                .text("The Symphony does not follow an external clock's rate by itself: set **Sample Rate** to the rate the external source runs at."),
            ]),
            HelpItem(title: "What do Ready and Clock Mismatch mean?",
                     blocks: PortStatusMessage.clockInfoParagraphs.map { .text($0) }),
            HelpItem(title: "How are two Symphony I/Os clocked?", blocks: [
                .text("With two Symphony I/Os at 64 channels, **Device Settings › Clock** has **Use Loop Sync** and **Loop Sync Master**, and shows **Configured Role** and **Clock Status** for the unit chosen in the Unit A / Unit B picker. See \"Can I connect more than one Symphony I/O?\" for the cabling."),
            ]),
        ])
    }

    private static var inputOutput: HelpSection {
        HelpSection(id: .inputOutput, title: "Input & Output", items: [
            HelpItem(title: "How do I set a trim to an exact value?", blocks: [
                .text("Press **Show Trims** on the Input or Output tab, click the trim value under a channel's trim fader, type the value and press **Return**. **Tab** applies it and moves to the next channel's trim, **Shift-Tab** to the previous one, and **Esc** leaves it unchanged. A value outside the fader's range is set to the nearest value the fader allows. The box beside it shows the meter level to a tenth of a dB, for calibrating against a tone. The fader values on the Mixer tab can be typed in the same way."),
            ]),
            HelpItem(title: "Why doesn't the D/A meter move when I change a Trim?", blocks: [
                .text("The D/A meter shows the level **before** conversion, so the trim is applied after the point being measured. This is expected. To calibrate against a trim you need to measure the analog output itself with an external voltmeter — send a 1 kHz sine at the digital reference level and adjust the trim until the meter reads the analog reference you chose (1.228 V AC for +4 dBu)."),
            ]),
            HelpItem(title: "What does the Over indicator actually mean?", blocks: [
                .text("It lights when **three or more consecutive full-scale samples** occur. Three samples on their own are very unlikely to be audible — treat it as an early warning that the level should come down rather than as proof of damage."),
                .text("On USB, Over lights use the unit’s Input, Output and Mixer meter data where available. On ThunderBridge and PCIe, Over lights on the Output page come from the unit’s own output meters (driver build 144 or later). On the Input and Mixer pages they light when the card’s meter reaches full scale (0 dBFS)."),
            ]),
            HelpItem(title: "How long are Peaks and Overs held?", blocks: [
                .text("Set **Peak Hold** and **Over Hold** in **Device Settings › Front Panel**. Peak Hold Off hides the peak mark. With 2 Seconds it holds, then falls. Over Hold Off lights for a tenth of a second, and 2 Seconds lights for two seconds on screen. Infinite holds until you click an Over light, choose **Clear Meters**, or clear meters with the front-panel encoder. Older saved Auto Clear settings use 2 Seconds."),
            ]),
            HelpItem(title: "Why do the outputs still say \"Line\" when I've set up speakers?", blocks: [
                .text("Output channels keep their **Line 1, Line 2 …** names in every mode. The menu under the **Speaker** knob on the Output page (Analog Out Format) changes what the outputs *do* — whether the level knob, Mute, Dim and Sum to Mono apply to them — but it does not rename them. Apogee labels the first pair **Monitor Out** on the rear panel; that is a label on the hardware, not a name that changes on screen."),
                .text("Option-click **Mute**, **Dim** or **Sum to Mono** to apply that setting to the speaker and both headphone outputs. Plain clicks affect only the output beside the button. Choosing **2 Speaker Sets** or **3 Speaker Sets** copies the Line 1-2 source to each active speaker pair, as in Apogee's software. Leaving speaker sets or resetting the Output tab restores freed pairs to their defaults. Front-panel **Mute All** updates the speaker and both headphones together."),
            ]),
            HelpItem(title: "Why do some channels say N.A., ADAT, SMUX or SPDIF Opt?", blocks: [
                .text("Channel names follow each card's optical format and the sample rate, as in Apogee's original Maestro. Optical channels are **ADAT** up to 48 kHz, **SMUX** at 88.2 and 96 kHz, and **SPDIF Opt** when the card's optical format is S/PDIF. **N.A.** means the channel carries nothing at the current setting, for example optical channels at 176.4 or 192 kHz. A pair that the S/PDIF coax input replaces is named **SPDIF Cx**."),
                .text("N.A. channels stay in their place on every page and are faded. Over ThunderBridge, Audio MIDI Setup and your DAW see the same names. Each Mac output is named after the hardware output at the same place in Apogee's order (every analog output of both cards first, then the digital ones), and keeps that name when you re-route it."),
            ]),
            HelpItem(title: "How do I use the AES port on an 8x8 card?", blocks: [
                .text("Press the card's **DIG I/O** button so it selects **AES**, then turn the Symphony off and on again. Its digital channels then read **AES** in Maestro."),
                .text("Clocking: over USB the Symphony is the clock master, so set the other AES device to follow the clock on its AES input. Over ThunderBridge you can also choose one of the card's AES inputs in **Clock Source** to lock the Symphony to the other device."),
            ]),
        ])
    }

    /// I/O modules, using Apogee's own product names rather than our internal
    /// enum labels. There are three different 16-channel modules and three
    /// different 8x8 variants, so "16x16" or "8ch Analog-Optical" on their own
    /// are ambiguous — a user cannot tell which card we think they have.
    private static var modules: HelpSection {
        HelpSection(id: .modules, title: "I/O modules", items: [
            HelpItem(blocks: [
                .text("Symphony I/O (original) takes two module slots. Maestro reads the installed modules from the hardware and names them the way Apogee does:"),
                .bullet("8x8 AES/OPT", "8 analog in/out, AES and optical. A front-panel switch selects which digital section is active."),
                .bullet("8x8 AES", "8 analog in/out with AES."),
                .bullet("8x8 OPT", "8 analog in/out with optical (ADAT / S-PDIF / SMUX)."),
                .bullet("16x16 Analog In/Out", "16 analog in and 16 analog out."),
                .bullet("16 Analog In / 16 Digital Out", "16 analog in, 16 optical out."),
                .bullet("16 Digital In / 16 Analog Out", "16 optical in, 16 analog out."),
                .bullet("2x6", "2 analog in, 6 analog out, plus AES and optical."),
                .bullet("8MicPre", "Adds 8 mic preamps in front of an analog module's line inputs, with inserts and four instrument inputs."),
                .text("The 8MicPre is the one module with a slot restriction: it must go in the **second** slot, with an 8x8, 16x16 Analog In/Out, or 16 Analog In / 16 Digital Out module in the first. It has no converters of its own — it feeds the analog module's inputs, which is why its preamps appear on channels 1–8 of that card."),
                .text(ioModulesLink),
            ]),
        ])
    }

    /// Mic Pre channel strip — shown ONLY when an 8MicPre module is present.
    /// Wording follows the Symphony I/O User's Guide, "Mic Pre Module Input Tab"
    /// (p. 56) and the Mic Pre Module page (p. 13).
    private static var micPreStrip: HelpSection {
        HelpSection(id: .micPreStrip, title: "Your Mic Pre channel strip", items: [
            HelpItem(blocks: [
                .text("Setting a channel's **Analog Ref** to **Mic** or **Instrument** routes it through the 8MicPre module and reveals the preamp controls. The preamps sit in front of the analog module's line inputs, so they always appear on **channels 1–8**."),
                .bullet("Level Trim", "the gain of the mic pre — 0–85 dB at Mic level, 0–65 dB at Instrument."),
                .bullet("Group", "controls the Level Trim of several inputs at once. Any level offset that exists before the inputs are grouped is preserved, so a group moves together rather than snapping to one value. Changing a channel's Analog Ref drops it back to Off."),
                .bullet("Insert Select", "patches one of the eight rear-panel send/return pairs into the signal path. The insert point is after the mic pre and high-pass filter and before A/D conversion — the right place for a compressor or EQ."),
                .bullet("Insert In", "enables the Insert Return. The Insert Send is always live once an insert is selected, so with In disengaged the send works as an analog direct out."),
                .bullet("Polarity", "inverts the polarity of the input signal."),
                .bullet("High Pass", "engages an 80 Hz high-pass filter."),
                .bullet("48V", "48 volt phantom power, which condenser mics need."),
                .text("**48 V is available at Mic level only.** It is not a UI preference — the hardware itself refuses the command on a channel set to anything else, so the control is greyed rather than simply ignored. Switching a channel away from Mic turns phantom off on the way out."),
                .text("**Instrument is offered on channels 1–4 only.** The module has exactly four 1/4\" instrument jacks on its front panel, so there is nowhere to plug in an instrument on channels 5–8."),
                .text("**Each insert can serve one channel at a time.** An insert already claimed elsewhere appears greyed out in the menu; free it by setting that channel back to None. Changing a channel's Analog Ref away from Mic/Instrument also releases its insert."),
                .text("Insert and Group are hidden on channels set to a line level — they have no meaning there. The original Maestro hid them in exactly the same way."),
            ]),
        ])
    }

    /// Mic Pre answers, shown only when an 8MicPre module is present. Source:
    /// User's Guide "Mic Pre Module FAQ" (p. 91).
    private static var micPreQuestions: HelpSection {
        HelpSection(id: .micPreQuestions, title: "Mic Pre questions", items: [
            HelpItem(title: "Does the Mic Pre module add 8 more channels?", blocks: [
                .text("No. It adds preamps to analog inputs you already have, rather than channels of its own. If you have an 8-channel analog module in slot 1, adding a Mic Pre gives those same eight inputs high-quality preamps internally instead of needing external ones. Whether each channel is used as line level or as a mic preamp is the **Analog Ref** setting on the Input tab."),
            ]),
            HelpItem(title: "What are the four ¼\" inputs on the module for?", blocks: [
                .text("High-impedance sources — electric guitar, bass, keyboards — so you can plug them in directly instead of using an adapter into the XLR input. Select **Instrument** as that channel's Analog Ref to enable them. There are four jacks, so Instrument is offered on channels 1–4 only."),
            ]),
            HelpItem(title: "Can I give the inserts my own names?", blocks: [
                .text("Yes — **Device Settings › Cards**. Name an insert after whatever is patched into it and that name appears wherever the insert can be chosen. Names belong to the insert rather than to a channel, so one rename shows up on every channel. Clear a field to go back to \"Insert 1\", \"Insert 2\" and so on."),
            ]),
            HelpItem(title: "What are the Inserts for, and where is the insert point?", blocks: [
                .text("They are hardware inserts for the preamps, for patching in outboard equipment such as a compressor or EQ. The insert point is **after the preamp and high-pass filter and before A/D conversion**. Inserts appear only on channels set to Mic or Instrument. The Send is always live once an insert is selected, so leaving **In** disengaged gives you an analog direct out."),
            ]),
            HelpItem(title: "Which modules can the Mic Pre be paired with?", blocks: [
                .text("It needs a module with at least 8 channels of analog **input** to attach to. The 2x6 analog card and the 16 Digital In + 16 Analog Out card do not have them, so the preamps have nothing to connect to. Maestro will not offer Mic or Instrument on a pairing that cannot support them."),
            ]),
        ])
    }

    private static var routing: HelpSection {
        HelpSection(id: .routing, title: "Routing", items: [
            HelpItem(title: "What do Reset Routing and Identify do?", blocks: [
                .text("**Reset Routing** is on the Input Routing and Output Routing pages. It puts that page back to its default: on Input Routing each software input records the matching hardware input, and on Output Routing each software output goes to the matching hardware output. Maestro asks before it changes anything. With a Symphony I/O, only the page you are on is reset. With converters only, it resets both pages."),
                .text("**Identify** is on the Output Routing page. It lights every light on the Symphony I/O's front panel so you can tell which unit is which, for example in a rack. Click it again to turn the lights off; quitting Maestro also turns them off. With two Symphony I/Os at 64 channels there is one button for each unit, **Identify A** and **Identify B**."),
            ]),
            HelpItem(title: "In what order are the Mac's channels?", blocks: [
                .text("In Apogee's order, over USB, ThunderBridge and PCIe alike: every analog input of the card in slot 1, then of the card in slot 2, then slot 1's digital inputs (AES, then optical), then slot 2's. The outputs follow the same rule. With an 8x8 with ADAT in slot 1 and an A16 in slot 2, Mac inputs 1-24 are Line 1-24 and 25-32 are ADAT 1-8."),
                .text("ThunderBridge and PCIe drivers before build 150 laid the channels out card by card instead (all of slot 1, then slot 2). The first time Maestro finds the new driver on a setup whose channels moved, it puts the routing whose channels moved back to its defaults once, on ThunderBridge and USB: Input Routing if the inputs moved, Output Routing (including routes from the mixers and speaker sets) if the outputs moved. With an 8x8 in slot 1 and an A16 in slot 2 only the inputs move, so only Input Routing is reset. A message says what moved, and a note stays on the Routing pages until you dismiss it. Where the outputs moved, some Mac outputs play on different hardware outputs, so check your levels and speakers before playing loud material."),
                .text("Routing presets saved before then are marked **(old channel order)** and cannot be applied where their channels moved; delete them, or set the routing again and save it under the same name. A setup file saved before then restores everything except its routing, and says so."),
            ]),
        ])
    }

    private static var mixer: HelpSection {
        HelpSection(id: .mixer, title: "Mixer", items: [
            HelpItem(blocks: [
                .text("The first time you open this version, Input Routing, Output Routing and both mixers go back to their defaults."),
            ]),
            HelpItem(title: "When do I hear an input directly through the Symphony?", blocks: [
                .text("**Only when its strip is unmuted in a mixer that feeds an output in Output Routing.** That is the whole rule, and there is no other setting for it."),
                .text("**By default no mixer feeds an output.** Every hardware output plays the matching software output directly (**1-2 → Line 1/2** and so on), so you hear your Mac's audio directly and you hear your inputs only through your DAW."),
                .text("To hear an input without the delay of going through the Mac, route **Mixer 1** or **Mixer 2** to the output you listen on in **Output Routing**, then use that mixer's strips: an unmuted strip is heard, a muted one is not. Your Mac's audio then reaches that output through the mixer's **Software Return**. On the Mixer page, **Mix 1** and **Mix 2** choose which mixer is shown."),
                .text("An output fed from a mixer is silent for a few seconds when Maestro connects, while the status bar shows **Restoring mixer and routing…**; over USB so is a headphone that follows it."),
            ]),
            HelpItem(title: "How do I move several strips at once?", blocks: [
                .text("Shift-click a strip (its name or anywhere on it) to select it. Shift-click another strip to add everything between the two; Shift-Command-click removes one, and Shift-Command-Option-click removes a range. Option-drag from an empty spot, above or below the strips, draws a box around them. Edit › Select All (Command-A) selects every visible strip. Edit › Deselect All (Shift-Command-A), Shift-D, Escape, a click on an empty spot or a plain click on a strip that is not selected clears the selection. Typing a value into a selected strip sets every selected strip to it; dragging moves them together."),
                .text("Move or type on one selected fader or pan value to move them all while keeping their spacing. Software Return and Master can join the selection. Mute and Solo apply to every selected strip. Option with a selection applies to that selection; with no selection it applies to every strip. Double-click a fader for 0 dB or a pan knob for centre. Click a fader or pan number to type, then press Tab for the next strip."),
            ]),
            HelpItem(title: "How do I record while hearing myself with no delay?", blocks: [
                .text("Monitor the input through a Symphony mixer instead of through your DAW. As in Apogee's guide:"),
                .bullet("1. In your DAW", "turn off software monitoring (in Logic Pro: Settings › Audio › General, **Software Monitoring** off), so you do not also hear the input late through the DAW. Send the DAW's output to **Out 1-2**."),
                .bullet("2. In Output Routing", "route **Mixer 1** to the output you listen on, for example **Line 1/2** (and **Mixer 2** to another output for a second mix)."),
                .bullet("3. For headphones", "set the headphone's source on the **Output** page to that output, for example Line 1-2."),
                .bullet("4. In the Mixer", "leave **Software Return** on **Out 1-2** and its fader and **Master** at 0 dB. Play the session: you hear your DAW's mix through the mixer."),
                .bullet("5. Bring up the input", "plug into Line In 1 and raise the **Line 1** strip until it sits well with the playback, then record."),
                .text("One mixer is enough for most sessions; use the second when a performer needs a different balance."),
                .link("Apogee: recording with the Maestro low-latency mixer", URL(string: "https://knowledge.apogeedigital.com/symphony-i/o-instructions-to-record-with-the-maestro-low-latency-mixer")!),
            ]),
            HelpItem(title: "What does the menu under Software Return do?", blocks: [
                .text("It chooses what comes **into** that mixer from your Mac: which pair of your Mac's outputs the **Software Return** strip carries. It is an input choice. It does not send anything to a hardware output; where a mixer is heard is set only in **Output Routing**, by routing **Mixer 1** or **Mixer 2** to an output."),
                .bullet("1-2", "what your Mac plays on outputs 1-2: Music, Spotify, a browser, or your DAW's main mix. This is the default, and for most uses it is the one to leave it on."),
                .bullet("3-4 and up", "what an application plays on that pair. Only an application that lets you choose its output, such as a DAW, can play there. Use it when the DAW sends a separate mix on that pair, for example a headphone mix for a performer: the mixer blends that mix with the live inputs, while your speakers go on playing the main mix on 1-2."),
                .text("Each mixer has its own choice, so Mixer 1 and Mixer 2 can carry two different mixes from the DAW. The Software Return meter shows the pair you chose: with a pair nothing is playing on, it stays dark and the mixer adds nothing from your Mac."),
            ]),
            HelpItem(title: "Why doesn't the Software Return fader or mute, or Master, change what I hear?", blocks: [
                .text("**By default nothing is fed from a mixer,** so the **Mixer** page does nothing until you route **Mixer 1** or **Mixer 2** to an output in **Output Routing**. An output fed straight from a software output pair (for example **1-2 → Line 1/2**, the default) plays your Mac's audio directly, and Software Return, Master and the input strips do not touch it."),
                .text("Route **Mixer 1** or **Mixer 2** to that output instead and the mixer's controls apply: your Mac's audio then arrives through **Software Return**, together with the hardware inputs that are unmuted, and **Master** sets the level."),
                .text("Inputs removed from **Input Routing** are hidden from the mixer until you route them again. Their saved mixer settings stay with the input."),
                .text("After an update that changes mixer headroom, saved faders above 0 dB may be set to 0 dB. The previous values are kept, and the update now plays levels above 0 dB as Apogee's did."),
                .text("**Mixer 1 and Mixer 2 are separate.** A control on Mixer 2 changes only the outputs fed from Mixer 2. If no output is fed from Mixer 2 in Output Routing, nothing on Mixer 2 can be heard, and the same goes for Mixer 1."),
                .text("**Over USB,** see **The Mixer over USB** further down for how Software Return mute behaves with the two Symphony audio devices."),
            ]),
        ])
    }

    /// The mixer behaves differently over USB than the page implies, and the
    /// difference is not obvious from looking at it. Worth stating plainly
    /// rather than letting people conclude a fader is broken.
    /// What the mixer controls do on the USB path.
    ///
    /// Nothing passes through a mixer until one is routed to an output: the
    /// default is every output direct (the helper programs USB ch n straight to
    /// output n). Software Return level, mute and solo and the Master level are
    /// written to the Symphony's own mixer (strips 32 and 33) and reach only
    /// the outputs fed from that mixer in Output Routing. Software Return mute
    /// is also applied by the proxy to USB channels 1-2 of "Maestro USB" (the
    /// proxy renders that device), but only while a mixer that takes the 1-2
    /// pair feeds an output (`USBHelperSoftwareReturn`). Solo and the fader
    /// stay on the unit only (the proxy holds its level at 0 dB and has no
    /// solo). Software Return has no pan.
    private static var mixerUSB: HelpSection {
        HelpSection(id: .mixerUSB, title: "The Mixer over USB", items: [
            HelpItem(blocks: [
                .text("Over USB, as over ThunderBridge, **nothing passes through a mixer until you route Mixer 1 or Mixer 2 to an output** in Output Routing. By default every output plays the matching channels of your Mac's playback directly. Once a mixer feeds an output, your Mac's audio reaches it through that mixer's **Software Return** (the pair chosen in its source menu, **Out 1-2** unless you change it). If the status bar asks you to reinstall Maestro with USB support, the mixers are not set until you do."),
                .bullet("An input is heard only through a mixer", "its strip must be unmuted in a mixer that feeds an output in Output Routing. With no mixer routed, you hear inputs only through your DAW."),
                .bullet("Software Return mute and solo belong to each mixer", "muting or soloing Software Return on **Mixer 1** leaves **Mixer 2** as it was, and the reverse, as in Apogee's Maestro."),
                .bullet("Software Return mute with Maestro USB", "Maestro mutes Software Return in that Symphony mixer. While a mixer that uses the **Out 1-2** pair feeds an output, and Software Return is muted on every such mixer, it also silences channels 1-2 of what you play through **Symphony I/O : Maestro USB**, wherever they go. Unmuting on either of those mixers clears that. With no mixer routed to an output, Software Return mute never touches an output that plays your Mac's audio directly."),
                .bullet("Software Return mute with USB Audio", "only the Symphony's mixer is muted, so it silences channels 1-2 only on outputs fed from that mixer in Output Routing."),
                .bullet("Software Return solo and the Software Return and Master faders", "are done by the Symphony's own mixer alone, with either device. Soloing Software Return silences the other strips in that mixer; there is no software solo."),
                .bullet("They change only outputs that are fed from that mixer", "set this in Output Routing. An output fed from somewhere else, such as a headphone output on its own source, does not change (except the Maestro USB mute above, which silences channels 1-2 of your playback wherever they go)."),
                .bullet("Software Return and Master are each one stereo fader", "it is drawn with a left and a right handle, and the two always move together, as in Apogee's Maestro. Software Return has a fader, mute and solo, and no pan. This is the same over ThunderBridge."),
                .bullet("Software Return meter", "it shows the signal before the fader. With **Maestro USB** and the default 1-2 source it drops to silence while Maestro is silencing channels 1-2 (see the mute above)."),
                .bullet("Master meter", "it follows that mixer's Software Return fader and mute and its Master fader."),
                .bullet("The headphone knobs control their own outputs", "independently of the mixer."),
                .bullet("Hardware input faders affect the live inputs being monitored", "not your Mac's playback."),
            ]),
        ])
    }

    private static var volumeKeys: HelpSection {
        HelpSection(id: .volumeKeys, title: "Volume keys", items: [
            HelpItem(title: "What do the Mac's volume and mute keys control?", blocks: [
                .text("The output chosen under **Device Settings › Volume Keys › Audio Output**: **Speaker**, **Headphone 1** or **Headphone 2**, as in Apogee's software. Speaker is the default, or Headphone 1 if the outputs are set to Line. The choice is kept for each Symphony I/O. On ThunderBridge and PCIe Maestro puts it in place when it opens: after the Mac restarts, until Maestro is open, the keys control the speaker, or Headphone 1 if the outputs are set to Line. A unit without an analog output card offers the two headphones only."),
                .text("The Speaker entry shows how many channels the format chosen under the **Speaker** knob on the Output page (Analog Out Format) uses, for example **Speaker (2ch)** or **Speaker (6ch)**. When you set the format to **Line**, Audio Output changes to **Headphone 1** by itself, as in Apogee's software, because line outputs have no level control. When you leave Line it goes back to the output it was on before, unless you chose another Audio Output yourself in the meantime. In Line mode the Speaker entry reads **Speaker (0ch)**: if you choose it, the volume keys do not change a level, and the mute key still mutes the speaker output, except that while Maestro does not yet know the speaker level (the driver has just started in Line) the mute key is put back."),
                .text("With two Symphony I/Os at 64 channels, **Peripheral** chooses which unit the keys control, and **Audio Output** then lists that unit's outputs."),
                .text("Over USB the keys work when **Symphony I/O : Maestro USB** is the Mac's output device (see **Choosing your USB output** for why there are two USB devices). There, turning up and unmuting wait up to three seconds after you change **Audio Output**. On ThunderBridge and PCIe, turning up and unmuting wait about five seconds after the Mac starts or wakes, the Symphony reconnects, the Ports setting changes between 32 and 64 channels, the VBus size changes, or macOS restarts its audio, so that a louder volume macOS saved earlier is not sent to the Symphony. Over USB, for five seconds after the helper starts, the unit is replugged or recovers, or the audio plug-in connects, only changes towards quieter are taken from the Mac, including repeated restores. On every connection, turning down and muting work at once."),
                .text("With converters only (AD-16X, DA-16X, DD-16X or Rosetta) there is no speaker or headphone. There, **Audio Output** offers **Mixer 1 level**, where the keys turn Mixer 1 down and up and mute it (heard only on outputs you feed from Mixer 1 in Output Routing), and **None**, where the keys do nothing and Mixer 1 is left at full level. This level control for converters is our own addition; Apogee's software had no volume control for them."),
            ]),
        ])
    }

    private static var vbus: HelpSection {
        HelpSection(id: .vbus, title: "VBus", items: [
            // Text from MaestroCore so a test can check it against the
            // names the driver publishes.
            HelpItem(title: "What is VBus, and how do I send audio from one application to another?", blocks: VBusChannels.helpText.map { .text($0) }),
        ])
    }

    private static var usbOutput: HelpSection {
        HelpSection(id: .usbOutput, title: "Choosing your USB output", items: [
            HelpItem(blocks: [
                .text("Over USB your Mac lists two Symphony devices: **Symphony I/O : USB Audio** and **Symphony I/O : Maestro USB**. Both play through the same USB connection."),
            ]),
            HelpItem(title: "Why don't the volume keys work with Symphony I/O : USB Audio?", blocks: [
                .text("**USB Audio** is the Symphony's own USB device, run by macOS's standard USB audio driver. The Mac's volume keys and the volume slider only work on a device that offers macOS a volume control, and over USB the Symphony does not offer one."),
                .text("Apogee's software added one through an add-on to Apple's USB driver, which current macOS no longer loads. The only other way would be to change the Symphony's firmware, which Maestro does not do."),
            ]),
            HelpItem(title: "What is Symphony I/O : Maestro USB?", blocks: [
                .text("Maestro's answer to that: an output device that does have a volume control. Maestro turns the volume keys and the slider into the Symphony's own speaker or headphone level (see **Volume keys**), and passes your audio on to USB Audio. It has 16 outputs and no inputs."),
            ]),
            HelpItem(title: "When I'm recording, how should I set my input and output?", blocks: [
                .bullet("Input", "**Symphony I/O : USB Audio**; it is the only one with inputs."),
                .bullet("Output, if you want the volume keys", "**Symphony I/O : Maestro USB**. Passing your audio on adds about **1.3 ms** at 48 kHz, and Maestro USB reports it, so your DAW keeps recordings in time."),
                .bullet("Output, if you don't need the volume keys", "**Symphony I/O : USB Audio**, for the slightly lower latency."),
                .text("Most DAWs let you choose a different device for input and for output. Your DAW's buffer size matters far more than either choice. To hear yourself with no delay at all, monitor through the Symphony's Mixer (see **How do I record while hearing myself with no delay?** under **Mixer**). Apogee's guide explains buffer size and latency:"),
                .link("Apogee: Symphony I/O, understanding latency", URL(string: "https://knowledge.apogeedigital.com/symphony-i/o-understanding-latency")!),
            ]),
            HelpItem(title: "Can Maestro select my preferred one when I plug in?", blocks: [
                .text("Yes. Turn on **Automatically switch to Symphony when connected** in **App Settings › When a Device Connects**, then choose **Preferred USB output**: **Maestro USB** (the default, with the volume keys) or **USB Audio**. Maestro then makes it your Mac's output when you plug the Symphony in."),
            ]),
        ])
    }

    private static var interfaceMode: HelpSection {
        HelpSection(id: .interfaceMode, title: "Audio Interface Modes (AIM)", items: [
            HelpItem(blocks: [
                .text("This is set from the buttons on the front of the unit. The firmware doesn't expose it to the host, so it can't be changed from the app — Maestro shows the current mode in **Device Settings › Info**."),
            ]),
            HelpItem(title: "What do the different Audio Interface Modes (AIM) do?", blocks: [
                .text("The Symphony I/O runs in one of four modes, and only one at a time. The mode is shown in **Device Settings › Info**, but it can only be changed on the unit: push and hold the right-hand front-panel encoder, turn until the mode you want is on the display, then push the encoder again. The unit restarts into that mode."),
                .bullet("Symphony", "for a Symphony 64 ThunderBridge or PCIe card in a Thunderbolt or PCI equipped Mac. This is the mode Maestro\'s Thunderbolt support needs."),
                .bullet("Pro Tools HD", "for an Avid HDX, HD Native, HD Accel Core, HD Accel, HD Core or HD Process card with Pro Tools HD or Pro Tools Ultimate. Pro Tools HD 12.6 and later needs a DigiLink I/O license to use third-party interfaces."),
                .bullet("USB", "for use as a USB audio interface on any USB-equipped Mac. This is the mode the USB path here needs."),
                .bullet("Standalone", "for use as a standalone converter, with parameter control over USB."),
                .text("Maestro works in **Symphony** and **USB** modes. In Pro Tools HD mode the audio goes to the Avid card; Apogee's Maestro still set levels, formats and headphone routing over USB there, which this Maestro does not do yet. Maestro is not for Standalone mode."),
            ]),
        ])
    }

    private static var twoUnits: HelpSection {
        HelpSection(id: .twoUnits, title: "Two units & converters", items: [
            // Text from MaestroCore so a test can check it uses the
            // driver's Source menu names.
            HelpItem(title: "Can I connect more than one Symphony I/O?",
                     blocks: (PortSelection.helpText + SecondUnitHelp.lines).map { .text($0) }),
            HelpItem(title: "Does Maestro work with AD-16X, DA-16X or Rosetta converters?", blocks: [
                .text("Yes. These older Apogee converters connect to a ThunderBridge or Symphony 64 card with the same PC-32 cable. Maestro supports them as Apogee's software did."),
                .text("When the connected unit does not answer as a Symphony I/O, the driver asks each unit what it is, up to four units on each port, in cable order with the nearest unit first. Port 1's units take the first channels. Port 2's units continue after them, and only while **64 channels** is chosen. Each unit gets a letter, so the channels are named as in Apogee's software: **A Line 1** for the first unit, **C Line 1** for the third. **Device Settings › Info** lists every unit with its X-Symphony firmware. If a unit does not say what it is, Maestro shows a generic 32-channel layout."),
                .text("**Device Type.** A DD-16X and an AD-16X or DA-16X in Advanced Routing answer the same way, and so do the Rosetta 800 and Rosetta 200. For those units **Device Settings › Info** has a **Device Type** menu, named with the unit's port and unit number: choose the unit you have. Maestro remembers it for that unit's place on the cable."),
                .text("**Clock and firmware.** With converters, **Device Settings › Clock** offers **Internal** and **External**. Each unit needs X-Symphony firmware 2.7 or later; **Device Settings › Info** says so if one is older."),
                .text("**Routing.** As in Apogee's software, the ThunderBridge or PCIe card routes the converters, both ways. **Output Routing** sends any DAW output pair or mixer to any converter output pair, and **Input Routing** picks which converter inputs each DAW input pair records. Both start on the default placement: DAW channel 1 is the first unit's channel 1, and so on through the chain, with port 2's units included while 64 channels run. **Reset Routing**, on either page, puts both pages back on that default. Maestro remembers your routes for this chain of units and puts them back when you connect; a different chain starts from the default. Routing presets are kept per chain too."),
                .text("**Controls.** With a converter, the Symphony I/O settings are greyed out: the per-channel reference levels, Soft Limit and trims, the headphone knobs and the speaker-only buttons. These converters have no speaker or headphone outputs. Levels and the converter's own routing mode are set on its front panel. With a Symphony I/O on port 1 and converters on port 2, while **64 channels** is chosen **Device Settings › Info** lists the converters as **Port 2 Unit 1**, **Port 2 Unit 2** and so on."),
                .text("**Volume.** The speaker knob, called **Volume** on the Output page, and the Mac's volume and mute keys turn **Mixer 1** up and down and mute it. As in Apogee's software, no mixer is routed to the converters by default (every DAW output goes straight to its converter output), so route **Mixer 1** to an output pair in **Output Routing** for these to have something to control; outputs routed directly do not follow it. The Master fader in the Mixer is separate. To stop the keys from doing this, choose **None** under **Device Settings › Volume Keys › Audio Output**. This level control is our own addition; Apogee's software had none for converters."),
                .text("Maestro does not send Symphony I/O settings to a converter on its own. The optical format, S/PDIF coax and per-card clock settings belong to the Symphony I/O's option cards, so they do not apply to these converters, as in Apogee's original software."),
                .text("If only some outputs play, check the converter's own **routing mode** on its front panel first: in its advanced routing mode the converter decides which incoming channels reach which outputs. Then check Maestro's **Output Routing**."),
            ]),
        ])
    }

    /// Answers to things the hardware does that the screen cannot explain, drawn
    /// from the Symphony I/O User's Guide "Troubleshooting - FAQ" (p. 83) and the
    /// Meters and Output pages (pp. 57, 77).
    ///
    /// Every step here was checked against THIS app rather than copied from the
    /// Guide: the Guide's troubleshooting list refers to Apogee's own Maestro and
    /// mentions controls we do not have. Anything we cannot back is left out
    /// rather than approximated.
    private static var troubleshooting: HelpSection {
        HelpSection(id: .troubleshooting, title: "Troubleshooting", items: [
            HelpItem(title: "What are Maestro's processes in Activity Monitor?", blocks: [
                .text("**Maestro** is the app itself. It runs only while it is open."),
                .text("**com.danielraffel.maestro.thunderbridge** is Maestro's ThunderBridge driver. macOS runs it while a ThunderBridge or Symphony 64 PCIe card is in the Mac, whether or not Maestro is open: it is what carries your audio and the volume keys over the card."),
                .text("**MaestroVolumeProxy** is the USB helper, installed with USB support. It runs in the background so that **Symphony I/O : Maestro USB** works and the Mac's volume keys reach the Symphony over USB, and it mutes the Symphony while the Mac sleeps. It uses almost nothing when no Symphony is on USB."),
                .text("The uninstaller removes them (see **Uninstalling**). macOS may ask you to confirm driver removal."),
            ]),
            HelpItem(title: "The status bar says \"No hardware detected\" or \"Bus error\".", blocks: [
                .text("The ThunderBridge or PCIe card is there, but the Symphony on its port is not answering. **No hardware detected** means nothing was found on the port: no unit is connected to it, or the unit is off. **Bus error** means a unit was found and the link to it failed. With 64 channels the message names the port. The ⓘ button next to it shows the whole message."),
                .text("Verify that the hardware is properly connected and powered on: the PC-32 cable from the Symphony's main port to the card's port, the unit's power, and **Symphony** mode on its front panel. Clicking the message in the status bar is the same as **Rescan**."),
            ]),
            HelpItem(title: "Symphony is powered on and connected, but Maestro can't see it.", blocks: [
                .text("Use **Rescan** (in the File menu, or ⌘R). It re-establishes the link between Maestro and the hardware, re-resolves which audio device the unit is, and rebuilds the audio path — which is what actually matters after the unit has been unplugged and replugged, or has re-enumerated on a different port. It does not change any of your settings."),
                .text("If Rescan does not find it, check the front panel for an exclamation mark (!) — that means the unit is not talking to the Mac at all, and the cable is the place to start rather than Maestro."),
            ]),
            HelpItem(title: "Maestro says \"Waiting for macOS audio to respond\" after an update.", blocks: [
                .text("Installing an update restarts macOS's audio system, which can be busy for a minute or two. With USB support installed, its helper is started before Maestro reconnects. Maestro opens straight away and connects to your Symphony as soon as macOS audio answers; you don't need to do anything. If it is still waiting after about five minutes, restart the Mac."),
            ]),
            HelpItem(title: "I'm not getting any audio — what should I check?", blocks: [
                .bullet("Look at the front panel", "an exclamation mark (!) there means the unit is not talking to the Mac properly. Over USB, unplug and replug the USB cable."),
                .bullet("Check the output device", "Symphony needs to be selected as the output device in macOS and in your audio software."),
                .bullet("Check the monitor controls", "on the Output tab, make sure the outputs are not muted or turned down, and if you are using speaker sets, that the set you are listening to is the selected one."),
                .bullet("Try Reset Routing", "on both the Input Routing and Output Routing tabs — this puts the signal path back to its default."),
                .text("Note that without a Mic Pre module the analog inputs are **line level only**. Microphones plugged straight in will be far too quiet, because there is no preamp in the path."),
            ]),
            HelpItem(title: "Why doesn't my ThunderBridge show up?", blocks: [
                .text("Two things have to be true. The unit's **interface mode** must be set to **Symphony** on the front panel — Thunderbolt only works in that mode, and **USB** mode is what the USB path needs. And the Thunderbolt connection has to be a real one all the way to the Mac."),
                .text("ThunderBridge is a Thunderbolt 2 card, so on a modern Mac it needs Apple's [Thunderbolt 3 (USB-C) to Thunderbolt 2 Adapter](https://www.apple.com/shop/product/myh93am/a/thunderbolt-3-usb%E2%80%91c-to-thunderbolt-2-adapter). Plug that adapter **directly** into the Mac, or into a dock that genuinely supports Thunderbolt. Many USB-C hubs and docks carry USB only — they will not pass Thunderbolt, and the card simply never appears."),
                .text("**System Information** tells you which half is failing — open **System Settings › General › About** and click **System Report**."),
                .text("Under **Hardware › Thunderbolt/USB4**, look for **Symphony64 | ThunderBridge**. A healthy one reads *Vendor Name: Apogee Electronics*, *Mode: Thunderbolt*, and *Status: Device connected* under its upstream port. If the entry is not there at all, the Thunderbolt enclosure is not enumerating; check the Thunderbolt cable, Apple adapter or dock, and power before troubleshooting Maestro."),
                .text("If it is listed, check **Hardware › PCI** for **pci19c2,2200** (ThunderBridge) or **pci19c2,2100** (the older Symphony 64 PCIe card). A healthy entry reads *Link Status: Link up* and **Driver Installed: Yes**. *Link up* with **Driver Installed: No** means the PCI function reached the Mac but the Maestro driver has not attached; check Driver Extension approval and include the PCI identifier when reporting the problem."),
                .text("The physical link has a second, separate half: connect the ThunderBridge's **DC power supply**, then connect the Symphony I/O's **Primary/Main Symphony** port directly to **ThunderBridge Port 1: Ch 1–32** with the PC-32 cable. Set the I/O to **Symphony** mode. A second unit goes on **Port 2**; see \"Can I connect more than one Symphony I/O?\"."),
                .text("If the ThunderBridge or PCIe card appears but no audio device appears, the PCI function is enumerating but the driver has not attached. Check the power, PC-32 cable, Port 1/Main connection, and Symphony mode. The first installation on a Mac may also need approval under **System Settings › General › Login Items & Extensions**. In the default **By App** view, open **Maestro → Driver Extension** and make sure its switch is on. In **By Category**, the extension is named **Symphony Thunderbridge**. If macOS asks for approval, follow its prompt, then relaunch Maestro. The Symphony 64 PCIe card uses the same banner, driver status, and approval flow as ThunderBridge."),
                .text("**Device Settings › Info** reports the ThunderBridge driver as **Enabled**, **Installed — approval required**, **Installed — disabled**, or **Ready — no ThunderBridge connected**. When it is installed but not enabled, use **Open Driver Settings…** in that row; it opens macOS's Driver Extensions panel directly. Maestro refreshes this state while the app is in the foreground and when you return from System Settings. If activation says a restart is required, restart macOS before trying Thunderbolt again."),
                .text("After a driver update, macOS can keep the previous driver on the ThunderBridge although it already lists the new one. Once Maestro has reopened after the update, **unplug the ThunderBridge cable and plug it back in**. Audio stops for a few seconds, and a muted output stays quiet while macOS restores its monitor controls. You can instead **turn the Maestro driver off and on** in **System Settings › General › Login Items & Extensions › Driver Extensions**, or **restart your Mac**. Maestro shows a banner at the top of the window until the new driver is running, and **Device Settings › Info** says which driver build is still running."),
            ]),
            HelpItem(title: "How do I reset Symphony I/O to its factory defaults?", blocks: [
                .text("The full hardware reset is done on the unit itself, not from here. Start with Symphony turned off, hold down the **left** front-panel encoder knob, and turn the unit on. When the display reads \"Reset All But Cal No\", turn the **right** encoder to select **Yes** and push it in. That resets everything except the converter calibration. To clear calibration as well, first turn the **left** encoder to change \"Reset All But Cal\" to \"Reset All\", then use the right encoder to select Yes."),
                .text("Maestro also has smaller resets that do not need a power cycle: **Reset Defaults** on the Input and Output tabs, **Reset Trims** on either tab, and **Reset Routing** on each routing tab. The Input and Output resets offer the same choice the front panel does — one that keeps your trims, because trims are calibration data, and one that clears them too."),
            ]),
            HelpItem(title: "When and how should I use diagnostics?", blocks: [
                .text("Use it when something doesn't work and you can make it happen again: your Symphony or converter isn't found, there's no sound, your DAW freezes or goes silent when it selects the device, audio drops out or crackles, or a control or the volume keys do nothing. Also use it when the developer asks you to."),
                .text("**1.** Update Maestro to the latest version (**Maestro › Check for Updates…**). **2.** Turn on **Diagnostics** in **App Settings › Diagnostics & Feedback**. **3.** Do what causes the problem, for example open your DAW and press play, then wait until it goes wrong. A minute or two is usually enough; it stops by itself after an hour. If Maestro doesn't find your Symphony or converter, or it shows as connected but nothing works, turn the unit off and on again while diagnostics is on. **4.** Press **Stop Diagnostics** in the red bar at the top of the window. Maestro saves a text file to your Desktop."),
                .text("Maestro then asks whether to email it, attached, to the developer to help diagnose the problem. You can tick what hardware you have and how it is connected, describe what is and isn't working, link an existing GitHub issue, and leave your email so we can reply; all are optional. Nothing is sent until you press **Agree and Send**. Diagnostics are never posted publicly, so please don't attach the file to a GitHub issue. If sending doesn't work, email the file to \(DiagnosticsRecorder.sendTo)."),
                .text("It records what Maestro, the USB helper and the driver are doing, and checks what is installed, including leftover Apogee software. It includes details about this Mac. We remove names, serial numbers and network addresses as best we can. It cannot see inside your DAW."),
            ]),
            HelpItem(title: "What should I include when I report a problem?", blocks: [
                .text("Open **Maestro › About Maestro** and click the copy button next to the version. That copies one block covering both halves of the picture — what hardware is attached (model, mode, both I/O modules, firmware) and what software is running (app version and build, macOS, whether audio is going over Thunderbolt or USB, and which driver extension is registered). Paste it into your report along with what you did and what happened."),
                .text("The same two blocks are in **Device Settings › Info** and **App Settings › About** if you would rather read them on screen."),
            ]),
        ])
    }

    private static var apogeeDrivers: HelpSection {
        HelpSection(id: .apogeeDrivers, title: "Apogee's original drivers", items: [
            HelpItem(title: "macOS keeps warning me about a \"Legacy System Extension\" from Apogee Electronics.", blocks: [
                .text("That warning is not about this app. It comes from Apogee's own older software, which installed a kernel extension that macOS still loads at startup. Maestro is not supported alongside it: remove it with **Uninstall** in Apogee's Symphony I/O installer, restart your Mac, then reinstall Maestro (see the next question)."),
                .text("If an **Apogee Electronics** entry is still listed under **App Background Activity** in **System Settings › General › Login Items & Extensions** afterwards, switch it off. Nothing here depends on it."),
            ]),
            HelpItem(title: "Can I keep Apogee's original drivers installed?", blocks: [
                .text(originalDriversAnswer),
                // The installer's steps, in its words (ApogeeDriverConflict.fixSteps).
            ] + ApogeeDriverConflict.fixSteps.enumerated().map { .text("\($0.offset + 1). \($0.element)") } + [
                .text(originalDriversAfterword),
                .manualApogeeRemoval,
                .text("\(OriginalApogeeDrivers.communityNote) "
                    + "[\(OriginalApogeeDrivers.communityIssueURL.absoluteString)]"
                    + "(\(OriginalApogeeDrivers.communityIssueURL.absoluteString))"),
            ]),
        ])
    }

    private static var uninstalling: HelpSection {
        HelpSection(id: .uninstalling, title: "Uninstalling", items: [
            HelpItem(blocks: [
                .text("Run this command in Terminal to remove the app, the audio plug-in and the background service."),
                .command(uninstallCommand),
                .text("Confirm the removal if macOS asks, and the script removes the ThunderBridge driver. If automatic removal fails, the script tells you how to remove the driver in System Settings. The script stops before making changes if Apogee's driver and Maestro's are both running."),
                .text("The script keeps your Maestro settings in `~/Library/Preferences/com.danielraffel.maestro.plist` so reinstalling restores your setup. To delete those settings, run this command as your usual user."),
                .command("defaults delete com.danielraffel.maestro"),
            ]),
        ])
    }

    private static var about: HelpSection {
        HelpSection(id: .about, title: "Supported hardware", items: [
            HelpItem(blocks: [
                .bullet("Macs", "Apple Silicon Macs with macOS 26 (Tahoe) or later. Intel Macs are not supported."),
                .bullet("Interface", "[Apogee Symphony I/O MK I](https://knowledge.apogeedigital.com/symphony64-pcie-thundebridge-users-guide-documentation-and-downloads-0), one unit or two."),
                .bullet("Connections", "Apogee [ThunderBridge and the Symphony 64 PCIe card](https://knowledge.apogeedigital.com/symphony64-pcie-thundebridge-users-guide-documentation-and-downloads), and USB."),
                .bullet("I/O modules", "8x8 AES/OPT, 8x8 AES, 8x8 OPT, 16x16 Analog In/Out, 16 Analog In / 16 Digital Out, 16 Digital In / 16 Analog Out, 2x6 and 8MicPre ([Apogee's list](https://knowledge.apogeedigital.com/can-mkii-i/o-modules-be-used-in-the-older-symphony-i/o))."),
                .bullet("Converters", "[AD-16X](https://www.apogeedigital.com/pdf/ad16x_usersguide.pdf), [DA-16X](https://apogeedigital.com/pdf/da16x_usersguide.pdf) and [Rosetta 800](https://apogeedigital.com/pdf/rosetta800_usersguide.pdf), on a ThunderBridge or Symphony 64 PCIe card."),
                .text("**Connection types**, **I/O modules** and **Two units & converters** have the details."),
            ]),
        ])
    }

    private static var feedback: HelpSection {
        HelpSection(id: .feedback, title: "How to report a bug", items: [
            HelpItem(blocks: [
                .text("**Please send a diagnostics report with every bug.** It records what Maestro and the driver were doing when it went wrong. With it we can investigate; without it we are usually guessing."),
                .bullet("1. Report it", "[open an issue on GitHub](\(FeedbackLinks.reportBug.absoluteString)) that says what happened, and copy its link."),
                .bullet("2. Record it", "switch on **Diagnostics** in **App Settings › Diagnostics & Feedback**, then do what causes the problem and wait until it goes wrong. A minute or two is usually enough."),
                .bullet("3. Send it", "press **Stop Diagnostics** in the red bar at the top of the window, answer the questions, paste the issue's link under **Existing GitHub issue**, and press **Agree and Send**. The report goes privately to the developer, so there is no need to attach it to the issue."),
                .text("Community support is available on [Gearspace](\(FeedbackLinks.discussion.absoluteString)) from fellow Apogee users."),
                .text("**Troubleshooting** has more on diagnostics under \"When and how should I use diagnostics?\". This is a community project, so please don't contact Apogee for support with it."),
            ]),
        ])
    }

    private static var donate: HelpSection {
        HelpSection(id: .donate, title: "How to donate", items: [
            HelpItem(blocks: [
                .text("If Maestro has been useful to you, consider making a donation to the SF-Marin Food Bank."),
                .link("Donate to the SF-Marin Food Bank", URL(string: "https://www.sfmfoodbank.org/")!),
            ]),
        ])
    }

    /// Apogee's own page for this unit. Worth linking because it documents the
    /// hardware — panels, specifications, calibration, module details — which
    /// this app does not reproduce, and because people reasonably want to know
    /// where the official software went. Both links were checked live; the
    /// Guide describes Apogee's Maestro, not this one, so that caveat is part
    /// of the sentence rather than a footnote.
    private static var apogeeDocsLink: String {
        let hub = "https://knowledge.apogeedigital.com/symphony64-pcie-thundebridge-users-guide-documentation-and-downloads-0"
        let guide = "https://knowledge.apogeedigital.com/hubfs/Users%20Guides%20and%20Documentation%20PDFs/Symphony%20IO%20-%20mk1/Symphony-IO-users-guide-july-2018.pdf?hsLang=en"
        let thunderBridgeGuide = "https://knowledge.apogeedigital.com/hubfs/Users%20Guides%20and%20Documentation%20PDFs/ThunderBridge-Quickstart-Guide_Web.pdf?hsLang=en"
        return "Apogee's [Symphony I/O mk1 documentation and downloads](\(hub)) page has everything "
            + "official, including the [Symphony I/O User's Guide (PDF)](\(guide)) and their final "
            + "Symphony System release. The [ThunderBridge Quick Start Guide (PDF)](\(thunderBridgeGuide)) "
            + "covers the ThunderBridge power, PC-32, and Thunderbolt connections. The Guide is the reference for the unit itself; its software "
            + "chapters describe Apogee's own Maestro, which is a different app than this one and no "
            + "longer runs on current macOS."
    }

    /// "Can I keep Apogee's original drivers installed?" Opens as the
    /// installer's dialog and the Device Settings warning do; the steps follow
    /// it (`ApogeeDriverConflict.fixSteps`), then `originalDriversAfterword`.
    /// The download is the same disk image the installer's warning page links to.
    private static var originalDriversAnswer: String {
        "No. If the installer or Maestro says: \"\(ApogeeDriverConflict.detected)\" Symphony Maestro "
            + "cannot be installed or updated while they are installed or loaded. \(ApogeeDriverConflict.crashRisk) "
            + "To fix this, use Apogee's own uninstaller, from "
            + "[Symphony I/O Release 5.5](\(OriginalApogeeDrivers.releaseDMGURL.absoluteString)):"
    }

    private static let originalDriversAfterword =
        "Then restart once more. Always use Apogee's latest installer: older ones leave parts behind. "
            + "\(OriginalApogeeDrivers.uninstallSideEffect) "
            + "**Device Settings** shows a warning at the top while Apogee's drivers are there, and lists what it "
            + "found. An update is stopped while Apogee's driver for the ThunderBridge or PCIe card is loaded, or "
            + "is in an Extensions folder; while it is loaded, Maestro also does not start or update its own "
            + "driver. If Maestro says both drivers are running, shut down your Mac and disconnect the "
            + "ThunderBridge or PCIe chassis, then start up again, before you remove anything. "
            + "If the warning is still there after all that, macOS may be keeping its own stored copy of "
            + "Apogee's kernel extension, which Apogee's uninstaller does not remove; that copy does not stop "
            + "an update, but it stops a first install; the installer then offers **Open Removal Guide**."

    private static let ioModulesLink =
        "Apogee's full list, with photos of each module's rear panel: [Supported I/O modules for Symphony I/O](https://knowledge.apogeedigital.com/can-mkii-i/o-modules-be-used-in-the-older-symphony-i/o)"

    /// Feedback line with inline, clickable links.
}

/// Each section's top edge in the Help page's scroll area.
private struct HelpSectionTops: PreferenceKey {
    static let defaultValue: [HelpSectionID: CGFloat] = [:]
    static func reduce(value: inout [HelpSectionID: CGFloat], nextValue: () -> [HelpSectionID: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}
