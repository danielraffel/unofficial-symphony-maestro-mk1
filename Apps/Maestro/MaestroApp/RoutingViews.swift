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
    // AppShell rebuilds per-unit pages on picker changes. Capture the connection
    // and cache too: an outstanding write must never follow the picker to A.
    private let unit: DeviceUnit
    private let device: (any DeviceConnection)?
    private let unitBCache: RoutingStateCache?
    private var prefix: String { unit == .b ? appState.unitBPeripheralPrefix : appState.peripheralPrefix }
    private var board1: IOCardType { unit == .b ? (appState.unitB?.slot1 ?? .none) : appState.primaryBoardType }
    private var board2: IOCardType { unit == .b ? (appState.unitB?.slot2 ?? .none) : appState.secondaryBoardType }
    private var board1Reading: BoardTypeReading {
        unit == .b ? BoardTypeReading(card: board1, source: appState.unitBBoardSource(slot: 0)) : appState.primaryBoardReading
    }
    private var board2Reading: BoardTypeReading {
        unit == .b ? BoardTypeReading(card: board2, source: appState.unitBBoardSource(slot: 1)) : appState.secondaryBoardReading
    }
    private var canWrite: Bool {
        (unit == .a || appState.unitBInputRoutingAllowed) && !appState.hardwareWritesSuspended
    }
    private var unitBResetRoutes: [SymphonyIODefaultRouting.Route] {
        // Original ResetInputRouting: analog across boards, then AES/optical.
        // Evidence: og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:714-792.
        SymphonyIODefaultRouting.inputRoutes(
            board0: .init(analog: board1.analogInputChannels, digital: board1.digitalInputChannels),
            board1: .init(analog: board2.analogInputChannels, digital: board2.digitalInputChannels),
            usbChannelCount: 32)
    }
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
        unit == .b ? 16 : (device?.identifier.mode.channelCount ?? 16) / 2
    }

    /// The installed cards' layout — the grid's hardware columns come from here.
    private var layout: CardLayout { unit == .b ? (appState.unitBLayout ?? CardLayout(isKnown: false)) : appState.cardLayout }

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
        columns.map { (type: unit == .b ? "\(prefix) \($0.type)" : $0.type, channels: $0.channels) }
    }

    /// The grid column a hardware routing byte belongs to, or nil when these
    /// cards have no such column.
    private func column(forRoutingByte byte: UInt8) -> Int? {
        let left = byte - (byte % 2)
        return columns.firstIndex { $0.routingByte == left }
    }

    // P3C-05: Routing presets
    @State private var presetNames: [String] = []
    private var presetKey: String { unit == .b ? "inputRoutingPresets.unitB" : "inputRoutingPresets" }

    private var routingCache: RoutingStateCache? {
        if unit == .b { return unitBCache }
        guard device != nil, appState.connectionMode != .hardware || appState.unitAIdentity != nil else { return nil }
        let cache = appState.peripheralRoutingCache(direction: "input")
        // Same one-time clear the connect-time replay runs, in case this page
        // reads the saved choices first.
        if appState.transportType == .thunderbolt {
            ThunderboltInputRoutingMigration.run(routingKey: cache.key)
        }
        return cache
    }

    /// Pending refusal / confirmation for Reset Routing. See ``RoutingResetPrompt``.
    @State private var resetPrompt: RoutingResetPrompt?

    init(appState: AppState) {
        self.appState = appState
        unit = appState.activeUnit
        device = appState.unitDevice
        unitBCache = appState.unitBInputRoutingCache
        let snapshot = restoredRoutes(defaultRouteGrid())
        _routes = State(initialValue: snapshot)
        _userChosenRows = State(initialValue: Set(routingCache?.load()?.keys.map { $0 } ?? []))
        _presetNames = State(initialValue: Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted()))
    }

    var body: some View {
        // Converters: the card's input routing (0xB6) over their channels.
        // The Symphony I/O grid below writes the unit's own router (P2P
        // routes), which a converter does not have.
        if appState.converterRoutingSurface {
            if let layout = appState.converterRoutingLayout {
                ConverterInputRoutingView(appState: appState, layout: layout)
            } else {
                ConverterRoutingUnavailableNote(
                    title: "Input Routing",
                    driverTooOld: appState.converterSystem?.driverSupportsConverterControls == false)
            }
        } else {
            VStack(spacing: 0) {
                // ThunderBridge exposes the card as one routing device. With
                // two Symphony I/Os the combined card grid owns the whole
                // surface; the per-unit grid remains the single-unit page.
                if appState.showsSymphonyCardInputGrid {
                    SymphonyCardInputRoutingView(appState: appState)
                } else {
                    routingGrid
                        .onChange(of: appState.activeUnit) { _, _ in
                            presetNames = Array(PresetManager.loadMultiRoutingPresetsAsSet(key: presetKey).keys.sorted())
                        }
                }
            }
        }
    }

    private var routingGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Reset Routing") {
                    requestRoutingReset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .maestroHelp("Put Input Routing back to the default: each software input records the matching hardware input.")
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
                                    await writeRoute(row: row, col: col, notifyMixer: false)
                                }
                                if appState.transportType == .thunderbolt { appState.thunderboltInputRoutingDidChange() }
                            }
                        }
                    },
                    onDelete: { name in
                        PresetManager.deleteRoutingPreset(name: name, key: presetKey)
                        presetNames = Array(PresetManager.loadRoutingPresets(key: presetKey).keys.sorted())
                    }
                )
            }
            .disabled(isLoadingRoutes || !canWrite)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    // Each software input is named after what is routed to it
                    // (the original's Core Audio names, `SymphonyCard.cpp:828-866`),
                    // so a row follows its route, the rate, format and Replaces.
                    // Converters: named after the unit channels each Mac input
                    // pair carries ("A Line 1/2"), as the driver names them.
                    let names = layout.converterPairNames(isInput: true, pairCount: pairCount)
                        ?? CardLayout.softwareInputRowNames(
                            rowCount: pairCount, routes: routes, columns: columns,
                            prefix: prefix)
                    let rowLabels: [(number: String, name: String)] = (0..<pairCount).map { i in
                        (number: "\(i * 2 + 1 + (unit == .b ? 32 : 0))-\(i * 2 + 2 + (unit == .b ? 32 : 0))", name: names[i])
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
                            guard !isLoadingRoutes, canWrite else { return }
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
        .task(id: "\(appState.viewReloadToken)-\(appState.cardLayoutToken)-\(appState.unitBLayoutToken)-\(prefix)") {
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
        // ThunderBridge: what the driver actually programs, card by card
        // (host input n from slot 1 channel n, then slot 2 from where slot
        // 1's inputs end: 12 behind a 2x6, 16 otherwise).
        // The USB table below put every analog channel first, so this grid
        // showed Line 9-24 on inputs 9-24 while the unit had slot 1's
        // digital channels there.
        if appState.transportType == .thunderbolt {
            return SymphonyIODefaultRouting.inputGrid(
                SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: unit == .b ? appState.unitB?.slot1 : appState.thunderboltCaptureSlot1), columns: columns)
        }
        let board1 = self.board1
        let board2 = self.board2
        // Same record-channel count Reset Routing writes (the mode's count:
        // 16/8 in the USB modes).
        let routeList = SymphonyIODefaultRouting.inputRoutes(
            board0: .init(analog: board1.analogInputChannels, digital: board1.digitalInputChannels),
            board1: .init(analog: board2.analogInputChannels, digital: board2.digitalInputChannels),
            usbChannelCount: device?.identifier.mode.channelCount
                ?? SymphonyIODefaultRouting.usbChannelCount)
        return SymphonyIODefaultRouting.inputGrid(routeList, columns: columns)
    }

    /// Persist only the crosspoints a person actually picked.
    ///
    /// The rest of ``routes`` is ``defaultRouteGrid``'s guess, redrawn from the
    /// card layout on every appearance. Writing that guess here would freeze it —
    /// the cache outranks the default, so a guess made while the card layout was
    /// still unknown would outlive the cards themselves. See ``RoutingStateCache``.
    private func persistChosenRows() {
        routingCache?.save(routes.filter { userChosenRows.contains($0.key) })
        appState.symphonyCardInputNamingRevision += 1
    }

    /// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:714-792`
    private func loadRoutes() async -> [Int: Int] {
        guard let device else { return [:] }
        // ThunderBridge reads through this path always failed until the
        // request-size fix in 0.8.36, so this grid has only ever been built from
        // the default table plus saved choices there. Unchanged until the
        // readback has been checked against real hardware.
        if appState.transportType == .thunderbolt { return [:] }
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
    private func writeRoute(row: Int, col: Int, notifyMixer: Bool = true) async {
        guard !isLoadingRoutes, canWrite, let device else { return }
        let board1 = self.board1
        let board2 = self.board2

        guard row >= 0, row < pairCount, col >= 0, col < columns.count else {
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
            if notifyMixer, appState.transportType == .thunderbolt { appState.thunderboltInputRoutingDidChange() }
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
        if appState.unitBOnCard {
            let refusal = RoutingResetGuard.refusalReason(board1: appState.primaryBoardReading, board2: appState.secondaryBoardReading)
            let ready = refusal == nil && appState.unitBInputRoutingAllowed
                && appState.unitBBoardSource(slot: 0) == .detected && appState.unitBBoardSource(slot: 1) == .detected
            resetPrompt = RoutingResetPrompt(title: "Reset Input Routing",
                message: ready ? "Reset input routing for the whole card and both Symphony I/Os (channels 1–64)?"
                    : (refusal ?? "Maestro has not read the second Symphony I/O's cards since it connected."), isRefusal: !ready)
            return
        }
        guard canWrite, let device else { return }
        let b1 = board1Reading
        let b2 = board2Reading
        if let refusal = RoutingResetGuard.refusalReason(board1: b1, board2: b2) {
            resetPrompt = RoutingResetPrompt(
                title: "Reset Input Routing", message: refusal, isRefusal: true)
            print("[Maestro] InputRouting: reset refused — slot provenance \(b1.source.rawValue)/\(b2.source.rawValue)")
            return
        }
        resetPrompt = RoutingResetPrompt(
            title: "Reset Input Routing",
            message: RoutingResetGuard.inputResetMessage(
                board1: b1.card, board2: b2.card,
                usbChannelCount: device.identifier.mode.channelCount,
                routes: unit == .b ? unitBResetRoutes : appState.transportType == .thunderbolt
                    ? SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: appState.thunderboltCaptureSlot1) : nil,
                hostChannelOffset: unit == .b ? 32 : 0,
                alsoResetsCardMapping: appState.showsSymphonyCardInputGrid),
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
        if appState.unitBOnCard {
            do {
                try await appState.resetTwoUnitRouting(input: true)
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
            return
        }
        guard canWrite, let device else { return }
        let b1 = board1Reading
        let b2 = board2Reading
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
        if appState.symphonyCardInputs.channelCount > 0,
           !(await appState.applySymphonyCardInputs([:], reset: true)) {
            errorMessage = "The card refused Reset Routing."
            return
        }
        let usbChannels = device.identifier.mode.channelCount

        // Preserve unit A's ThunderBridge startup table; B uses the original reset order.
        let routeList = unit == .b ? unitBResetRoutes : appState.transportType == .thunderbolt
            ? SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: appState.thunderboltCaptureSlot1)
            : SymphonyIODefaultRouting.inputRoutes(
                board0: .init(analog: board1.analogInputChannels, digital: board1.digitalInputChannels),
                board1: .init(analog: board2.analogInputChannels, digital: board2.digitalInputChannels),
                usbChannelCount: usbChannels)

        var newRoutes: [Int: Int] = [:]
        var failures = 0
        for route in routeList {
            guard !Task.isCancelled, canWrite else { return }
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

        // A partial B reset must not discard the choices needed for retry.
        if unit == .b && failures > 0 {
            errorMessage = "\(failures) of \(routeList.count) routes failed to write"
            return
        }
        routes = newRoutes
        // Unit A retains its existing cache-clearing behavior.
        if unit == .b {
            // B resets to the original analog-first table, which can differ
            // from the driver's startup table; remember that explicit choice.
            userChosenRows = Set(newRoutes.keys)
        } else {
            userChosenRows.removeAll()
        }
        persistChosenRows()
        if appState.transportType == .thunderbolt { appState.thunderboltInputRoutingDidChange() }
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
    /// Unit B's outputs (64 channels, a second Symphony I/O on port 2): grid
    /// row (DAW pairs 0-31, Mixer 1 = 32, Mixer 2 = 33) → unit B columns.
    /// Saved under unit B's own key; unit A's `routes` keep their encoding.
    @State private var unitBRoutes: [Int: Set<Int>] = [:]
    @State private var unitBChosenRows: Set<Int> = []
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
    // Over USB, row i is named after hardware column i (analog of both slots
    // first, as the USB default table routes them); over ThunderBridge, after
    // the board outputs at the same position (CardLayout.thunderboltOutputPairName).
    // Evidence: original Maestro 2 shows "A Line 1/2", "A ADAT 1/2" etc.
    // The hardware part is the output column's name, so it is named by the
    // card that has it (an 8x8 in AES mode is "AES", not "ADAT") and follows
    // the rate and optical format (SMUX, SPDIF Opt, N.A.) as the daemon's
    // channel names did.
    private var rowLabels: [(number: String, name: String)] {
        let total = swOutputPairCount
        let hardware = layout.outputRoutingColumns
        // Converters: each Mac output pair is named after the unit channels
        // it plays to ("C Line 1/2"), as the driver names them.
        let converterNames = layout.converterPairNames(isInput: false, pairCount: total)
        var labels: [(number: String, name: String)] = []
        for i in 0..<total {
            let sw1 = i * 2 + 1
            let sw2 = i * 2 + 2
            let name: String
            if let converterNames {
                labels.append((number: "\(sw1)-\(sw2)", name: converterNames[i]))
                continue
            }
            // The unit's prefix letter, and a bare "N.A." for a pair with no
            // channel the rate or format carries (`APUtilities.m:323-400`).
            // ThunderBridge: the board outputs at the same position (Mac 1-16
            // on slot 1, 17-32 on slot 2), which is where the driver plays
            // them and the names it gives them in Core Audio.
            if appState.transportType == .thunderbolt,
               let positional = layout.thunderboltOutputPairName(pair: i, prefix: appState.peripheralPrefix) {
                name = positional
            } else if i < hardware.count {
                name = CardLayout.softwarePairName(hardwarePair: hardware[i].stereoName,
                                                   prefix: appState.peripheralPrefix)
            } else {
                name = CardLayout.softwarePairName(hardwarePair: "Digital \(sw1)/\(sw2)",
                                                   prefix: appState.peripheralPrefix)
            }
            labels.append((number: "\(sw1)-\(sw2)", name: name))
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
    /// The preset menu's lines. The grid is the card's, so presets never
    /// follow the Unit A / Unit B picker of the other pages; what each action
    /// touches is ``OutputRoutingPresets``'s rule.
    private func loadPresetNames() -> [String] {
        OutputRoutingPresetStore.load().entries(twoUnits: appState.unitBOnCard).map(\.displayName)
    }

    private var routingCache: RoutingStateCache? {
        guard appState.device != nil else { return nil }
        return appState.peripheralRoutingCache(direction: "output")
    }

    /// Pending refusal / confirmation for Reset Routing. See ``RoutingResetPrompt``.
    @State private var resetPrompt: RoutingResetPrompt?

    init(appState: AppState) {
        self.appState = appState
        let snapshot = restoredRoutes(defaultRouteGrid())
        _routes = State(initialValue: snapshot)
        _userChosenRows = State(initialValue: Set(routingCache?.loadMulti()?.keys.map { $0 } ?? []))
        _presetNames = State(initialValue: loadPresetNames())
    }

    var body: some View {
        // Converters have their own grid (their channels, the card's routing).
        // The Symphony I/O grid below must never reach them: its clicks would
        // become converter routes on unrelated channels.
        if appState.converterRoutingSurface {
            if let layout = appState.converterRoutingLayout, let system = appState.cardLayout.converterLayout {
                ConverterOutputRoutingView(appState: appState, layout: layout, system: system)
            } else {
                ConverterRoutingUnavailableNote(
                    title: "Output Routing",
                    driverTooOld: appState.converterSystem?.driverSupportsConverterControls == false)
            }
        } else {
            routingGrid
                .onChange(of: appState.unitBOnCard) { _, _ in presetNames = loadPresetNames() }
        }
    }

    private var routingGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Reset Routing") { requestRoutingReset() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .maestroHelp("Put Output Routing back to the default: each software output goes to the matching hardware output.")
                .routingResetPrompt($resetPrompt) {
                    Task { await resetToDefaultRouting() }
                }
                // The original's ID button sat in each device's column header
                // (APRoutingDeviceColumnViewController.m:212-219); Symphony I/O only.
                if appState.connectedUnit == nil {
                    IdentifyButton(title: appState.unitBOnCard ? "Identify A" : "Identify",
                                   device: appState.device, state: appState.identifyA)
                    if appState.unitBOnCard {
                        IdentifyButton(title: "Identify B", device: appState.unitBDevice,
                                       state: appState.identifyB)
                    }
                }
                Spacer()
                PresetMenuButton(
                    presetNames: presetNames,
                    onSave: { name in savePreset(name) },
                    onLoad: { name in loadPreset(name) },
                    onDelete: { name in deletePreset(name) }
                )
            }
            .disabled(isLoadingRoutes)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    // Output Routing column headers — board-aware OUTPUT analog/digital split.
                    // With two units, unit A's block then unit B's, each headed by its unit.
                    let grid = self.grid
                    let colLabels: [(type: String, channels: String)] =
                        grid.columns.map { (type: $0.type, channels: $0.channels) }
                    let labels = gridRowLabels
                    RoutingGridView(
                        rowCount: labels.count,
                        columnCount: colLabels.count,
                        rowLabels: labels,
                        columnLabels: colLabels,
                        rowGroupLabel: "Software Outputs",
                        colGroupLabel: "Hardware Outputs",
                        isActiveCell: { row, col in
                            guard let cell = grid.cell(gridRow: row, column: col) else { return false }
                            return (cell.unit == .b ? unitBRoutes : routes)[cell.row]?.contains(cell.column) == true
                        },
                        hoverRow: $hoverRow,
                        hoverCol: $hoverCol,
                        columnMeterLevels: [],
                        columnGroups: grid.columnGroups,
                        onCellTap: { gridRow, gridCol in
                            guard !isLoadingRoutes, !appState.hardwareWritesSuspended,
                                  let cell = grid.cell(gridRow: gridRow, column: gridCol) else { return }
                            if cell.unit == .b {
                                tapUnitB(row: cell.row, col: cell.column)
                                return
                            }
                            let row = cell.row
                            let col = cell.column
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
            loadUnitBRoutes()
            presetNames = loadPresetNames()
            isLoadingRoutes = false
            showLoadingIndicator = false
            indicatorTask.cancel()
        }
    }

    // MARK: Unit B's outputs (64 channels)

    /// The grid's columns: this unit's alone, or with two units unit A's
    /// block then unit B's (``OutputRoutingGrid``).
    private var grid: OutputRoutingGrid {
        guard appState.unitBOnCard, let layoutB = appState.unitBLayout else {
            return .singleUnit(columns: columns, unitAPairs: swOutputPairCount)
        }
        return .twoUnits(unitA: columns, prefixA: appState.peripheralPrefix,
                         unitB: layoutB, prefixB: appState.unitBPeripheralPrefix,
                         unitAPairs: swOutputPairCount)
    }

    /// Unit B's output columns, after unit A's; none with one unit.
    private var unitBColumns: [CardLayout.RoutingColumn] { grid.columns(of: .b) }

    // MARK: Presets

    /// Save the whole preset: unit A's table and, with two units, unit B's
    /// with unit B's cards. A one-unit save drops the name's unit B half.
    private func savePreset(_ name: String) {
        var unitB: OutputRoutingPresets.UnitBHalf?
        if appState.unitBOnCard {
            guard let scope = appState.unitBOutputPresetScope else {
                errorMessage = "Preset not saved: unit B's I/O cards are not known yet."
                return
            }
            unitB = .init(cardScope: scope, rows: unitBRoutes)
        }
        var presets = OutputRoutingPresetStore.load()
        let old = presets
        // Mixer rows are stored under fixed sentinels so a preset
        // survives a change in DAW pair count (USB 8, ThunderBridge 16).
        presets.save(name: name,
                     unitA: RoutingPresetRows.encode(routes, dawPairCount: swOutputPairCount,
                                                     unitBActive: appState.unitBOnCard),
                     unitB: unitB)
        OutputRoutingPresetStore.store(presets, replacing: old)
        presetNames = loadPresetNames()
    }

    private func deletePreset(_ displayName: String) {
        var presets = OutputRoutingPresetStore.load()
        let old = presets
        guard let entry = presets.entry(displayName: displayName, twoUnits: appState.unitBOnCard) else { return }
        presets.delete(entry)
        OutputRoutingPresetStore.store(presets, replacing: old)
        presetNames = loadPresetNames()
    }

    /// Load a preset. Unit B's half is checked against unit B's current
    /// cards first; a mismatch writes nothing. A preset without a unit B
    /// half leaves unit B's outputs as they are.
    private func loadPreset(_ displayName: String) {
        let presets = OutputRoutingPresetStore.load()
        let twoUnits = appState.unitBOnCard
        guard let entry = presets.entry(displayName: displayName, twoUnits: twoUnits) else { return }
        let state = twoUnits
            ? OutputRoutingPresets.UnitBState(cardScope: appState.unitBOutputPresetScope,
                                              columnCount: unitBColumns.count,
                                              writable: appState.unitBOutputRoutingWritable)
            : nil
        let plan: OutputRoutingPresets.LoadPlan
        switch presets.loadPlan(entry, unitB: state) {
        case .failure(let refusal):
            errorMessage = refusal.message
            return
        case .success(let planned):
            plan = planned
        }
        let targetB = appState.unitBWriteTarget
        var writesA: [(row: Int, col: Int, clear: Bool)] = []
        if let stored = plan.unitA {
            let preset = RoutingPresetRows.decode(stored, dawPairCount: swOutputPairCount, unitBActive: twoUnits)
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
            writesA = orphaned.sorted { $0.col < $1.col }.map { (row: $0.row, col: $0.col, clear: true) }
            for (row, cols) in preset.sorted(by: { $0.key < $1.key }) {
                writesA += cols.sorted().map { (row: row, col: $0, clear: false) }
            }
        }
        Task {
            var failedA = 0
            for write in writesA where await !writeRoute(row: write.row, col: write.col, clear: write.clear) {
                failedA += 1
            }
            if plan.unitA != nil, let device = appState.device {
                await HeadphoneCrosspoint.reapplyAll(
                    device: device, cachedRoutes: appState.cachedOutputRouteMap(),
                    transport: appState.transportType ?? .usb, state: appState)
            }
            var problems: [String] = []
            if failedA > 0 { problems.append("Unit A: \(failedA) of \(writesA.count) routes failed to write.") }
            if let rowsB = plan.unitB {
                do {
                    try await appState.applyUnitBOutputRouting(rowsB, target: targetB)
                    unitBRoutes = rowsB.filter { !$0.value.isEmpty }
                    unitBChosenRows = Set(0..<TwoUnitOutputRouting.rowCount)
                } catch {
                    problems.append((plan.unitA != nil ? "Unit A loaded; unit B" : "Unit B")
                                    + " not loaded: \(error.localizedDescription)")
                }
            }
            errorMessage = problems.isEmpty ? nil : problems.joined(separator: " ")
        }
    }

    /// Row labels: with unit B, the 64 DAW channels (33-64 named after unit
    /// B's outputs, where the card plays them by default), then the mixers.
    private var gridRowLabels: [(number: String, name: String)] {
        let single = rowLabels
        guard appState.unitBOnCard, let unitB = appState.unitBLayout else { return single }
        let pairs = swOutputPairCount
        var labels: [(number: String, name: String)] = Array(single.prefix(pairs))
        for p in pairs..<TwoUnitOutputRouting.dawPairCount {
            let number = "\(p * 2 + 1)-\(p * 2 + 2)"
            let name = unitB.thunderboltOutputPairName(pair: p - TwoUnitOutputRouting.unitBChannelBaseDAW / 2, prefix: appState.unitBPeripheralPrefix)
                ?? CardLayout.softwarePairName(hardwarePair: "Digital \(p * 2 + 1)/\(p * 2 + 2)",
                                               prefix: appState.unitBPeripheralPrefix)
            labels.append((number: number, name: name))
        }
        // Mixer buses, numbered after the 64 DAW channels as the rows above.
        for i in 0..<2 {
            let ch1 = TwoUnitOutputRouting.dawPairCount * 2 + 1 + i * 2
            labels.append((number: "\(ch1)-\(ch1 + 1)", name: "Mixer \(i + 1)"))
        }
        return labels
    }

    /// The card's start-up routes for unit B (output c plays DAW 33 + c) with
    /// the saved choices laid over them.
    private func loadUnitBRoutes() {
        guard appState.unitBOnCard else {
            unitBRoutes = [:]
            unitBChosenRows = []
            return
        }
        var grid: [Int: Set<Int>] = [:]
        for (col, column) in unitBColumns.enumerated() {
            guard let channel = ThunderboltCardRouting.channel(forDestination: column.routingByte) else { continue }
            grid[TwoUnitOutputRouting.defaultRow(unitBChannel: Int(channel)), default: []].insert(col)
        }
        let saved = appState.unitBOutputRoutingCache?.loadMulti() ?? [:]
        // Bundle recall saves every row, including empty rows: this is a full
        // table, so an unclaimed output must stay disconnected.
        if (0..<TwoUnitOutputRouting.rowCount).allSatisfy({ saved[$0] != nil }) { grid = [:] }
        for (row, cols) in saved where row >= 0 && row < TwoUnitOutputRouting.rowCount {
            let live = cols.filter { $0 >= 0 && $0 < unitBColumns.count }
            guard !live.isEmpty else { continue }
            for (other, others) in grid where other != row {
                let remaining = others.subtracting(live)
                if remaining.isEmpty { grid.removeValue(forKey: other) } else { grid[other] = remaining }
            }
            grid[row] = live
        }
        unitBRoutes = grid
        unitBChosenRows = Set(saved.keys)
    }

    /// A click on one of unit B's columns: the same one-source-per-output
    /// rule as unit A's, written as a card route on XLink TX 32-63.
    private func tapUnitB(row: Int, col: Int) {
        guard col >= 0, col < unitBColumns.count else { return }
        let removing = unitBRoutes[row]?.contains(col) == true
        if removing {
            unitBRoutes[row]?.remove(col)
            if unitBRoutes[row]?.isEmpty == true { unitBRoutes.removeValue(forKey: row) }
        } else {
            for (key, vals) in unitBRoutes where vals.contains(col) {
                unitBRoutes[key]?.remove(col)
                if unitBRoutes[key]?.isEmpty == true { unitBRoutes.removeValue(forKey: key) }
            }
            unitBRoutes[row, default: []].insert(col)
        }
        unitBChosenRows.insert(row)
        let chosen = unitBRoutes.filter { unitBChosenRows.contains($0.key) }
        // A complete table (after a preset or bundle) stays complete, so its
        // unrouted outputs stay unrouted when the grid is read back.
        let complete = (0..<TwoUnitOutputRouting.rowCount).allSatisfy(unitBChosenRows.contains)
        appState.unitBOutputRoutingCache?.save(complete ? TwoUnitOutputRouting.completeTable(chosen) : chosen)
        appState.outputRoutingSaved()
        let destLeft = unitBColumns[col].routingByte
        Task {
            do {
                try await appState.writeUnitBOutputRoutePair(destLeft: destLeft, gridRow: removing ? nil : row)
                errorMessage = nil
                print("[Maestro] OutputRouting: unit B row \(row) → col \(col) (dest \(destLeft), clear=\(removing))")
            } catch {
                errorMessage = "Error: \(error.localizedDescription)"
            }
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
        let saved = routingCache?.loadMulti() ?? [:]
        let rowCount = appState.unitBOnCard ? TwoUnitOutputRouting.rowCount : swOutputPairCount + 2
        if (0..<rowCount).allSatisfy({ saved[$0] != nil }) {
            return saved.filter { (0..<rowCount).contains($0.key) }.mapValues {
                $0.filter { columns.indices.contains($0) }
            }
        }
        var routes = base
        for (row, cols) in routingCache?.loadMulti() ?? [:] where
            TwoUnitOutputRouting.playbackPair(unitARow: row, unitAPairs: swOutputPairCount,
                                              unitBActive: appState.unitBOnCard) != nil {
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
        // On ThunderBridge: Mac output n on slot 1 output n (1-16) and slot 2
        // output n-16 (17-32), every output direct and no mixer routed, as in
        // the original. The grid shows it, Maestro writes it on connect and
        // Reset Routing writes it, so the picture matches the sound.
        if appState.transportType == .thunderbolt {
            return SymphonyIODefaultRouting.thunderboltOutputRoutes(
                board0Outputs: board1.totalOutputChannels, board1Outputs: board2.totalOutputChannels)
        }
        return SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: board1.analogOutputChannels, digital: board1.digitalOutputChannels),
            board1: .init(analog: board2.analogOutputChannels, digital: board2.digitalOutputChannels),
            usbChannelCount: SymphonyIODefaultRouting.usbChannelCount)
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
        // A restore in progress (or one that deferred this route until its
        // mixer is written) starts again from what was just saved.
        appState.outputRoutingSaved()
    }

    /// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp`
    private func loadRoutes() async -> [Int: Set<Int>] {
        guard let device = appState.device else { return [:] }
        // On ThunderBridge, host playback routing lives in the card, which has
        // no readback; the Symphony's own table that this read reaches says
        // nothing about it. These reads always failed until the request-size fix
        // in 0.8.36, so the grid was already built from the default table plus
        // the user's saved choices. Keep it that way now that they would succeed.
        if appState.transportType == .thunderbolt { return [:] }
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
    /// Returns whether the route was written.
    @discardableResult
    private func writeRoute(row: Int, col: Int, clear: Bool = false) async -> Bool {
        guard !isLoadingRoutes else { return false }
        guard let device = appState.device else { return false }
        let board1 = appState.primaryBoardType
        let board2 = appState.secondaryBoardType

        // Destination = HW output IOBoard byte
        guard col >= 0, col < columns.count else {
            print("[Maestro] OutputRouting: col \(col) out of range for board types \(board1)/\(board2)")
            errorMessage = "Invalid routing column"
            return false
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
        } else if let pair = TwoUnitOutputRouting.playbackPair(
            unitARow: row, unitAPairs: swOutputPairCount, unitBActive: appState.unitBOnCard) {
            // DAW playback pair — P2P on USB, XLink RX on ThunderBridge.
            srcLeft = SymphonyIORoutingAddress.hostPlaybackBase(for: appState.transportType ?? .usb)
                + UInt8(pair * 2)
        } else if row == swOutputPairCount {
            // Mixer 1
            srcLeft = SymphonyIORoutingAddress.mixer0Base
        } else if row == swOutputPairCount + 1 {
            // Mixer 2
            srcLeft = SymphonyIORoutingAddress.mixer1Base
        } else {
            errorMessage = "Invalid source row"
            return false
        }

        do {
            // Symphony 0x31 table over USB; card output routing on ThunderBridge.
            try await appState.writeOutputRoutePair(destLeft: destLeft, srcLeft: srcLeft, device: device)
            errorMessage = nil
            userChosenRows.insert(row)
            persistChosenRows()
            // A mixer may have started or stopped feeding an output (USB helper rule).
            appState.syncUSBHelperSoftwareReturn()
            print("[Maestro] OutputRouting: wrote row \(row) → col \(col) (dest \(destLeft), src \(srcLeft), clear=\(clear))")
            // Legacy re-runs RouteHeadphones() after every routing change, because a
            // headphone's crosspoint source is inherited from the output pair it
            // follows — SymphonyIOUSBAudioRoutingController.cpp:1005-1008, :1193-1196.
            // Without this the headphone keeps feeding on the previous source.
            await HeadphoneCrosspoint.reapplyAll(
                device: device, cachedRoutes: appState.cachedOutputRouteMap(),
            transport: appState.transportType ?? .usb, state: appState)
            return true
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
            return false
        }
    }

    /// Build the refusal or the confirmation for Reset Routing, and show it.
    ///
    /// Nothing is written from here. The confirmation names the cards the app
    /// believes are installed and, line by line, what every hardware output will
    /// end up carrying — ADAT included, because that is the destination a wrong
    /// card silently re-points.
    private func requestRoutingReset() {
        if appState.unitBOnCard {
            let refusal = RoutingResetGuard.refusalReason(board1: appState.primaryBoardReading, board2: appState.secondaryBoardReading)
            let ready = refusal == nil && appState.unitBInputRoutingAllowed
                && appState.unitBBoardSource(slot: 0) == .detected && appState.unitBBoardSource(slot: 1) == .detected
            resetPrompt = RoutingResetPrompt(title: "Reset Output Routing",
                message: ready ? "Reset output routing for the whole card and both Symphony I/Os (channels 1–64)?"
                    : (refusal ?? "Maestro has not read the second Symphony I/O's cards since it connected."), isRefusal: !ready)
            return
        }
        guard appState.device != nil else { return }
        let b1 = appState.primaryBoardReading
        let b2 = appState.secondaryBoardReading
        if let refusal = RoutingResetGuard.refusalReason(board1: b1, board2: b2) {
            resetPrompt = RoutingResetPrompt(
                title: "Reset Output Routing", message: refusal, isRefusal: true)
            print("[Maestro] OutputRouting: reset refused — slot provenance \(b1.source.rawValue)/\(b2.source.rawValue)")
            return
        }
        resetPrompt = RoutingResetPrompt(
            title: "Reset Output Routing",
            message: RoutingResetGuard.outputResetMessage(
                board1: b1.card, board2: b2.card, transport: appState.transportType ?? .usb),
            isRefusal: false)
    }

    /// Restore the daemon's default output routing (`ResetOutputRouting`).
    ///
    /// Over USB, board-aware: analog destinations across both slots first, then
    /// digital, each fed from the next USB playback channel. This is not a
    /// diagonal and not the dual map we used to write — see
    /// ``SymphonyIODefaultRouting``. Over ThunderBridge, the driver's position
    /// table (`SymphonyIODefaultRouting.thunderboltOutputRoutes`).
    ///
    /// Only reachable through ``requestRoutingReset()``, which refuses unless both
    /// slots were genuinely detected this session.
    private func resetToDefaultRouting() async {
        if appState.unitBOnCard {
            do {
                try await appState.resetTwoUnitRouting(input: false)
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
            return
        }
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
        // Output reset must leave card inputs alone, matching ResetRouting(false).
        // Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:849-953.
        // Over USB: 16, not the device mode's channel count — see
        // `SymphonyIODefaultRouting.usbChannelCount`. In 8-ch mode the mode count
        // wrapped ADAT 1-8 back onto DAW 1-8; in 32-ch mode it assigned USB 16-31,
        // which the proxy never renders. ThunderBridge renders all 32.
        // On ThunderBridge/PCIe, Reset writes Apogee's reset layout (every software
        // output on the matching output, the main pair on Software 1-2, no mixer
        // routed), which is also the default.
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
        // (On ThunderBridge Maestro writes the default table on every connect.)
        userChosenRows.removeAll()
        persistChosenRows()
        appState.syncUSBHelperSoftwareReturn()
        errorMessage = failures == 0 ? nil : "\(failures) of \(routeList.count) routes failed to write"
        print("[Maestro] OutputRouting: reset to legacy defaults (\(routeList.count) routes, \(failures) failed)")
        await HeadphoneCrosspoint.reapplyAll(
            device: device, cachedRoutes: appState.cachedOutputRouteMap(),
            transport: appState.transportType ?? .usb, state: appState)
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
    /// Headers over runs of columns (two Symphony I/Os: one per unit), in
    /// place of the single `colGroupLabel` header. Empty: the single header.
    var columnGroups: [(label: String, count: Int)] = []
    let onCellTap: (Int, Int) -> Void

    private let cellSize: CGFloat = 40
    private let cellHeight: CGFloat = 22

    /// How far an "N.A." column header or row name is faded.
    static let notApplicableOpacity: Double = 0.45

    static func isNotApplicable(_ labels: [(type: String, channels: String)], _ col: Int) -> Bool {
        col < labels.count && labels[col].channels.isEmpty && CardLayout.isNotApplicable(labels[col].type)
    }
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
                if columnGroups.isEmpty {
                    Text(colGroupLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.leading, 6)
                        .frame(width: CGFloat(columnCount) * cellSize, height: colHeaderHeight, alignment: .leading)
                        .background(Color.gray.opacity(0.35))
                } else {
                    // As the original's routing card: "Hardware Outputs" once,
                    // over the first device's block, and each device's own
                    // header on its block (APOutputRoutingTabRowViewController.m:226-230).
                    ForEach(Array(columnGroups.enumerated()), id: \.offset) { index, group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(index == 0 ? colGroupLabel : " ")
                            Text(group.label)
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.leading, 6)
                        .frame(width: CGFloat(group.count) * cellSize, height: colHeaderHeight, alignment: .leading)
                        .background(Color.gray.opacity(0.35))
                        .border(Color.gray.opacity(0.5), width: 0.5)
                    }
                }
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
                    // A pair the rate or format does not carry stays, as the
                    // original's did, but reads as inactive.
                    .opacity(Self.isNotApplicable(columnLabels, col) ? Self.notApplicableOpacity : 1)
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
                        .minimumScaleFactor(0.75)
                        .opacity(row < rowLabels.count && CardLayout.isNotApplicable(rowLabels[row].name)
                                 ? Self.notApplicableOpacity : 1)
                        .maestroHelp(row < rowLabels.count ? rowLabels[row].name : "")
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
        .maestroHelp("Presets")
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
    ///
    /// Over USB the write goes through the app's route gate
    /// (`AppState.writeUSBRoute`): a headphone following a pair that a mixer
    /// feeds is pointed at that mixer only once the mixer is written. Until
    /// then the crosspoint is disabled, the route is owed, the restore sends
    /// it, and this returns false. On ThunderBridge a headphone's source is
    /// always the XLink channel of the output it follows, never a mixer
    /// (`SymphonyIOHeadphoneRouting.inheritedSource`; the mixers there are on
    /// the card, behind the card's own gate).
    @MainActor
    @discardableResult
    static func apply(
        _ headphone: SymphonyIOHeadphoneRouting.Headphone,
        sourceID: UInt32,
        device: any DeviceConnection,
        cachedRoutes: [UInt8: UInt8],
        transport: TransportType = .usb,
        state: AppState,
        restoring: Bool = false
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
            if device is XPCDeviceConnection {
                let left = try await state.writeUSBRoute(destination: dest.left, source: srcLeft,
                                                         device: device, restoring: restoring)
                let right = try await state.writeUSBRoute(destination: dest.right, source: srcRight,
                                                          device: device, restoring: restoring)
                guard left == .written, right == .written else {
                    print("[Maestro] HP\(headphone.rawValue + 1) crosspoint: outputs \(pair.left)/\(pair.right) are fed by a mixer that is not set yet; headphone disabled until it is")
                    return false
                }
            } else {
                // ThunderBridge: the mixers are on the card and this table
                // only ever names XLink channels. A mixer source here would
                // pass no gate, so it is never sent.
                if device is ThunderboltDeviceConnection || transport == .thunderbolt {
                    guard CardOutputTableOrder.mixer(ofSource: srcLeft) == nil,
                          CardOutputTableOrder.mixer(ofSource: srcRight) == nil else {
                        print("[Maestro] HP\(headphone.rawValue + 1) crosspoint: a mixer source is never written over ThunderBridge")
                        return false
                    }
                }
                try await device.setProperty(
                    PropertyAddress(selector: .routing, scope: .output, element: UInt32(dest.left)),
                    value: .uint32(UInt32(srcLeft)))
                try await device.setProperty(
                    PropertyAddress(selector: .routing, scope: .output, element: UInt32(dest.right)),
                    value: .uint32(UInt32(srcRight)))
            }
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
    @MainActor
    static func reapplyAll(device: any DeviceConnection, cachedRoutes: [UInt8: UInt8],
                           transport: TransportType = .usb, state: AppState) async {
        let known = recalled()
        guard !known.isEmpty else { return }
        for headphone in SymphonyIOHeadphoneRouting.Headphone.allCases {
            guard let id = known[headphone.rawValue] else { continue }
            await apply(headphone, sourceID: id, device: device, cachedRoutes: cachedRoutes,
                        transport: transport, state: state)
        }
    }
}
