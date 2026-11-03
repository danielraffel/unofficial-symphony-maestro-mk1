import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


/// Input Controls view — horizontal channel strips matching legacy Maestro 2 layout.
/// Ref level and soft limit displayed as stacked labels above the meter (like original).
/// Toolbar provides Show/Hide Trims and Reset Trims buttons.
///
/// Evidence: `og_source/maestro2/App/Controllers/Input/APAnalogInputSidebarViewController.m`
/// Evidence: `og_source/maestro2/App/Controllers/Input/APAnalogInputController.m`
struct InputControlsView: View {
    private let appState: AppState
    /// Seed the persisted strip state before the first body evaluation. The async task below
    /// still performs migration, simulation, and the normal board-count refresh; this seed only
    /// prevents an empty rack from appearing while that task is scheduled.
    @State private var channels: [InputChannelState]
    @State private var errorMessage: String?
    @State private var showResetAlert: Bool = false
    /// Non-nil while the "reset input defaults" confirmation is up; carries the scope.
    @State private var pendingResetScope: SymphonyIOResetScope?
    /// SPDIF Coax Replace values per board.
    @State private var spdifReplace1: UInt32 = 0
    @State private var spdifReplace2: UInt32 = 0
    /// Measured height of the tallest analog strip — used to match ADAT/DIGITAL heights.
    @State private var analogStripHeight: CGFloat = 0
    /// True once `initializeChannels()` has run. The DIGITAL column is gated on
    /// this rather than on `!channels.isEmpty`: a card with no analog inputs at
    /// all (a 16 Digital In / 16 Analog Out) has zero strips, and gating on the
    /// strip array would then hide the only input controls it has.
    @State private var didInitializeChannels = false
    /// Gain values as last settled by the group rules, indexed like `channels`.
    /// The gain knob mutates `channels[i].gain` through its binding, so this is
    /// the only way to recover the pre-move value a relative group move needs.
    @State private var appliedGains: [Double] = []
    @State private var scrollPosition: ScrollPosition
    @State private var scrollRestorationPending = true
    @State private var scrollObservationEnabled = false
    @State private var scrollRestorationTarget: CGFloat?
    @State private var scrollRestorationGeneration = 0
    @AppStorage("rememberControlTabScrollPositions") private var rememberControlTabScrollPositions = true

    init(appState: AppState) {
        self.appState = appState
        let channels = Self.seedChannels(appState)
        _channels = State(initialValue: channels)
        _appliedGains = State(initialValue: channels.map(\.gain))
        _didInitializeChannels = State(initialValue: true)
        let offset = ControlTabScrollPreferences.remembers
            ? appState.controlTabScrollOffset(for: .input) : 0
        _scrollPosition = State(initialValue: ScrollPosition(x: offset))
    }

    private static func seedChannels(_ appState: AppState) -> [InputChannelState] {
        let count = appState.cardLayout.analogInputStripCount
        guard let saved: [InputChannelState] = appState.channelStateStore.load(ChannelStateStore.inputKey),
              !saved.isEmpty else {
            return (0..<count).map { _ in InputChannelState() }
        }
        if saved.count >= count { return Array(saved.prefix(count)) }
        return saved + (saved.count..<count).map { _ in InputChannelState() }
    }

    /// The installed cards' layout — every count on this page comes from here.
    /// See `CardLayout`: the `*PairsPerBoard` counts are the XLink bus slice and
    /// report 8 pairs for an 8MicPre, which has no converters at all.
    private var layout: CardLayout { appState.cardLayout }

    /// User-editable insert names, edited in Device Settings and shared across
    /// every channel -- see `InsertLabels`. Stored as a plain dictionary so it
    /// lives in UserDefaults without a custom coder.
    @AppStorage("micPreInsertLabels") private var insertLabelsJSON: String = "{}"

