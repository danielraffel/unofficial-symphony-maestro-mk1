import SwiftUI
import MaestroCore
import MaestroDevice

/// Original card-level Input Routing surface: software rows, peripheral
/// source columns. Evidence: og_source/maestro2/App/Model/APAudioSystemModel.m:725-752;
/// App/Controllers/APInputRoutingTabRowViewController.m:155-231,423-470.
struct SymphonyCardInputRoutingView: View {
    let appState: AppState
    @State private var hoverRow: Int?
    @State private var hoverColumn: Int?
    @State private var writing = false
    @State private var errorMessage: String?
    @State private var presetNames: [String] = []
    @State private var resetPrompt: RoutingResetPrompt?

    private let presetKey = "inputRoutingPresets.twoUnit"
    /// The card's 64 host channels span both units: a preset of the old
    /// channel order is marked and refused when either unit's channels move.
    private func presetIsStale(_ name: String) -> Bool {
        appState.transportType == .thunderbolt
            && RoutingPresetChannelOrder.isStale(name: name, presetKey: presetKey,
                                                 current: [appState.thunderboltUnitOrder(unit: .a),
                                                           appState.thunderboltUnitOrder(unit: .b)])
    }

    var body: some View {
        let routing = appState.symphonyCardInputs
        let names = appState.symphonyCardInputNames()
        let columns = SymphonyCombinedInputRouting.columns(
            unitANames: Array(names.prefix(16)), unitBNames: Array(names.dropFirst(16).prefix(16)))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Reset Routing") {
                    resetPrompt = RoutingResetPrompt(
                        title: "Reset Input Routing",
                        message: "Reset input routing for both Symphony I/Os (channels 1–64)?",
                        isRefusal: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!appState.routingHardwareAvailable)
                .routingResetPrompt($resetPrompt) {
                    Task {
                        do {
                            try await appState.resetTwoUnitRouting(input: true)
                            appState.markSetupEdited(.routing)
                            errorMessage = nil
                        }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                PresetMenuButton(
                    presetNames: presetNames,
                    onSave: { name in
                        PresetManager.saveRoutingPreset(name: name,
                            routes: appState.symphonyCardInputEdits, key: presetKey)
                        RoutingPresetChannelOrder.mark(name: name, presetKey: presetKey,
                            order: RoutingPresetChannelOrder.savingOrder(transport: appState.transportType,
                                                                         covering: [appState.thunderboltUnitOrder(unit: .a),
                                                                                    appState.thunderboltUnitOrder(unit: .b)]))
                        presetNames = Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted())
                    },
                    onLoad: { name in
                        if presetIsStale(name) {
                            errorMessage = RoutingPresetChannelOrder.refusalMessage
                            return
                        }
                        guard let preset = PresetManager.loadRoutingPresets(key: presetKey)[name] else { return }
                        Task {
                            let ok = await appState.applySymphonyCardInputs(preset)
                            errorMessage = ok ? nil : "The card refused the input route."
                        }
                    },
                    onDelete: { name in
                        PresetManager.deleteRoutingPreset(name: name, key: presetKey)
                        RoutingPresetChannelOrder.unmark(name: name, presetKey: presetKey)
                        presetNames = Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted())
                    },
                    label: { RoutingPresetChannelOrder.label($0, stale: presetIsStale($0)) },
                    canLoad: appState.routingHardwareAvailable)
                Spacer()
            }
            .padding(.horizontal, 16)
            Text("Software Inputs").font(.headline).padding(.horizontal, 16)
            ScrollView([.horizontal, .vertical]) {
                RoutingGridView(
                    rowCount: SymphonyCombinedInputRouting.softwarePairCount,
                    columnCount: columns.count,
                    rowLabels: (0..<SymphonyCombinedInputRouting.softwarePairCount).map { row in
                        (number: "\(row * 2 + 1)-\(row * 2 + 2)", name: rowName(row, names: names))
                    },
                    columnLabels: columns.map { (type: $0.name, channels: "") },
                    rowGroupLabel: "Software Inputs", colGroupLabel: "Hardware Inputs",
                    isActiveCell: { row, column in
                        guard columns.indices.contains(column) else { return false }
                        let source = columns[column].sourcePair * 2
                        return routing.source(host: row * 2, edits: appState.symphonyCardInputEdits) == source
                            && routing.source(host: row * 2 + 1, edits: appState.symphonyCardInputEdits) == source + 1
                    },
                    hoverRow: $hoverRow, hoverCol: $hoverColumn,
                    isEnabled: appState.routingHardwareAvailable,
                    onCellTap: { row, column in
                        guard !writing else { return }
                        guard columns.indices.contains(column) else { return }
                        let source = columns[column].sourcePair * 2
                        let previousRoutesA = appState.thunderboltCaptureRoutes(unit: .a)
                        let previousRoutesB = appState.thunderboltCaptureRoutes(unit: .b)
                        let clear = routing.source(host: row * 2, edits: appState.symphonyCardInputEdits) == source
                            && routing.source(host: row * 2 + 1, edits: appState.symphonyCardInputEdits) == source + 1
                        writing = true
                        let selectedEdits = SymphonyCombinedInputRouting.cardEdits(row: row, column: columns[column])
                        Task {
                            let edits = clear ? selectedEdits.mapValues { _ in -1 } : selectedEdits
                            let ok = await appState.applySymphonyCardInputs(edits)
                            if ok {
                                appState.markSetupEdited(.routing)
                                appState.thunderboltInputRoutingDidChange(previousRoutes: [.a: previousRoutesA, .b: previousRoutesB])
                            }
                            errorMessage = ok ? nil : "The card refused the input route."
                            writing = false
                        }
                    })
                    .padding(16)
            }
            .disabled(writing)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal, 16) }
        }
        .task(id: appState.symphonyCardInputStore?.key) {
            appState.symphonyCardInputEdits = appState.symphonyCardInputStore?.load() ?? [:]
            presetNames = Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted())
        }
    }
    private func rowName(_ row: Int, names: [String]) -> String {
        let routing = appState.symphonyCardInputs
        let left = routing.source(host: row * 2, edits: appState.symphonyCardInputEdits)
        let right = routing.source(host: row * 2 + 1, edits: appState.symphonyCardInputEdits)
        if let left, left % 2 == 0, right == left + 1, names.indices.contains(left / 2) {
            return names[left / 2]
        }
        func sideName(_ source: Int?) -> String {
            guard let source, names.indices.contains(source / 2), names[source / 2] != CardLayout.notApplicable else {
                return CardLayout.notApplicable
            }
            return names[source / 2] + (source % 2 == 0 ? " (L)" : " (R)")
        }
        if left == nil && right == nil { return CardLayout.notApplicable }
        return sideName(left) + " / " + sideName(right)
    }

}
