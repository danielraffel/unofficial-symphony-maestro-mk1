import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


/// A pending "Reset Routing" prompt — either a refusal to explain, or a
/// confirmation that names the detected cards and the concrete consequence.
///
/// Reset Routing rewrites the whole crosspoint from the card complement. It is
/// never issued without the user seeing, in advance, which cards it believes are
/// installed and what each hardware output will end up carrying.
struct RoutingResetPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// True when the reset cannot run at all — the dialog is informational.
    let isRefusal: Bool
}

extension View {
    /// Present a ``RoutingResetPrompt``: a refusal gets a single OK, a
    /// confirmation gets an explicit destructive "Reset Routing" and a Cancel.
    /// The reset only runs from the confirmation button.
    func routingResetPrompt(
        _ prompt: Binding<RoutingResetPrompt?>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        let isPresented = Binding<Bool>(
            get: { prompt.wrappedValue != nil },
            set: { if !$0 { prompt.wrappedValue = nil } })
        return alert(
            prompt.wrappedValue?.title ?? "Reset Routing",
            isPresented: isPresented,
            presenting: prompt.wrappedValue
        ) { pending in
            if pending.isRefusal {
                Button("OK", role: .cancel) { prompt.wrappedValue = nil }
            } else {
                Button("Cancel", role: .cancel) { prompt.wrappedValue = nil }
                Button("Reset Routing", role: .destructive) {
                    prompt.wrappedValue = nil
                    onConfirm()
                }
            }
        } message: { pending in
            Text(pending.message)
        }
    }
}

/// Input Routing view — grid matrix mapping hardware inputs to software channels.
///
/// Evidence: `og_source/maestro2/App/Controllers/InputRouting/`
/// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp`
struct InputRoutingView: View {
    private let appState: AppState
    @State private var routes: [Int: Int] = [:] // row → column mapping
    /// Rows the user actually chose, as opposed to rows drawn from the default
    /// table. Only these are persisted — see ``RoutingStateCache``.
    @State private var userChosenRows: Set<Int> = []
    @State private var hoverRow: Int? = nil
    @State private var hoverCol: Int? = nil
    @State private var errorMessage: String?
    @State private var isLoadingRoutes = true
    @State private var showLoadingIndicator = false

    // Software input row count = USB audio class channels / 2 (stereo pairs).
    private var pairCount: Int {
        (appState.device?.identifier.mode.channelCount ?? 16) / 2
    }

    /// The installed cards' layout — the grid's hardware columns come from here.
    private var layout: CardLayout { appState.cardLayout }

    /// Hardware INPUT columns: one per stereo pair the installed cards actually
    /// provide, analog (both boards) then digital (both boards).
    ///
    /// NOT a fixed 16. An empty slot contributes nothing and an 8MicPre
    /// contributes nothing, because a click on a column for a board that is not
    /// there writes a real routing byte into an empty XLink region. Each column
    /// carries its own routing byte (`CardLayout.RoutingColumn`), so the grid the
    /// user clicks and the byte the click writes cannot drift apart.
    private var columns: [CardLayout.RoutingColumn] { layout.inputRoutingColumns }

    private var columnLabels: [(type: String, channels: String)] {
        columns.map { (type: $0.type, channels: $0.channels) }
    }

    /// The grid column a hardware routing byte belongs to, or nil when these
    /// cards have no such column.
    private func column(forRoutingByte byte: UInt8) -> Int? {
        let left = byte - (byte % 2)
        return columns.firstIndex { $0.routingByte == left }
    }

    // P3C-05: Routing presets
    @State private var presetNames: [String] = []
    private let presetKey = "inputRoutingPresets"

    private var routingCache: RoutingStateCache? {
        guard let id = appState.device?.identifier else { return nil }
        return RoutingStateCache(direction: "input", productID: id.productID)
    }

    /// Pending refusal / confirmation for Reset Routing. See ``RoutingResetPrompt``.
    @State private var resetPrompt: RoutingResetPrompt?

