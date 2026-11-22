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
    static let audioOutput = [
        "The output the Mac's volume and mute keys, and the volume slider in the menu bar, control: **Speaker**, **Headphone 1** or **Headphone 2**, as in Apogee's software. Maestro remembers it for each Symphony I/O.",
        "When the **Speaker** knob's format on the Output page is **Line**, the speaker outputs run at a fixed line level and have no volume, so Audio Output changes to **Headphone 1** by itself. When you leave Line it goes back to the output it was on.",
        "Over USB the keys work only when **Symphony I/O : Maestro USB** is your Mac's output: macOS gives the Symphony's own **USB Audio** device no volume control.",
    ]
}
