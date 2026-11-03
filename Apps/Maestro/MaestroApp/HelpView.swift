import SwiftUI
import AppKit
import MaestroCore

// MARK: - Help View

/// In-app rendered help. Deliberately succinct — the goal is to answer the
/// questions people actually ask (which USB device to pick, what works today,
/// how to uninstall) without reproducing the full user manual.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    /// Whether the 8MicPre module is installed (or simulated) in either slot.
    /// The Mic Pre section is the only conditional one — everything else applies
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

    private let uninstallCommand =
        "sudo /Applications/Maestro.app/Contents/Resources/uninstall.sh"
    private let feedbackEmail = "thegenerouscorp@gmail.com"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    whatItDoes
                    twoWaysToConnect
                    choosingUSBOutput
                    worksToday
                    mixerOverUSB
                    if micPreInstalled { micPreChannelStrip }
                    ioModules
                    interfaceMode
                    uninstalling
                    faq
                    if micPreInstalled { micPreFAQ }
                    testedAndFeedback
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Help is reference material people quote back in bug reports and forum
                // posts, so every paragraph is selectable, not just the uninstall command.
                .textSelection(.enabled)
            }
            Divider()
            footer
        }
        .frame(width: 580, height: 620)
    }

    // MARK: FAQ

    /// Answers to things the hardware does that the screen cannot explain, drawn
    /// from the Symphony I/O User's Guide "Troubleshooting - FAQ" (p. 83) and the
    /// Meters and Output pages (pp. 57, 77).
    ///
    /// Every step here was checked against THIS app rather than copied from the
    /// Guide: the Guide's troubleshooting list refers to Apogee's own Maestro and
    /// mentions controls we do not have. Anything we cannot back is left out
    /// rather than approximated.
    private var faq: some View {
        Section("Common questions") {
            HelpQuestion("How do I reset Symphony I/O to its factory defaults?") {
                Text("The full hardware reset is done on the unit itself, not from here. Start with Symphony turned off, hold down the **left** front-panel encoder knob, and turn the unit on. When the display reads \"Reset All But Cal No\", turn the **right** encoder to select **Yes** and push it in. That resets everything except the converter calibration. To clear calibration as well, first turn the **left** encoder to change \"Reset All But Cal\" to \"Reset All\", then use the right encoder to select Yes.")
                Text("Maestro also has smaller resets that do not need a power cycle: **Reset Defaults** on the Input and Output tabs, **Reset Trims** on either tab, and **Reset Routing** on each routing tab. The Input and Output resets offer the same choice the front panel does — one that keeps your trims, because trims are calibration data, and one that clears them too.")
            }
            HelpQuestion("Symphony is powered on and connected, but Maestro can't see it.") {
                Text("Use **Rescan** (in the View menu, or ⌘R). It re-establishes the link between Maestro and the hardware, re-resolves which audio device the unit is, and rebuilds the audio path — which is what actually matters after the unit has been unplugged and replugged, or has re-enumerated on a different port. It does not change any of your settings.")
                Text("If Rescan does not find it, check the front panel for an exclamation mark (!) — that means the unit is not talking to the Mac at all, and the cable is the place to start rather than Maestro.")
            }
            HelpQuestion("Can I choose a light or dark appearance?") {
                Text("In **Device Settings › Preferences**, set **Appearance** to **Auto**, **Light**, or **Dark**. Auto is the default and follows your Mac’s appearance. Light and Dark apply only to Maestro. Your choice is saved and takes effect immediately.")
            }
            HelpQuestion("Why doesn't the D/A meter move when I change a Trim?") {
                Text("The D/A meter shows the level **before** conversion, so the trim is applied after the point being measured. This is expected. To calibrate against a trim you need to measure the analog output itself with an external voltmeter — send a 1 kHz sine at the digital reference level and adjust the trim until the meter reads the analog reference you chose (1.228 V AC for +4 dBu).")
            }
            HelpQuestion("What does the Over indicator actually mean?") {
                Text("It lights when **three or more consecutive full-scale samples** occur. Three samples on their own are very unlikely to be audible — treat it as an early warning that the level should come down rather than as proof of damage.")
            }
            HelpQuestion("How long are Peaks and Overs held?") {
                Text("Both are set in **System Setup**, independently, to Off, 2 Seconds or Infinite. Infinite holds until you clear it. Clear held peaks and overs with **Clear Meters**, or by clicking the front-panel left-hand encoder — the unit shows \"Meters Cleared\" on its display.")
            }
            HelpQuestion("I'm not getting any audio — what should I check?") {
                bullet("Look at the front panel", "an exclamation mark (!) there means the unit is not talking to the Mac properly. Over USB, unplug and replug the USB cable.")
                bullet("Check the output device", "Symphony needs to be selected as the output device in macOS and in your audio software.")
                bullet("Check the monitor controls", "on the Output tab, make sure the outputs are not muted or turned down, and if you are using speaker sets, that the set you are listening to is the selected one.")
                bullet("Try Reset Routing", "on both the Input Routing and Output Routing tabs — this puts the signal path back to its default.")
                Text("Note that without a Mic Pre module the analog inputs are **line level only**. Microphones plugged straight in will be far too quiet, because there is no preamp in the path.")
            }
            HelpQuestion("Why does Audio MIDI Setup show Maestro USB with 0 inputs and 16 outputs?") {
                Text("That is intentional. **Symphony I/O : USB Audio** is the full 16-input/16-output device and is the one to choose when an audio application needs to record from the Symphony. **Symphony I/O : Maestro USB** is a separate 0-input/16-output output device used by Maestro's volume-control proxy, so the Mac's keyboard volume keys can adjust the Symphony's hardware output level.")
                Text("Choose **Maestro USB** as the macOS output for keyboard volume control, or choose **USB Audio** when you need inputs. This split is a limitation of the volume-control integration and does not indicate missing hardware inputs.")
            }
            HelpQuestion("Why do the outputs still say \"Line\" when I've set up speakers?") {
                Text("Output channels keep their **Line 1, Line 2 …** names in every mode. The Analog Out Format setting changes what the outputs *do* — whether the level knob, Mute, Dim and Sum to Mono apply to them — but it does not rename them. Apogee labels the first pair **Monitor Out** on the rear panel; that is a label on the hardware, not a name that changes on screen.")
            }
            HelpQuestion("What do the different Audio Interface Modes (AIM) do?") {
                Text("The Symphony I/O runs in one of four modes, and only one at a time. The mode is shown in **System Setup**, but it can only be changed on the unit: push and hold the right-hand front-panel encoder, turn until the mode you want is on the display, then push the encoder again. The unit restarts into that mode.")
                bullet("Symphony", "for a Symphony 64 ThunderBridge or PCIe card in a Thunderbolt or PCI equipped Mac. This is the mode Maestro\'s Thunderbolt support needs.")
                bullet("Pro Tools HD", "for an Avid HDX, HD Native, HD Accel Core, HD Accel, HD Core or HD Process card with Pro Tools HD or Pro Tools Ultimate. Pro Tools HD 12.6 and later needs a DigiLink I/O license to use third-party interfaces.")
                bullet("USB", "for use as a USB audio interface on any USB-equipped Mac. This is the mode the USB path here needs.")
                bullet("Standalone", "for use as a standalone converter, with parameter control over USB.")
                Text("Maestro works in **Symphony** and **USB** modes. In Pro Tools HD mode the unit belongs to the Avid card, so there is nothing here for this app to talk to. Standalone mode does expose parameter control over USB, but this app has not been tested against it.")
            }
            HelpQuestion("What should I include when I report a problem?") {
                Text("Open **Maestro › About Maestro** and click the copy button next to the version. That copies one block covering both halves of the picture — what hardware is attached (model, mode, both I/O modules, firmware) and what software is running (app version and build, macOS, whether audio is going over Thunderbolt or USB, and which driver extension is registered). Paste it into your report along with what you did and what happened.")
                Text("The same two blocks are on the **System Setup** page under **Device Info** and **Software Info** if you would rather read them on screen.")
            }
            HelpQuestion("Why doesn't my ThunderBridge show up?") {
                Text("Two things have to be true. The unit's **interface mode** must be set to **Symphony** on the front panel — Thunderbolt only works in that mode, and **USB** mode is what the USB path needs. And the Thunderbolt connection has to be a real one all the way to the Mac.")
                Text("ThunderBridge is a Thunderbolt 2 card, so on a modern Mac it needs Apple's [Thunderbolt 3 (USB-C) to Thunderbolt 2 Adapter](https://www.apple.com/shop/product/myh93am/a/thunderbolt-3-usb%E2%80%91c-to-thunderbolt-2-adapter). Plug that adapter **directly** into the Mac, or into a dock that genuinely supports Thunderbolt. Many USB-C hubs and docks carry USB only — they will not pass Thunderbolt, and the card simply never appears.")
                Text("**System Information** tells you which half is failing — open **System Settings › General › About** and click **System Report**.")
                Text("Under **Hardware › Thunderbolt/USB4**, look for **Symphony64 | ThunderBridge**. A healthy one reads *Vendor Name: Apogee Electronics*, *Mode: Thunderbolt*, and *Status: Device connected* under its upstream port. If the entry is not there at all, the Thunderbolt enclosure is not enumerating; check the Thunderbolt cable, Apple adapter or dock, and power before troubleshooting Maestro.")
                Text("If it is listed, check **Hardware › PCI** for **pci19c2,2200** (ThunderBridge) or **pci19c2,2100** (the older Symphony 64 PCIe card). A healthy entry reads *Link Status: Link up* and **Driver Installed: Yes**. *Link up* with **Driver Installed: No** means the PCI function reached the Mac but the experimental Maestro driver has not attached; check Driver Extension approval and include the PCI identifier when reporting the problem.")
                Text("The physical link has a second, separate half: connect the ThunderBridge's **DC power supply**, then connect the Symphony I/O's **Primary/Main Symphony** port directly to **ThunderBridge Port 1: Ch 1–32** with the PC-32 cable. Set the I/O to **Symphony** mode. The current Maestro driver supports one Symphony I/O as a fixed 32-channel device, so it does not provide the old Audio MIDI Setup **Source** menu (Port 1: 32ch / Port 1–2: 64ch). That menu belonged to the legacy driver when two interfaces could be combined.")
                Text("If the ThunderBridge or PCIe card appears but no audio device appears, the PCI function is enumerating but the driver has not attached. Check the power, PC-32 cable, Port 1/Main connection, and Symphony mode. The first installation on a Mac may also need approval under **System Settings › General › Login Items & Extensions**. In the default **By App** view, open **Maestro → Driver Extension** and make sure its switch is on. In **By Category**, the extension is named **Symphony Thunderbridge**. If macOS asks for approval, follow its prompt, then relaunch Maestro. The experimental PCIe-2100 build uses the same banner, driver status, and approval flow as ThunderBridge.")
                Text("System Setup › Software Info now reports the ThunderBridge driver as **Enabled**, **Installed — approval required**, **Installed — disabled**, or **Ready — no ThunderBridge connected**. When it is installed but not enabled, use **Open Driver Extensions…** in that row; it opens macOS's Driver Extensions panel directly. Maestro refreshes this state while the app is in the foreground and when you return from System Settings. If activation says a restart is required, restart macOS before trying Thunderbolt again.")
            }
            HelpQuestion("macOS keeps warning me about a \"Legacy System Extension\" from Apogee Electronics.") {
                Text("That warning is not about this app. It comes from Apogee's own older software, which installed a system extension that macOS still loads at startup — and running Apogee's uninstaller does not always remove the entry.")
                Text("To stop it: **System Settings › General › Login Items & Extensions**, find **Apogee Electronics** under **App Background Activity**, and switch it off. Nothing here depends on it.")
            }
            HelpQuestion("Where do I find Apogee's own documentation and software?") {
                Text(apogeeDocsLink)
            }
            HelpQuestion("How can I say thanks?") {
                Text("If Maestro has been useful to you, consider making a donation to the SF-Marin Food Bank.")
                Link("Donate to the SF-Marin Food Bank", destination: URL(string: "https://www.sfmfoodbank.org/")!)
            }
        }
    }


    /// Apogee's own page for this unit. Worth linking because it documents the
    /// hardware — panels, specifications, calibration, module details — which
    /// this app does not reproduce, and because people reasonably want to know
    /// where the official software went. Both links were checked live; the
    /// Guide describes Apogee's Maestro, not this one, so that caveat is part
    /// of the sentence rather than a footnote.
    private var apogeeDocsLink: AttributedString {
        let hub = "https://knowledge.apogeedigital.com/symphony64-pcie-thundebridge-users-guide-documentation-and-downloads-0"
        let guide = "https://knowledge.apogeedigital.com/hubfs/Users%20Guides%20and%20Documentation%20PDFs/Symphony%20IO%20-%20mk1/Symphony-IO-users-guide-july-2018.pdf?hsLang=en"
        let thunderBridgeGuide = "https://knowledge.apogeedigital.com/hubfs/Users%20Guides%20and%20Documentation%20PDFs/ThunderBridge-Quickstart-Guide_Web.pdf?hsLang=en"
        let md = "Apogee's [Symphony I/O mk1 documentation and downloads](\(hub)) page has everything "
            + "official, including the [Symphony I/O User's Guide (PDF)](\(guide)) and their final "
            + "Symphony System release. The [ThunderBridge Quick Start Guide (PDF)](\(thunderBridgeGuide)) "
            + "covers the ThunderBridge power, PC-32, and Thunderbolt connections. The Guide is the reference for the unit itself; its software "
            + "chapters describe Apogee's own Maestro, which is a different app than this one and no "
            + "longer runs on current macOS."
        return (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    /// Mic Pre answers, shown only when an 8MicPre module is present. Source:
    /// User's Guide "Mic Pre Module FAQ" (p. 91).
    private var micPreFAQ: some View {
        Section("Mic Pre questions") {
            HelpQuestion("Does the Mic Pre module add 8 more channels?") {
                Text("No. It adds preamps to analog inputs you already have, rather than channels of its own. If you have an 8-channel analog module in slot 1, adding a Mic Pre gives those same eight inputs high-quality preamps internally instead of needing external ones. Whether each channel is used as line level or as a mic preamp is the **Analog Ref** setting on the Input tab.")
            }
            HelpQuestion("What are the four ¼\" inputs on the module for?") {
                Text("High-impedance sources — electric guitar, bass, keyboards — so you can plug them in directly instead of using an adapter into the XLR input. Select **Instrument** as that channel's Analog Ref to enable them. There are four jacks, so Instrument is offered on channels 1–4 only.")
            }
            HelpQuestion("Can I give the inserts my own names?") {
                Text("Yes — **Device Settings › Insert Labels**. Name an insert after whatever is patched into it and that name appears wherever the insert can be chosen. Names belong to the insert rather than to a channel, so one rename shows up on every channel. Clear a field to go back to \"Insert 1\", \"Insert 2\" and so on.")
            }
            HelpQuestion("What are the Inserts for, and where is the insert point?") {
                Text("They are hardware inserts for the preamps, for patching in outboard equipment such as a compressor or EQ. The insert point is **after the preamp and high-pass filter and before A/D conversion**. Inserts appear only on channels set to Mic or Instrument. The Send is always live once an insert is selected, so leaving **In** disengaged gives you an analog direct out.")
            }
            HelpQuestion("Which modules can the Mic Pre be paired with?") {
                Text("It needs a module with at least 8 channels of analog **input** to attach to. The 2x6 analog card and the 16 Digital In + 16 Analog Out card do not have them, so the preamps have nothing to connect to. Maestro will not offer Mic or Instrument on a pairing that cannot support them.")
            }
        }
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
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Link("Send feedback", destination: URL(string: "mailto:\(feedbackEmail)")!)
                .font(.callout)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Sections

    private var whatItDoes: some View {
        Section("What Maestro does") {
            Text("A modern native control app for the Apogee Symphony I/O MK I — volume, mute, clock source, sample rate, optical format, routing, and metering. Built for macOS 26 (Tahoe) on Apple Silicon.")
        }
    }

    private var twoWaysToConnect: some View {
        Section("Two ways to connect") {
            bullet("Thunderbolt", "If you have the ThunderBridge card, Maestro uses it automatically for 32-channel I/O at the lowest latency, at any of the six sample rates from 44.1 up to 192 kHz. The driver loads only when the card is present.")
            bullet("USB", "Works on any supported Mac. Shows up as an audio device you can select from the volume menu or Audio MIDI Setup. Over USB, Maestro gives you 16 channels at 44.1, 48, 88.2 or 96 kHz. For 176.4 or 192 kHz, use the Thunderbolt card.")
        }
    }

    private var choosingUSBOutput: some View {
        Section("Choosing your USB output") {
            Text("Audio MIDI Setup shows two separate USB devices. **Symphony I/O : USB Audio** is the full 16-input/16-output device for recording and playback. **Symphony I/O : Maestro USB** is an output-only 0-input/16-output device: it exists so the keyboard volume keys can control Symphony's hardware volume through Maestro.")
            Text("Use **USB Audio** when you need the Symphony's inputs in an audio application. Use **Maestro USB** as the macOS output when you want keyboard volume control. Maestro can switch to Maestro USB automatically when you plug in; choose the preference in **Settings › Device › Preferred USB output**.")
        }
    }

    private var worksToday: some View {
        Section("What works today") {
            Text("Over Thunderbolt: volume, mute, clock source, sample rate, optical format (ADAT/S-PDIF), input routing, the **32-channel low-latency mixer** (SW Return, Master, and input strips — level, pan, mute, solo), and **hardware metering** are all working.")
            Text("**Output Routing is not confirmed.** The commands are sent, but the hardware gives back nothing we can read to verify them, and we have not measured the result on a unit. Treat that page as untested rather than broken — if you change a route and the audio does not move, that is a known gap and worth telling us about.")
        }
    }

    /// I/O modules, using Apogee's own product names rather than our internal
    /// enum labels. There are three different 16-channel modules and three
    /// different 8x8 variants, so "16x16" or "8ch Analog-Optical" on their own
    /// are ambiguous — a user cannot tell which card we think they have.
    /// The mixer behaves differently over USB than the page implies, and the
    /// difference is not obvious from looking at it. Worth stating plainly
    /// rather than letting people conclude a fader is broken.
    /// What the mixer controls actually do on the USB path.
    ///
    /// Measured on hardware 2026-09-11, after two earlier versions of this
    /// section got it wrong in opposite directions. Three separate observations:
    /// the Master fader does NOT change the headphones, the SW Return fader
    /// DOES, and the headphone knob does. Those pin the topology, and the code
    /// explains each one:
    ///
    /// - SW Return is applied in SOFTWARE, by the proxy, to the USB stream
    ///   before it reaches the hardware at all (`MixerViews.swift:763-764`
    ///   takes the `XPCDeviceConnection.setSwReturnLevel` branch on USB rather
    ///   than writing a mixer property). So it lands upstream of every hardware
    ///   tap and changes everything.
    /// - Master writes the hardware Mixer0 output level, and Mixer0's output is
    ///   routed only to the DAC (`MaestroVolumeProxy.c:1224-1225`). The
    ///   headphones are fed from their own crosspoint, so Master cannot reach
    ///   them.
    /// - Only USB channels 1-2 pass through the mixer. Step 4a of the same
    ///   routing block sends USB ch2-15 straight to the I/O board, "bypassing
    ///   mixer" in its own words.
    ///
    /// NOT measured: whether Master changes the main analog outputs. The routing
    /// says it should. That is stated as an expectation, not a fact.
    private var mixerOverUSB: some View {
        Section("The Mixer over USB") {
            Text("Over USB, **channels 1-2 of your Mac's playback pass through Symphony's hardware mixer** on the way to the main analog outputs. Channels 3 and up go straight to the outputs and do not touch the mixer at all.")
            bullet("SW Return changes everything you hear", "its fader, pan and mute are applied in software before the audio reaches the hardware, so they affect the speakers and the headphones alike.")
            bullet("The headphone knobs control their own outputs", "independently of the mixer.")
            bullet("The Master fader does not affect the headphones", "it sets the level of the mixer's own output, and the headphones are fed from a separate point. This is measured, not theory — if you are reaching for a headphone level, use SW Return or the headphone knob.")
            bullet("Hardware input faders affect the live inputs being monitored", "not your Mac's playback.")
            Text("**Which output device you pick matters.** All of this applies when macOS output is set to **Symphony I/O : Maestro USB**. On the standard **Symphony I/O : USB Audio** device your audio bypasses Maestro entirely, so the SW Return meter sits silent and its fader does nothing — that is expected, not a fault.")
        }
    }

    /// Mic Pre channel strip — shown ONLY when an 8MicPre module is present.
    /// Wording follows the Symphony I/O User's Guide, "Mic Pre Module Input Tab"
    /// (p. 56) and the Mic Pre Module page (p. 13).
    private var micPreChannelStrip: some View {
        Section("Your Mic Pre channel strip") {
            Text("Setting a channel's **Analog Ref** to **Mic** or **Instrument** routes it through the 8MicPre module and reveals the preamp controls. The preamps sit in front of the analog module's line inputs, so they always appear on **channels 1–8**.")
            bullet("Level Trim", "the gain of the mic pre — 0–85 dB at Mic level, 0–65 dB at Instrument.")
            bullet("Group", "controls the Level Trim of several inputs at once. Any level offset that exists before the inputs are grouped is preserved, so a group moves together rather than snapping to one value. Changing a channel's Analog Ref drops it back to Off.")
            bullet("Insert Select", "patches one of the eight rear-panel send/return pairs into the signal path. The insert point is after the mic pre and high-pass filter and before A/D conversion — the right place for a compressor or EQ.")
            bullet("Insert In", "enables the Insert Return. The Insert Send is always live once an insert is selected, so with In disengaged the send works as an analog direct out.")
            bullet("Polarity", "inverts the polarity of the input signal.")
            bullet("High Pass", "engages an 80 Hz high-pass filter.")
            bullet("48V", "48 volt phantom power, which condenser mics need.")
            Text("**48 V is available at Mic level only.** It is not a UI preference — the hardware itself refuses the command on a channel set to anything else, so the control is greyed rather than simply ignored. Switching a channel away from Mic turns phantom off on the way out.")
            Text("**Instrument is offered on channels 1–4 only.** The module has exactly four 1/4\" instrument jacks on its front panel, so there is nowhere to plug in an instrument on channels 5–8.")
            Text("**Each insert can serve one channel at a time.** An insert already claimed elsewhere appears greyed out in the menu; free it by setting that channel back to None. Changing a channel's Analog Ref away from Mic/Instrument also releases its insert.")
            Text("Insert and Group are hidden on channels set to a line level — they have no meaning there. The original Maestro hid them in exactly the same way.")
        }
    }

    private var ioModules: some View {
        Section("I/O modules") {
            Text("Symphony I/O (original) takes two module slots. Maestro reads the installed modules from the hardware and names them the way Apogee does:")
            bullet("8x8 AES/OPT", "8 analog in/out, AES and optical. A front-panel switch selects which digital section is active.")
            bullet("8x8 AES", "8 analog in/out with AES.")
            bullet("8x8 OPT", "8 analog in/out with optical (ADAT / S-PDIF / SMUX).")
            bullet("16x16 Analog In/Out", "16 analog in and 16 analog out.")
            bullet("16 Analog In / 16 Digital Out", "16 analog in, 16 optical out.")
            bullet("16 Digital In / 16 Analog Out", "16 optical in, 16 analog out.")
            bullet("2x6", "2 analog in, 6 analog out, plus AES and optical.")
            bullet("8MicPre", "Adds 8 mic preamps in front of an analog module's line inputs, with inserts and four instrument inputs.")
            Text("The 8MicPre is the one module with a slot restriction: it must go in the **second** slot, with an 8x8, 16x16 Analog In/Out, or 16 Analog In / 16 Digital Out module in the first. It has no converters of its own — it feeds the analog module's inputs, which is why its preamps appear on channels 1–8 of that card.")
            Text(ioModulesLink)
        }
    }

    private var ioModulesLink: AttributedString {
        let url = "https://knowledge.apogeedigital.com/can-mkii-i/o-modules-be-used-in-the-older-symphony-i/o"
        let md = "Apogee's full list, with photos of each module's rear panel: [Supported I/O modules for Symphony I/O](\(url))"
        return (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    private var interfaceMode: some View {
        Section("Interface mode (Symphony / USB / Pro Tools)") {
            Text("This is set from the buttons on the front of the unit. The firmware doesn't expose it to the host, so it can't be changed from the app — Maestro shows the current mode on the Device tab for reference.")
        }
    }

    private var uninstalling: some View {
        Section("Uninstalling") {
            Text("Run this one command in Terminal. It removes the app, plug-in, Thunderbolt driver, and background service, and restores the original Apogee driver if it was present:")
            HStack(spacing: 8) {
                Text(uninstallCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(uninstallCommand, forType: .string)
                    showCommandCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showCommandCopied = false
                    }
                } label: {
                    CopyGlyph(copied: showCommandCopied)
                }
                .buttonStyle(.borderless)
                .help("Copy command")
                .accessibilityLabel("Copy uninstall command")
            }
        }
    }

    private var testedAndFeedback: some View {
        Section("Tested hardware & feedback") {
            Text("Maestro has only been tested on **Apple Silicon (M-series) Macs**. Intel Macs are not supported.")
            Text(feedbackText)
        }
    }

    /// Feedback line with an inline, clickable mailto link (markdown-rendered).
    private var feedbackText: AttributedString {
        let md = "Found a bug or have a request? Email [\(feedbackEmail)](mailto:\(feedbackEmail)) — feedback is genuinely welcome."
        return (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    // MARK: Helpers

    /// A titled block with consistent spacing.
    private func Section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ term: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            (Text(term).fontWeight(.semibold) + Text(" — \(desc)"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