    init(appState: AppState) {
        self.appState = appState
        let snapshot = restoredRoutes(defaultRouteGrid())
        _routes = State(initialValue: snapshot)
        _userChosenRows = State(initialValue: Set(routingCache?.load()?.keys.map { $0 } ?? []))
        _presetNames = State(initialValue: Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Reset Routing") {
                    requestRoutingReset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .routingResetPrompt($resetPrompt) {
                    Task { await resetToDefaultRouting() }
                }
                Spacer()
                PresetMenuButton(
                    presetNames: presetNames,
                    onSave: { name in
                        PresetManager.saveRoutingPreset(name: name, routes: routes, key: presetKey)
                        presetNames = Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted())
                    },
                    onLoad: { name in
                        if let preset = PresetManager.loadRoutingPresets(key: presetKey)[name] {
                            routes = preset
                            userChosenRows.formUnion(preset.keys)
                            persistChosenRows()
                            Task {
                                for (row, col) in preset.sorted(by: { $0.key < $1.key }) {
                                    await writeRoute(row: row, col: col)
                                }
                            }
                        }
                    },
                    onDelete: { name in
                        PresetManager.deleteRoutingPreset(name: name, key: presetKey)
                        presetNames = Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted())
                    }
                )
            }
            .disabled(isLoadingRoutes)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    let rowLabels: [(number: String, name: String)] = (0..<pairCount).map { i in
                        let sw1 = i * 2 + 1
                        let sw2 = i * 2 + 2
                        return (number: "\(sw1)-\(sw2)", name: "A Line \(sw1)/\(sw2)")
                    }
                    RoutingGridView(
                        rowCount: pairCount,
                        columnCount: columnLabels.count,
                        rowLabels: rowLabels,
                        columnLabels: columnLabels,
                        rowGroupLabel: "Software Inputs",
                        colGroupLabel: "Hardware Inputs",
                        isActiveCell: { row, col in routes[row] == col },
                        hoverRow: $hoverRow,
                        hoverCol: $hoverCol,
                        onCellTap: { row, col in
                            guard !isLoadingRoutes else { return }
                            routes[row] = col
                            userChosenRows.insert(row)
                            persistChosenRows()
                            Task { await writeRoute(row: row, col: col) }
                        }
                    )
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }

            if let error = errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("Input Routing")
        .overlay {
            if isLoadingRoutes && showLoadingIndicator {
                ProgressView("Loading routes…")
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: "\(appState.viewReloadToken)-\(appState.cardLayoutToken)") {
            isLoadingRoutes = true
            showLoadingIndicator = false
            // Only show indicator if loading takes more than 300ms
            let indicatorTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled && isLoadingRoutes { showLoadingIndicator = true }
            }
            // Refresh a complete snapshot, then publish once; never paint one
            // crosspoint at a time as each hardware read completes.
            let measured = await loadRoutes()
            guard !Task.isCancelled else { indicatorTask.cancel(); return }
            routes = restoredRoutes(measured.isEmpty ? defaultRouteGrid() : measured)
            userChosenRows = Set(routingCache?.load()?.keys.map { $0 } ?? [])
            presetNames = Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted())
            isLoadingRoutes = false
            showLoadingIndicator = false
            indicatorTask.cancel()
        }
    }

    /// Read current input routing from hardware via USB command 0x31.
    ///
    /// For each USB record channel pair (P2P dest 192+pair*2), reads the source byte,
    /// then reverse-maps to the column index in the routing grid.
    ///
    /// The grid to show when the hardware read came back with nothing.
    ///
    /// Derived from `SymphonyIODefaultRouting.inputRoutes` — the same table
    /// `Reset Routing` writes — rather than the clamped diagonal
    /// `min(i, columns.count - 1)` this replaced, which stacked every software
    /// pair past the last hardware column onto that one column. Display only:
    /// nothing is written here.
    private func restoredRoutes(_ base: [Int: Int]) -> [Int: Int] {
        var routes = base
        for (row, col) in routingCache?.load() ?? [:]
        where row >= 0 && row < pairCount && col >= 0 && col < columns.count {
            routes[row] = col
        }
        return routes
    }

    private func defaultRouteGrid() -> [Int: Int] {
        let board1 = appState.primaryBoardType
        let board2 = appState.secondaryBoardType
        // Same record-channel count Reset Routing writes (the mode's count:
        // 32 over ThunderBridge, 16/8 in the USB modes). A fixed 16 drew only
        // half the diagonal on ThunderBridge after a reset (2026-10-22 13:34).
        let routeList = SymphonyIODefaultRouting.inputRoutes(
            board0: .init(analog: board1.analogInputChannels, digital: board1.digitalInputChannels),
            board1: .init(analog: board2.analogInputChannels, digital: board2.digitalInputChannels),
            usbChannelCount: appState.device?.identifier.mode.channelCount
                ?? SymphonyIODefaultRouting.usbChannelCount)
        var grid: [Int: Int] = [:]
        for route in routeList {
            guard route.source != SymphonyIORoutingAddress.none,
                  route.destination % 2 == 0,
                  let col = column(forRoutingByte: route.source)
            else { continue }
            grid[Int(route.destination - SymphonyIORoutingAddress.p2pBase) / 2] = col
        }
        return grid
    }

    /// Persist only the crosspoints a person actually picked.
    ///
    /// The rest of ``routes`` is ``defaultRouteGrid``'s guess, redrawn from the
    /// card layout on every appearance. Writing that guess here would freeze it —
    /// the cache outranks the default, so a guess made while the card layout was
    /// still unknown would outlive the cards themselves. See ``RoutingStateCache``.
    private func persistChosenRows() {
        routingCache?.save(routes.filter { userChosenRows.contains($0.key) })
    }

    /// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:714-792`
    private func loadRoutes() async -> [Int: Int] {
        guard let device = appState.device else { return [:] }
        var routes: [Int: Int] = [:]

        for pair in 0..<pairCount {
            guard !Task.isCancelled else { return [:] }
            let destByte = UInt32(SymphonyIORoutingAddress.p2pBase) + UInt32(pair * 2)
            do {
                let result = try await device.getProperty(
                    PropertyAddress(selector: .routing, scope: .input, element: destByte)
                )
                if let srcByte = result.asUInt32,
                   let col = column(forRoutingByte: UInt8(srcByte)) {
                    routes[pair] = col
                }
            } catch {
                print("[Maestro] InputRouting: read pair \(pair) (dest \(destByte)) failed: \(error)")
            }
        }

        print("[Maestro] InputRouting: loaded \(routes.count) routes from hardware")
        return routes
    }

    /// Write a stereo input routing pair via USB command 0x31.
    ///
    /// Maps (row, col) to USB routing bytes and writes both L+R channels.
    /// Input routing: destination = P2P byte (192+), source = IOBoard byte (32-63).
    ///
    /// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIORouting.h`
    /// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp`
    private func writeRoute(row: Int, col: Int) async {
        guard !isLoadingRoutes else { return }
        guard let device = appState.device else { return }
        let board1 = appState.primaryBoardType
        let board2 = appState.secondaryBoardType

        guard col >= 0, col < columns.count else {
            print("[Maestro] InputRouting: col \(col) out of range for board types \(board1)/\(board2)")
            errorMessage = "Invalid routing column"
            return
        }
        let srcLeft = columns[col].routingByte

        let destLeft = UInt32(SymphonyIORoutingAddress.p2pBase) + UInt32(row * 2)

        do {
            // Write left channel: dest=P2P(row*2), src=IOBoard(col left ch)
            try await device.setProperty(
                PropertyAddress(selector: .routing, scope: .input, element: destLeft),
                value: .uint32(UInt32(srcLeft))
            )
            // Write right channel: dest=P2P(row*2+1), src=IOBoard(col left ch + 1)
            try await device.setProperty(
                PropertyAddress(selector: .routing, scope: .input, element: destLeft + 1),
                value: .uint32(UInt32(srcLeft + 1))
            )
            errorMessage = nil
            userChosenRows.insert(row)
            persistChosenRows()
            print("[Maestro] InputRouting: wrote row \(row) → col \(col) (dest \(destLeft), src \(srcLeft))")
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

    /// Build the refusal or the confirmation for Reset Routing, and show it.
    ///
    /// Nothing is written from here. The input reset previously had no
    /// confirmation at all, which is how a reset derived from a WRONG card could
    /// run unannounced.
    private func requestRoutingReset() {
        guard let device = appState.device else { return }
        let b1 = appState.primaryBoardReading
        let b2 = appState.secondaryBoardReading
        if let refusal = RoutingResetGuard.refusalReason(board1: b1, board2: b2) {
            resetPrompt = RoutingResetPrompt(
                title: "Reset Input Routing", message: refusal, isRefusal: true)
            print("[Maestro] InputRouting: reset refused — slot provenance \(b1.source.rawValue)/\(b2.source.rawValue)")
            return
        }
        let plan = RoutingResetGuard.inputPlanLines(
            board1: b1.card, board2: b2.card,
            usbChannelCount: device.identifier.mode.channelCount)
        resetPrompt = RoutingResetPrompt(
            title: "Reset Input Routing",
            message: """
                Detected cards — Slot 1: \(b1.displayText), Slot 2: \(b2.displayText).

                Every software input will be re-pointed to the default:

                \(plan.joined(separator: "\n"))
                """,
            isRefusal: false)
    }

    /// Restore the daemon's default input routing (`ResetInputRouting`).
    ///
    /// Writes only P2P (USB record) destinations 192+, so it cannot affect any
    /// hardware output — ADAT included. Software inputs with no hardware channel
    /// behind them are left at silence (236) rather than clamped onto the last
    /// column, which is what legacy does
    /// (`SymphonyIOUSBAudioRoutingController.cpp:735-740`).
    ///
    /// Only reachable through ``requestRoutingReset()``, which refuses unless both
    /// slots were genuinely detected this session.
    private func resetToDefaultRouting() async {
        guard let device = appState.device else { return }
        let b1 = appState.primaryBoardReading
        let b2 = appState.secondaryBoardReading
        // Provenance guard, re-checked at the point of writing. A cached or
        // unknown card is a WRONG card waiting to happen, and the whole table is
        // derived from it — `.none` was never the failure mode to guard.
        guard RoutingResetGuard.refusalReason(board1: b1, board2: b2) == nil else {
            errorMessage = "I/O cards were not detected this session — routing reset is unavailable."
            print("[Maestro] InputRouting: reset refused at write time, provenance not .detected")
            return
        }
        let board1 = b1.card
        let board2 = b2.card
        // NOTE: on the INPUT side this parameter is a destination COUNT, not the
        // wrapping modulo it is on the output side — `inputRoutes` never wraps, it
        // stops when the boards run out of channels. So the mode's channel count
        // is the right value here and 16 would be wrong: in 8-channel mode it
        // would hand ADAT inputs to USB record channels 9-16, which that mode does
        // not stream. Every destination written is a P2P byte (192+), so this can
        // never touch a hardware output.
        let usbChannels = device.identifier.mode.channelCount

        let routeList = SymphonyIODefaultRouting.inputRoutes(
            board0: .init(analog: board1.analogInputChannels, digital: board1.digitalInputChannels),
            board1: .init(analog: board2.analogInputChannels, digital: board2.digitalInputChannels),
            usbChannelCount: usbChannels)

        var newRoutes: [Int: Int] = [:]
        var failures = 0
        for route in routeList {
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .routing, scope: .input, element: UInt32(route.destination)),
                    value: .uint32(UInt32(route.source)))
            } catch {
                failures += 1
                continue
            }
            guard route.source != SymphonyIORoutingAddress.none,
                  route.destination % 2 == 0,
                  let col = column(forRoutingByte: route.source)
            else { continue }
            newRoutes[Int(route.destination - SymphonyIORoutingAddress.p2pBase) / 2] = col
        }

        routes = newRoutes
        // A reset writes the default table to the hardware, so there are no
        // overrides left to remember — clearing is the point of the button.
        // Keeping them would restore the old picks on the next appearance.
        userChosenRows.removeAll()
        persistChosenRows()
        errorMessage = failures == 0 ? nil : "\(failures) of \(routeList.count) routes failed to write"
        print("[Maestro] InputRouting: reset to legacy defaults (\(routeList.count) routes, \(failures) failed)")
    }
}

