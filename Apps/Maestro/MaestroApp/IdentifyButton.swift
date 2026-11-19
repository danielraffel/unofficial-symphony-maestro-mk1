import SwiftUI
import MaestroCore
import MaestroDevice

/// The original Maestro's identify control toggled all front-panel LEDs on and
/// off (`og_source/maestro2/App/Controllers/APRoutingDeviceColumnViewController.m:212-219`).
/// The wire command is stateful too, so keep the button state local until the
/// device can provide a readback.
struct IdentifyButton: View {
    let title: String
    let device: (any DeviceConnection)?
    @State private var isOn = false

    var body: some View {
        Button {
            let next = !isOn
            isOn = next
            Task {
                try? await device?.setProperty(
                    PropertyAddress(selector: .identify), value: .bool(next))
            }
        } label: {
            Label(title, systemImage: isOn ? "lightbulb.fill" : "lightbulb")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(device == nil)
        .help("Toggle the unit's front-panel identify lights")
    }
}
