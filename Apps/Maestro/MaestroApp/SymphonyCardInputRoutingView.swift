import SwiftUI
import MaestroCore

/// Original card-level Input Routing surface: software rows, peripheral
/// source columns. Evidence: og_source/maestro2/App/Model/APAudioSystemModel.m:725-752;
/// App/Controllers/APInputRoutingTabRowViewController.m:155-231,423-470.
struct SymphonyCardInputRoutingView: View {
    let appState: AppState
    @State private var hoverRow: Int?
    @State private var hoverColumn: Int?
    @State private var writing = false
    @State private var error: String?

    var body: some View {
        let routing = appState.symphonyCardInputs
        let names = appState.symphonyCardInputNames()
        let sources = names.indices.filter { names[$0] != CardLayout.notApplicable }
        VStack(alignment: .leading, spacing: 4) {
            Text("Software Inputs").font(.headline).padding(.horizontal, 16)
            ScrollView([.horizontal, .vertical]) {
                RoutingGridView(
                    rowCount: routing.channelCount / 2,
                    columnCount: sources.count,
                    rowLabels: (0..<routing.channelCount / 2).map { row in
                        (number: "\(row * 2 + 1)-\(row * 2 + 2)", name: rowName(row, names: names))
                    },
                    columnLabels: sources.map { (type: names[$0], channels: "") },
                    rowGroupLabel: "Software Inputs", colGroupLabel: "Hardware Inputs",
                    isActiveCell: { row, column in
                        routing.source(host: row * 2, edits: appState.symphonyCardInputEdits) == sources[column] * 2
                            && routing.source(host: row * 2 + 1, edits: appState.symphonyCardInputEdits) == sources[column] * 2 + 1
                    },
                    hoverRow: $hoverRow, hoverCol: $hoverColumn,
                    onCellTap: { row, column in
                        guard !writing else { return }
                        let source = sources[column] * 2
                        let clear = routing.source(host: row * 2, edits: appState.symphonyCardInputEdits) == source
                            && routing.source(host: row * 2 + 1, edits: appState.symphonyCardInputEdits) == source + 1
                        writing = true
                        Task {
                            let ok = await appState.applySymphonyCardInputs([
                                row * 2: clear ? -1 : source,
                                row * 2 + 1: clear ? -1 : source + 1])
                            error = ok ? nil : "The card refused the input route."
                            writing = false
                        }
                    })
                    .padding(16)
            }
            .disabled(writing)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 16) }
        }
        .task(id: appState.symphonyCardInputStore?.key) {
            appState.symphonyCardInputEdits = appState.symphonyCardInputStore?.load() ?? [:]
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