/// Output Routing view — grid matrix mapping software outputs to hardware outputs.
///
/// Evidence: `og_source/maestro2/App/Controllers/OutputRouting/`
struct OutputRoutingView: View {
    private let appState: AppState
    @State private var routes: [Int: Set<Int>] = [:] // row → {cols} mapping (source → HW output dests, supports dual routing)
    /// Rows the user actually chose. Only these are persisted — see
    /// ``RoutingStateCache``. The output grid has never been seen poisoned the way
    /// the input grid was, but it cached the same way, so it could be.
    @State private var userChosenRows: Set<Int> = []
    @State private var hoverRow: Int? = nil
    @State private var hoverCol: Int? = nil
    @State private var errorMessage: String?
    @State private var isLoadingRoutes = true
    @State private var showLoadingIndicator = false

    /// The installed cards' layout — the grid's hardware columns come from here.
    private var layout: CardLayout { appState.cardLayout }

    /// Hardware OUTPUT columns: one per stereo pair the installed cards actually
    /// provide. Was hardcoded to 16, which offered eight columns for an absent
    /// board and eight more for an 8MicPre that has no outputs at all.
    private var columns: [CardLayout.RoutingColumn] { layout.outputRoutingColumns }

    private var hwPairCount: Int { columns.count }

    /// The grid column a hardware routing byte belongs to, or nil when these
    /// cards have no such column.
    private func column(forRoutingByte byte: UInt8) -> Int? {
        let left = byte - (byte % 2)
        return columns.firstIndex { $0.routingByte == left }
    }

    // Software output source row count = DAW playback channels / 2 (stereo pairs).
    private var swOutputPairCount: Int {
        (appState.device?.identifier.mode.channelCount ?? 16) / 2
    }

