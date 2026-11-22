import SwiftUI
import MaestroCore
import MaestroDevice

/// The original's Use Loop Sync checkbox and master popup live in System Setup's
/// Clock section, with the master popup hidden while Loop Sync is off.
/// Evidence: og_source/maestro2/App/Controllers/APSystemClockingViewController.m:223-260;
/// og_source/maestro2/App/Views/APSystemClockingView.xib:147,436.
struct LoopSyncControls: View {
    let appState: AppState
    @State private var enabled = true
    @State private var master = DeviceUnit.a
    @State private var source: UInt32 = 1
    @State private var showInfo = false

    private var choices: [ClockSourceChoice] {
        ClockSourceMenu.unitAChoices(ClockSourceMenu.thunderbolt(
            slot1: appState.unitB?.slot1 ?? .none, slot2: appState.unitB?.slot2 ?? .none,
            sampleRate: appState.channelNaming.sampleRate,
            opticalIsSPDIF: appState.unitBChannelNaming.opticalIsSPDIF), unitBFollows: true)
    }

    var body: some View {
        Group {
            Toggle(isOn: $enabled) {
                HStack(spacing: 4) {
                    Text("Use Loop Sync")
                    Button { showInfo.toggle() } label: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About Loop Sync")
                    .maestroHelp("Explain Loop Sync.")
                    .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(LoopSyncInfo.paragraphs, id: \.self) { paragraph in
                                Text(LocalizedStringKey(paragraph))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            SeeHelpLink(section: .clock, appState: appState, popover: $showInfo)
                        }
                        .font(.callout)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 340, alignment: .leading)
                        .padding(14)
                    }
                }
            }
                .maestroHelp("Lock Symphony I/Os to the same clock over their Loop Sync connection.")
                .onChange(of: enabled) { _, value in
                    guard let state = appState.loopSyncState, value != state.settings.enabled else { return }
                    Task { await appState.setLoopSync(.init(enabled: value, master: state.settings.master)) }
                }
            if enabled && !appState.loopSyncOneUnit {
                Picker("Loop Sync Master", selection: $master) {
                    Text("Unit A").tag(DeviceUnit.a)
                    Text("Unit B").tag(DeviceUnit.b)
                }
                .maestroHelp("Choose which Symphony I/O is the Loop Sync clock master.")
                .onChange(of: master) { _, value in
                    guard let state = appState.loopSyncState, value != state.settings.master else { return }
                    Task { await appState.setLoopSync(.init(enabled: state.settings.enabled, master: value)) }
                }
            }
            if appState.activeUnit == .b, appState.loopSyncState?.settings.effectiveMaster == .b {
                Picker("Clock Source", selection: $source) {
                    ForEach(choices) { choice in Text(choice.name).tag(choice.id) }
                }
                .onChange(of: source) { _, value in
                    guard let state = appState.loopSyncState, value != state.sourceKey(.b),
                          let tb = appState.device as? ThunderboltDeviceConnection else { return }
                    Task {
                        do { try await tb.setUnitBMasterSource(value) }
                        catch { appState.loopSyncError = "The driver could not set the clock source." }
                        await appState.refreshLoopSync()
                    }
                }
            }
        }
        .disabled(appState.loopSyncBusy || appState.loopSyncState == nil)
        .onChange(of: appState.loopSyncState, initial: true) { _, state in
            guard let state else { return }
            enabled = state.settings.enabled
            master = state.settings.master
            source = state.sourceKey(.b)
        }
        LabeledContent("Configured Role", value: appState.loopSyncState?.role(appState.activeUnit) ?? "Not read")
        LabeledContent("Clock Status", value: appState.loopSyncState?.lockText(appState.activeUnit) ?? "Not read")
        if let error = appState.loopSyncError {
            Text(error).font(.caption).foregroundStyle(.secondary)
        }
    }
}
