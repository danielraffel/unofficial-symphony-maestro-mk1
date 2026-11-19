import SwiftUI
import MaestroCore
import MaestroDevice

/// The confirmation for Reset Routing with converters. One command (0xB7)
/// puts both tables back, so it says so on either page.
private func converterResetPrompt() -> RoutingResetPrompt {
    RoutingResetPrompt(
        title: "Reset Routing",
        message: """
            Every converter output and every DAW input goes back to the default placement: \
            DAW output n to the converter output Apogee's software put there, and DAW input n \
            from the converter input it put there. This resets both Output Routing and Input Routing.
            """,
        isRefusal: false)
}

/// Output Routing with AD-16X, DA-16X, DD-16X or Rosetta converters: DAW
/// playback pairs and the two card mixers (rows) to converter output pairs
/// (columns), on the card's routing (0xB5). The grid shows the default
/// placement with the user's routes for this chain on top; the card has no
/// readback.
struct ConverterOutputRoutingView: View {
    let appState: AppState
    let layout: ConverterRoutingLayout
    let system: ConverterSystem

    @State private var hoverRow: Int?
    @State private var hoverCol: Int?
    @State private var errorMessage: String?
    @State private var resetPrompt: RoutingResetPrompt?
    @State private var presetNames: [String] = []

    private var pairs: [ConverterRoutingLayout.Pair] { layout.outputPairs }

    private var rowLabels: [(number: String, name: String)] {
        var labels = layout.playbackRowNames(system: system).enumerated().map { i, name in
            (number: "\(i * 2 + 1)-\(i * 2 + 2)", name: name)
        }
        let mixerStart = layout.hostChannels + 1
        for i in 0..<2 {
            labels.append((number: "\(mixerStart + i * 2)-\(mixerStart + i * 2 + 1)", name: "Mixer \(i + 1)"))
        }
        return labels
    }

    var body: some View {
        let sources = layout.outputSources(appState.converterRoutingEdits)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Reset Routing") { resetPrompt = converterResetPrompt() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .routingResetPrompt($resetPrompt) {
                        Task {
                            let ok = await appState.resetConverterRouting()
                            errorMessage = ok ? nil : "The driver did not accept Reset Routing"
                        }
                    }
                Spacer()
                ConverterRoutingPresetButton(appState: appState, layout: layout, input: false,
                                             presetNames: $presetNames, errorMessage: $errorMessage)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    let labels = rowLabels
                    RoutingGridView(
                        rowCount: labels.count,
                        columnCount: pairs.count,
                        rowLabels: labels,
                        columnLabels: pairs.map(\.header),
                        rowGroupLabel: "Software Outputs",
                        colGroupLabel: "Converter Outputs",
                        isActiveCell: { row, col in layout.outputCellActive(row: row, column: col, sources: sources) },
                        hoverRow: $hoverRow,
                        hoverCol: $hoverCol,
                        onCellTap: { row, col in
                            guard let change = layout.toggleOutput(row: row, column: col,
                                                                   edits: appState.converterRoutingEdits) else { return }
                            Task {
                                let ok = await appState.applyConverterRouting(change.edits, commands: change.commands)
                                errorMessage = ok ? nil : "The driver did not accept this route"
                                print("[Maestro] Converter output routing: row \(row) → column \(col): \(change.commands)")
                            }
                        }
                    )
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }

            ConverterRoutingErrorLine(message: errorMessage)
        }
        .navigationTitle("Output Routing")
        .task(id: appState.converterRoutingSignature) {
            presetNames = appState.converterRoutingStore?.presetNames(input: false) ?? []
        }
    }
}

/// Input Routing with converters: each DAW input pair (rows) records one
/// converter input pair (columns), on the card's routing (0xB6). Clicking the
/// chosen cell again leaves the DAW pair empty.
struct ConverterInputRoutingView: View {
    let appState: AppState
    let layout: ConverterRoutingLayout

    @State private var hoverRow: Int?
    @State private var hoverCol: Int?
    @State private var errorMessage: String?
    @State private var resetPrompt: RoutingResetPrompt?
    @State private var presetNames: [String] = []