    private var insertLabels: InsertLabels {
        guard let data = insertLabelsJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return InsertLabels() }
        return InsertLabels(storage: dict)
    }

    /// Whether a MicPre8 module is installed in either slot.
    /// It is always slot 1 in practice (slot 0 is a hard init failure in the
    /// legacy daemon, `SymphonyIO.cpp:933-948`) but either is accepted here.
    private var micPreInstalled: Bool {
        InputChannelLogic.micPreIsUsable(
            primary: appState.primaryBoardType, secondary: appState.secondaryBoardType)
    }

    /// Analog INPUT channels contributed by the card the MicPre delegates onto --
    /// i.e. the card that is not the MicPre itself.
    ///
    /// A MicPre8 has no converters; `installMicPre`
    /// (`SymphonyIO_IOBoard.cpp:606-625`) delegates it onto the host board's
    /// analog input stream, and returns false when the host has none. Pairing a
    /// MicPre8 with a 16 Digital In + 16 Analog Out card therefore yields no
    /// preamps at all, and offering Mic/Instrument there would put eight preamp
    /// strips in front of zero analog inputs.
    private var micPreHostAnalogInputs: Int {
        let primary = appState.primaryBoardType
        let secondary = appState.secondaryBoardType
        let host = primary == .micPre8 ? secondary : primary
        return host.analogInputChannels
    }

    /// Number of analog input strips to show — based on detected board types,
    /// falls back to the device channel count when boards aren't detected yet.
    private var analogInputStripCount: Int { layout.analogInputStripCount }

    /// The card that owns a given 0-based analog input strip.
    private func cardForStrip(_ index: Int) -> IOCardType {
        layout.cardForAnalogInputStrip(index)
    }

    /// Board-aware channel labels for analog input strips.
    ///
    /// The label is derived LIVE from each channel's current analog level:
    /// Mic → "Mic N", Instrument → "Inst N", everything else → "Line N".
    /// Numbering is continuous across the whole device, not per-card.
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:914-961`, `SymphonyIO_Stream.cpp:653-655`.
    private var inputChannelLabels: [String] {
        (1...max(analogInputStripCount, 1)).map { number in
            let raw = number - 1 < channels.count ? channels[number - 1].inputType : 1
            return InputChannelLogic.channelLabel(number: number, rawLevel: raw)
        }
    }

    /// Board-aware digital input stereo pairs (AES / ADAT meter strips).
    private var digitalInputPairs: [CardLayout.DigitalPair] { layout.digitalInputPairs }

    /// Whether to draw the DIGITAL column at all.
    ///
    /// Deliberately NOT `digitalInputPairs.count > 0`. That gate hid the whole
    /// column on a 16x16, whose S/PDIF coax is its only digital I/O — every
    /// module carries the S/PDIF RCA pair (user guide pp. 10-12). The ADAT/AES
    /// meter strips inside the column stay gated on real digital pairs.
    private var hasDigitalIO: Bool { layout.showsDigitalSection(isInput: true) }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar row — Show/Hide Trims, Reset Trims (styled like Reset Routing)
            HStack {
                Button(appState.showInputTrims ? "Hide Trims" : "Show Trims") {
                    appState.showInputTrims.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Reset Trims is NOT gated on trims being visible — legacy only
                // hides the button when no channel supports trim at all
                // (APAnalogInputSidebarViewController.m:92-93).
                Button("Reset Trims") {
                    showResetAlert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reset Trims — sets every analog input trim to 0.0 dB and nothing else")

                // Two scopes, matching SymphonyIOResetRequestType, and the same
                // shape as the Output page. The default offered first preserves
                // trims: they are calibration data (and legacy groups the two
                // reference levels in with them).
                Menu("Reset Defaults") {
                    Button("Reset Input Settings (keep trims)") {
                        pendingResetScope = .allButCalibration
                    }
                    Button("Reset Input Settings and Trims", role: .destructive) {
                        pendingResetScope = .all
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Restore the input channel settings to the factory defaults. "
                      + "Routing is not touched.")

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .alert("Reset All Input Trims?", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset All Trims", role: .destructive) {
                    // Sets trim to 0.0 on every analog input and changes nothing
                    // else. Only line-level channels are pushed — Mic/Instrument
                    // carry no trim byte, so a write there is a hardware no-op.
                    let writes = InputChannelLogic.resetTrims(&channels)
                    saveChannelStates()
                    for i in writes {
                        Task { await writeChannelProperty(i, .analogIOType,
                            value: .uint32(analogIOTypeWithTrim(i))) }
                    }
                }
            } message: {
                Text("All input trim values will be reset to 0.0 dB.")
            }
            .alert("Reset input settings?",
                   isPresented: Binding(get: { pendingResetScope != nil },
                                        set: { if !$0 { pendingResetScope = nil } })) {
                Button("Cancel", role: .cancel) { pendingResetScope = nil }
                Button("Reset", role: .destructive) {
                    let scope = pendingResetScope ?? .allButCalibration
                    pendingResetScope = nil
                    Task { await resetInputDefaults(scope: scope) }
                }
            } message: {
                Text(resetConfirmationMessage)
            }

            // Mic Pre controls can be taller than the available window. Let the
            // rack scroll vertically instead of imposing its intrinsic height
            // on the NavigationSplitView and displacing the sidebar bottom.
            GeometryReader { viewport in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(0..<min(channels.count, analogInputStripCount)), id: \.self) { i in
                        if i > 0 {
                            Divider()
                                .frame(height: nil)
                                .opacity(0.4)
                        }
                        InputChannelStripView(
                            channel: $channels[i],
                            label: i < inputChannelLabels.count ? inputChannelLabels[i] : "In \(i + 1)",
                            appState: appState,
                            meterIndex: i,
                            showTrims: appState.showInputTrims,
                            onPhantomChange: { enabled in
                                Task { await writeChannelProperty(i, .phantom, value: .bool(enabled)) }
                                saveChannelStates()
                            },
                            onPhaseChange: { enabled in
                                Task { await writeChannelProperty(i, .phaseReverse, value: .bool(enabled)) }
                                saveChannelStates()
                            },
                            onHPFChange: { enabled in
                                Task { await writeChannelProperty(i, .highPassFilter, value: .bool(enabled)) }
                                saveChannelStates()
                            },
                            onSoftLimitChange: { mode in
                                applySoftLimitChange(i, mode: mode)
                            },
                            onGainChange: { gain in
                                applyGainChange(i, to: gain)
                            },
                            onInputTypeChange: { _ in
                                applyInputTypeChange(i)
                            },
                            onDigitalRefChange: { level in
                                applyDigitalRefChange(i, level: level)
                            },
                            onTrimChange: { trim in
                                saveChannelStates()
                                // Trim is sent as part of the analog ref level command
                                Task { await writeChannelProperty(i, .analogIOType,
                                    value: .uint32(analogIOTypeWithTrim(i))) }
                            },
                            showZoneColoring: appState.showMeterZoneColoring,
                            boardType: cardForStrip(i),
                            channelNumber: i + 1,
                            micPreBacked: InputChannelLogic.isMicPreBacked(
                                number: i + 1, micPreInstalled: micPreInstalled,
                                hostAnalogInputChannels: micPreHostAnalogInputs),
                            rackHasMicPre: micPreInstalled,
                            insertOptions: InputChannelLogic.insertOptions(
                                forChannel: i, in: channels, labels: insertLabels),
                            insertLabels: insertLabels,
                            onGroupChange: { group in applyGroupChange(i, to: group) },
                            onInsertChange: { insert in applyInsertChange(i, to: insert) },
                            onInsertReturnChange: { enabled in
                                Task { await writeChannelProperty(i, .insertReturnEnable,
                                                                  value: .bool(enabled)) }
                                saveChannelStates()
                            }
                        )
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: AnalogStripHeightKey.self, value: geo.size.height)
                        })
                    }

                    // DIGITAL divider + SPDIF + ADAT — inline after analog strips
                    // Gate on didInitializeChannels so digital/ADAT don't flash
                    // before the analog strips render.
                    if hasDigitalIO && didInitializeChannels {
                        Divider()
                            .opacity(0.4)

                        // SPDIF Coax + DIGITAL label column
                        VStack(spacing: 8) {
                            Text("DIGITAL")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.primary.opacity(0.08))
                                )

                            // One coax pair per module, and the command is
                            // per board (nValue = board index), so each popup
                            // appears only when that slot's module has the jacks
                            // and lists only the pairs that module supplies.
                            if layout.hasSPDIF(slot: 0) {
                                spdifReplaceDropdown(
                                    label: "SPDIF Coax\n1-2 Replace",
                                    value: $spdifReplace1,
                                    selector: .spdifReplaceID
                                )
                            }

                            if layout.hasSPDIF(slot: 1) {
                                spdifReplaceDropdown(
                                    label: "SPDIF Coax\n3-4 Replace",
                                    value: $spdifReplace2,
                                    selector: .spdifReplaceID,
                                    element: 1
                                )
                            }
                        }
                        .frame(width: 96)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 5)
                        .frame(height: analogStripHeight > 0 ? analogStripHeight : nil, alignment: .top)

                        Divider()
                            .opacity(0.4)

                        // Digital stereo pair meters — board-aware count and labels.
                        // The meter arrays are fixed at 24 entries (4 metered
                        // pairs per board); a DA16 pair supplies 8 digital input
                        // pairs per board, so the index MUST be checked or the
                        // page traps on open.
                        let digPairs = digitalInputPairs
                        ForEach(Array(digPairs.enumerated()), id: \.offset) { index, digPair in
                            if index > 0 {
                                Divider()
                                    .opacity(0.4)
                            }
                            ADATStereoPairView(
                                label: digPair.label,
                                leftLevel: Self.meterLevel(appState.digitalInputMeterLevels, digPair.meterIndex),
                                rightLevel: Self.meterLevel(appState.digitalInputMeterLevels, digPair.meterIndex, offset: 1),
                                leftPeak: Self.meterLevel(appState.digitalInputPeakHold, digPair.meterIndex),
                                rightPeak: Self.meterLevel(appState.digitalInputPeakHold, digPair.meterIndex, offset: 1),
                                matchHeight: analogStripHeight > 0 ? analogStripHeight : nil,
                                showZoneColoring: appState.showMeterZoneColoring
                            )
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true) // dividers match strip height, not page height
                .frame(minHeight: max(0, viewport.size.height - 16), alignment: .top)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .onPreferenceChange(AnalogStripHeightKey.self) { analogStripHeight = $0 }
                .background {
                    ControlTabScrollObserver(
                        tab: "Input",
                        restorationOffset: appState.controlTabScrollOffset(for: .input)
                    ) { offset in
                        guard rememberControlTabScrollPositions, scrollObservationEnabled else { return }
                        if offset == 0 && !scrollPosition.isPositionedByUser { return }
                        if scrollPosition.isPositionedByUser, scrollRestorationTarget != nil {
                            scrollRestorationTarget = nil
                            scrollRestorationGeneration += 1
                            scrollRestorationPending = false
                        }
                        if let target = scrollRestorationTarget {
                            if offset == 0 || abs(offset - target) <= 1 { return }
                            scrollRestorationTarget = nil
                        }
                        appState.setControlTabScrollOffset(offset, for: .input)
                    } onDetachOffset: { offset in
                        guard rememberControlTabScrollPositions else { return }
                        appState.setControlTabScrollOffset(offset, for: .input)
                    }
                }
            }
            .scrollPosition($scrollPosition)
            .onChange(of: rememberControlTabScrollPositions) { _, enabled in
                if !enabled {
                    scrollRestorationTarget = nil
                    scrollPosition.scrollTo(x: 0)
                    appState.setControlTabScrollOffset(0, for: .input)
                }
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
        .navigationTitle("Input")
        .onAppear {
            scrollRestorationPending = true
            restoreSessionScrollPosition()
        }
        .onDisappear {
            scrollRestorationGeneration += 1
            scrollObservationEnabled = false
            scrollRestorationPending = true
        }
        .onChange(of: appState.selectedArea) { _, area in
            guard area != .input else { return }
            scrollRestorationGeneration += 1
            scrollObservationEnabled = false
            scrollRestorationPending = true
        }
        .task(id: appState.viewReloadToken) {
            initializeChannels()
            await loadDigitalSettings()
            restoreSessionScrollPosition()
        }
        // Board detection is async and lands AFTER the first `.task` — without
        // this the strip array keeps whatever count the pre-detection layout had.
        .onChange(of: appState.cardLayoutToken) { _, _ in
            scrollRestorationPending = true
            initializeChannels()
            restoreSessionScrollPosition()
        }
    }

    /// Channel content is populated asynchronously after the view is created.
    /// Reapply the in-memory session offset after that content exists so SwiftUI
    /// does not clamp a valid saved position back to zero during tab switches.
    /// Publish the saved session offset to the native observer. The observer is
    /// the only restoration writer. SwiftUI's delayed `ScrollPosition.scrollTo`
    /// retries used to write zero first and then the saved value as the document
    /// width settled, which produced the small visible slide when returning to a
    /// tab. The native observer applies the offset without an animated SwiftUI
    /// transaction and retries only against the clip view while layout settles.
    private func restoreSessionScrollPosition() {
        scrollRestorationGeneration += 1
        guard rememberControlTabScrollPositions else {
            scrollRestorationTarget = nil
            scrollRestorationPending = false
            scrollObservationEnabled = true
            return
        }
        scrollRestorationTarget = appState.controlTabScrollOffset(for: .input) > 0
            ? appState.controlTabScrollOffset(for: .input) : nil
        scrollRestorationPending = false
        scrollObservationEnabled = true
    }

    private func initializeChannels() {
        // Keyed by the installed card pair — see `ChannelStateStore`.
        if let saved: [InputChannelState] = appState.channelStateStore.load(ChannelStateStore.inputKey),
           !saved.isEmpty {
            let n = analogInputStripCount
            if saved.count >= n {
                channels = Array(saved.prefix(n))
            } else {
                channels = saved + (saved.count..<n).map { _ in InputChannelState() }
            }
            // One-time migration: old default was inputType=0 (Variable); new default is 1 (+4 dBu).
            if !UserDefaults.standard.bool(forKey: "inputTypeDefaultMigrated") {
                for i in channels.indices where channels[i].inputType == 0 {
                    channels[i].inputType = 1  // +4 dBu
                }
                saveChannelStates()
                UserDefaults.standard.set(true, forKey: "inputTypeDefaultMigrated")
                print("[Maestro] initializeChannels: migrated inputType defaults from Variable to +4 dBu")
            }
            print("[Maestro] initializeChannels: restored \(channels.count) channel states from UserDefaults")
        } else {
            channels = (0..<analogInputStripCount).map { _ in InputChannelState() }
            print("[Maestro] initializeChannels: no saved state — using defaults (\(analogInputStripCount) strips)")
        }
        applySimulatedAnalogLevels()
        syncAppliedGains()
        didInitializeChannels = true
        print("[Maestro] initializeChannels: skipping daemon queries (unsupported on Symphony IO MKI)")
    }

    private func saveChannelStates() {
        appState.channelStateStore.save(channels, for: ChannelStateStore.inputKey)
    }

    /// Debug: force analog levels from `-MaestroSimulateAnalogLevels` so a Mic or
    /// Instrument strip can be screenshotted without driving the popup. Only
    /// levels the channel actually offers are applied (Mic needs a MicPre-backed
    /// channel, Instrument one of channels 1-4), exactly as the popup would.
    /// Inert without a card-simulation request.
    private func applySimulatedAnalogLevels() {
        guard let presets = SimulatedDevice.simulatedAnalogLevels() else { return }
        for (i, preset) in presets.enumerated() where i < channels.count {
            guard let preset else { continue }
            let number = i + 1
            let backed = InputChannelLogic.isMicPreBacked(number: number, micPreInstalled: micPreInstalled, hostAnalogInputChannels: micPreHostAnalogInputs)
            let offered = InputChannelLogic.analogLevelOptions(number: number, micPreBacked: backed)
            guard offered.contains(preset.level) else {
                print("[Maestro] CARD SIMULATION: channel \(number) does not offer \(preset.level.displayName) — ignored")
                continue
            }
            _ = InputChannelLogic.applyLevelChange(&channels[i], to: preset.level)
            if let gain = preset.gain {
                channels[i].gain = InputChannelLogic.clampGain(gain, level: preset.level)
            }
            channels[i].softLimit = InputChannelLogic.coerceSoftLimit(
                channels[i].softLimit, card: cardForStrip(i))
        }
        print("[Maestro] CARD SIMULATION: preset analog levels applied to \(presets.compactMap { $0 }.count) channel(s)")
    }

    private func writeChannelProperty(_ index: Int, _ selector: AudioPropertySelector, value: PropertyValue) async {
        guard let device = appState.device else { return }
        do {
            let element = UInt32(index)
            try await device.setProperty(
                PropertyAddress(selector: selector, scope: .input, element: element),
                value: value
            )
        } catch {
            print("[Maestro] Input channel write \(selector) ch\(index) failed: \(error)")
        }
    }

    /// Encode analog ref type + trim into a single UInt32 for the USB command.
    /// Format: bits[7:0] = type, bits[15:8] = trim byte.
    ///
    /// The trim byte is level-dependent: `round(10*dB)` for +4 dBu/-10 dBV,
    /// `round(2*dB)` for Variable, and the 127 "do not set" sentinel for
    /// Mic/Instrument (which carry gain, not trim).
    /// Evidence: `SymphonyIOControl.cpp:595-635`; command `0x20` pData = [type, trim].
    private func analogIOTypeWithTrim(_ index: Int) -> UInt32 {
        guard index < channels.count else { return 0 }
        let level = AnalogInputLevel(rawValue: channels[index].inputType) ?? .plus4dBu
        return InputChannelLogic.analogIOTypeWithTrim(level: level, trim: channels[index].trim)
    }

    /// Apply an analog level change: push the new type (+ trim), and if the change
    /// dropped the channel out of Mic, clear +48 V on the hardware too.
    ///
    /// Legacy left phantom latched here (`fTurnOffPhantomPower` was assigned and
    /// never read), so `ApplySettingsToHardware` re-pushed +48 V onto a channel now
    /// set to Instrument or Line. We clear it instead.
    private func applyInputTypeChange(_ index: Int) {
        guard index < channels.count else { return }
        let level = AnalogInputLevel(rawValue: channels[index].inputType) ?? .plus4dBu
        let before = channels[index]
        let clearedPhantom = InputChannelLogic.applyLevelChange(&channels[index], to: level)

        // Soft limit choices are card-dependent; collapse an illegal carry-over.
        channels[index].softLimit = InputChannelLogic.coerceSoftLimit(
            channels[index].softLimit, card: cardForStrip(index))

        // applyLevelChange also drops the channel out of its gain group and, when
        // the new level is not Mic/Instrument, frees the insert and its return.
        // Push whichever of those actually moved.
        let clearedGroup = before.group != channels[index].group
        let clearedInsert = before.insert != channels[index].insert
        let clearedInsertReturn = before.insertReturn != channels[index].insertReturn

        let packed = analogIOTypeWithTrim(index)
        let gain = UInt32(max(0, channels[index].gain.rounded()))
        let sendsGain = InputChannelLogic.usesGainKnob(level: level)
        let insertsAfterLevelChange = insertAssignmentWrites()
        Task {
            if clearedPhantom {
                await writeChannelProperty(index, .phantom, value: .bool(false))
            }
            await writeChannelProperty(index, .analogIOType, value: .uint32(packed))
            if sendsGain {
                // Re-assert gain: Mic (0-85) and Instrument (0-65) are separate
                // hardware gain stages, so the value must be re-sent after a swap.
                // TODO(instrument-gain): Instrument gain is opcode 0xC4
                // (`SymphonyIOCommand.instrumentGain`), but no property selector maps
                // to it yet — `.micGain` (0xC3) is all we can address today.
                await writeChannelProperty(index, .micGain, value: .uint32(gain))
            }
            if clearedGroup {
                await writeChannelProperty(index, .groupID,
                                          value: .uint32(InputChannelLogic.groupOff))
            }
            if clearedInsert {
                // 0xC8 is addressed by INSERT and rebuilt whole — releasing this
                // channel's insert means writing mask 0 to it, which only the full
                // table does (`SymphonyIOBoard_MicPre8ch.cpp:1790-1810`).
                await pushInsertAssignments(insertsAfterLevelChange)
            }
            if clearedInsertReturn {
                await writeChannelProperty(index, .insertReturnEnable, value: .bool(false))
            }
        }
        syncAppliedGains()

        // Option-click applies the level to every other channel that offers it.
        // Evidence: APInputTabRowViewController.m:258-271.
        if Self.optionKeyIsDown {
            let snapshot = channels
            let others = InputChannelLogic.applyLevelToAll(
                &channels, to: level, micPreInstalled: micPreInstalled,
                hostAnalogInputChannels: micPreHostAnalogInputs, excluding: index)
            for i in others {
                // Each of these ran the same transition, so push the same set of
                // dependent writes the touched channel gets.
                let otherPacked = analogIOTypeWithTrim(i)
                let droppedPhantom = snapshot[i].phantom && !channels[i].phantom
                let droppedGroup = snapshot[i].group != channels[i].group
                let droppedReturn = snapshot[i].insertReturn != channels[i].insertReturn
                let sendsOtherGain = InputChannelLogic.usesGainKnob(level: level)
                let otherGain = UInt32(max(0, channels[i].gain.rounded()))
                Task {
                    if droppedPhantom {
                        await writeChannelProperty(i, .phantom, value: .bool(false))
                    }
                    await writeChannelProperty(i, .analogIOType, value: .uint32(otherPacked))
                    if sendsOtherGain {
                        await writeChannelProperty(i, .micGain, value: .uint32(otherGain))
                    }
                    if droppedGroup {
                        await writeChannelProperty(i, .groupID,
                                                  value: .uint32(InputChannelLogic.groupOff))
                    }
                    if droppedReturn {
                        await writeChannelProperty(i, .insertReturnEnable, value: .bool(false))
                    }
                }
            }
            // One rebuild covers every insert the option-click released. It is
            // deliberately outside the per-channel loop: `0xC8` is addressed by
            // INSERT, so N channels dropping inserts is still ONE eight-write
            // table, and it must be built from the final state of `channels`.
            if others.contains(where: { snapshot[$0].insert != channels[$0].insert }) {
                let rebuilt = insertAssignmentWrites()
                Task { await pushInsertAssignments(rebuilt) }
            }
            syncAppliedGains()
        }
        saveChannelStates()
    }

    /// Digital Ref change, with legacy's option-click "apply to every channel".
    /// Evidence: APInputTabRowViewController.m:275-283.
    private func applyDigitalRefChange(_ index: Int, level: UInt32) {
        Task { await writeChannelProperty(index, .digitalRefLevel, value: .uint32(level)) }
        if Self.optionKeyIsDown {
            for i in InputChannelLogic.applyDigitalRefToAll(&channels, to: level, excluding: index) {
                Task { await writeChannelProperty(i, .digitalRefLevel, value: .uint32(level)) }
            }
        }
        saveChannelStates()
    }

    /// Soft Limit change. Option-click applies it to every channel whose card
    /// offers that value, and turns soft limit OFF on the ones that do not —
    /// legacy bug 9466's fix, which is not the same as `coerceSoftLimit`.
    /// Evidence: APInputTabRowViewController.m:287-330.
    private func applySoftLimitChange(_ index: Int, mode: UInt32) {
        Task { await writeChannelProperty(index, .softLimit, value: .uint32(mode)) }
        if Self.optionKeyIsDown {
            let cards = (0..<channels.count).map { cardForStrip($0) }
            let others = InputChannelLogic.applySoftLimitToAll(
                &channels, to: mode, cards: cards, excluding: index)
            for i in others {
                let value = channels[i].softLimit
                Task { await writeChannelProperty(i, .softLimit, value: .uint32(value)) }
            }
        }
        saveChannelStates()
    }

    /// Gain change, routed through the group rules.
    ///
    /// The knob writes `channels[index].gain` directly through its binding, so
    /// the pre-move value is restored from `appliedGains` before the group logic
    /// converts the request into a relative offset.
    ///
    /// The firmware has been told the grouping (`0xC7`, see `applyGroupChange`),
    /// so ONLY the touched channel is written — the device derives every other
    /// member's gain itself and re-sending the derived values would apply the
    /// offset twice.
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:293-299` ("Don't set any derived
    /// group gains down to firmware ... The device is also calculating grouped
    /// gain changes").
    private func applyGainChange(_ index: Int, to requested: Double) {
        guard index < channels.count else { return }
        if index < appliedGains.count {
            channels[index].gain = appliedGains[index]
        }
        let result = InputChannelLogic.applyGainChange(&channels, channel: index, to: requested)
        syncAppliedGains()
        for i in result.hardwareWrites {
            let value = UInt32(max(0, channels[i].gain.rounded()))
            // TODO(instrument-gain): Instrument channels need 0xC4, not 0xC3.
            Task { await writeChannelProperty(i, .micGain, value: .uint32(value)) }
        }
        saveChannelStates()
    }

    /// Group assignment. Joining a group does NOT equalise gains — members keep
    /// their existing offsets and only move together from here on.
    /// Evidence: the daemon only writes `setMicPreGroup` (0xC7); gains are
    /// untouched until the next gain move (`SymphonyIOBoard_MicPre8ch.cpp:833-856`).
    ///
    /// Writes `0xC7` for the touched channel only; the firmware derives the rest
    /// of the group from there.
    private func applyGroupChange(_ index: Int, to group: UInt32) {
        guard index < channels.count else { return }
        channels[index].group = group
        Task { await writeChannelProperty(index, .groupID, value: .uint32(group)) }
        saveChannelStates()
    }

    /// Insert assignment. The insert return follows it automatically, so both
    /// are pushed. Evidence: SymphonyIOBoard_MicPre8ch.cpp:608-617.
    private func applyInsertChange(_ index: Int, to insert: UInt32) {
        guard index < channels.count else { return }
        let returnChanged = InputChannelLogic.applyInsertChange(&channels, channel: index, to: insert)
        let returnEnabled = channels[index].insertReturn
        let assignments = insertAssignmentWrites()
        Task {
            await pushInsertAssignments(assignments)
            if returnChanged {
                await writeChannelProperty(index, .insertReturnEnable, value: .bool(returnEnabled))
            }
        }
        saveChannelStates()
    }

    /// The complete eight-insert table, snapshotted from the CURRENT channel state.
    ///
    /// `0xC8` is addressed by INSERT, not by channel, and the daemon rebuilds all
    /// eight on every change — writing mask 0 is the only thing that releases an
    /// insert a channel just gave up. Doing anything less leaves a stale insert
    /// patched into a channel that no longer claims it.
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:1790-1810`
    /// (`SetInsertAssignmentInHardware`).
    private func insertAssignmentWrites() -> [(insert: Int, mask: UInt8)] {
        InputChannelLogic.insertAssignmentMasks(in: channels)
    }

    /// Push one full insert table. `element` is the INSERT index here — see the
    /// `.insertID` case in `SymphonyIOPropertyMapper`.
    private func pushInsertAssignments(_ assignments: [(insert: Int, mask: UInt8)]) async {
        guard let device = appState.device else { return }
        for (insert, mask) in assignments {
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .insertID, scope: .input, element: UInt32(insert)),
                    value: .uint32(UInt32(mask))
                )
            } catch {
                print("[Maestro] Insert \(insert + 1) assignment write failed: \(error)")
            }
        }
    }

    // MARK: - Reset to defaults

    /// What the confirmation dialog promises, phrased for the cards actually
    /// installed — on a unit with no MicPre the preamp sentence would be a lie.
    private var resetConfirmationMessage: String {
        let full = pendingResetScope == .all
        var parts: [String] = ["Soft Limit turns Off on every analog input."]
        if micPreInstalled {
            parts.append("Mic Pre channels return to +4 dBu with gain at 0 dB, "
                         + "no group and no insert, and 48 V, polarity and the "
                         + "high-pass filter switched off.")
        }
        parts.append(full
            ? "Every analog input returns to +4 dBu and -16 dBfs, with its trim at 0.0 dB."
            : "Analog Ref, Digital Ref and trims are left alone on line inputs.")
        parts.append("Routing is not changed.")
        return parts.joined(separator: " ")
    }

    /// Restore the Input page to the legacy factory defaults and push them.
    ///
    /// WRITE ORDER is legacy's `ApplySettingsToHardware`
    /// (`SymphonyIOBoard_MicPre8ch.cpp:2269-2296`): analog level FIRST, then
    /// insert enable, gain, group, polarity, **then phantom**, then high-pass.
    /// Phantom last-but-one is a safety ordering, not a stylistic one: the
    /// hardware refuses +48 V on a channel that is not at Mic
    /// (`SymphonyIOBoard_MicPre8ch.cpp:686-696`), so it can only be trusted once
    /// the level has been established.
    private func resetInputDefaults(scope: SymphonyIOResetScope) async {
        let result = InputChannelLogic.resetToDefaults(
            &channels,
            includingCalibration: scope.resetsTrims,
            micPreInstalled: micPreInstalled,
            hostAnalogInputChannels: micPreHostAnalogInputs)
        syncAppliedGains()
        saveChannelStates()
        guard !result.changed.isEmpty else { return }

        let micPre = Set(result.micPreChannels)
        for i in result.changed {
            // 1. Analog level (+ trim in byte[1]) — everything else depends on it.
            await writeChannelProperty(i, .analogIOType, value: .uint32(analogIOTypeWithTrim(i)))

            if micPre.contains(i) {
                // 2. Insert return off. The insert ASSIGNMENT is addressed by
                //    insert rather than channel, so it is one table written once,
                //    after this loop.
                await writeChannelProperty(i, .insertReturnEnable, value: .bool(false))
                // 3. Gain. TODO(instrument-gain): 0xC4 has no selector yet, but
                //    the default is 0 for both stages, so one write covers it.
                await writeChannelProperty(i, .micGain,
                                           value: .uint32(UInt32(InputResetDefaults.gain)))
                // 4. Group.
                await writeChannelProperty(i, .groupID, value: .uint32(InputResetDefaults.group))
                // 5. Polarity.
                await writeChannelProperty(i, .phaseReverse, value: .bool(InputResetDefaults.polarity))
                // 6. Phantom — after the level is known to be +4 dBu.
                await writeChannelProperty(i, .phantom, value: .bool(InputResetDefaults.phantom))
                // 7. High pass.
                await writeChannelProperty(i, .highPassFilter,
                                           value: .bool(InputResetDefaults.highPassFilter))
            }

            // Line-channel settings. Digital Ref is legal here because step 1 has
            // already put the channel back at a line level.
            await writeChannelProperty(i, .digitalRefLevel, value: .uint32(channels[i].digitalRefLevel))
            await writeChannelProperty(i, .softLimit, value: .uint32(channels[i].softLimit))
        }

        // One eight-insert rebuild releases everything the reset gave up — a
        // per-channel write cannot, because mask 0 has to reach each insert.
        if result.releasedAnInsert {
            await pushInsertAssignments(insertAssignmentWrites())
        }
    }

    /// Mirror of the gain values the group logic last settled on, so a knob move
    /// can be re-read as a relative offset.
    private func syncAppliedGains() {
        appliedGains = channels.map(\.gain)
    }

    /// Legacy's `[APUtilities optionKeyIsDown]` (`APUtilities.m:69-72`), which reads
    /// the modifier flags of the current event. `NSApp.currentEvent` is the menu's
    /// mouse-up by the time a `PillMenu` action fires, so the live hardware state
    /// is consulted as well.
    private static var optionKeyIsDown: Bool {
        NSEvent.modifierFlags.contains(.option)
            || (NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    // MARK: - SPDIF Replace Helpers

    /// Meter level at `index + offset`, or silence when the payload has no word
    /// for that pair. The digital meter arrays are fixed at 24 entries.
    private static func meterLevel(_ levels: [Double], _ index: Int?, offset: Int = 0) -> Double {
        guard let index, index + offset < levels.count else { return -60 }
        return levels[index + offset]
    }

    /// SPDIF Coax Replace options for one slot's module.
    ///
    /// `SymphonyIOBoardSPDIFCoaxReplace` (`SymphonyIOVendorSpecific.h:937-948`)
    /// is eight pair indices within the board's own 16-channel slice — its own
    /// comment says the `Analog`/`Digital` names "dont make sense for certain
    /// boards (e.g. AD16 which should have analog 1 through 16 instead of
    /// digital)" — so the names and the count come from the installed card.
    private func spdifReplaceOptions(element: UInt32) -> [CardLayout.SPDIFOption] {
        layout.spdifOptions(slot: Int(element), isInput: true)
    }

    @ViewBuilder
    private func spdifReplaceDropdown(label: String, value: Binding<UInt32>, selector: AudioPropertySelector, element: UInt32 = 0) -> some View {
        let spdifReplaceOptions = spdifReplaceOptions(element: element)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            PillMenu(
                text: spdifReplaceOptions.first(where: { $0.id == value.wrappedValue })?.name ?? "Off",
                fontSize: 9,
                pillHeight: 20,
                toolTip: "SPDIF Replace — replace an input pair with the SPDIF coax input",
                options: spdifReplaceOptions.map { [appState] option in
                    let optVal = option.id
                    return (option.name, {
                        value.wrappedValue = optVal
                        Task {
                            guard let device = appState.device else { return }
                            do {
                                try await device.setProperty(
                                    PropertyAddress(selector: selector, scope: .input, element: element),
                                    value: .uint32(optVal)
                                )
                            } catch {
                                print("[Maestro] SPDIF Replace write failed: \(error)")
                            }
                        }
                    })
                }
            )
            .frame(width: 90)
        }
    }

    private func loadDigitalSettings() async {
        guard let device = appState.device else { return }
        do {
            let val = try await device.getProperty(PropertyAddress(selector: .spdifReplaceID, scope: .input))
            if let u = val.asUInt32 { spdifReplace1 = u }
        } catch {
            print("[Maestro] loadDigitalSettings spdifReplace1: \(error)")
        }
        do {
            let val = try await device.getProperty(PropertyAddress(selector: .spdifReplaceID, scope: .input, element: 1))
            if let u = val.asUInt32 { spdifReplace2 = u }
        } catch {
            print("[Maestro] loadDigitalSettings spdifReplace2: \(error)")
        }
    }
}

/// ADAT stereo pair meter — two thin LED meters side by side with a shared label.
/// Displayed in the DIGITAL section of Input/Output views.
struct ADATStereoPairView: View {
    let label: String
    let leftLevel: Double
    let rightLevel: Double
    var leftPeak: Double = -60
    var rightPeak: Double = -60
    /// When set, the strip matches this total height — Spacer fills gap between label and meters.
    var matchHeight: CGFloat? = nil
    var showZoneColoring: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 3) {
            // Label pill — matches analog channel strip style
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )

            // Spacer fills the gap where analog strips have pills — pushes meters to bottom
            if matchHeight != nil {
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 1) {
                // Left LED meter (no scale)
                LEDMeterView(
                    level: leftLevel,
                    peak: leftPeak,
                    label: "",
                    height: 200,
                    width: 10,
                    rangeDB: 48,
                    showZoneColoring: showZoneColoring
                )
                // Center scale between meters — labels centered for readability
                adatCenterScale
                // Right LED meter (no scale)
                LEDMeterView(
                    level: rightLevel,
                    peak: rightPeak,
                    label: "",
                    height: 200,
                    width: 10,
                    rangeDB: 48,
                    showZoneColoring: showZoneColoring
                )
            }
        }
        .frame(width: 70)
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .frame(height: matchHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.controlBackgroundColor).opacity(colorScheme == .light ? 0.6 : 0.3))
        )
    }

    /// Centered dB scale drawn between left and right ADAT meters.
    /// Uses segment-center alignment so labels at extremes don't clip.
    /// Perceptually scaled: labeled marks every 6 dB + minor ticks at 3/9 for density near 0.
    @ViewBuilder
    private var adatCenterScale: some View {
        let meterHeight: CGFloat = 200
        let scale = MeterScale(rangeDB: 48)
        let segmentHeight = (meterHeight - 23) / 24
        let majorMarks: [Int] = [0, 6, 12, 18, 24, 30, 36, 42, 48]
        let minorMarks: [Int] = [3, 9]  // perceptual density near 0 dB
        // Extra height for top/bottom labels (half text height above 0 dB, below -48 dB)
        let labelPad: CGFloat = 6

        Canvas { context, size in
            // Scale positions inset by labelPad so extreme labels aren't clipped
            let topY: CGFloat = labelPad + segmentHeight / 2
            let bottomY: CGFloat = size.height - labelPad - segmentHeight / 2

            // Major marks — labeled with ticks on both sides (perceptual spacing)
            for db in majorMarks {
                let y = scale.perceptualY(db: Double(db), topCenter: Double(topY), bottomCenter: Double(bottomY))

                var tickL = Path()
                tickL.move(to: CGPoint(x: 0, y: y))
                tickL.addLine(to: CGPoint(x: 3, y: y))
                context.stroke(tickL, with: .color(.gray.opacity(0.4)), lineWidth: 0.5)

                var tickR = Path()
                tickR.move(to: CGPoint(x: size.width - 3, y: y))
                tickR.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(tickR, with: .color(.gray.opacity(0.4)), lineWidth: 0.5)

                // Centered label with minus sign (dBFS)
                let label = db == 0 ? "0" : "-\(db)"
                let text = Text(label)
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundColor(.gray)
                context.draw(text, at: CGPoint(x: size.width / 2, y: y), anchor: .center)
            }

            // Minor marks — tick only (no label), perceptual density near 0 dB
            for db in minorMarks {
                let y = scale.perceptualY(db: Double(db), topCenter: Double(topY), bottomCenter: Double(bottomY))

                var tickL = Path()
                tickL.move(to: CGPoint(x: 1, y: y))
                tickL.addLine(to: CGPoint(x: 3, y: y))
                context.stroke(tickL, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)

                var tickR = Path()
                tickR.move(to: CGPoint(x: size.width - 3, y: y))
                tickR.addLine(to: CGPoint(x: size.width - 1, y: y))
                context.stroke(tickR, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
            }
        }
        .frame(width: 22, height: meterHeight + labelPad * 2)
        .offset(y: -labelPad) // shift scale up so marks align with meter segments
    }
}

/// A `PillMenu` whose items can be individually disabled.
///
/// Needed for the Insert popup: insert IDs are exclusive across channels, and
/// legacy greys out an ID already claimed by another channel rather than hiding
/// it (`APAnalogInputController.m:425-441`, backed by
/// `kmAEstroPropertyInsertEnableForID`, `SymphonyIOBoard_MicPre8ch.cpp:1216-1248`).
///
/// TODO(controls): this duplicates `PillMenu`'s chrome because `PillMenu.options`
/// is `[(String, () -> Void)]` with no enabled flag. Folding an `enabled` field
/// into `PillMenu` would delete this type — `Controls.swift` is owned elsewhere.
private struct DisablablePillMenu: View {
    let text: String
    var highlight: Bool = false
    var highlightColor: Color = .blue
    var fontSize: CGFloat = 8
    var pillHeight: CGFloat = 18
    var toolTip: String = ""
    /// (label, enabled, action)
    let options: [(String, Bool, () -> Void)]
    @State private var isHovered = false

    var body: some View {
        Button {
            showNativeMenu()
        } label: {
            ZStack {
                Text(text)
                    .font(.system(size: fontSize, weight: .medium))
                    .lineLimit(1)
                HStack {
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: max(6, fontSize - 1), weight: .medium))
                        .opacity(isHovered ? 0.5 : 0)
                        .padding(.trailing, 3)
                }
            }
            .foregroundStyle(highlight ? highlightColor : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: pillHeight)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(highlight
                            ? highlightColor.opacity(isHovered ? 0.22 : 0.15)
                            : Color.primary.opacity(isHovered ? 0.12 : 0.06))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(highlight
                        ? highlightColor.opacity(isHovered ? 0.6 : 0.5)
                        : Color.primary.opacity(isHovered ? 0.35 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(toolTip)
    }

    private func showNativeMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false   // otherwise AppKit re-enables every item
        for (label, enabled, action) in options {
            let item = NSMenuItem(title: label, action: #selector(DisablablePillMenuTarget.fire), keyEquivalent: "")
            let target = DisablablePillMenuTarget(action)
            item.target = target
            item.representedObject = target   // prevent ARC dealloc during menu display
            item.isEnabled = enabled
            if label == text { item.state = .on }
            menu.addItem(item)
        }
        if let event = NSApp.currentEvent, let contentView = event.window?.contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil, at: point, in: contentView)
        }
    }
}

/// Target-action bridge for NSMenuItem → Swift closure.
private class DisablablePillMenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// A single input channel strip matching legacy Maestro 2 layout:
/// Label → Ref Level → Soft Limit → Preamp buttons → Gain readout → Fader + Meter → dB readout.
///
/// Evidence: `og_source/maestro2/App/Controllers/Input/APAnalogInputController.m`
/// Evidence: `SymphonyIOVendorSpecific.h` — SymphonyIOAnalogIOType enum
struct InputChannelStripView: View {
    @Binding var channel: InputChannelState
    let label: String
    /// Keep 20 Hz meter observation inside each strip. Reading these arrays in
    /// InputView would invalidate the entire horizontal rack on every sample.
    var appState: AppState? = nil
    var meterIndex: Int? = nil
    var meterLevel: Double = -60
    var meterPeakHold: Double = -60
    var showTrims: Bool = false
    let onPhantomChange: (Bool) -> Void
    let onPhaseChange: (Bool) -> Void
    let onHPFChange: (Bool) -> Void
    var onSoftLimitChange: ((UInt32) -> Void)?
    /// Mic/Instrument preamp gain in dB — written to 'AEmg' (0xC3).
    var onGainChange: ((Double) -> Void)?
    var onInputTypeChange: ((UInt32) -> Void)?
    var onDigitalRefChange: ((UInt32) -> Void)?
    var onTrimChange: ((Double) -> Void)?
    var showZoneColoring: Bool = false
    /// The I/O card type for this channel's board — determines the soft limit list.
    var boardType: IOCardType = .none
    /// 1-based device-wide channel number (continuous across cards).
    var channelNumber: Int = 1
    /// Whether a MicPre8 module feeds this channel (device inputs 1-8).
    var micPreBacked: Bool = false
    /// Whether ANY channel in this rack can show MicPre controls.
    ///
    /// The Group / Insert / preamp-button rows are reserved as blank space on
    /// channels that cannot use them, so every strip in the rack keeps the same
    /// height and the meters share one baseline -- `AnalogStripHeightKey` takes
    /// the max across strips, so a ragged rack stretches the digital columns too.
    /// But when NO strip in the rack can ever show them there is nothing to align
    /// against, and reserving anyway just adds ~110 pt of dead space below every
    /// meter. Legacy sized its strip view once at 82x270 and swapped contents
    /// inside it (`APAnalogInputView.xib`); it never grew a rack that had no
    /// MicPre.
    var rackHasMicPre: Bool = false
    /// Insert popup contents for THIS channel — insert IDs are exclusive across
    /// channels, so an ID claimed elsewhere arrives with `enabled == false`.
    var insertOptions: [(value: UInt32, name: String, enabled: Bool)] = []
    /// User-editable insert names from Device Settings; shared across channels.
    var insertLabels: InsertLabels = InsertLabels()
    /// Group popup — the parent owns the whole group, so the change is routed up.
    var onGroupChange: ((UInt32) -> Void)?
    /// Insert assignment ('AEit'). The parent also pushes the insert return that follows it.
    var onInsertChange: ((UInt32) -> Void)?
    /// Insert return "In" button ('AEir').
    var onInsertReturnChange: ((Bool) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    /// The channel's current analog reference level (wire enum).
    private var level: AnalogInputLevel {
        AnalogInputLevel(rawValue: channel.inputType) ?? .plus4dBu
    }

    private var resolvedMeterLevel: Double {
        guard let appState, let meterIndex else { return meterLevel }
        return meterIndex < appState.inputMeterLevels.count ? appState.inputMeterLevels[meterIndex] : -60
    }

    private var resolvedMeterPeakHold: Double {
        guard let appState, let meterIndex else { return meterPeakHold }
        return meterIndex < appState.inputPeakHold.count ? appState.inputPeakHold[meterIndex] : -60
    }

    /// Soft limit options for the card that owns this channel.
    /// The 16x16 exposes only Off / On (On == -4 dBfs).
    private var softLimitLabels: [(UInt32, String)] {
        InputChannelLogic.softLimitOptions(card: boardType).map { ($0.value, $0.name) }
    }

    /// Analog level options — per-CHANNEL capability, not per-card.
    private var inputTypeLabels: [(UInt32, String)] {
        InputChannelLogic.analogLevelOptions(number: channelNumber, micPreBacked: micPreBacked)
            .map { ($0.rawValue, $0.displayName) }
    }

    /// Whether this channel shows the preamp row (48V, Ø, HPF).
    /// Present on a MicPre-backed channel set to Mic **or Instrument**.
    private var hasMicPreControls: Bool {
        InputChannelLogic.showsPreampControls(micPreBacked: micPreBacked, level: level)
    }

    /// Whether this channel shows the Group popup (MicPre channel at a preamp level).
    /// Wired to `0xC7` via `SymphonyIOPropertyMapper` `.groupID`.
    private var hasGroupControl: Bool {
        InputChannelLogic.showsGroupControl(micPreBacked: micPreBacked, level: level)
    }

    /// Whether this channel shows the Insert popup + "In" (insert return) button.
    /// Wired to `0xC8` / `0xC9` via `.insertID` / `.insertReturnEnable`.
    private var hasInsertControls: Bool {
        InputChannelLogic.showsInsertControls(micPreBacked: micPreBacked, level: level)
    }

    /// +48 V is interlocked to Mic — the daemon silently refuses it at any other
    /// level, so the button is disabled rather than allowed to lie.
    private var phantomEnabled: Bool { InputChannelLogic.phantomAllowed(level: level) }

    /// Whether the strip shows a gain knob (Mic/Instrument) instead of a trim fader.
    private var usesGainKnob: Bool { InputChannelLogic.usesGainKnob(level: level) }

    /// Whether anything sits beside the meter (gain knob or trim fader).
    /// The gain knob is always present on preamp channels — it is the channel's
    /// primary control, not an optional "show trims" extra.
    private var hasSideControl: Bool { usesGainKnob || showTrims }

    /// Digital ref level options — same as output (Evidence: SymphonyIOVendorSpecific.h)
    private let digitalRefLabels: [(UInt32, String)] = [
        (0, "-20 dBfs"), (1, "-18 dBfs"), (2, "-16 dBfs"),
        (3, "-14 dBfs"), (4, "-12 dBfs"), (5, "-10 dBfs")
    ]

    var body: some View {
        VStack(spacing: 3) {
            // Channel label — styled prominently with background pill
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )

            // Stacked dropdown labels — fixed-width pills, chevron on hover only
            VStack(spacing: 3) {
                // Analog reference level
                if let onInputTypeChange {
                    PillMenu(
                        text: inputTypeName(channel.inputType),
                        toolTip: "Analog Ref — Sets the analog reference level (+4 dBu for pro gear, -10 dBV for consumer)",
                        options: inputTypeLabels.map { val, name in
                            // The parent runs the full transition (clamp gain/trim,
                            // clear phantom when leaving Mic, push to hardware).
                            (name, { channel.inputType = val; onInputTypeChange(val) })
                        }
                    )
                }

                // Digital reference level — conditional on the analog level:
                //   Variable        → hidden (daemon reports the property not implemented)
                //   Mic/Instrument  → shown but disabled (legacy greys it, never hides it)
                //   +4 dBu/-10 dBV  → shown and enabled
                // Evidence: AnalogIn_SymphonyIO_Stream.cpp:768-787, APAnalogInputController.m:854
                let digitalRefState = InputChannelLogic.digitalRefVisibility(for: level)
                if digitalRefState != .hidden {
                    PillMenu(
                        text: digitalRefLabels.first(where: { $0.0 == channel.digitalRefLevel })?.1 ?? "-16 dBfs",
                        toolTip: digitalRefState == .disabled
                            ? "Digital Ref — not available at \(level.displayName) level"
                            : "Digital Ref — Sets digital headroom reference (-16 dBfs standard, -20 dBfs for more headroom)",
                        options: digitalRefLabels.map { val, name in
                            (name, {
                                channel.digitalRefLevel = val
                                onDigitalRefChange?(val)
                            })
                        }
                    )
                    .disabled(digitalRefState == .disabled)
                    .opacity(digitalRefState == .disabled ? 0.45 : 1)
                } else {
                    // Keep the row height stable so neighbouring strips (and the
                    // ADAT columns that match their height) stay aligned.
                    Color.clear.frame(height: 18)
                }

                // Soft limiter
                if let onSoftLimitChange {
                    PillMenu(
                        text: InputChannelLogic.softLimitName(channel.softLimit, card: boardType),
                        highlight: channel.softLimit > 0,
                        highlightColor: .purple,
                        toolTip: "Soft Limit — Analog limiter that gently catches peaks before clipping",
                        options: softLimitLabels.map { val, name in
                            (name, { channel.softLimit = val; onSoftLimitChange(val) })
                        }
                    )
                }
            }

            // Constant breathing room so toggling trims doesn't shift vertically
            Spacer().frame(height: 16)

            // Meter + optional trim fader area.
            // Default: just the meter + scale (left), centered. Show Trims: trim fader + meter filling width.
            HStack(alignment: .top, spacing: 1) {
                if usesGainKnob {
                    // Mic / Instrument channels carry preamp GAIN (a separate
                    // property, 'AEmg'/0xC3), not calibration trim: integer dB,
                    // 0-85 for Mic and 0-65 for Instrument, 1 dB step.
                    // The widget swap is driven by the analog level, not the card
                    // (APAnalogInputController.m:583-590).
                    let gainRange = InputChannelLogic.gainRange(for: level) ?? 0...85
                    VStack(spacing: 4) {
                        RotaryKnobView(
                            value: $channel.gain,
                            range: gainRange,
                            step: 1,
                            label: "Gain",
                            unit: "dB",
                            size: 40,
                            defaultValue: 0,
                            externalReadout: true,  // drawn just below, inside this column
                            onUserChange: { onGainChange?($0) }
                        )
                        // The Level Trim value belongs to the knob, so it sits
                        // directly beneath it inside the knob's own column —
                        // where Apogee puts it (User's Guide p. 56). It is NOT
                        // in the readout row below the meter: there it would sit
                        // unlabelled next to the meter-level number, and nothing
                        // would say which was which.
                        Text(String(format: "%.0f", channel.gain))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                            .help("Level Trim — gain of the mic pre, currently \(String(format: "%.0f", channel.gain)) dB (\(level == .instrument ? "0–65 dB at Instrument" : "0–85 dB at Mic")).")
                        Spacer(minLength: 0)
                    }
                    .frame(width: 46, height: 200, alignment: .top)
                    .help("Level Trim — adjusts the gain of the mic pre. "
                          + (level == .instrument ? "0–65 dB at Instrument level." : "0–85 dB at Mic level.")
                          + " When the channel is in a Group, the whole group moves with it and existing offsets between members are preserved.")
                    .transition(.opacity)
                } else if showTrims {
                    let trimSpec = InputChannelLogic.trimRange(for: level) ?? (-2.0...2.0, 0.1)
                    FaderView(
                        value: $channel.trim,
                        range: trimSpec.range,
                        step: trimSpec.step,
                        defaultValue: 0,  // 0.0 dB is the default at every level
                        height: 200,
                        showScale: true,
                        externalReadout: true,
                        thumbHeight: 20,
                        thumbWidth: 18
                    )
                    .help("Trim — precisely trims the A/D conversion level once the reference levels have been chosen.")
                    .transition(.opacity)
                    .onChange(of: channel.trim) { _, newTrim in
                        onTrimChange?(newTrim)
                    }
                }

                // A/D converter meter: -48 to 0 dBFS — scale always on left
                LEDMeterView(
                    level: resolvedMeterLevel,
                    peak: resolvedMeterPeakHold,
                    label: "",
                    height: 200,
                    width: hasSideControl ? 10 : 14,
                    showScale: true,
                    scaleOnLeft: true,
                    rangeDB: 48,
                    showZoneColoring: showZoneColoring
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(x: hasSideControl ? 0 : -8) // center the group visually within the strip
            .animation(.easeInOut(duration: 0.15), value: showTrims)

            // Trim readout + Meter Level readout — a LINE-strip row (User's Guide
            // p. 55, items 6 and 8). A Mic/Instrument strip has neither: its gain
            // number lives under the knob and the original shows no meter-level
            // box beside the mic pre meter (p. 56). The row is still reserved on
            // those strips so Group / Insert / Ø-48-HPF stay on one grid across
            // the whole rack.
            if hasSideControl && !usesGainKnob {
                HStack(spacing: 3) {
                    Text(String(format: "%.1f", channel.trim))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                        .help("Trim — calibration trim, currently \(String(format: "%.1f", channel.trim)) dB.")
                    Text(String(format: "%.0f", resolvedMeterLevel))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                        .help("Meter Level: \(String(format: "%.1f", resolvedMeterLevel)) dBFS")
                }
                .offset(x: 0)
                .padding(.top, 4)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: showTrims)
            } else {
                // Reserve the readout row so every strip's Group / Insert /
                // Ø-48-HPF rows sit at the same height across the rack, even
                // with trims hidden on the line strips.
                Color.clear.frame(height: Self.readoutRowHeight)
            }

            // ---- Group / Insert / preamp buttons ----------------------------
            // Order is Apogee's, from the Mic Pre Module Input Tab (User's Guide
            // p. 56): Level Trim and its meter first, then Group, then Insert
            // (with "In" on the label line and the selection popup beneath it),
            // and the Ø / 48 / high-pass row last.
            //
            // A MicPre strip sits directly beside a plain Line strip, so the
            // rows are RESERVED rather than omitted on channels that have no
            // preamp — the same thing Digital Ref already does. Without that the
            // rack's rows stagger wherever a Mic strip meets a Line strip.
            groupRow
            insertRow
            preampButtonRow

        }
        .frame(width: 112)
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.controlBackgroundColor).opacity(colorScheme == .light ? 0.6 : 0.3))
        )
        .animation(.easeInOut(duration: 0.15), value: showTrims)
    }

    // MARK: - Row grid (Apogee's order, reserved on every strip)

    /// Heights of the rows that are reserved rather than omitted, so a MicPre
    /// strip and the Line strip beside it stay on the same grid.
    private static let readoutRowHeight: CGFloat = 21
    private static let captionRowHeight: CGFloat = 16
    private static let pillRowHeight: CGFloat = 18
    private static let buttonRowHeight: CGFloat = 16

    /// Small row caption, standing in for the original's left-edge row labels.
    private func rowCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// **Group** — caption above, value below, exactly as the manual's strip has
    /// it. Grouped channels move by a shared RELATIVE offset; their existing gain
    /// differences are preserved, and the group drops to Off whenever the analog
    /// level changes.
    /// Evidence: SymphonyIOBoard_MicPre8ch.cpp:186-330, :513-526.
    @ViewBuilder
    private var groupRow: some View {
        if hasGroupControl {
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    rowCaption("Group")
                    Spacer(minLength: 0)
                }
                .frame(height: Self.captionRowHeight)
                PillMenu(
                    text: InputChannelLogic.groupName(channel.group),
                    highlight: channel.group != InputChannelLogic.groupOff,
                    highlightColor: .teal,
                    toolTip: "Group — chooses a Level Trim group, for controlling the Level Trim of multiple inputs simultaneously. Any level offset that exists before inputs are grouped is preserved after a group is chosen.",
                    options: InputChannelLogic.groupOptions().map { val, name in
                        (name, { onGroupChange?(val) })
                    }
                )
            }
        } else if rackHasMicPre {
            Color.clear.frame(height: Self.captionRowHeight + 2 + Self.pillRowHeight)
        }
    }

    /// **Insert** — the caption line carries the "In" (insert return) button on
    /// its right, with the insert selection popup directly beneath, matching the
    /// manual's strip. "In" only exists once an insert is assigned (legacy binds
    /// its `hidden` to the insert being None) but its slot is still reserved, so
    /// the popup below does not jump.
    /// Evidence: APAnalogInputController.m:244-248, :608-617 for the follow.
    @ViewBuilder
    private var insertRow: some View {
        if hasInsertControls {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    rowCaption("Insert")
                    Spacer(minLength: 0)
                    if channel.insert != InputChannelLogic.insertNone {
                        Button {
                            channel.insertReturn.toggle()
                            onInsertReturnChange?(channel.insertReturn)
                        } label: {
                            Text("In")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(channel.insertReturn ? .blue : .secondary)
                                .frame(width: 20, height: 14)
                                .background(channel.insertReturn ? Color.blue.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        .buttonStyle(.plain)
                        .help("Insert In — enables the Insert Return. The Insert Send is always active once an insert is selected, so the send can be used as an analog direct out while In is not engaged.")
                    } else {
                        Color.clear.frame(width: 20, height: 14)
                    }
                }
                .frame(height: Self.captionRowHeight)
                DisablablePillMenu(
                    text: InputChannelLogic.insertName(channel.insert, labels: insertLabels),
                    highlight: channel.insert != InputChannelLogic.insertNone,
                    highlightColor: .blue,
                    toolTip: "Insert Select — inserts one of the eight rear-panel send/return pairs into the input signal path. The insert point occurs after the mic pre and high-pass filter and before the A/D conversion stage. Each insert can serve only one channel.",
                    options: insertOptions.map { val, name, enabled in
                        (name, enabled, { onInsertChange?(val) })
                    }
                )
            }
        } else if rackHasMicPre {
            Color.clear.frame(height: Self.captionRowHeight + 2 + Self.pillRowHeight)
        }
    }

    /// **Ø | 48 | high pass** — the manual's bottom button row, in that
    /// left-to-right order. Shown on a MicPre-backed channel set to Mic or
    /// Instrument. Phantom is separately interlocked to Mic: the daemon silently
    /// refuses +48 V at any other level (SymphonyIOBoard_MicPre8ch.cpp:686-696),
    /// so the button is disabled rather than allowed to show a state the hardware
    /// ignores.
    @ViewBuilder
    private var preampButtonRow: some View {
        if hasMicPreControls {
            HStack(spacing: 3) {
                Button {
                    channel.phase.toggle()
                    onPhaseChange(channel.phase)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 8))
                        .foregroundStyle(channel.phase ? .orange : .secondary)
                        .frame(width: 18, height: Self.buttonRowHeight)
                        .background(channel.phase ? Color.orange.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .help("Polarity — inverts the polarity of the input signal.")

                Button {
                    guard phantomEnabled else { return }
                    channel.phantom.toggle()
                    onPhantomChange(channel.phantom)
                } label: {
                    Text("48V")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(channel.phantom ? .yellow : .secondary)
                        .frame(width: 24, height: Self.buttonRowHeight)
                        .background(channel.phantom ? Color.yellow.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .disabled(!phantomEnabled)
                .opacity(phantomEnabled ? 1 : 0.4)
                .help(phantomEnabled
                      ? "48V — enables 48 volt phantom power on this Analog IN channel. Condenser mics require it."
                      : "48V — Mic level only. The hardware refuses phantom power on a channel set to any other level, so this is unavailable until Analog Ref is Mic.")

                Button {
                    channel.hpf.toggle()
                    onHPFChange(channel.hpf)
                } label: {
                    Text("80Hz")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(channel.hpf ? .green : .secondary)
                        .frame(width: 26, height: Self.buttonRowHeight)
                        .background(channel.hpf ? Color.green.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                // Fixed corner frequency — the firmware never exposes it; the
                // Symphony I/O user guide specifies 80 Hz.
                .help("High Pass — engages a fixed \(InputChannelLogic.highPassFrequencyHz) Hz high-pass filter on the input.")
            }
            .frame(height: Self.buttonRowHeight)
        } else if rackHasMicPre {
            Color.clear.frame(height: Self.buttonRowHeight)
        }
    }

    /// Display name for the wire-enum analog level.
    private func inputTypeName(_ type: UInt32) -> String {
        AnalogInputLevel(rawValue: type)?.displayName ?? "?"
    }
}
