import SwiftUI
import MaestroCore
import MaestroDevice

struct IdentifyButton: View {
    let title: String
    let device: (any DeviceConnection)?
    let state: IdentifyState

    var body: some View {
        Button {
            // Capture this button's unit connection before scheduling any work.
            guard let device else { return }
            state.toggle(device: device)
        } label: {
            Label(title, systemImage: state.isOn ? "lightbulb.fill" : "lightbulb")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(device == nil)
        .help("Toggle the unit's front-panel identify lights")
    }
}
