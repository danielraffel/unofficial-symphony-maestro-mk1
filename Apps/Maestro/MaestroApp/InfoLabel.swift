import SwiftUI

/// A settings row label with an ⓘ that opens a short explanation, in the
/// same look as the Ports, VBus and Clock Status popovers.
struct InfoLabel: View {
    let title: String
    let paragraphs: [String]
    let helpSection: HelpSectionID
    let appState: AppState
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Button { shown.toggle() } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(title)")
            .maestroHelp("Explain \(title).")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(paragraphs, id: \.self) { paragraph in
                        Text(LocalizedStringKey(paragraph))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    SeeHelpLink(section: helpSection, appState: appState, popover: $shown)
                }
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 340, alignment: .leading)
                .padding(14)
                // The settings page is redacted while it loads; an explanation
                // never is (it was drawn as grey bars).
                .unredacted()
            }
        }
    }
}

enum SettingsInfoText {
    static let configuredRole = [
        "What this unit does in the clock setup, as Maestro has set it:",
        "**Loop Sync master**: it runs on its own clock source and sends that clock out of **Loop Out**.",
        "**Loop Sync (follows Unit A or B)**: it takes its clock from the other unit through **Loop In**.",
        "**Master (Loop Sync off)**: it runs on its own clock source and sends nothing on Loop Sync.",
        "**Not confirmed**: the driver could not confirm the last change; Maestro tries again.",
    ]
    static let clockStatus = [
        "**Ready**: the unit is running on its clock source. On **Internal** it is always Ready.",
        "**Clock Mismatch**: the source it should follow (Word Clock, a digital input, or Loop Sync from the other unit) has no usable signal, or runs at another sample rate. Check the cable and that both ends are set to the same rate.",
    ]
    static let levelOverlay = [
        "A HUD, like the one macOS shows for its volume keys: when a speaker or headphone level, a mute or an 8MicPre gain changes, Maestro shows the new level on screen for a moment.",
        "It also shows changes made with the Symphony's front-panel knob, which macOS does not show. As in Apogee's software (its Display pop-ups). Off unless you turn it on.",
    ]
    static let autoSwitch = [
        "When you plug the Symphony in or turn it on, Maestro makes it your Mac's sound output, so you don't have to pick it in the Sound menu. The input is left as it is.",
        "**ThunderBridge or PCIe**: the Symphony's device, once the unit answers. **USB**: the device chosen in **Preferred USB output** below.",
        "If you have both connected, the one you just connected wins. Turn this off to keep choosing the output yourself.",
    ]
    static let preferredUSBOutput = [
        "Which of the Symphony's two USB devices Maestro makes your Mac's output when it switches over USB. It applies only over USB and only while **Automatically switch to Symphony when connected** is on.",
        "**Maestro USB** (recommended): the Mac's volume keys and menu-bar slider control the Symphony. It adds about 1.3 ms of latency, which it reports to your DAW.",
        "**USB Audio**: the Symphony's own device, with the lowest latency, but macOS gives it no volume control, so the volume keys do nothing. For recording, set your DAW's input to **USB Audio** either way.",
    ]
    static let audioOutput = [
        "The output the Mac's volume and mute keys, and the volume slider in the menu bar, control: **Speaker**, **Headphone 1** or **Headphone 2**, as in Apogee's software. Maestro remembers it for each Symphony I/O.",
        "When the **Speaker** knob's format on the Output page is **Line**, the speaker outputs run at a fixed line level and have no volume, so Audio Output changes to **Headphone 1** by itself. When you leave Line it goes back to the output it was on.",
        "Over USB the keys work only when **Symphony I/O : Maestro USB** is your Mac's output: macOS gives the Symphony's own **USB Audio** device no volume control.",
    ]
}
