import SwiftUI
import MaestroCore

/// Unit A / Unit B, above the pages that belong to one Symphony I/O, while 64
/// channels run with a second unit on ThunderBridge port 2.
struct UnitPickerBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        HStack(spacing: 10) {
            Picker("Unit", selection: $state.selectedUnit) {
                Text(UnitPicker.label(.a, prefix: appState.peripheralPrefix)).tag(DeviceUnit.a)
                Text(UnitPicker.label(.b, prefix: appState.unitBPeripheralPrefix)).tag(DeviceUnit.b)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Choose which Symphony I/O this page shows: unit A on ThunderBridge port 1 "
                  + "or unit B on port 2")
            Text(appState.activeUnit.portName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
