import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


/// Output Controls view — per-channel output strips with analog/digital ref levels,
/// optional trim faders, Speaker/HP inline controls, and DIGITAL section with ADAT meters.
/// Mirrors InputControlsView structure with output-specific adaptations.
///
/// # Parity with the original Maestro's Output tab
///
/// The user guide (July 2018, p. 57) documents eight controls. Seven are here:
/// Show/Hide Trims, Reset Trims, Analog Ref Level, Digital Ref Level, Trim
/// Fader, D/A Meter and S/PDIF Mirrors, all with the option-click and range
/// behaviour Apogee describes.
///
/// The eighth, "Device Icon & ID Button", is **not** implemented. Note that the
/// guide's *text* for item 1 is a copy of item 4's ("use this drop down menu to
/// choose the analog level for each D/A conversion channel") — the callout
/// points at the device icon and the ID button in the row header, which is a
/// different control entirely. The ID button toggles
/// `kmAEstroPropertyIdentify` / `SymphonyIOCommands_IdentifyUnit` (`0x33`) to
/// flash the front-panel LEDs (`APAnchorDeviceViewController.m:191-196`).
/// `AudioPropertySelector.identify` ("AEbb") exists, but no case in
/// `SymphonyIOCommand` or `SymphonyIOPropertyMapper` maps it to `0x33`, so the
/// write would be dropped.
/// TODO(SymphonyIOCommand/SymphonyIOPropertyMapper owner): add
/// `identifyUnit = 0x33` and map `.identify` to it; this page can then host the
/// ID button.
///
/// Evidence: `og_source/maestro2/App/Controllers/Output/`
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` — output properties
struct OutputControlsView: View {
    private let appState: AppState
    @State private var channels: [OutputChannelState]
    @State private var errorMessage: String?
    @State private var showResetAlert: Bool = false
    /// Non-nil while the "reset defaults" confirmation is up; carries the scope.
    @State private var pendingResetScope: SymphonyIOResetScope?
    /// SPDIF Coax 1-2 Mirrors value.
    ///
    /// Legacy's own default is `m_nSPDIFMirrorsID = 2`
    /// (`SymphonyIO_IOBoard.cpp:96`), i.e. wire value 1 — the board's first
    /// output pair. Both slots default the same way; the old `5` on slot 2 was
    /// an 8x8-shaped guess ("Digital 1-2") that names a different pair on every
    /// other card.
    @State private var spdifMirror1: UInt32 = 1
    /// SPDIF Coax 3-4 Mirrors value.
    @State private var spdifMirror2: UInt32 = 1
    /// Measured height of the tallest analog strip — used to match ADAT/DIGITAL heights.
    @State private var analogStripHeight: CGFloat = 0

    // Speaker / HP state — inline in output tab
    @State private var speakerDim: Bool = false
    @State private var speakerMono: Bool = false
    @State private var speakerConfig: UInt32 = 2  // default Stereo (Out 1-2)
    /// Speaker Select mask — bit 0/1/2 = set A/B/C, shown as pills 1/2/3.
    ///
    /// This really is a **bitmask**, not a selected index, so more than one
    /// speaker set can be active at once — which is what makes the guide's
    /// "hold down [command] and select another speaker set button" possible.
    /// `MaestroSpeakerSetAssignmentMask` is A=0x1, B=0x2, C=0x4
    /// (`mAEstro.h:581-587`); `kMaestroProperty_SpeakerSetSelection` ('AELD',
    /// `mAEstro.h:1127`) carries it whole (`SymphonyIO.cpp:3540-3548`); and
    /// `AnalogOutMutedForSpeakerSets` tests one bit per analog output PAIR —
    /// `mask & (0x01 << (channel / 2))` (`SymphonyIO.cpp:7316`) — so any subset
    /// of pairs can be unmuted together. On the wire it is one byte of `0xE9`
    /// (`SymphonyIOCommand.setActiveSpeakerSet`, masked to `& 0x07`).
    ///
    /// Defaults to set A, as the daemon does (`SymphonyIO.cpp:168`).
    @State private var speakerSetMask: UInt32 = SpeakerOutputLogic.defaultSpeakerSetMask
    // HP level/mute synced via AppState (shared with monitor panel)
    @State private var hp1Dim: Bool = false
    @State private var hp1Mono: Bool = false
    // Source IDs are output-pair indices 0-15 (see hpSourceOptions), so the first
    // analog pair is 0, not 1. The old default of 1 selected "Line 3-4".
    @State private var hp1Source: UInt32 = 0
    @State private var hp2Dim: Bool = false
    @State private var hp2Mono: Bool = false
    @State private var hp2Source: UInt32 = 0
    @State private var isMonitorLoading = true
    @State private var scrollPosition: ScrollPosition
    @State private var scrollRestorationPending = true
    @State private var scrollObservationEnabled = false
    @State private var scrollRestorationTarget: CGFloat?
    @State private var scrollRestorationGeneration = 0
    @AppStorage("rememberControlTabScrollPositions") private var rememberControlTabScrollPositions = true

    init(appState: AppState) {
        self.appState = appState
        let count = max(appState.cardLayout.analogOutputStripCount, 1)
        let restored: [OutputChannelState]? = appState.channelStateStore.load(ChannelStateStore.outputKey)
        if let restored, !restored.isEmpty {
            _channels = State(initialValue: restored.count >= count
                              ? Array(restored.prefix(count))
                              : restored + (restored.count..<count).map { _ in OutputChannelState() })
        } else {
            _channels = State(initialValue: (0..<count).map { _ in OutputChannelState() })
        }
        let offset = ControlTabScrollPreferences.remembers
            ? appState.controlTabScrollOffset(for: .output) : 0
        _scrollPosition = State(initialValue: ScrollPosition(x: offset))
    }

    /// Speaker output **mode** — not a source selector. The IDs are
    /// non-contiguous (0, 2, 6, 8, 9, 10 — `SymphonyIOVendorSpecific.h:967-975`,
    /// cross-checked against `eMainOutControls`, `mAEstro.h:540-546`), so this
    /// list always carries the ID beside the name and never a row index.
    ///
    /// Mode `0` is `eSymphonyIOSpeakerOutputMode_Off`, but Apogee's UI calls it
    /// **"Line"** (`SymphonyIO.cpp:3502`) — it hands monitoring to HP1 and
    /// disables the speaker knob (`SymphonyIO.cpp:6142-6168`), which is exactly
    /// what the guide describes under Line. Calling it "Off" made it look like a
    /// mute.
    ///
    /// Analog Out Format — the speaker modes this unit can actually drive, in
    /// Apogee's own order and under Apogee's own names.
    ///
    /// The rule and the names both come from the daemon rather than from the
    /// user guide's prose: see `SpeakerOutputLogic.availableModes`. Two things
    /// the old local version got wrong and the daemon rule fixes — it counted
    /// only module 1's outputs (the daemon counts the device's), and it offered
    /// "2 Speaker Sets" at four analog outputs, a tier the daemon does not have.
    private var speakerConfigLabels: [(UInt32, String)] {
        SpeakerOutputLogic.availableModes(
            analogOutputChannels: analogOutputStripCount,
            module1IsTwoBySix: layout.isKnown && layout.slot1 == .twoBySix
        ).map { ($0, SpeakerOutputLogic.name($0)) }
    }

    /// Whether the speaker level knob, Mute and Dim are live. Line mode turns
    /// outputs 1/2 into plain line outputs and takes the monitor functions with
    /// it (`SymphonyIO.cpp:7327-7333`; User's Guide p. 60).
    private var speakerControlsEnabled: Bool {
        SpeakerOutputLogic.speakerControlsEnabled(
            mode: speakerConfig, analogOutputChannels: analogOutputStripCount)
    }

    /// Sum to Mono is also dead in 5.1 and 7.1 (`SymphonyIO.cpp:7335-7344`).
    private var speakerSumEnabled: Bool {
        SpeakerOutputLogic.sumToMonoEnabled(
            mode: speakerConfig, analogOutputChannels: analogOutputStripCount)
    }

    /// The installed cards' layout — every count on this page comes from here.
    private var layout: CardLayout { appState.cardLayout }

    /// Headphone Output Source options, as **source IDs 0-15**.
    ///
    /// These are NOT the `kmAEstroHeadPhoneAssign*` constants from
    /// `mAEstro.h:437-448` — that is the Ensemble-family encoding, and the values
    /// above 15 that we used to offer (17, 23, 25 … 37) cannot even survive the
    /// `0x54` register, whose nibbles are 4 bits wide. "Optical 7-8" (17) was
    /// masked to 1, i.e. silently re-selected "Line 1-2".
    ///
    /// The Symphony MKI daemon builds its own list instead:
    /// `m_aHPSourceIDs[i] = boardIdx * 8 + startChannel/2 + i`
    /// (`SymphonyIO_Stream.cpp:264-276`), so board 0's output pairs are 0-7 and
    /// board 1's are 8-15, analog pairs before digital within each board. Names
    /// come from the stream that owns the ID — "Line N-M"
    /// (`SymphonyIO_Stream.cpp:485-495`) or "Optical N-M"
    /// (`OpticalOut_SymphonyIO_Stream.cpp:132-148`), numbered continuously across
    /// boards per plug type.
    private var hpSourceOptions: [(UInt32, String)] {
        layout.headphoneSources.map { ($0.id, $0.name) }
    }

    /// SPDIF Coax Mirrors — the output pairs each slot's module can mirror onto
    /// its coax output.
    ///
    /// `SymphonyIOBoardSPDIFCoaxReplace` (`SymphonyIOVendorSpecific.h:937-948`,
    /// shared by the `0x36` mirror command at `:204-216`) is eight pair indices
    /// within that board's own 16-channel slice plus `Off`; the `Analog…` /
    /// `Digital…` names are the 8x8 card's split, which is why the header itself
    /// notes they "dont make sense for certain boards". The old slot-2 list was
    /// both fixed to "Optical" labels and ran to ID 12, four values past the end
    /// of the enum.
    ///
    /// `Off` is filtered out: the coax output is always tapped from *some* pair
    /// (User's Guide p. 76), and legacy's mirror list is the replace list minus
    /// its Off entry — `SymphonyIO_IOBoard.cpp:1212-1214`, "doesn't includes OFF
    /// option". See `OutputChannelLogic.mirrorOptions`.
    private var spdifMirror1Options: [CardLayout.SPDIFOption] {
        OutputChannelLogic.mirrorOptions(layout.spdifOptions(slot: 0, isInput: false))
    }

    private var spdifMirror2Options: [CardLayout.SPDIFOption] {
        OutputChannelLogic.mirrorOptions(layout.spdifOptions(slot: 1, isInput: false))
    }

    /// Number of analog output strips to show — based on detected board types,
    /// falls back to USB channel count when boards aren't detected yet.
    ///
    /// `analogOutputPairsPerBoard` is the XLink bus slice, not the converter
    /// count: it reports 8 pairs for an 8MicPre (which has no converters) and so
    /// drew 32 output strips on a 16x16 + 8MicPre, and 16 analog output strips on
    /// an A16 IP + 8MicPre — a pair of cards with zero analog outputs between
    /// them. That is the legacy `SymphonyIO.cpp:975-978` bug this project is
    /// explicitly not copying (`Docs/issue-1-research.md`).
    private var analogOutputStripCount: Int { layout.analogOutputStripCount }

    /// Board-aware channel labels for analog output strips.
    private var outputChannelLabels: [String] {
        let count = analogOutputStripCount
        guard count > 0 else { return [] }
        return (1...count).map { "Line \($0)" }
    }

    /// Board-aware digital output stereo pairs (AES / ADAT meter strips).
    private var digitalOutputPairs: [CardLayout.DigitalPair] { layout.digitalOutputPairs }

    /// Whether to draw the DIGITAL column at all. Every module carries S/PDIF
    /// coax (user guide pp. 10-12), so the column — and the S/PDIF Mirrors popups
    /// in it — is not gated on the card having ADAT/AES pairs. A 16x16 has none.
    private var hasDigitalIO: Bool { layout.showsDigitalSection(isInput: false) }

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            // Toolbar row — Show/Hide Trims, Reset Trims
            HStack {
                // Both trim buttons are hidden only when no channel carries a
                // trim at all (a card pair with zero analog outputs, e.g. an
                // A16 IP). Legacy does exactly this — hides, never disables:
                // `APAnalogOutputSidebarViewController.m:86-88`.
                if analogOutputStripCount > 0 {
                    Button(appState.showOutputTrims ? "Hide Trims" : "Show Trims") {
                        appState.showOutputTrims.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show or hide the Trim faders on every analog output strip.")

                    // NOT gated on the faders being visible — legacy's Reset
                    // Trims works either way (`:120-129`).
                    Button("Reset Trims") {
                        showResetAlert = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reset Trims — sets every analog output trim to 0.0 dB "
                          + "and changes nothing else.")
                }

                // Two scopes, matching SymphonyIOResetRequestType. The default
                // offered first preserves trims — they are calibration data.
                Menu("Reset Defaults") {
                    Button("Reset Monitor Settings (keep trims)") {
                        pendingResetScope = .allButCalibration
                    }
                    Button("Reset Monitor Settings and Trims", role: .destructive) {
                        pendingResetScope = .all
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Restore speaker/headphone levels, mute, dim, sum and speaker mode "
                      + "to the factory defaults. Routing is not touched.")

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .alert("Reset All Output Trims?", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset All Trims", role: .destructive) {
                    // Only the strips that were not already at 0.0 need a write;
                    // the trim rides in byte[1] of the packed analog-IO-type
                    // command, so the reset re-sends that command.
                    let touched = OutputChannelLogic.resetTrims(&channels)
                    saveChannelStates()
                    for i in touched {
                        Task { await writeOutputProperty(i, .analogIOType,
                            value: .uint32(outputAnalogIOTypeWithTrim(i))) }
                    }
                }
            } message: {
                Text("All output trim values will be reset to 0.0 dB.")
            }
            .alert("Reset monitor settings?",
                   isPresented: Binding(get: { pendingResetScope != nil },
                                        set: { if !$0 { pendingResetScope = nil } })) {
                Button("Cancel", role: .cancel) { pendingResetScope = nil }
                Button("Reset", role: .destructive) {
                    let scope = pendingResetScope ?? .allButCalibration
                    pendingResetScope = nil
                    Task { await resetMonitorDefaults(scope: scope) }
                }
            } message: {
                Text(resetMonitorMessage)
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    // Analog output strips
                    ForEach(Array(0..<min(channels.count, analogOutputStripCount)), id: \.self) { i in
                        if i > 0 {
                            Divider()
                                .frame(height: nil)
                                .opacity(0.4)
                        }
                        OutputChannelStripView(
                            channel: $channels[i],
                            label: i < outputChannelLabels.count ? outputChannelLabels[i] : "Out \(i + 1)",
                            appState: appState,
                            meterIndex: i,
                            showTrims: appState.showOutputTrims,
                            onAnalogRefChange: { level in
                                applyAnalogRefChange(i, level: level)
                            },
                            onDigitalRefChange: { level in
                                applyDigitalRefChange(i, level: level)
                            },
                            onTrimChange: { _ in
                                saveChannelStates()
                                Task { await writeOutputProperty(i, .analogIOType,
                                    value: .uint32(outputAnalogIOTypeWithTrim(i))) }
                            },
                            showZoneColoring: appState.showMeterZoneColoring
                        )
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: AnalogStripHeightKey.self, value: geo.size.height)
                        })
                    }

                    // Speaker / HP section — inline after analog strips, no header
                    // Gate on !channels.isEmpty so monitor+digital don't flash before analog strips render.
                    if !channels.isEmpty {
                        Divider().opacity(0.4)

                        outputMonitorSection
                    }

                    // DIGITAL section — SPDIF Coax Mirrors + ADAT output pair meters
                    if hasDigitalIO && !channels.isEmpty {
                        Divider().opacity(0.4)

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

                            if layout.hasSPDIF(slot: 0) { spdifMirror1Dropdown }
                            if layout.hasSPDIF(slot: 1) { spdifMirror2Dropdown }
                        }
                        .frame(width: 110)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 5)
                        .frame(height: analogStripHeight > 0 ? analogStripHeight : nil, alignment: .top)

                        Divider().opacity(0.4)

                        // Digital output pair meters — board-aware count and
                        // labels. The meter arrays hold 4 metered pairs per board;
                        // an AD16 pair supplies 8 digital output pairs per board,
                        // so the index MUST be checked or the page traps on open.
                        let digOutPairs = digitalOutputPairs
                        ForEach(Array(digOutPairs.enumerated()), id: \.offset) { index, digPair in
                            if index > 0 {
                                Divider().opacity(0.4)
                            }
                            ADATStereoPairView(
                                label: digPair.label,
                                leftLevel: Self.meterLevel(appState.digitalOutputMeterLevels, digPair.meterIndex),
                                rightLevel: Self.meterLevel(appState.digitalOutputMeterLevels, digPair.meterIndex, offset: 1),
                                leftPeak: Self.meterLevel(appState.digitalOutputPeakHold, digPair.meterIndex),
                                rightPeak: Self.meterLevel(appState.digitalOutputPeakHold, digPair.meterIndex, offset: 1),
                                matchHeight: analogStripHeight > 0 ? analogStripHeight : nil,
                                showZoneColoring: appState.showMeterZoneColoring
                            )
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true) // dividers match strip height, not page height
                .frame(maxHeight: .infinity, alignment: .top) // fill page, content at top, scrollbar at bottom
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .onPreferenceChange(AnalogStripHeightKey.self) { analogStripHeight = $0 }
                .background {
                    ControlTabScrollObserver(
                        tab: "Output",
                        restorationOffset: appState.controlTabScrollOffset(for: .output)
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
                        appState.setControlTabScrollOffset(offset, for: .output)
                    } onDetachOffset: { offset in
                        guard rememberControlTabScrollPositions else { return }
                        appState.setControlTabScrollOffset(offset, for: .output)
                    }
                }
            }
            .scrollPosition($scrollPosition)
            .onChange(of: rememberControlTabScrollPositions) { _, enabled in
                if !enabled {
                    scrollRestorationTarget = nil
                    scrollPosition.scrollTo(x: 0)
                    appState.setControlTabScrollOffset(0, for: .output)
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
        .navigationTitle("Output")
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
            guard area != .output else { return }
            scrollRestorationGeneration += 1
            scrollObservationEnabled = false
            scrollRestorationPending = true
        }
        .task(id: appState.viewReloadToken) {
            initializeOutputChannels()
            await loadSPDIFMirrors()
            await loadMonitorState()
            restoreSessionScrollPosition()
        }
        // Board detection is async and lands AFTER the first `.task` — without
        // this the strip array keeps whatever count the pre-detection layout had.
        .onChange(of: appState.cardLayoutToken) { _, _ in
            scrollRestorationPending = true
            initializeOutputChannels()
            restoreSessionScrollPosition()
        }
    }

    private var resetMonitorMessage: String {
        if pendingResetScope == .all {
            return "Speaker and headphone levels return to -20 dB; mute, dim and sum turn off; speaker mode returns to Stereo; all output trims return to 0.0 dB. Routing is not changed."
        }
        return "Speaker and headphone levels return to -20 dB; mute, dim and sum turn off; speaker mode returns to Stereo. Trims and routing are not changed."
    }

    /// Reapply the session offset after asynchronous channel and monitor state
    /// loading has established the scroll content width.
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
        scrollRestorationTarget = appState.controlTabScrollOffset(for: .output) > 0
            ? appState.controlTabScrollOffset(for: .output) : nil
        scrollRestorationPending = false
        scrollObservationEnabled = true
    }

    // MARK: - Speaker / HP Inline Section

    @ViewBuilder
    private var outputMonitorSection: some View {
        @Bindable var state = appState
        VStack(spacing: 6) {
            // Speaker section
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    RotaryKnobView(
                        value: $state.speakerLevel,
                        range: -64...0,
                        step: 1,
                        label: "Speaker",
                        unit: "dB",
                        size: 32,
                        defaultValue: -20,
                        arcColor: appState.speakerMuted ? .red.opacity(0.4) : speakerDim ? .orange.opacity(0.6) : Color(red: 0.52, green: 0.69, blue: 0.98),
                        onUserChange: { level in
                            guard !isMonitorLoading else { return }
                            Task { await writeMonitorProperty(.outputLevel, value: .uint32(UInt32(max(0, -level)))) }
                            appState.writeASPVolume(level)
                        }
                    )
                    .help("Speaker Level — controls the speaker output level. In 2 or 3 "
                          + "Speaker Sets mode every active set is adjusted together. "
                          + "Drag to adjust, double-tap to reset.")
                    .disabled(!speakerControlsEnabled)
                    .opacity(speakerControlsEnabled ? 1 : 0.4)

                    // M / D / Σ, in the original's order and with the original's
                    // meanings: M is Mute, Σ is Sum to Mono. We used to label
                    // Sum to Mono "M", which reads as Mute and is what a public
                    // bug report called out. Art: `Mute_Medium_On.png` renders
                    // "M", `Dim_Medium_On.png` "D", `Sum_Medium_On.png` "Σ".
                    outputToggle("M", isOn: $state.speakerMuted, tint: .red,
                                 tooltip: "Mute — silences the speaker output.",
                                 enabled: speakerControlsEnabled) {
                        Task { await writeMonitorProperty(.outputMute, value: .bool(appState.speakerMuted)) }
                        appState.writeASPMute(appState.speakerMuted)
                    }
                    outputToggle("D", isOn: $speakerDim, tint: .orange,
                                 tooltip: Self.dimTooltip("speaker"),
                                 enabled: speakerControlsEnabled) {
                        Task { await writeMonitorProperty(.outputDim, value: .bool(speakerDim)) }
                    }
                    outputToggle("Σ", isOn: $speakerMono, tint: .purple,
                                 tooltip: Self.sumTooltip("speaker"),
                                 enabled: speakerSumEnabled) {
                        Task { await writeMonitorProperty(.outputSumToMono, value: .bool(speakerMono)) }
                    }
                }

                // Analog Out Format below the knob, Speaker Select pills inline
                // to its right — the original's arrangement.
                HStack(spacing: 3) {
                    PillMenu(
                        text: speakerConfigLabels.first(where: { $0.0 == speakerConfig })?.1
                            ?? speakerConfigLabels.first?.1 ?? "Line",
                        fontSize: 8,
                        pillHeight: 18,
                        toolTip: "Analog Out Format — how the analog outputs are configured. "
                               + "Line leaves outputs 1/2 as plain line outputs with level, "
                               + "Mute, Dim and Sum disabled; Stereo makes them speaker outputs; "
                               + "2 or 3 Speaker Sets pairs them up for the Speaker Select "
                               + "buttons; 5.1 and 7.1 need 6 and 8 analog outputs.",
                        options: speakerConfigLabels.map { val, name in
                            (name, {
                                let oldMode = speakerConfig
                                speakerConfig = val
                                appState.speakerOutputMode = val
                                guard SpeakerOutputLogic.modeChangeClearsMonitorState(from: oldMode,
                                                                                       to: val) else { return }
                                // Legacy clears these controls on every user
                                // mode transition before applying the new
                                // format. Keep the UI and both transports in
                                // the same state even when the hardware was
                                // previously muted or dimmed.
                                appState.speakerMuted = false
                                speakerDim = false
                                speakerMono = false
                                Task {
                                    await writeMonitorProperty(.outputMute, value: .bool(false))
                                    await writeMonitorProperty(.outputDim, value: .bool(false))
                                    await writeMonitorProperty(.outputSumToMono, value: .bool(false))
                                    await writeMonitorProperty(.speakerOutputMode, value: .uint32(val))
                                }
                            })
                        }
                    )
                    .frame(maxWidth: .infinity)

                    ForEach(0..<3, id: \.self) { index in
                        speakerSelectButton(index)
                    }
                }
            }

            Divider().opacity(0.3)

            // Headphone 1 section — level/mute via AppState for monitor panel sync
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    RotaryKnobView(
                        value: $state.hp1Level,
                        range: -127...0,
                        step: 1,
                        label: "Headphone 1",
                        unit: "dB",
                        size: 32,
                        defaultValue: -20,
                        arcColor: appState.hp1Muted ? .red.opacity(0.4) : Color(red: 0.52, green: 0.69, blue: 0.98),
                        onUserChange: { level in
                            guard !isMonitorLoading else { return }
                            Task { await writeMonitorProperty(.headphone1Level, value: .uint32(UInt32(max(0, -level)))) }
                        }
                    )
                    .help("Headphone Level — controls the output level of Headphone 1. "
                          + "Drag to adjust, double-tap to reset.")

                    outputToggle("M", isOn: $state.hp1Muted, tint: .red,
                                 tooltip: "Mute — silences Headphone 1.") {
                        Task { await writeMonitorProperty(.headphone1Mute, value: .bool(appState.hp1Muted)) }
                    }
                    outputToggle("D", isOn: $hp1Dim, tint: .orange,
                                 tooltip: Self.dimTooltip("Headphone 1")) {
                        Task { await writeMonitorProperty(.headphone1Dim, value: .bool(hp1Dim)) }
                    }
                    outputToggle("Σ", isOn: $hp1Mono, tint: .purple,
                                 tooltip: Self.sumTooltip("Headphone 1")) {
                        Task { await writeMonitorProperty(.headphone1SumToMono, value: .bool(hp1Mono)) }
                    }
                }

                // HP 1 routing dropdown below knob
                PillMenu(
                    text: hpSourceOptions.first(where: { $0.0 == hp1Source })?.1 ?? "Line 1-2",
                    fontSize: 8,
                    pillHeight: 18,
                    toolTip: "HP 1 Routing — selects the software outputs routed to "
                           + "Headphone Out 1.",
                    options: hpSourceOptions.map { val, name in
                        (name, {
                            hp1Source = val
                            Task { await selectHeadphoneSource(.headphone1, sourceID: val) }
                        })
                    }
                )
                .frame(maxWidth: .infinity)
            }

            Divider().opacity(0.3)

            // Headphone 2 section — level/mute via AppState for monitor panel sync
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    RotaryKnobView(
                        value: $state.hp2Level,
                        range: -127...0,
                        step: 1,
                        label: "Headphone 2",
                        unit: "dB",
                        size: 32,
                        defaultValue: -20,
                        arcColor: appState.hp2Muted ? .red.opacity(0.4) : Color(red: 0.52, green: 0.69, blue: 0.98),
                        onUserChange: { level in
                            guard !isMonitorLoading else { return }
                            Task { await writeMonitorProperty(.headphone2Level, value: .uint32(UInt32(max(0, -level)))) }
                        }
                    )
                    .help("Headphone Level — controls the output level of Headphone 2. "
                          + "Drag to adjust, double-tap to reset.")

                    outputToggle("M", isOn: $state.hp2Muted, tint: .red,
                                 tooltip: "Mute — silences Headphone 2.") {
                        Task { await writeMonitorProperty(.headphone2Mute, value: .bool(appState.hp2Muted)) }
                    }
                    outputToggle("D", isOn: $hp2Dim, tint: .orange,
                                 tooltip: Self.dimTooltip("Headphone 2")) {
                        Task { await writeMonitorProperty(.headphone2Dim, value: .bool(hp2Dim)) }
                    }
                    outputToggle("Σ", isOn: $hp2Mono, tint: .purple,
                                 tooltip: Self.sumTooltip("Headphone 2")) {
                        Task { await writeMonitorProperty(.headphone2SumToMono, value: .bool(hp2Mono)) }
                    }
                }

                // HP 2 routing dropdown below knob
                PillMenu(
                    text: hpSourceOptions.first(where: { $0.0 == hp2Source })?.1 ?? "Line 1-2",
                    fontSize: 8,
                    pillHeight: 18,
                    toolTip: "HP 2 Routing — selects the software outputs routed to "
                           + "Headphone Out 2.",
                    options: hpSourceOptions.map { val, name in
                        (name, {
                            hp2Source = val
                            Task { await selectHeadphoneSource(.headphone2, sourceID: val) }
                        })
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: analogStripHeight > 0 ? analogStripHeight : nil, alignment: .top)
    }

    /// Meter level at `index + offset`, or silence when the payload has no word
    /// for that pair. The digital meter arrays are fixed at 24 entries.
    private static func meterLevel(_ levels: [Double], _ index: Int?, offset: Int = 0) -> Double {
        guard let index, index + offset < levels.count else { return -60 }
        return levels[index + offset]
    }

    // MARK: - SPDIF Mirror Dropdowns

    /// Apogee's own description of the control, condensed (User's Guide p. 57
    /// item 8 and p. 76 "S/PDIF Coax Output").
    private static func spdifMirrorTooltip(slotLabel: String) -> String {
        "S/PDIF Coax Mirrors — the coax output is tapped from one of \(slotLabel)'s "
        + "analog or digital output pairs and transmits it in parallel. Choose which "
        + "pair is duplicated. The pair keeps feeding its own outputs as well."
    }

    /// Name to show for a stored mirror ID, falling back to the card's first
    /// pair when the stored value is not one this card offers (card swap, or a
    /// device that never answered the read).
    private static func mirrorName(_ id: UInt32,
                                   in options: [CardLayout.SPDIFOption]) -> String {
        guard let resolved = OutputChannelLogic.resolvedMirrorID(id, options: options),
              let option = options.first(where: { $0.id == resolved }) else { return "—" }
        return option.name
    }

    @ViewBuilder
    private var spdifMirror1Dropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SPDIF Coax\n1-2 Mirrors")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            PillMenu(
                text: Self.mirrorName(spdifMirror1, in: spdifMirror1Options),
                fontSize: 9,
                pillHeight: 20,
                toolTip: Self.spdifMirrorTooltip(slotLabel: "Module 1"),
                options: spdifMirror1Options.map { [appState] option in
                    let optVal = option.id
                    return (option.name, {
                        spdifMirror1 = optVal
                        Task {
                            guard let device = appState.device else { return }
                            do {
                                try await device.setProperty(
                                    PropertyAddress(selector: .spdifMirrorID, scope: .output),
                                    value: .uint32(optVal)
                                )
                            } catch {
                                print("[Maestro] SPDIF Mirror 1-2 write failed: \(error)")
                            }
                        }
                    })
                }
            )
            .frame(width: 100)
        }
    }

    @ViewBuilder
    private var spdifMirror2Dropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SPDIF Coax\n3-4 Mirrors")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            PillMenu(
                text: Self.mirrorName(spdifMirror2, in: spdifMirror2Options),
                fontSize: 9,
                pillHeight: 20,
                toolTip: Self.spdifMirrorTooltip(slotLabel: "Module 2"),
                options: spdifMirror2Options.map { [appState] option in
                    let optVal = option.id
                    return (option.name, {
                        spdifMirror2 = optVal
                        Task {
                            guard let device = appState.device else { return }
                            do {
                                try await device.setProperty(
                                    PropertyAddress(selector: .spdifMirror2ID, scope: .output),
                                    value: .uint32(optVal)
                                )
                            } catch {
                                print("[Maestro] SPDIF Mirror 3-4 write failed: \(error)")
                            }
                        }
                    })
                }
            )
            .frame(width: 100)
        }
    }

    // MARK: - Toggle/Button Helpers

    /// The dim depth is fixed in firmware — `cstSymphonyIODimLevelOffsetDb 15`
    /// (`SymphonyIOGeneral.h:20`, applied at `SymphonyIOMainController.cpp:1513`)
    /// — and the User's Guide quotes the same number (p. 58, item 5). It is not
    /// adjustable and not guessable, so the tooltip says it.
    private static func dimTooltip(_ target: String) -> String {
        "Dim — lowers the \(target) output level by 15 dB, for talking over the "
        + "playback without muting it."
    }

    private static func sumTooltip(_ target: String) -> String {
        "Sum to Mono — combines the left and right channels of the \(target) "
        + "output to mono, to check the mono compatibility of a stereo signal."
    }

    /// Speaker Select — pill 1/2/3 for speaker sets A/B/C.
    ///
    /// Live only in 2 and 3 Speaker Sets mode (`SymphonyIO.cpp:3516-3533`).
    /// A plain click selects that set alone; Command-click adds or removes it,
    /// and the last set cannot be switched off
    /// (`APSpeakerOutputViewController.m:738-760`).
    @ViewBuilder
    private func speakerSelectButton(_ index: Int) -> some View {
        let enabled = index < SpeakerOutputLogic.speakerSetCount(mode: speakerConfig)
        let isOn = SpeakerOutputLogic.speakerSetIsOn(
            index: index, mask: speakerSetMask, mode: speakerConfig)
        Button {
            let extending = NSEvent.modifierFlags.contains(.command)
                || (NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
            let next = SpeakerOutputLogic.speakerSetMask(
                clicking: index, current: speakerSetMask, extending: extending)
            guard next != speakerSetMask else { return }
            speakerSetMask = next
            Task { await writeMonitorProperty(.activeSpeakerSet, value: .uint32(next)) }
        } label: {
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .medium))
                .frame(width: 16, height: 18)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Color.green.opacity(0.25) : Color.gray.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.green : .secondary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help("Speaker Select \(index + 1) — switches monitoring to speaker set "
              + "\(index + 1). Available in 2 and 3 Speaker Sets mode; "
              + "Command-click to engage more than one set.")
    }

    @ViewBuilder
    private func outputToggle(_ label: String, altIcon: String? = nil, isOn: Binding<Bool>, tint: Color, tooltip: String = "", enabled: Bool = true, action: @escaping () -> Void) -> some View {
        let isSymbol = label.contains(".")
        Button {
            isOn.wrappedValue.toggle()
            action()
        } label: {
            if isSymbol {
                Image(systemName: isOn.wrappedValue ? label : (altIcon ?? label))
                    .font(.system(size: 11))
                    .frame(width: 24, height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isOn.wrappedValue ? tint.opacity(0.25) : Color.gray.opacity(0.15)))
            } else {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .frame(minWidth: 28, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isOn.wrappedValue ? tint.opacity(0.25) : Color.gray.opacity(0.15)))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn.wrappedValue ? tint : .secondary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(tooltip)
    }

    // MARK: - Data Loading

    private func initializeOutputChannels() {
        let n = max(analogOutputStripCount, 1)
        // Keyed by the installed card pair — see `ChannelStateStore`.
        if let saved: [OutputChannelState] = appState.channelStateStore.load(ChannelStateStore.outputKey),
           !saved.isEmpty {
            if saved.count >= n {
                channels = Array(saved.prefix(n))
            } else {
                channels = saved + (saved.count..<n).map { _ in OutputChannelState() }
            }
            print("[Maestro] initializeOutputChannels: restored \(channels.count) channel states from UserDefaults (\(analogOutputStripCount) strips)")
        } else {
            channels = (0..<n).map { _ in OutputChannelState() }
            print("[Maestro] initializeOutputChannels: no saved state — using defaults (\(analogOutputStripCount) strips)")
        }
    }

    private func saveChannelStates() {
        appState.channelStateStore.save(channels, for: ChannelStateStore.outputKey)
    }

    private func loadSPDIFMirrors() async {
        guard let device = appState.device else { return }
        do {
            let val = try await device.getProperty(PropertyAddress(selector: .spdifMirrorID))
            if let u = val.asUInt32 { spdifMirror1 = u }
        } catch {
            print("[Maestro] loadSPDIFMirrors mirror1: \(error)")
        }
        do {
            let val = try await device.getProperty(PropertyAddress(selector: .spdifMirror2ID))
            if let u = val.asUInt32 { spdifMirror2 = u }
        } catch {
            print("[Maestro] loadSPDIFMirrors mirror2: \(error)")
        }
    }

    private func loadMonitorState() async {
        defer { isMonitorLoading = false }
        guard appState.device != nil else { return }
        let deadline = Date().addingTimeInterval(30)
        while !appState.isHardwareInitialized {
            if Date() > deadline { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        do {
            if let attenuation = (try await appState.device?.getProperty(PropertyAddress(selector: .outputLevel)))?.asUInt32 {
                appState.speakerLevel = -Double(attenuation)
            }
        } catch { print("[Maestro] ERROR: output loadMonitorState outputLevel: \(error)") }
        do {
            if let mute = (try await appState.device?.getProperty(PropertyAddress(selector: .outputMute)))?.asBool {
                appState.speakerMuted = mute
            }
        } catch { print("[Maestro] ERROR: output loadMonitorState outputMute: \(error)") }
        do {
            if let dim = (try await appState.device?.getProperty(PropertyAddress(selector: .outputDim)))?.asBool {
                speakerDim = dim
            }
        } catch DeviceConnectionError.unsupportedProperty(_) {
            // Optional on some Symphony/ThunderBridge configurations.
        } catch { print("[Maestro] ERROR: output loadMonitorState outputDim: \(error)") }
        do {
            if let mono = (try await appState.device?.getProperty(PropertyAddress(selector: .outputSumToMono)))?.asBool {
                speakerMono = mono
            }
        } catch DeviceConnectionError.unsupportedProperty(_) {
            // Optional on some Symphony/ThunderBridge configurations.
        } catch { print("[Maestro] ERROR: output loadMonitorState outputSumToMono: \(error)") }
        do {
            if let mode = (try await appState.device?.getProperty(PropertyAddress(selector: .speakerOutputMode)))?.asUInt32 {
                speakerConfig = mode
                appState.speakerOutputMode = mode
            }
        } catch { /* speakerOutputMode may not be supported on MKI */ }
        do {
            // Speaker Select mask (0xE9). `SymphonyIO::init` reads it the same
            // way before it trusts its own copy (`SymphonyIO.cpp:1334-1339`).
            // A zero mask is never legal, so it is treated as "no answer".
            if let mask = (try await appState.device?.getProperty(
                PropertyAddress(selector: .activeSpeakerSet)))?.asUInt32, mask & 0x7 != 0 {
                speakerSetMask = mask & 0x7
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { /* not on every unit */ }
        do {
            if let att = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone1Level)))?.asUInt32 {
                appState.hp1Level = -Double(att)
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { print("[Maestro] ERROR: output loadMonitorState HP1 level: \(error)") }
        do {
            if let mute = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone1Mute)))?.asBool {
                appState.hp1Muted = mute
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { print("[Maestro] ERROR: output loadMonitorState HP1 mute: \(error)") }
        do {
            if let dim = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone1Dim)))?.asBool {
                hp1Dim = dim
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { /* HP dim may not be supported */ }
        do {
            if let mono = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone1SumToMono)))?.asBool {
                hp1Mono = mono
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { /* HP mono may not be supported */ }
        do {
            if let att = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone2Level)))?.asUInt32 {
                appState.hp2Level = -Double(att)
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { print("[Maestro] ERROR: output loadMonitorState HP2 level: \(error)") }
        do {
            if let mute = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone2Mute)))?.asBool {
                appState.hp2Muted = mute
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { print("[Maestro] ERROR: output loadMonitorState HP2 mute: \(error)") }
        do {
            if let dim = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone2Dim)))?.asBool {
                hp2Dim = dim
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { /* HP dim may not be supported */ }
        do {
            if let mono = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone2SumToMono)))?.asBool {
                hp2Mono = mono
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { /* HP mono may not be supported */ }
        do {
            if let routing = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone1RoutingID)))?.asUInt32 {
                hp1Source = routing
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { print("[Maestro] ERROR: output loadMonitorState HP1 routing: \(error)") }
        do {
            if let routing = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone2RoutingID)))?.asUInt32 {
                hp2Source = routing
            }
        } catch DeviceConnectionError.unsupportedProperty(_) { } catch { print("[Maestro] ERROR: output loadMonitorState HP2 routing: \(error)") }
    }

    // MARK: - Reference Level Changes (with option-click fan-out)

    /// Legacy's `[APUtilities optionKeyIsDown]` (`APUtilities.m:69-72`).
    ///
    /// `NSApp.currentEvent` is the menu's mouse-up by the time a `PillMenu`
    /// action fires, so the live hardware modifier state is consulted as well.
    /// Same pair of reads the Input page uses.
    private static var optionKeyIsDown: Bool {
        NSEvent.modifierFlags.contains(.option)
            || (NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    /// Analog Ref change. Option-click applies it to every other analog output.
    /// Evidence: `APOutputTabRowViewController.m:230-243`.
    ///
    /// The trim byte rides in byte[1] of the packed analog-IO-type command, so
    /// every affected channel re-sends that one command and nothing else.
    private func applyAnalogRefChange(_ index: Int, level: UInt32) {
        guard channels.indices.contains(index),
              OutputChannelLogic.offersAnalogRef(level) else { return }
        OutputChannelLogic.applyAnalogRefChange(&channels, channel: index, to: level)
        Task { await writeOutputProperty(index, .analogIOType,
                                         value: .uint32(outputAnalogIOTypeWithTrim(index))) }

        if Self.optionKeyIsDown {
            for i in OutputChannelLogic.applyAnalogRefToAll(&channels, to: level, excluding: index) {
                let packed = outputAnalogIOTypeWithTrim(i)
                Task { await writeOutputProperty(i, .analogIOType, value: .uint32(packed)) }
            }
        }
        saveChannelStates()
    }

    /// Digital Ref change. Option-click applies it to every other analog output.
    /// Evidence: `APOutputTabRowViewController.m:245-253`.
    ///
    /// Selecting -20 dBFS shrinks the trim range to 0…-2 dB (User's Guide p. 74,
    /// step 6), so a positive trim is clamped and its packed analog-IO-type
    /// command re-sent alongside the digital-reference command.
    private func applyDigitalRefChange(_ index: Int, level: UInt32) {
        let trimClamped = OutputChannelLogic.applyDigitalRefChange(
            &channels, channel: index, to: level)
        Task { await writeOutputProperty(index, .digitalRefLevel, value: .uint32(level)) }
        if trimClamped {
            Task { await writeOutputProperty(index, .analogIOType,
                                             value: .uint32(outputAnalogIOTypeWithTrim(index))) }
        }

        if Self.optionKeyIsDown {
            for change in OutputChannelLogic.applyDigitalRefToAll(
                &channels, to: level, excluding: index) {
                let i = change.index
                let packed = outputAnalogIOTypeWithTrim(i)
                let alsoTrim = change.trimChanged
                Task {
                    await writeOutputProperty(i, .digitalRefLevel, value: .uint32(level))
                    if alsoTrim {
                        await writeOutputProperty(i, .analogIOType, value: .uint32(packed))
                    }
                }
            }
        }
        saveChannelStates()
    }

    // MARK: - Property Writes

    private func writeOutputProperty(_ index: Int, _ selector: AudioPropertySelector, value: PropertyValue) async {
        guard let device = appState.device else { return }
        do {
            let element = UInt32(index)
            try await device.setProperty(
                PropertyAddress(selector: selector, scope: .output, element: element),
                value: value
            )
        } catch {
            print("[Maestro] Output channel write \(selector) ch\(index) failed: \(error)")
        }
    }

    /// Encode output analog ref type + trim into a single UInt32 for the USB command.
    /// Format: bits[7:0] = type, bits[15:8] = trim (Int8 tenths-of-dB as UInt8 bit pattern).
    private func outputAnalogIOTypeWithTrim(_ index: Int) -> UInt32 {
        guard index < channels.count else { return 1 }
        let type = channels[index].analogRefLevel
        let trimTenths = Int8(clamping: Int(channels[index].trim * 10))
        let trimByte = UInt32(UInt8(bitPattern: trimTenths))
        return (trimByte << 8) | type
    }

    private func writeMonitorProperty(_ selector: AudioPropertySelector, value: PropertyValue) async {
        do {
            try await appState.device?.setProperty(PropertyAddress(selector: selector), value: value)
        } catch {
            print("[Maestro] ERROR: writeMonitorProperty \(selector) failed: \(error)")
        }
    }

    /// Select a headphone Output Source — **both** halves of the operation.
    ///
    /// Step 1 stores the choice in `0x54`, which the vendor header describes as
    /// "opaque for the firmware … store/recall" and which changes nothing audible
    /// on its own. Step 2 is legacy's `RouteHeadphones()`: the `0x31` crosspoint
    /// write to destinations 224/225 or 226/227, sourced from whatever Output
    /// Routing currently feeds the selected pair. Doing only step 1 is the
    /// "headphone Output Source does nothing" report.
    ///
    /// ADAT-safe: step 2 writes only destinations 224-227.
    private func selectHeadphoneSource(
        _ headphone: SymphonyIOHeadphoneRouting.Headphone,
        sourceID: UInt32
    ) async {
        let selector: AudioPropertySelector =
            headphone == .headphone1 ? .headphone1RoutingID : .headphone2RoutingID
        await writeMonitorProperty(selector, value: .uint32(sourceID))
        guard let device = appState.device else { return }
        // The crosspoint source is inherited from the app's own output-routing
        // knowledge, never from a 0x31 readback (that returns residue, 0x20 for
        // every destination — Docs/issue-1-research.md).
        await HeadphoneCrosspoint.apply(headphone, sourceID: sourceID, device: device,
                                        cachedRoutes: appState.cachedOutputRouteMap(),
                                        transport: appState.transportType ?? .usb)
    }

    /// Restore the monitor section to the daemon's defaults.
    ///
    /// Values from `SymphonyIO::ResetToDefaults` (`SymphonyIO.cpp:1570-1637`):
    /// 20 dB attenuation on speaker and both headphones, mute/dim/sum all off,
    /// speaker mode Stereo when the unit has at least two analog outputs (else
    /// Off), and peak/over hold Off in USB Audio boot mode.
    ///
    /// `scope` follows `SymphonyIOResetRequestType`: trims are calibration data
    /// and survive `.allButCalibration`, which is the default the UI offers first.
    ///
    /// **Routing is deliberately not touched here.** Legacy only resets routing
    /// when the reset is explicitly user-initiated *and* goes through the routing
    /// controller (`SymphonyIO.cpp:1626-1634`); on this unit that would rewrite
    /// the ADAT output crosspoints. Reset Routing lives on the routing pages.
    private func resetMonitorDefaults(scope: SymphonyIOResetScope) async {
        let attenuation = UInt32(SymphonyIOMonitorDefaults.levelAttenuationDB)
        let level = -Double(SymphonyIOMonitorDefaults.levelAttenuationDB)

        appState.speakerLevel = level
        appState.hp1Level = level
        appState.hp2Level = level
        appState.speakerMuted = SymphonyIOMonitorDefaults.muted
        appState.hp1Muted = SymphonyIOMonitorDefaults.muted
        appState.hp2Muted = SymphonyIOMonitorDefaults.muted
        speakerDim = SymphonyIOMonitorDefaults.dimmed
        hp1Dim = SymphonyIOMonitorDefaults.dimmed
        hp2Dim = SymphonyIOMonitorDefaults.dimmed
        speakerMono = SymphonyIOMonitorDefaults.summedToMono
        hp1Mono = SymphonyIOMonitorDefaults.summedToMono
        hp2Mono = SymphonyIOMonitorDefaults.summedToMono

        await writeMonitorProperty(.outputLevel, value: .uint32(attenuation))
        await writeMonitorProperty(.headphone1Level, value: .uint32(attenuation))
        await writeMonitorProperty(.headphone2Level, value: .uint32(attenuation))
        appState.writeASPVolume(level)

        for (selector, flag) in [
            (AudioPropertySelector.outputMute, SymphonyIOMonitorDefaults.muted),
            (.headphone1Mute, SymphonyIOMonitorDefaults.muted),
            (.headphone2Mute, SymphonyIOMonitorDefaults.muted),
            (.outputDim, SymphonyIOMonitorDefaults.dimmed),
            (.headphone1Dim, SymphonyIOMonitorDefaults.dimmed),
            (.headphone2Dim, SymphonyIOMonitorDefaults.dimmed),
            (.outputSumToMono, SymphonyIOMonitorDefaults.summedToMono),
            (.headphone1SumToMono, SymphonyIOMonitorDefaults.summedToMono),
            (.headphone2SumToMono, SymphonyIOMonitorDefaults.summedToMono)
        ] {
            await writeMonitorProperty(selector, value: .bool(flag))
        }
        appState.writeASPMute(SymphonyIOMonitorDefaults.muted)

        // Speaker mode from board types, but ONLY when those types were actually
        // measured. Unprovenanced boards read as .none, which yields 0 analog
        // outs and therefore mode Off -- and Off hands monitoring to Headphone 1
        // and greys out the speaker knob, while the confirmation text promises
        // "returns to Stereo". Defaulting to Stereo on unknown provenance keeps
        // the dialog honest and matches what the proxy writes at every boot.
        let boardsMeasured = appState.primaryBoardSource == .detected
                          && appState.secondaryBoardSource == .detected
        let mode: SymphonyIOSpeakerMode
        if boardsMeasured {
            let analogOuts = appState.primaryBoardType.analogOutputChannels
                           + appState.secondaryBoardType.analogOutputChannels
            mode = SymphonyIOMonitorDefaults.speakerMode(analogOutputChannels: analogOuts)
        } else {
            mode = .stereo
        }
        speakerConfig = UInt32(mode.rawValue)
        appState.speakerOutputMode = UInt32(mode.rawValue)
        await writeMonitorProperty(.speakerOutputMode, value: .uint32(UInt32(mode.rawValue)))

        await writeMonitorProperty(.peakHoldMode,
                                   value: .uint32(UInt32(SymphonyIOMonitorDefaults.peakHoldMode)))
        await writeMonitorProperty(.oversHoldMode,
                                   value: .uint32(UInt32(SymphonyIOMonitorDefaults.oversHoldMode)))

        if scope.resetsTrims {
            for i in 0..<channels.count { channels[i].trim = 0 }
            saveChannelStates()
            for i in 0..<channels.count {
                await writeOutputProperty(i, .analogIOType,
                                          value: .uint32(outputAnalogIOTypeWithTrim(i)))
            }
        }
        print("[Maestro] Monitor reset to defaults (scope: \(scope), trims \(scope.resetsTrims ? "cleared" : "preserved"))")
    }
}

/// A single output channel strip matching the InputChannelStripView layout:
/// Label pill → Analog Ref Level → Digital Ref Level → Spacer → Meter + optional Trim → Readouts.
///
/// Evidence: `SymphonyIOVendorSpecific.h` — SymphonyIOAnalogIOType, SymphonyIODigitalReferenceLevel
struct OutputChannelStripView: View {
    @Binding var channel: OutputChannelState
    let label: String
    /// Keep 20 Hz meter observation inside each strip. Reading these arrays in
    /// OutputView would invalidate the entire horizontal rack on every sample.
    var appState: AppState? = nil
    var meterIndex: Int? = nil
    var meterLevel: Double = -60
    var meterPeakHold: Double = -60
    var showTrims: Bool = false
    var onAnalogRefChange: ((UInt32) -> Void)?
    var onDigitalRefChange: ((UInt32) -> Void)?
    var onTrimChange: ((Double) -> Void)?
    var showZoneColoring: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedMeterLevel: Double {
        guard let appState, let meterIndex else { return meterLevel }
        return meterIndex < appState.outputMeterLevels.count ? appState.outputMeterLevels[meterIndex] : -60
    }

    private var resolvedMeterPeakHold: Double {
        guard let appState, let meterIndex else { return meterPeakHold }
        return meterIndex < appState.outputPeakHold.count ? appState.outputPeakHold[meterIndex] : -60
    }

    /// Output analog ref: no Variable option (input-only).
    private let analogRefLabels: [(UInt32, String)] = [
        (OutputChannelLogic.plus4dBu, "+4 dBu"),
        (OutputChannelLogic.minus10dBV, "-10 dBV")
    ]

    /// Digital ref level options (same as input).
    private let digitalRefLabels: [(UInt32, String)] = [
        (0, "-20 dBfs"), (1, "-18 dBfs"), (2, "-16 dBfs"),
        (3, "-14 dBfs"), (4, "-12 dBfs"), (5, "-10 dBfs")
    ]

    /// Trim fader range for this strip. The ceiling drops to 0.0 dB at -20 dBFS
    /// digital reference — see `OutputChannelLogic.trimRange`.
    private var trimSpec: (range: ClosedRange<Double>, step: Double) {
        OutputChannelLogic.trimRange(digitalRefLevel: channel.digitalRefLevel)
    }

    /// "+2.0 … -2.0 dB" / "0.0 … -2.0 dB", written the way the user guide does
    /// (p. 74, step 6: "only a negative Trim value is possible (0dB to -2 dB)").
    private static func rangeText(_ range: ClosedRange<Double>) -> String {
        String(format: "%.1f to %.1f dB", range.upperBound, range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 3) {
            // Channel label pill
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
                .help("\(label) — analog output, D/A conversion channel")

            // Stacked PillMenu dropdowns
            VStack(spacing: 3) {
                // Analog reference level
                if let onAnalogRefChange {
                    PillMenu(
                        text: analogRefLabels.first(where: { $0.0 == channel.analogRefLevel })?.1 ?? "+4 dBu",
                        toolTip: "Analog Ref Level — the analog reference for this D/A channel. "
                               + "+4 dBu for 'pro' gear; -10 dBV for semi-pro, hi-fi or musical "
                               + "instrument gear. Option-click to set every channel at once.",
                        options: analogRefLabels.map { val, name in
                            // The parent owns the mutation so the option-click
                            // fan-out and the trim clamp see one consistent array.
                            (name, { onAnalogRefChange(val) })
                        }
                    )
                }

                // Digital reference level
                PillMenu(
                    text: digitalRefLabels.first(where: { $0.0 == channel.digitalRefLevel })?.1 ?? "-16 dBfs",
                    toolTip: "Digital Ref Level — the digital reference for this D/A channel; "
                           + "a lower setting leaves more headroom. At -20 dBfs the Trim range "
                           + "shrinks to 0 … -2 dB. Option-click to set every channel at once.",
                    options: digitalRefLabels.map { val, name in
                        (name, { onDigitalRefChange?(val) })
                    }
                )
            }

            // Constant breathing room (same as input — prevents vertical shift on trim toggle)
            Spacer().frame(height: 16)

            // Meter + optional trim fader
            HStack(alignment: .top, spacing: 1) {
                if showTrims {
                    FaderView(
                        value: $channel.trim,
                        range: trimSpec.range,
                        step: trimSpec.step,
                        defaultValue: 0,
                        height: 200,
                        showScale: true,
                        externalReadout: true,
                        thumbHeight: 20,
                        thumbWidth: 18
                    )
                    .transition(.opacity)
                    .help("Trim Fader — trims the D/A conversion level in 0.1 dB steps "
                          + "(\(Self.rangeText(trimSpec.range))). The D/A meter shows the "
                          + "signal BEFORE conversion, so calibrate against an external "
                          + "voltmeter on the analog output, not against the meter.")
                    .onChange(of: channel.trim) { _, newTrim in
                        onTrimChange?(newTrim)
                    }
                }

                // Scale always on left side of meter
                LEDMeterView(
                    level: resolvedMeterLevel,
                    peak: resolvedMeterPeakHold,
                    label: "",
                    height: 200,
                    width: showTrims ? 10 : 14,
                    showScale: true,
                    scaleOnLeft: true,
                    rangeDB: 48,
                    showZoneColoring: showZoneColoring
                )
                .help("D/A Meter — the level of this output BEFORE D/A conversion, "
                      + "-48 to 0 dBfs. It does not show the analog output level.")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(x: showTrims ? 0 : -8) // center the group visually within the strip
            .animation(.easeInOut(duration: 0.15), value: showTrims)

            // Pill-styled readouts below meter — only when trims visible
            if showTrims {
                HStack(spacing: 3) {
                    Text(String(format: "%.1f", channel.trim))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                        .help("Trim: \(String(format: "%.1f", channel.trim)) dB "
                              + "(range \(Self.rangeText(trimSpec.range)), 0.1 dB steps)")
                    Text(String(format: "%.0f", resolvedMeterLevel))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                        .help("Meter Level Readout: \(String(format: "%.1f", resolvedMeterLevel)) dBfs. "
                              + "This reading is pre-Trim, so moving the Trim fader does not "
                              + "change it — calibrate with an external voltmeter.")
                }
                .offset(x: 0)
                .padding(.top, 4)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: showTrims)
            }
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
}