    // Output routing row labels: board-aware "A Line"/"A ADAT" + Mixer buses.
    // Evidence: original Maestro 2 shows "A Line 1/2", "A ADAT 1/2" etc.
    private var rowLabels: [(number: String, name: String)] {
        let total = swOutputPairCount
        let board1 = appState.primaryBoardType
        let board2 = appState.secondaryBoardType
        // Count analog output pairs across both boards
        let analogPairs = board1.analogOutputPairsForUI + board2.analogOutputPairsForUI

        var labels: [(number: String, name: String)] = []
        for i in 0..<total {
            let sw1 = i * 2 + 1
            let sw2 = i * 2 + 2
            if i < analogPairs {
                labels.append((number: "\(sw1)-\(sw2)", name: "A Line \(sw1)/\(sw2)"))
            } else {
                let adatIdx = (i - analogPairs) * 2 + 1
                labels.append((number: "\(sw1)-\(sw2)", name: "A ADAT \(adatIdx)/\(adatIdx + 1)"))
            }
        }

        // Mixer buses (Symphony IO MKI: always 2).
        let mixerStart = total * 2 + 1
        for i in 0..<2 {
            let ch1 = mixerStart + i * 2
            let ch2 = ch1 + 1
            labels.append((number: "\(ch1)-\(ch2)", name: "Mixer \(i+1)"))
        }
        return labels
    }

    // P3C-05: Routing presets
    @State private var presetNames: [String] = []
    private let presetKey = "outputRoutingPresets"

    private var routingCache: RoutingStateCache? {
        guard let id = appState.device?.identifier else { return nil }
        return RoutingStateCache(direction: "output", productID: id.productID)
    }

    /// Pending refusal / confirmation for Reset Routing. See ``RoutingResetPrompt``.
    @State private var resetPrompt: RoutingResetPrompt?

    init(appState: AppState) {
        self.appState = appState
        let snapshot = restoredRoutes(defaultRouteGrid())
        _routes = State(initialValue: snapshot)
        _userChosenRows = State(initialValue: Set(routingCache?.loadMulti()?.keys.map { $0 } ?? []))
        _presetNames = State(initialValue: Array(PresetManager.loadMultiRoutingPresetsAsSet(key: presetKey).keys.sorted()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Reset Routing") { requestRoutingReset() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .routingResetPrompt($resetPrompt) {
                    Task { await resetToDefaultRouting() }
                }
                Spacer()
                PresetMenuButton(
                    presetNames: presetNames,
                    onSave: { name in
                        // Mixer rows are stored under fixed sentinels so a preset
                        // survives a change in DAW pair count (USB 8, ThunderBridge 16).
                        PresetManager.saveMultiRoutingPreset(
                            name: name,
                            routes: RoutingPresetRows.encode(routes, dawPairCount: swOutputPairCount),
                            key: presetKey)
                        presetNames = Array(PresetManager.loadMultiRoutingPresetsAsSet(key: presetKey).keys.sorted())
                    },
                    onLoad: { name in
                        if let stored = PresetManager.loadMultiRoutingPresetsAsSet(key: presetKey)[name] {
                            let preset = RoutingPresetRows.decode(stored, dawPairCount: swOutputPairCount)
                                .mapValues { $0.filter { $0 >= 0 && $0 < columns.count } }
                                .filter { !$0.value.isEmpty }
                            // A preset is the whole table: outputs it does not
                            // mention go silent, so clear every column the old grid
                            // had routed that the preset leaves empty.
                            let covered = Set(preset.values.flatMap { $0 })
                            let orphaned: [(row: Int, col: Int)] = routes.flatMap { row, cols in
                                cols.filter { !covered.contains($0) }.map { (row: row, col: $0) }
                            }
                            routes = preset
                            userChosenRows.formUnion(preset.keys)
                            persistChosenRows()
                            Task {
                                for item in orphaned.sorted(by: { $0.col < $1.col }) {
                                    await writeRoute(row: item.row, col: item.col, clear: true)
                                }
                                for (row, cols) in preset.sorted(by: { $0.key < $1.key }) {
                                    for col in cols.sorted() {
                                        await writeRoute(row: row, col: col)
                                    }
                                }
                                if let device = appState.device {
                                    await HeadphoneCrosspoint.reapplyAll(
                                        device: device, cachedRoutes: appState.cachedOutputRouteMap(),
                                        transport: appState.transportType ?? .usb)
                                }
                            }
                        }
                    },
                    onDelete: { name in
                        PresetManager.deleteRoutingPreset(name: name, key: presetKey)
                        presetNames = Array(PresetManager.loadMultiRoutingPresetsAsSet(key: presetKey).keys.sorted())
                    }
                )
            }
            .disabled(isLoadingRoutes)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    // Output Routing column headers — board-aware OUTPUT analog/digital split.
                    let colLabels: [(type: String, channels: String)] =
                        columns.map { (type: $0.type, channels: $0.channels) }
                    RoutingGridView(
                        rowCount: rowLabels.count,
                        columnCount: hwPairCount,
                        rowLabels: rowLabels,
                        columnLabels: colLabels,
                        rowGroupLabel: "Software Outputs",
                        colGroupLabel: "Hardware Outputs",
                        isActiveCell: { row, col in routes[row]?.contains(col) == true },
                        hoverRow: $hoverRow,
                        hoverCol: $hoverCol,
                        columnMeterLevels: [],
                        onCellTap: { row, col in
                            guard !isLoadingRoutes else { return }
                            // Toggle: if this (row,col) is active, remove it; otherwise add it.
                            // Each column can only have one source row — clear other rows' claim.
                            let removing = routes[row]?.contains(col) == true
                            if removing {
                                routes[row]?.remove(col)
                                if routes[row]?.isEmpty == true { routes.removeValue(forKey: row) }
                            } else {
                                // Remove col from any other row (one source per HW output)
                                for (key, vals) in routes where vals.contains(col) {
                                    routes[key]?.remove(col)
                                    if routes[key]?.isEmpty == true { routes.removeValue(forKey: key) }
                                }
                                routes[row, default: []].insert(col)
                            }
                            userChosenRows.insert(row)
                            persistChosenRows()
                            Task { await writeRoute(row: row, col: col, clear: removing) }
                        }
                    )
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
            }