    private var pairs: [ConverterRoutingLayout.Pair] { layout.inputPairs }

    var body: some View {
        let sources = layout.inputSources(appState.converterRoutingEdits)
        let names = layout.inputRowNames(sources: sources)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Reset Routing") { resetPrompt = converterResetPrompt() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .routingResetPrompt($resetPrompt) {
                        Task {
                            let ok = await appState.resetConverterRouting()
                            errorMessage = ok ? nil : "The driver did not accept Reset Routing"
                        }
                    }
                Spacer()
                ConverterRoutingPresetButton(appState: appState, layout: layout, input: true,
                                             presetNames: $presetNames, errorMessage: $errorMessage)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    let rowLabels: [(number: String, name: String)] = (0..<layout.inputPairCount).map { i in
                        (number: "\(i * 2 + 1)-\(i * 2 + 2)", name: names[i])
                    }
                    RoutingGridView(
                        rowCount: rowLabels.count,
                        columnCount: pairs.count,
                        rowLabels: rowLabels,
                        columnLabels: pairs.map(\.header),
                        rowGroupLabel: "Software Inputs",
                        colGroupLabel: "Converter Inputs",
                        isActiveCell: { row, col in layout.inputColumn(row: row, sources: sources) == col },
                        hoverRow: $hoverRow,
                        hoverCol: $hoverCol,
                        onCellTap: { row, col in
                            guard let change = layout.toggleInput(row: row, column: col,
                                                                  edits: appState.converterRoutingEdits) else { return }
                            Task {
                                let ok = await appState.applyConverterRouting(change.edits, commands: change.commands)
                                errorMessage = ok ? nil : "The driver did not accept this route"
                                print("[Maestro] Converter input routing: row \(row) → column \(col): \(change.commands)")
                            }
                        }
                    )
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }

            ConverterRoutingErrorLine(message: errorMessage)
        }
        .navigationTitle("Input Routing")
        .task(id: appState.converterRoutingSignature) {
            presetNames = appState.converterRoutingStore?.presetNames(input: true) ?? []
        }
    }
}

/// Routing presets for converters: one direction each, kept per chain of
/// units (a preset made for one chain means nothing on another). Loading one
/// writes that direction's whole table.
private struct ConverterRoutingPresetButton: View {
    let appState: AppState
    let layout: ConverterRoutingLayout
    let input: Bool
    @Binding var presetNames: [String]
    @Binding var errorMessage: String?

    var body: some View {
        PresetMenuButton(
            presetNames: presetNames,
            onSave: { name in
                guard let store = appState.converterRoutingStore else { return }
                let edits = appState.converterRoutingEdits
                store.savePreset(name: name, input: input, routes: input ? edits.inputs : edits.outputs)
                presetNames = store.presetNames(input: input)
            },
            onLoad: { name in
                guard let store = appState.converterRoutingStore,
                      let routes = store.presets(input: input)[name] else { return }
                var edits = appState.converterRoutingEdits
                if input { edits.inputs = routes } else { edits.outputs = routes }
                let commands = input ? layout.fullInputCommands(edits) : layout.fullOutputCommands(edits)
                Task {
                    let ok = await appState.applyConverterRouting(edits, commands: commands)
                    errorMessage = ok ? nil : "The driver did not accept every route in the preset"
                }
            },
            onDelete: { name in
                appState.converterRoutingStore?.deletePreset(name: name, input: input)
                presetNames = appState.converterRoutingStore?.presetNames(input: input) ?? []
            }
        )
    }
}

private struct ConverterRoutingErrorLine: View {
    let message: String?

    var body: some View {
        if let message {
            HStack {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// Converters are on the cable but not every unit is one Maestro knows, so
/// their channels cannot be laid out (and the Symphony I/O grid would write
/// nonsense to them).
struct ConverterRoutingUnavailableNote: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routing needs every converter identified")
                .font(.headline)
            Text("A unit on the cable did not identify as an AD-16X, DA-16X, DD-16X or Rosetta, so Maestro can't lay out its channels. Device Info lists what each unit answered.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(title)
    }
}