            if let error = errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("Output Routing")
        .overlay {
            if isLoadingRoutes && showLoadingIndicator {
                ProgressView("Loading routes…")
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: "\(appState.viewReloadToken)-\(appState.cardLayoutToken)") {
            isLoadingRoutes = true
            showLoadingIndicator = false
            // Only show indicator if loading takes more than 300ms
            let indicatorTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled && isLoadingRoutes { showLoadingIndicator = true }
            }
            // Same order as the input grid: measurement if there is one, otherwise
            // the default table, with the user's own picks laid over the top.
            let measured = await loadRoutes()
            guard !Task.isCancelled else { indicatorTask.cancel(); return }
            routes = restoredRoutes(measured.isEmpty ? defaultRouteGrid() : measured)
            userChosenRows = Set(routingCache?.loadMulti()?.keys.map { $0 } ?? [])
            presetNames = Array(PresetManager.loadMultiRoutingPresetsAsSet(key: presetKey).keys.sorted())
            isLoadingRoutes = false
            showLoadingIndicator = false
            indicatorTask.cancel()
        }
    }

    /// Read current output routing from hardware via USB command 0x31.
    ///
    /// For each HW output destination (IOBoard bytes), reads the source byte,
    /// then reverse-maps to the row index (P2P pair or Mixer bus).
    /// Multiple columns can map to the same row (dual routing).
    ///
    /// The grid to show when the hardware read came back with nothing.
    ///
    /// Derived from `SymphonyIODefaultRouting.outputRoutes` — the same table
    /// `Reset Routing` writes — so the grid the user is looking at is the grid
    /// the device would have after a reset.
    ///
    /// This replaced a hand-rolled "dual routing" pattern that put row `i` on
    /// columns `i` AND `hwPairCount/2 + i`. On a 16x16 card (8 hardware pairs)
    /// that gave rows 1-4 two crosspoints each and left columns 9/10-15/16
    /// claimed by two different sources at once — a state the grid's own click
    /// handler forbids ("each column can only have one source row") and the
    /// hardware cannot hold. Display only: nothing is written here.
    private func restoredRoutes(_ base: [Int: Set<Int>]) -> [Int: Set<Int>] {
        var routes = base
        for (row, cols) in routingCache?.loadMulti() ?? [:] where row >= 0 && row < swOutputPairCount {
            let live = cols.filter { $0 >= 0 && $0 < columns.count }
            guard !live.isEmpty else { continue }
            // A hardware output carries one source, so claiming it for this row
            // releases it from whichever default row held it.
            for (other, others) in routes where other != row {
                let remaining = others.subtracting(live)
                if remaining.isEmpty { routes.removeValue(forKey: other) }
                else { routes[other] = remaining }
            }
            routes[row] = live
        }
        return routes
    }

    /// The legacy default output table for the given cards on this transport.
    /// Over USB the proxy renders 16 playback channels (see
    /// `SymphonyIODefaultRouting.usbChannelCount`); ThunderBridge carries 32,
    /// board 1 ← playback 17-32, as XLink sources.
    private func defaultOutputRouteList(board1: IOCardType, board2: IOCardType) -> [SymphonyIODefaultRouting.Route] {
        let transport = appState.transportType ?? .usb
        return SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: board1.analogOutputChannels, digital: board1.digitalOutputChannels),
            board1: .init(analog: board2.analogOutputChannels, digital: board2.digitalOutputChannels),
            usbChannelCount: transport == .thunderbolt
                ? Int(ThunderboltCardRouting.channelCount)
                : SymphonyIODefaultRouting.usbChannelCount,
            playbackBase: SymphonyIORoutingAddress.hostPlaybackBase(for: transport))
    }

    private func defaultRouteGrid() -> [Int: Set<Int>] {
        let routeList = defaultOutputRouteList(board1: appState.primaryBoardType,
                                               board2: appState.secondaryBoardType)
        var grid: [Int: Set<Int>] = [:]
        for route in routeList {
            guard route.source != SymphonyIORoutingAddress.none,
                  route.destination % 2 == 0,
                  let col = column(forRoutingByte: route.destination),
                  let row = sourceByteToRow(route.source)
            else { continue }
            grid[row, default: []].insert(col)
        }
        return grid
    }

    /// Persist only the crosspoints a person actually picked — see the input
    /// grid's twin of this and ``RoutingStateCache`` for why the derived table
    /// must never be written here.
    private func persistChosenRows() {
        routingCache?.save(routes.filter { userChosenRows.contains($0.key) })
    }

    /// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp`
    private func loadRoutes() async -> [Int: Set<Int>] {
        guard let device = appState.device else { return [:] }
        var routes: [Int: Set<Int>] = [:]

        for (col, column) in columns.enumerated() {
            guard !Task.isCancelled else { return [:] }
            let destByte = column.routingByte

            do {
                let result = try await device.getProperty(
                    PropertyAddress(selector: .routing, scope: .output, element: UInt32(destByte))
                )
                if let srcByte = result.asUInt32 {
                    if let row = sourceByteToRow(UInt8(srcByte)) {
                        routes[row, default: []].insert(col)
                    }
                }
            } catch {
                print("[Maestro] OutputRouting: read col \(col) (dest \(destByte)) failed: \(error)")
            }
        }

        let totalRoutes = routes.values.reduce(0) { $0 + $1.count }
        print("[Maestro] OutputRouting: loaded \(totalRoutes) routes (\(routes.count) rows) from hardware")
        return routes
    }

    /// Reverse-map a USB source byte to an output routing row index.
    /// P2P bytes (192-207) → DAW pair rows. Mixer bytes (64-65, 96-97) → Mixer rows.
    private func sourceByteToRow(_ byte: UInt8) -> Int? {
        // Host playback: P2P (192+) on USB, XLink RX (0+) on ThunderBridge.
        let playbackBase = SymphonyIORoutingAddress.hostPlaybackBase(for: appState.transportType ?? .usb)
        if byte >= playbackBase && byte < playbackBase + UInt8(swOutputPairCount * 2) {
            return Int(byte - playbackBase) / 2
        }
        let mixer0 = SymphonyIORoutingAddress.mixer0Base
        if byte == mixer0 || byte == mixer0 + 1 {
            return swOutputPairCount  // Mixer 1 row
        }
        let mixer1 = SymphonyIORoutingAddress.mixer1Base
        if byte == mixer1 || byte == mixer1 + 1 {
            return swOutputPairCount + 1  // Mixer 2 row
        }
        return nil
    }

    /// Write a stereo output routing pair via USB command 0x31.
    ///
    /// Maps (row, col) to USB routing bytes and writes both L+R channels.
    /// Output routing: destination = IOBoard byte (32-63), source = P2P byte (192+) or Mixer byte.
    ///
    /// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIORouting.h`
    private func writeRoute(row: Int, col: Int, clear: Bool = false) async {
        guard !isLoadingRoutes else { return }
        guard let device = appState.device else { return }
        let board1 = appState.primaryBoardType
        let board2 = appState.secondaryBoardType

        // Destination = HW output IOBoard byte
        guard col >= 0, col < columns.count else {
            print("[Maestro] OutputRouting: col \(col) out of range for board types \(board1)/\(board2)")
            errorMessage = "Invalid routing column"
            return
        }
        let destLeft = columns[col].routingByte

        // Source = P2P (DAW) or Mixer byte
        let srcLeft: UInt8
        if clear {
            // Removing a route writes the legacy "no source" value (236), the
            // same byte the default table uses for an unassigned output
            // (SymphonyIOUSBAudioRoutingController.cpp:628/707 writes
            // eSymphonyIORoutingSource_None for every unrouted destination).
            // 0xFF ("clear and mute the destination") was tried first and left
            // the output frozen on its last sample — stuck front-panel meter,
            // and on this unit the right channel stayed dead until a reset
            // rewrote it (2026-10-22 12:10, USB). On ThunderBridge the card
            // path disables the channel for either value.
            srcLeft = SymphonyIORoutingAddress.none
        } else if row < swOutputPairCount {
            // DAW playback pair — P2P on USB, XLink RX on ThunderBridge.
            srcLeft = SymphonyIORoutingAddress.hostPlaybackBase(for: appState.transportType ?? .usb)
                + UInt8(row * 2)
        } else if row == swOutputPairCount {
            // Mixer 1
            srcLeft = SymphonyIORoutingAddress.mixer0Base
        } else if row == swOutputPairCount + 1 {
            // Mixer 2
            srcLeft = SymphonyIORoutingAddress.mixer1Base
        } else {
            errorMessage = "Invalid source row"
            return
        }

        do {
            // Symphony 0x31 table over USB; card output routing on ThunderBridge.
            try await appState.writeOutputRoutePair(destLeft: destLeft, srcLeft: srcLeft, device: device)
            errorMessage = nil
            userChosenRows.insert(row)
            persistChosenRows()
            print("[Maestro] OutputRouting: wrote row \(row) → col \(col) (dest \(destLeft), src \(srcLeft), clear=\(clear))")
            // Legacy re-runs RouteHeadphones() after every routing change, because a
            // headphone's crosspoint source is inherited from the output pair it
            // follows — SymphonyIOUSBAudioRoutingController.cpp:1005-1008, :1193-1196.
            // Without this the headphone keeps feeding on the previous source.
            await HeadphoneCrosspoint.reapplyAll(
                device: device, cachedRoutes: appState.cachedOutputRouteMap(),
            transport: appState.transportType ?? .usb)
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

    /// Build the refusal or the confirmation for Reset Routing, and show it.
    ///
    /// Nothing is written from here. The confirmation names the cards the app
    /// believes are installed and, line by line, what every hardware output will
    /// end up carrying — ADAT included, because that is the destination a wrong
    /// card silently re-points.
    private func requestRoutingReset() {
        guard appState.device != nil else { return }
        let b1 = appState.primaryBoardReading
        let b2 = appState.secondaryBoardReading
        if let refusal = RoutingResetGuard.refusalReason(board1: b1, board2: b2) {
            resetPrompt = RoutingResetPrompt(
                title: "Reset Output Routing", message: refusal, isRefusal: true)
            print("[Maestro] OutputRouting: reset refused — slot provenance \(b1.source.rawValue)/\(b2.source.rawValue)")
            return
        }
        let plan = RoutingResetGuard.outputPlanLines(board1: b1.card, board2: b2.card)
        resetPrompt = RoutingResetPrompt(
            title: "Reset Output Routing",
            message: """
                Detected cards — Slot 1: \(b1.displayText), Slot 2: \(b2.displayText).

                Every hardware output will be re-pointed to the default:

                \(plan.joined(separator: "\n"))
                """,
            isRefusal: false)
    }

    /// Restore the daemon's default output routing (`ResetOutputRouting`).
    ///
    /// Board-aware: analog destinations across both slots first, then digital,
    /// each fed from the next USB playback channel. This is not a diagonal and
    /// not the dual map we used to write — see ``SymphonyIODefaultRouting``.
    ///
    /// Only reachable through ``requestRoutingReset()``, which refuses unless both
    /// slots were genuinely detected this session.
    private func resetToDefaultRouting() async {
        guard let device = appState.device else { return }
        let b1 = appState.primaryBoardReading
        let b2 = appState.secondaryBoardReading
        // Provenance guard, re-checked at the point of writing. The default table
        // is derived ENTIRELY from the card types: misreading slot 1 as a second
        // Optical card moves ADAT 1-8 from DAW 9-16 onto DAW 1-8. `readCardTypes()`
        // keeps the stale value when a live read fails, so a WRONG card — not
        // `.none` — is the expected failure mode, and only `.detected` is safe.
        guard RoutingResetGuard.refusalReason(board1: b1, board2: b2) == nil else {
            errorMessage = "I/O cards were not detected this session — routing reset is unavailable."
            print("[Maestro] OutputRouting: reset refused at write time, provenance not .detected")
            return
        }
        // Over USB: 16, not the device mode's channel count — see
        // `SymphonyIODefaultRouting.usbChannelCount`. In 8-ch mode the mode count
        // wrapped ADAT 1-8 back onto DAW 1-8; in 32-ch mode it assigned USB 16-31,
        // which the proxy never renders. ThunderBridge renders all 32.
        let routeList = defaultOutputRouteList(board1: b1.card, board2: b2.card)

        var newRoutes: [Int: Set<Int>] = [:]
        var failures = 0
        for route in routeList {
            do {
                try await appState.writeOutputRoute(destination: route.destination, source: route.source,
                                                    device: device)
            } catch {
                failures += 1
                continue
            }
            // Rebuild the grid from the left channel of each pair only.
            guard route.source != SymphonyIORoutingAddress.none,
                  let col = column(forRoutingByte: route.destination),
                  let row = sourceByteToRow(route.source),
                  route.destination % 2 == 0
            else { continue }
            newRoutes[row, default: []].insert(col)
        }

        routes = newRoutes
        // The defaults are now on the hardware; there are no overrides left.
        userChosenRows.removeAll()
        persistChosenRows()
        errorMessage = failures == 0 ? nil : "\(failures) of \(routeList.count) routes failed to write"
        print("[Maestro] OutputRouting: reset to legacy defaults (\(routeList.count) routes, \(failures) failed)")
        await HeadphoneCrosspoint.reapplyAll(
            device: device, cachedRoutes: appState.cachedOutputRouteMap(),
            transport: appState.transportType ?? .usb)
    }
}

// MARK: - Routing Grid

/// Reusable routing grid matrix matching legacy Maestro 2 layout.
///
/// Layout:
///   Top-left corner: rowGroupLabel ("Software Inputs" / "Software Outputs")
///   Top-right header: colGroupLabel ("Hardware Inputs" / "Hardware Outputs")
///   Column headers: two-line (type on top, channel pair on bottom), evenly spaced
///   Row labels: number cell (bold, darker) + name cell (secondary, lighter)
///   Cells: X marker for active route, hover crosshair highlight
///
/// Evidence: `og_source/maestro2/App/Views/APRoutingCrossPointView.m`
struct RoutingGridView: View {
    let rowCount: Int
    let columnCount: Int
    let rowLabels: [(number: String, name: String)]
    let columnLabels: [(type: String, channels: String)]
    let rowGroupLabel: String   // e.g. "Software Inputs"
    let colGroupLabel: String   // e.g. "Hardware Inputs"
    let isActiveCell: (Int, Int) -> Bool  // (row, col) → active?
    @Binding var hoverRow: Int?
    @Binding var hoverCol: Int?
    /// Per-column dBFS meter level (-60..0). Empty array = no meters shown.
    var columnMeterLevels: [Double] = []
    let onCellTap: (Int, Int) -> Void

    private let cellSize: CGFloat = 40
    private let cellHeight: CGFloat = 22
    private let numWidth: CGFloat = 40   // wide enough for "23-24" without wrapping
    private let nameWidth: CGFloat = 86
    private let colHeaderHeight: CGFloat = 40

    var labelWidth: CGFloat { numWidth + nameWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Row 1: blank left | "Hardware Inputs/Outputs" ───────────────
            // Same height as colHeaderHeight so both header cells are the same visual weight.
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: colHeaderHeight)
                Text(colGroupLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 6)
                    .frame(width: CGFloat(columnCount) * cellSize, height: colHeaderHeight, alignment: .leading)
                    .background(Color.gray.opacity(0.35))
            }

            // ── Row 2: "Software Inputs/Outputs" label | column type headers ────
            // Placing the row group label here (same row as column headers, above
            // first data row) matches the legacy Maestro 2 layout.
            HStack(spacing: 0) {
                Text(rowGroupLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 6)
                    .frame(width: labelWidth, height: colHeaderHeight, alignment: .leading)
                    .background(Color.gray.opacity(0.45))

                ForEach(0..<columnCount, id: \.self) { col in
                    VStack(spacing: 1) {
                        // Show a compact dBFS meter bar above the label when levels are provided.
                        if !columnMeterLevels.isEmpty {
                            let level = col < columnMeterLevels.count ? columnMeterLevels[col] : -60.0
                            let fraction = max(0.0, min(1.0, (level + 60.0) / 60.0))
                            let meterColor: Color = level > -6 ? .red.opacity(0.85) : (level > -18 ? .yellow.opacity(0.8) : .green.opacity(0.75))
                            ZStack(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                Rectangle()
                                    .fill(meterColor)
                                    .frame(height: 12.0 * fraction)
                            }
                            .frame(width: cellSize - 8, height: 12)
                        }
                        Text(col < columnLabels.count ? columnLabels[col].type : "")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(col < columnLabels.count ? columnLabels[col].channels : "\(col)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: cellSize, height: colHeaderHeight)
                    .border(Color.gray.opacity(0.15), width: 0.5)
                }
            }

            // ── Grid rows ───────────────────────────────────────────────
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 0) {
                    // Number cell — bold, slightly darker background.
                    // numWidth=40 gives ~36pt of text space; .lineLimit(1) prevents wrapping.
                    Text(row < rowLabels.count ? rowLabels[row].number : "\(row)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                        .frame(width: numWidth, height: cellHeight, alignment: .trailing)
                        .background(row % 2 == 0 ? Color.gray.opacity(0.18) : Color.gray.opacity(0.12))

                    // Name cell — secondary style. Interior padding keeps width = nameWidth.
                    Text(row < rowLabels.count ? rowLabels[row].name : "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                        .frame(width: nameWidth, height: cellHeight, alignment: .trailing)
                        .background(row % 2 == 0 ? Color.gray.opacity(0.08) : Color.gray.opacity(0.04))

                    // Routing cells
                    ForEach(0..<columnCount, id: \.self) { col in
                        let isActive = isActiveCell(row, col)
                        let isHovered = hoverRow == row || hoverCol == col

                        Button {
                            onCellTap(row, col)
                        } label: {
                            ZStack {
                                Rectangle()
                                    .fill(cellBackground(isActive: isActive, isHovered: isHovered, row: row, col: col))
                                    .frame(width: cellSize, height: cellHeight)
                                    .border(Color.gray.opacity(0.2), width: 0.5)

                                if isActive {
                                    Text("X")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                hoverRow = row
                                hoverCol = col
                            } else if hoverRow == row && hoverCol == col {
                                hoverRow = nil
                                hoverCol = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private func cellBackground(isActive: Bool, isHovered: Bool, row: Int, col: Int) -> Color {
        if isActive { return Color.gray.opacity(0.7) }
        if isHovered { return Color.purple.opacity(0.15) }
        return row % 2 == 0 ? Color.gray.opacity(0.05) : Color.gray.opacity(0.1)
    }
}

/// Preset toolbar button for routing views and mixer view.
struct PresetMenuButton: View {
    let presetNames: [String]
    let onSave: (String) -> Void
    let onLoad: (String) -> Void
    let onDelete: (String) -> Void

    @State private var showSaveAlert: Bool = false
    @State private var newPresetName: String = ""

    var body: some View {
        Menu {
            Section("Load Preset") {
                if presetNames.isEmpty {
                    Text("No presets saved")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(presetNames, id: \.self) { name in
                        Button(name) { onLoad(name) }
                    }
                }
            }

            Divider()

            Button("Save Preset...") {
                newPresetName = ""
                showSaveAlert = true
            }

            if !presetNames.isEmpty {
                Menu("Delete Preset") {
                    ForEach(presetNames, id: \.self) { name in
                        Button(name, role: .destructive) { onDelete(name) }
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help("Presets")
        .alert("Save Preset", isPresented: $showSaveAlert) {
            TextField("Preset Name", text: $newPresetName)
            Button("Save") {
                if !newPresetName.isEmpty { onSave(newPresetName) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Headphone crosspoint (the audible half of Output Source)

/// Programs the FPGA crosspoint that actually feeds the headphone jacks.
///
/// The headphone Output Source popup is a two-step operation and `0x54`
/// `HeadphoneAssignments` — the step we used to do alone — is *storage only*.
/// The vendor header says so outright: "1 byte, opaque for the firmware.
/// Software uses it to store/recall the headphone assignment"
/// (`SymphonyIOVendorSpecific.h:274-276`). Nothing audible changed, which is the
/// "headphone Input Select does nothing" report.
///
/// The audible step is legacy's `RouteHeadphones()`
/// (`SymphonyIO_Stream.cpp:756-805`): a `0x31` write to destinations 224/225
/// (HP1) or 226/227 (HP2), whose **source is inherited** — it reads whatever
/// Output Routing currently feeds the chosen hardware output pair
/// (`GetRoutedToHWSource`,
/// `SymphonyIOUSBAudioRoutingController.cpp:382-396`) and copies that byte
/// across. Legacy re-runs it after every routing change
/// (`SymphonyIOUSBAudioRoutingController.cpp:1005-1008`, `:1193-1196`) and after
/// a routing reset (`SymphonyIO_Stream.cpp:429-437`).
///
/// ## ADAT safety
///
/// Everything here writes ONLY destinations 224-227. It never writes an IOBoard
/// destination (32-63), never touches optical format, and never issues `0xC2`.
/// The hardware output pair named by the source ID is *read*, not written.
enum HeadphoneCrosspoint {

    /// Source ID last applied in this session, per headphone. Preferred over a
    /// `0x54` read: the register is opaque storage and a failed EP0 read shows up
    /// as 0xFF, which decodes to two perfectly plausible nibbles (15/15).
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastApplied: [Int: UInt32] = [:]

    private static func remember(_ headphone: SymphonyIOHeadphoneRouting.Headphone, _ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        lastApplied[headphone.rawValue] = id
    }

    private static func recalled() -> [Int: UInt32] {
        lock.lock(); defer { lock.unlock() }
        return lastApplied
    }

    /// Apply the crosspoint for one headphone from a source ID (0-15).
    ///
    /// `cachedRoutes` is the app's own persisted output routing
    /// (`AppState.cachedOutputRouteMap()`), destination byte → source byte.
    /// Nothing here reads the hardware: `0x31` route readback returns residue
    /// (`0x20` for every destination 32-191, DAC L/R included — measured, see
    /// `Docs/issue-1-research.md`), and byte 32 in SOURCE space is analog input 1.
    /// Inheriting that would silently swap a headphone from the DAW mix to a mono
    /// analog input — silence with nothing plugged in.
    ///
    /// Returns true when both channels were written. When no source can be
    /// determined for either channel this writes NOTHING and says why; the
    /// firmware default then stands, which is what stood before this feature.
    @discardableResult
    static func apply(
        _ headphone: SymphonyIOHeadphoneRouting.Headphone,
        sourceID: UInt32,
        device: any DeviceConnection,
        cachedRoutes: [UInt8: UInt8],
        transport: TransportType = .usb
    ) async -> Bool {
        guard let pair = SymphonyIOHeadphoneRouting.outputPairDestinations(sourceID: sourceID) else {
            print("[Maestro] HP routing: source ID \(sourceID) is out of range 0-15 — skipping crosspoint")
            return false
        }
        remember(headphone, sourceID)

        guard let srcLeft = SymphonyIOHeadphoneRouting.inheritedSource(
                forDestination: pair.left, cachedRoutes: cachedRoutes, transport: transport),
              let srcRight = SymphonyIOHeadphoneRouting.inheritedSource(
                forDestination: pair.right, cachedRoutes: cachedRoutes, transport: transport)
        else {
            print("""
                [Maestro] HP\(headphone.rawValue + 1) crosspoint: no source known for outputs \
                \(pair.left)/\(pair.right) — neither the app's cached output routing nor the \
                proxy boot table names one. Writing nothing; the firmware default stands. \
                (Hardware route readback is residue and is deliberately not consulted.)
                """)
            return false
        }

        do {
            let dest = SymphonyIOHeadphoneRouting.headphoneDestinations(headphone)
            try await device.setProperty(
                PropertyAddress(selector: .routing, scope: .output, element: UInt32(dest.left)),
                value: .uint32(UInt32(srcLeft)))
            try await device.setProperty(
                PropertyAddress(selector: .routing, scope: .output, element: UInt32(dest.right)),
                value: .uint32(UInt32(srcRight)))
            print("[Maestro] HP\(headphone.rawValue + 1) crosspoint: dest \(dest.left)/\(dest.right) ← src \(srcLeft)/\(srcRight) (source ID \(sourceID), inherited from outputs \(pair.left)/\(pair.right))")
            return true
        } catch {
            print("[Maestro] HP\(headphone.rawValue + 1) crosspoint failed: \(error)")
            return false
        }
    }

    /// Re-apply both headphones after an Output Routing change, mirroring legacy
    /// (`SymphonyIOUSBAudioRoutingController.cpp:1005-1008`, `:1193-1196`).
    ///
    /// Only headphones whose source the user has actually chosen in this session
    /// are touched. Nothing is guessed: without a known source this writes no
    /// crosspoint at all, because guessing would silently re-point a jack.
    static func reapplyAll(device: any DeviceConnection, cachedRoutes: [UInt8: UInt8],
                           transport: TransportType = .usb) async {
        let known = recalled()
        guard !known.isEmpty else { return }
        for headphone in SymphonyIOHeadphoneRouting.Headphone.allCases {
            guard let id = known[headphone.rawValue] else { continue }
            await apply(headphone, sourceID: id, device: device, cachedRoutes: cachedRoutes,
                        transport: transport)
        }
    }
}
