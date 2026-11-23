import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice

/// Shared logical height for the link/Unity/output control rows.
private let mixerControlRowHeight: CGFloat = 22
private let mixerReadoutGapHeight: CGFloat = 14

/// Every strip must reserve the same vertical fader/meter row. Stereo meters
/// include their L/R label baseline, so without this shared frame their
/// subsequent controls start lower than the mono strips.
private let mixerFaderMeterRowHeight: CGFloat = 220


/// Low-Latency Mixer view — Mix 1 & Mix 2 with channel faders, pan, mute, solo, master.
/// Includes channel naming and channel visibility. Layout matches Input/Output tabs.
///
/// Evidence: `og_source/maestro2/App/Controllers/Mixer/`
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
struct MixerView: View {
    private let appState: AppState
    @State private var selectedMixer: Int = 0
    /// Restored together before the first body evaluation; tied to a physical scope.
    @State private var editor: MixerEditorState
    @State private var errorMessage: String?
    @State private var showMixerResetAlert = false
    /// SwiftUI reports the newly-created scroll view's initial zero offset
    /// before the saved session offset is restored. Ignore that one callback
    /// so it cannot overwrite the session position.
    @State private var scrollRestorationPending = true
    @State private var scrollObservationEnabled = false
    @State private var scrollRestorationTarget: CGFloat?
    @State private var scrollRestorationGeneration = 0
    /// AppKit's field editor does not resign when a SwiftUI sibling is clicked.
    /// Keep a view-scoped monitor so mixer labels behave like native controls.
    @State private var outsideClickMonitor: Any?
    @State private var keyboardMonitor: Any?
    @State private var scrollPosition: ScrollPosition
    @AppStorage("rememberControlTabScrollPositions") private var rememberControlTabScrollPositions = true
    /// The fader level readout being typed into, if any — one at a time.
    @State private var editingReadout: MixerLevelReadout?
    /// Keyboard focus among the fader level readouts; Tab moves it along the strips.
    @FocusState private var focusedReadout: MixerLevelReadout?
    /// Keyboard focus among the editable pan readouts.
    @State private var editingPanReadout: MixerPanReadout?
    @FocusState private var focusedPanReadout: MixerPanReadout?

    /// What a strip's level readout needs to take part in Tab order: inputs
    /// that are showing, then Software Return, then Master.
    private func readoutEntry(_ id: MixerLevelReadout) -> LevelReadoutEntry<MixerLevelReadout> {
        LevelReadoutEntry(id: id, editing: $editingReadout, focus: $focusedReadout) { current, forward in
            let inputs = (0..<min(editor.channels.count, channelCount)).filter { isChannelVisible($0) }
            return LevelEntry.neighbour(of: current, in: MixerLevelReadout.order(visibleInputs: inputs),
                                        forward: forward) { _ in true }
        }
    }

    private func panReadoutEntry(_ id: MixerPanReadout) -> LevelReadoutEntry<MixerPanReadout> {
        LevelReadoutEntry(id: id, editing: $editingPanReadout, focus: $focusedPanReadout) { current, forward in
            let inputs = (0..<min(editor.channels.count, channelCount)).filter { isChannelVisible($0) }
            return LevelEntry.neighbour(of: current, in: MixerPanReadout.order(visibleInputs: inputs),
                                        forward: forward) { _ in true }
        }
    }

    init(appState: AppState) {
        self.appState = appState
        let mixer = appState.lastSelectedMixer == 1 ? 1 : 0
        _selectedMixer = State(initialValue: mixer)
        if appState.unitBKnownAbsent { appState.resetSoftwareReturnSourcesBeyondOneUnit() }
        _editor = State(initialValue: MixerEditorState(appState: appState, selectedMixer: mixer))
        let offset = ControlTabScrollPreferences.remembers
            ? appState.controlTabScrollOffset(for: .mixer) : 0
        _scrollPosition = State(initialValue: ScrollPosition(x: offset))
    }

    // MARK: - Channel Selection & Batch Operations
    @State private var selectedChannels: Set<Int> = []
    @State private var lastSelectedChannel: Int? = nil
    /// Snapshot of fader levels at batch drag start — preserves relative levels during Option+Drag.
    @State private var batchDragStartLevels: [Int: Double] = [:]
    /// Snapshot of pan values at batch drag start.
    @State private var batchDragStartPans: [Int: Double] = [:]

    // Mixer writes are rate-limited as the original's were: at most 50 a
    // second for each control (ApogeeDispatchQueue.cpp:18,
    // MAX_PROPERTY_CHANGES_PER_SECOND = 50), the newest value each time and
    // always the last one. Until 0.9.21 this was a debounce, which sent
    // nothing while a fader kept moving and only the value it stopped on, so
    // a drag was heard late and in one step.
    @State private var levelThrottle = ControlWriteThrottle()
    @State private var swReturnThrottle = ControlWriteThrottle()
    @State private var panThrottle = ControlWriteThrottle()
    @State private var masterThrottle = ControlWriteThrottle()

    // P3F-15: Channel naming — stored in UserDefaults
    private var channelNamesJSON: String {
        get { _ = namesRevision; return UserDefaults.standard.string(forKey: appState.mixerNamesKey()) ?? "[]" }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: appState.mixerNamesKey())
            namesRevision += 1
        }
    }
    @State private var namesRevision = 0
    /// Unit B labels are indexed within unit B's own peripheral.
    private var unitBChannelNamesJSON: String {
        get { _ = namesRevision; return UserDefaults.standard.string(forKey: appState.mixerNamesKey(unit: .b)) ?? "[]" }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: appState.mixerNamesKey(unit: .b))
            namesRevision += 1
        }
    }

    // P3F-16: Channel visibility — stored in UserDefaults
    @AppStorage("mixerChannelVisibility") private var channelVisibilityJSON: String = "[]"

    /// When enabled, mixer meters show input signal level regardless of mute state.
    /// When disabled, meters drop to silence when a channel is muted (post-mute metering).
    @AppStorage("mixerPreMuteMetering") private var preMuteMetering: Bool = true

    /// Symphony IO MKI has 2 usable low-latency mixers.
    /// Evidence: SymphonyIOVendorSpecific.h — kSymphonyIOMixerCount.
    private let mixerCount = 2

    private var channelNames: [String] {
        decodeNames(channelNamesJSON) + decodeNames(unitBChannelNamesJSON)
    }

    private func decodeNames(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private var unitACount: Int { appState.cardLayout.mixerChannels.count }

    private func isUnitBChannel(_ index: Int) -> Bool {
        appState.unitBOnCard && index >= unitACount
    }

    private func localChannelIndex(_ index: Int) -> Int {
        isUnitBChannel(index) ? index - unitACount : index
    }

    private var channelVisibility: [Bool] {
        get {
            (try? JSONDecoder().decode([Bool].self, from: Data(channelVisibilityJSON.utf8))) ?? []
        }
    }

    /// The installed cards' layout — every count on this page comes from here.
    private var layout: CardLayout { appState.cardLayout }

    /// The mixer's input strips: every input channel the installed cards actually
    /// provide, analog first within each board.
    ///
    /// `totalPairsPerBoard * 2` is the XLink bus slice — a flat 16 per installed
    /// board whatever the board is — so it drew 32 strips for a 16x16 + 8MicPre
    /// (16 real channels) and 32 for any other pair regardless of what they carry.
    /// With a second Symphony I/O on port 2 (64 channels), unit B's strips
    /// follow unit A's (mixer channels 32-63, `TwoUnitMixer`).
    private var mixerChannels: [CardLayout.MixerChannel] { appState.mixerStripChannels }

    private var channelCount: Int { mixerChannels.count }

    var body: some View {
        let labels = mixerStripLabels
        VStack(spacing: 0) {
            // Toolbar row — Mixer selector + channel visibility (matches Input/Output toolbar style)
            HStack {
                // The mix being shown is filled in; the other is outlined. A
                // tinted outline alone was easy to miss.
                ForEach(0..<2, id: \.self) { index in
                    let button = Button("Mix \(index + 1)") {
                        selectedMixer = index
                        appState.lastSelectedMixer = index
                        initializeChannels()
                        Task { await syncMixerToHardware(recalling: true) }
                    }
                    .controlSize(.small)
                    .maestroHelp(selectedMixer == index
                          ? "Showing Mix \(index + 1)" : "Show Mix \(index + 1)")
                    .accessibilityAddTraits(selectedMixer == index ? .isSelected : [])
                    if selectedMixer == index {
                        button.buttonStyle(.borderedProminent)
                    } else {
                        button.buttonStyle(.bordered)
                    }
                }

                Menu {
                    ForEach(0..<channelCount, id: \.self) { i in
                        let vis = channelVisibility
                        Toggle(
                            labels[i],
                            isOn: Binding(
                                get: { i < vis.count ? vis[i] : true },
                                set: { newValue in
                                    var updated = vis
                                    while updated.count <= i { updated.append(true) }
                                    updated[i] = newValue
                                    if let data = try? JSONEncoder().encode(updated) {
                                        channelVisibilityJSON = String(data: data, encoding: .utf8) ?? "[]"
                                    }
                                }
                            )
                        )
                    }
                    Divider()
                    Button("Show All") {
                        let all = Array(repeating: true, count: channelCount)
                        if let data = try? JSONEncoder().encode(all) {
                            channelVisibilityJSON = String(data: data, encoding: .utf8) ?? "[]"
                        }
                    }
                    Divider()
                    Button("Reset Channel Labels") {
                        // Keep the array empty so newly discovered channels
                        // continue to use their hardware/default names.
                        channelNamesJSON = "[]"
                        unitBChannelNamesJSON = "[]"
                        NSApp.keyWindow?.endEditing(for: nil)
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                    .disabled(!channelNames.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    Divider()
                    Button("Reset Mixer Defaults") {
                        showMixerResetAlert = true
                    }
                    .maestroHelp("Reset this mixer's faders, pans, mute/solo states, and software return to factory defaults")
                    Divider()
                    Toggle("Pre-Mute Metering", isOn: $preMuteMetering)
                        .maestroHelp("When on, mixer meters show input signal even when a channel is muted — useful for seeing signal before unmuting. When off, meters drop to silence on mute (legacy behavior).")
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .maestroHelp("Channel Visibility")

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if let notice = appState.mixerHeadroomNotice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Dismiss") { appState.mixerHeadroomNotice = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            Spacer().frame(height: 8)

            // Channel strips — left-aligned horizontal scroll matching Input/Output tab layout.
            // Give the scroll container the available window height so its
            // indicator stays bottom-aligned while strips remain top-aligned.
            GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    Spacer().frame(width: 7)
                    // Input channel strips (filtered by visibility)
                    ForEach(Array(0..<min(editor.channels.count, channelCount)), id: \.self) { i in
                        if isChannelVisible(i) {
                            MixerChannelStripView(
                                channel: $editor.channels[i],
                                label: labels[i],
                                appState: appState,
                                inputMeterIndex: i,
                                preMuteMetering: preMuteMetering,
                                onLevelChange: { level in
                                    levelChanged(channel: i, value: level)
                                },
                                onPanChange: { pan in
                                    panChanged(channel: i, value: pan)
                                },
                                onMuteChange: { muted, isOption in
                                    if isOption {
                                        batchToggleMute(newValue: muted)
                                    } else {
                                        Task { await writeMute(channel: i, muted: muted); saveMixerState() }
                                    }
                                },
                                onSoloChange: { solo, isOption in
                                    if isOption {
                                        batchApplySolo(newValue: solo)
                                    } else {
                                        Task { await writeSolo(channel: i, solo: solo); saveMixerState() }
                                    }
                                },
                                isSelected: selectedChannels.contains(i),
                                onBatchLevelChange: { delta in
                                    batchApplyLevelDelta(delta: delta)
                                },
                                onBatchLevelDragStart: {
                                    beginBatchLevelDrag(fromChannel: i)
                                },
                                onBatchPanChange: { delta in
                                    batchApplyPanDelta(delta: delta)
                                },
                                onBatchPanDragStart: {
                                    beginBatchPanDrag(fromChannel: i)
                                },
                                onPanOptionClick: {
                                    batchCenterPans()
                                },
                                onSelect: { modifiers in
                                    selectChannel(i, modifiers: modifiers)
                                },
                                customLabel: customChannelLabel(for: i),
                                onCustomLabelChange: { value in
                                    setCustomChannelLabel(value, for: i)
                                },
                                showZoneColoring: appState.showMeterZoneColoring,
                                readoutEntry: readoutEntry(.input(i)),
                                panReadoutEntry: panReadoutEntry(.input(i))
                            )
                            .id(MixerLevelReadout.input(i))
                        }
                    }

                    // SW Return strip. Its own trailing separator is attached
                    // to the card below, so it cannot stretch to the scroll
                    // viewport's full height.
                    swReturnStrip
                        .id(MixerLevelReadout.softwareReturn)

                    // Master fader strip — pill aligned with SW Return pill,
                    // fader+meter+dB aligned with channel strips, no M/S at bottom.
                    VStack(spacing: 3) {
                        Text("Master")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.orange.opacity(0.15))
                            )

                        // Spacer matching pan knob(36) + 3 + panPill(~22) + 3 + breathingRoom(14) + alignment(9)
                        Spacer().frame(height: 87)

                        HStack(alignment: .top, spacing: 4) {
                            FaderView(
                                value: $editor.masterLeftLevel,
                                range: -48...6,
                                step: 1,
                                defaultValue: MixerValueConversion.faderDoubleClickResetValue(),
                                height: 200,
                                showScale: false,
                                externalReadout: true,
                                onUserChange: { newLevel in masterSideChanged(newLevel) },
                                thumbWidth: 22
                            )

                            FaderView(
                                value: $editor.masterRightLevel,
                                range: -48...6,
                                step: 1,
                                defaultValue: MixerValueConversion.faderDoubleClickResetValue(),
                                height: 200,
                                showScale: false,
                                externalReadout: true,
                                onUserChange: { newLevel in masterSideChanged(newLevel) },
                                thumbWidth: 22
                            )

                            // Keep meter observation inside this child view so
                            // 20 Hz meter updates do not rebuild every strip.
                            MixerMasterMetersView(
                                appState: appState,
                                mixerIndex: selectedMixer
                            )
                        }

                        // Master needs a small final optical adjustment to align
                        // its readout with the other strips.
                        masterReadoutRow

                    }
                    // Stereo master needs room for two faders, the scale, and
                    // both meters without painting into the next strip.
                    .frame(width: 116)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 5)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 1)
                    }
                    .id(MixerLevelReadout.master)
                }
                // Keep the scroll content at its intrinsic strip height. A
                // max-height frame here makes Divider stretch to the window
                // bottom and leaves Master visually floating above the others.
                .fixedSize(horizontal: false, vertical: true)
                // Mixer has no vertical content padding, so reserve the full
                // viewport height (Input achieves the same total height with
                // an explicit -16 frame plus 8pt top/bottom padding).
                .frame(minHeight: max(0, viewport.size.height), alignment: .top)
                .padding(.leading, 4)
                .background {
                    ControlTabScrollObserver(
                        tab: "Mixer",
                        restorationOffset: appState.controlTabScrollOffset(for: .mixer)
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
                        appState.setControlTabScrollOffset(offset, for: .mixer)
                    } onDetachOffset: { offset in
                        guard rememberControlTabScrollPositions else { return }
                        appState.setControlTabScrollOffset(offset, for: .mixer)
                    }
                }
            }
            .scrollPosition($scrollPosition)
            .onChange(of: rememberControlTabScrollPositions) { _, enabled in
                if !enabled {
                    scrollRestorationTarget = nil
                    scrollPosition.scrollTo(x: 0)
                    appState.setControlTabScrollOffset(0, for: .mixer)
                }
            }
            // Tab can move editing to a strip that is scrolled out of view;
            // bring it in by the smallest amount (no move when already visible).
            .onChange(of: editingReadout) { _, readout in
                if let readout { scrollProxy.scrollTo(readout) }
            }
            }
            }

            .background(Color.clear.contentShape(Rectangle()).onTapGesture { selectedChannels.removeAll() })

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
        .onAppear { installOutsideClickMonitor(); installKeyboardMonitor() }
        // On the page, not on the menu's toggle: an observer inside a
        // menu may not run.
        .onChange(of: preMuteMetering) { _, _ in appState.refreshSoftwareReturnMeterGains() }
        .onAppear {
            scrollRestorationPending = true
            restoreSessionScrollPosition()
        }
        .onDisappear {
            scrollRestorationGeneration += 1
            scrollObservationEnabled = false
            scrollRestorationPending = true
            removeOutsideClickMonitor()
            removeKeyboardMonitor()
        }
        .onChange(of: appState.selectedArea) { _, area in
            guard area != .mixer else { return }
            scrollRestorationGeneration += 1
            scrollObservationEnabled = false
            scrollRestorationPending = true
        }
        .alert("Reset Mixer Defaults?", isPresented: $showMixerResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                resetMixerDefaults()
            }
        } message: {
            Text("This resets Mix \(selectedMixer + 1)'s input faders, pans, mute/solo states, Master, and Software Return. Output Routing and channel labels are not changed.")
        }
        .disabled(!editor.canEdit(appState))
        .allowsHitTesting(editor.canEdit(appState))
        .navigationTitle("Mixer \(selectedMixer + 1)")
        .task {
            // Local state is already complete; only hardware synchronization
            // waits for this task. No partial strip layout is exposed meanwhile.
            ensureNamesAndVisibility()
            await syncMixerToHardware(recalling: true)
            restoreSessionScrollPosition()
        }
        .onAppear { appState.startMeterPolling() }
        .onExitCommand { selectedChannels.removeAll() }
        // Live board detection can refine the cached layout after construction.
        // Reconcile saved state when that happens; @State initializers only seed
        // the first lifetime of this view.
        .onChange(of: appState.cardLayoutToken) { _, _ in
            scrollRestorationPending = true
            initializeChannels()
            ensureNamesAndVisibility()
            restoreSessionScrollPosition()
            Task { await syncMixerToHardware(recalling: true) }
        }

        .onChange(of: appState.deviceRecoveryCount) { _, _ in
            // USB recovered after power cycle/sleep — FPGA reset to defaults.
            // Reload persisted mixer state and re-sync to hardware.
            initializeChannels()
            Task {
                guard !appState.usesTwoUnitReplay else { return }
                await syncMixerToHardware()
            }
            print("[Maestro] MixerView: Reloaded mixer state after recovery")
        }
    }

    /// Reapply the session offset after a tab recreation or card-layout update.
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
        scrollRestorationTarget = appState.controlTabScrollOffset(for: .mixer) > 0
            ? appState.controlTabScrollOffset(for: .mixer) : nil
        scrollRestorationPending = false
        scrollObservationEnabled = true
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let responder = window.firstResponder,
                  responder is NSTextField || responder is NSTextView else { return event }
            let hit = window.contentView?.hitTest(event.locationInWindow)
            var view: NSView? = hit
            var clickedField = false
            while let current = view {
                if current is NSTextField || current is NSTextView {
                    clickedField = true
                    break
                }
                view = current.superview
            }
            if !clickedField {
                window.endEditing(for: nil)
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard appState.selectedArea == .mixer,
                  !(NSApp.keyWindow?.firstResponder is NSTextField),
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.charactersIgnoringModifiers?.lowercased() == "a", flags.contains(.command) {
                selectedChannels = Set((0..<min(editor.channels.count, channelCount)).filter(isChannelVisible))
                return nil
            }
            if event.charactersIgnoringModifiers?.lowercased() == "d", flags.contains(.shift), !flags.contains(.command) {
                selectedChannels.removeAll()
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor { NSEvent.removeMonitor(monitor); keyboardMonitor = nil }
    }

    private func resetMixerDefaults() {
        guard editor.canEdit(appState) else { return }
        let empty = MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)
        editor.channels = Array(repeating: empty, count: editor.channels.count)
        editor.swReturnChannel = empty
        editor.swReturnLeftLevel = 0
        editor.swReturnRightLevel = 0
        editor.softwareReturnSource = 0
        editor.masterLevel = 0
        editor.masterLeftLevel = 0
        editor.masterRightLevel = 0
        saveMixerState()
        initializeChannels()
        Task {
            await syncMixerToHardware()
            await writeSWReturnLevel(0)
            await centreSWReturnPanOnCard()
            await writeSWReturnMute(false)
            await writeSWReturnSolo(false)
            await writeSoftwareReturnSource(0)
        }
    }

    // MARK: - Batch Operations

    /// Channels affected by batch operations. Only visible strips participate.
    private var batchTargetChannels: [Int] {
        if !selectedChannels.isEmpty {
            return selectedChannels.sorted().filter(isChannelVisible)
        }
        return (0..<min(editor.channels.count, channelCount)).filter(isChannelVisible)
    }

    /// Hidden strips keep their saved values, but have no live card element.
    /// Their old card ID may now belong to a different routed input.
    private func batchChannelIsRouted(_ channel: Int) -> Bool {
        mixerElement(channel: channel) != nil
    }

    /// Set mute to the same value for all target channels.
    private func batchToggleMute(newValue: Bool) {
        let targets = batchTargetChannels
        for i in targets {
            guard i < editor.channels.count else { continue }
            editor.channels[i].isMuted = newValue
            if batchChannelIsRouted(i) { Task { await writeMute(channel: i, muted: newValue) } }
        }
        saveMixerState()
    }

    /// Apply the clicked strip's new solo state to the target strips.
    private func batchApplySolo(newValue: Bool) {
        for i in batchTargetChannels where i < editor.channels.count {
            editor.channels[i].isSoloed = newValue
            if batchChannelIsRouted(i) { Task { await writeSolo(channel: i, solo: newValue) } }
        }
        saveMixerState()
    }

    /// Snapshot current levels for batch drag start.
    private func beginBatchLevelDrag(fromChannel: Int) {
        batchDragStartLevels = [:]
        for i in batchTargetChannels {
            guard i < editor.channels.count else { continue }
            batchDragStartLevels[i] = editor.channels[i].level
        }
        // Option-drag with no selection keeps its existing all-strip meaning.
        if selectedChannels.isEmpty { batchDragStartLevels[-1] = editor.swReturnChannel.level }
    }

    /// Apply a delta to all target channel levels (clamped, preserves relative positions).
    private func batchApplyLevelDelta(delta: Double) {
        let keys = batchDragStartLevels.keys.sorted()
        let starts = keys.compactMap { batchDragStartLevels[$0] }
        let values = MixerGroupMath.applyingDelta(delta.rounded(), to: starts, in: -48...0)
        for (i, newValue) in zip(keys, values) {
            let newLevel = MixerFaderLevel.played(newValue)
            if i == -1 {
                // SW Return (sentinel key)
                editor.swReturnChannel.level = newLevel
                // One stereo fader: both handles follow.
                editor.swReturnLeftLevel = newLevel
                editor.swReturnRightLevel = newLevel
                swReturnThrottle.submit(-1, newLevel) { value in await writeSWReturnLevel(value) }
            } else {
                guard i < editor.channels.count else { continue }
                editor.channels[i].level = newLevel
                if batchChannelIsRouted(i) { levelThrottle.submit(i, newLevel) { value in await writeLevel(channel: i, level: value) } }
            }
        }
        saveMixerState()
    }

    /// Snapshot current pans for batch drag start.
    private func beginBatchPanDrag(fromChannel: Int) {
        batchDragStartPans = [:]
        for i in batchTargetChannels {
            guard i < editor.channels.count else { continue }
            batchDragStartPans[i] = editor.channels[i].pan
        }
    }

    /// Apply a delta to all target channel pans (clamped, preserves relative positions).
    private func batchApplyPanDelta(delta: Double) {
        let keys = batchDragStartPans.keys.sorted()
        let starts = keys.compactMap { batchDragStartPans[$0] }
        let values = MixerGroupMath.applyingDelta(delta, to: starts, in: -1...1)
        for (i, newPan) in zip(keys, values) {
            let steppedPan = (newPan / MixerValueConversion.panStep).rounded() * MixerValueConversion.panStep
            guard i >= 0, i < editor.channels.count else { continue }
            editor.channels[i].pan = steppedPan
            if batchChannelIsRouted(i) { panThrottle.submit(i, steppedPan) { value in await writePan(channel: i, pan: value) } }
        }
        saveMixerState()
    }

    /// Center all input pans — triggered by Option+click on any pan knob.
    /// Software Return has no pan.
    private func batchCenterPans() {
        for i in batchTargetChannels {
            guard i < editor.channels.count else { continue }
            editor.channels[i].pan = 0
            if batchChannelIsRouted(i) { Task { await writePan(channel: i, pan: 0) } }
        }
        saveMixerState()
    }

    /// Handle channel selection with modifier keys (Cmd, Shift, plain click).
    private func selectChannel(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        let visible = (0..<min(editor.channels.count, channelCount)).filter(isChannelVisible)
        selectedChannels = MixerSelection.applyingClick(
            index: index,
            modifiers: MixerSelectionModifiers(
                shift: modifiers.contains(.shift),
                command: modifiers.contains(.command),
                option: modifiers.contains(.option)),
            visible: visible, selected: selectedChannels, last: lastSelectedChannel)
        lastSelectedChannel = index
    }

    private func levelChanged(channel: Int, value: Double) {
        guard selectedChannels.count > 1, batchDragStartLevels.isEmpty else {
            levelThrottle.submit(channel, value) { value in await writeLevel(channel: channel, level: value); saveMixerState() }
            return
        }
        for i in batchTargetChannels where i < editor.channels.count {
            editor.channels[i].level = value
            if batchChannelIsRouted(i) { levelThrottle.submit(i, value) { value in await writeLevel(channel: i, level: value) } }
        }
        saveMixerState()
    }

    private func panChanged(channel: Int, value: Double) {
        guard selectedChannels.count > 1, batchDragStartPans.isEmpty else {
            panThrottle.submit(channel, value) { value in await writePan(channel: channel, pan: value); saveMixerState() }
            return
        }
        for i in batchTargetChannels where i < editor.channels.count {
            editor.channels[i].pan = value
            if batchChannelIsRouted(i) { panThrottle.submit(i, value) { value in await writePan(channel: i, pan: value) } }
        }
        saveMixerState()
    }

    private func customChannelLabel(for index: Int) -> String {
        let names = isUnitBChannel(index) ? decodeNames(unitBChannelNamesJSON) : decodeNames(channelNamesJSON)
        let local = localChannelIndex(index)
        return local < names.count ? names[local] : ""
    }

    private var mixerStripLabels: [String] {
        let a = appState.inputNamingLayout(for: .a, labels: decodeNames(channelNamesJSON))
            .mixerChannels.map(\.label)
        guard appState.unitBOnCard else { return a }
        let b = appState.inputNamingLayout(for: .b, labels: decodeNames(unitBChannelNamesJSON))
            .mixerChannels.map { TwoUnitMixer.unitChannelName($0.label, prefix: appState.unitBPeripheralPrefix) }
        return a + b
    }

    private func setCustomChannelLabel(_ value: String, for index: Int) {
        let unitB = isUnitBChannel(index)
        var names = unitB ? decodeNames(unitBChannelNamesJSON) : decodeNames(channelNamesJSON)
        let local = localChannelIndex(index)
        if names.count <= local {
            names.append(contentsOf: Array(repeating: "", count: local + 1 - names.count))
        }
        names[local] = value
        if let data = try? JSONEncoder().encode(names) {
            let encoded = String(data: data, encoding: .utf8) ?? "[]"
            if unitB { unitBChannelNamesJSON = encoded } else { channelNamesJSON = encoded }
        }
    }

    private func isChannelVisible(_ index: Int) -> Bool {
        guard isChannelRouted(index) else { return false }
        let vis = channelVisibility
        if index < vis.count {
            return vis[index]
        }
        return true // default visible
    }

    /// Card inputs removed from Input Routing remain saved, but the original
    /// removed their mixer strips until a route was restored. Evidence:
    /// `Docs/2026-11-21-parity-differences.md:103` (C9). The meter map's nil
    /// entry is the exact unrouted condition.
    private func isChannelRouted(_ index: Int) -> Bool {
        guard appState.transportType == .thunderbolt,
              appState.connectedUnit == nil,
              !appState.converterRoutingSurface else { return true }
        let unit: DeviceUnit = isUnitBChannel(index) ? .b : .a
        let local = localChannelIndex(index)
        let numbers = appState.thunderboltMixerInputNumbers(unit: unit)
        return local < numbers.count && numbers[local] != nil
    }

    private func ensureNamesAndVisibility() {
        // Initialize arrays if they don't match channel count
        let aCount = unitACount
        var aNames = decodeNames(channelNamesJSON)
        var bNames = decodeNames(unitBChannelNamesJSON)
        // Migrate the pre-two-unit flat array once, preserving existing names
        // when unit B first appears.
        if appState.unitBOnCard && bNames.isEmpty && aNames.count > aCount {
            bNames = Array(aNames.dropFirst(aCount))
            aNames = Array(aNames.prefix(aCount))
            if let data = try? JSONEncoder().encode(bNames) {
                unitBChannelNamesJSON = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
        if aNames.count < aCount, let data = try? JSONEncoder().encode(aNames + Array(repeating: "", count: aCount - aNames.count)) {
            channelNamesJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
        if appState.unitBOnCard {
            let bCount = max(0, channelCount - aCount)
            if bNames.count < bCount, let data = try? JSONEncoder().encode(bNames + Array(repeating: "", count: bCount - bNames.count)) {
                unitBChannelNamesJSON = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
        let count = channelCount
        var vis = channelVisibility
        if vis.count < count {
            vis.append(contentsOf: Array(repeating: true, count: count - vis.count))
            if let data = try? JSONEncoder().encode(vis) {
                channelVisibilityJSON = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    private func initializeChannels() {
        guard editor.scopes == appState.mixerViewScopes else { return }
        editor = MixerEditorState(appState: appState, selectedMixer: selectedMixer)
    }

    private func saveMixerState() {
        editor.save(appState: appState, selectedMixer: selectedMixer)
    }

    /// Send all mixer channel states to hardware on startup/mixer switch.
    /// The FPGA doesn't persist mixer state — it powers up with defaults that
    /// may not match the UI, causing silent channels until user interaction.
    private func syncMixerToHardware(recalling: Bool = false) async {
        guard editor.canEdit(appState) else { return }
        // Over USB the connection's restore writes each mixer in full, in an
        // order that keeps it off every output until it is done. Until it has
        // written this mixer, a copy from here could unmute strips on a mixer
        // that still feeds an output (an older helper, or a restore that has
        // not reached it yet); afterwards this is the page's usual re-send.
        if appState.device is XPCDeviceConnection, !recalling, !appState.usbMixerIsWritten(selectedMixer) { return }
        // Two-unit lifecycle recall belongs to AppState even with this page closed.
        if recalling && appState.usesTwoUnitReplay { return }
        guard let device = appState.device else { return }
        // D5 owns a mixer the serving ThunderBridge driver started empty: the
        // restore writes all of it, paced, after 5 s of stable link. This
        // partial, unpaced copy would mark the driver's mixer as set and race
        // it. A reset (recalling == false) is an edit and is always written.
        if recalling, await appState.mixerPageDefersToCardMixerRestore(mixer: selectedMixer) { return }
        let loaded = editor
        // Every strip shown, saved or not: a strip nobody has touched shows
        // unmuted at 0 dB, and the unit or the driver may hold something else
        // (the ThunderBridge driver starts its card mixer with inputs muted).
        // A strip is muted only when it shows muted.
        for i in 0..<min(editor.channels.count, channelCount) {
            guard loaded.canEdit(appState), appState.device === device else { return }
            let ch = loaded.channels[i]
            guard let elem = mixerElement(channel: i) else { continue }
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelLevel, element: elem),
                    value: .float64(ch.level))
                guard loaded.canEdit(appState), appState.device === device else { return }
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelMute, element: elem),
                    value: .bool(ch.isMuted))
            } catch {
                // Non-critical — channel may not exist on this board config
            }
        }
        guard loaded.canEdit(appState), appState.device === device else { return }
        if usbDevice != nil {
            // USB: the unit's mixer owns Master and Software Return for every
            // source. The helper is written neutral inside writeSoftwareReturnSource.
            // The connection's lifecycle restore already wrote Master and Software
            // Return for this generation; the strips above are still this page's job.
            guard appState.usbMixerLifecycleRestoreGeneration != appState.unitAGeneration else { return }
            if editor.loadedMaster { await writeMasterFader() }
            if editor.loadedReturn { await writeSoftwareReturnSource(editor.softwareReturnSource) }
        } else {
            // Master level
            if loaded.loadedMaster {
                do {
                    try await device.setProperty(
                        PropertyAddress(selector: .mixerChannelLevel, element: masterElement),
                        value: .float64(loaded.masterLevel))
                } catch {}
            }
            if editor.loadedReturn { await writeSoftwareReturnSource(editor.softwareReturnSource) }
        }
        print("[Maestro] syncMixerToHardware: sent \(editor.channels.count) channels + master to mixer \(selectedMixer + 1)")
    }

    /// Encode mixer element: (mixerID << 16) | card receive-slot number.
    /// Evidence: SymphonyIOControl.cpp:1904-1942 — (nMixer << 16) | (nChannel & 0xFFFF).
    /// selectedMixer is 0-based in UI; USB protocol mixer IDs are 1-based.
    private func mixerElement(channel: Int, includeUnrouted: Bool = false) -> UInt32? {
        guard channel >= 0 else { return nil }
        if usbDevice != nil, channel >= mixerChannels.count {
            return (UInt32(selectedMixer + 1) << 16) | UInt32(channel)
        }
        guard channel < mixerChannels.count else { return nil }
        let strip = mixerChannels[channel]
        let unit: DeviceUnit = isUnitBChannel(channel) ? .b : .a
        let local = localChannelIndex(channel)
        if includeUnrouted, strip.hardwareIndex < 0 {
            let layoutStrips = (unit == .b ? appState.unitBLayout : appState.cardLayout)?.mixerChannels ?? []
            if layoutStrips.indices.contains(local) {
                let hardwareIndex = layoutStrips[local].hardwareIndex
                return (UInt32(selectedMixer + 1) << 16)
                    | UInt32(hardwareIndex + (unit == .b ? 32 : 0))
            }
        }
        guard strip.hardwareIndex >= 0 else { return nil }
        let id: Int?
        if usbDevice != nil {
            id = strip.hardwareIndex
        } else {
            let numbers = appState.thunderboltMixerInputNumbers(unit: unit)
            id = local < numbers.count
                ? numbers[local].map { unit == .b ? $0 + 32 : $0 }
                : nil
            if id == nil, includeUnrouted {
                // Batch gestures still clear saved strips after Input Routing
                // hides them. The card mixer uses the compact strip ID here.
                return (UInt32(selectedMixer + 1) << 16)
                    | UInt32(strip.hardwareIndex + (unit == .b ? 32 : 0))
            }
        }
        guard let id else { return nil }
        return (UInt32(selectedMixer + 1) << 16) | UInt32(id)
    }

    /// Master fader element: (mixerID << 16) | 2000.
    /// Evidence: SymphonyIOVendorSpecific.h — kSymphonyIOMixerChannelID_MasterOutput = 2000.
    ///
    /// USB addresses the strip as 33 instead; ThunderBridge keeps 2000.
    private var masterElement: UInt32 {
        (UInt32(selectedMixer + 1) << 16)
            | UInt32(usbDevice != nil ? USBMixerStrip.master : USBMixerStrip.masterLogicalID)
    }

    /// Software return element: (mixerID << 16) | 1000.
    /// Evidence: SymphonyIOVendorSpecific.h — kSymphonyIOMixerChannelID_SoftwareReturnInput = 1000.
    /// USB protocol mixer IDs are 1-based.
    ///
    /// USB addresses the strip as 32 instead; ThunderBridge keeps 1000.
    private var swReturnElement: UInt32 {
        (UInt32(selectedMixer + 1) << 16)
            | UInt32(usbDevice != nil ? USBMixerStrip.softwareReturn : USBMixerStrip.softwareReturnLogicalID)
    }

    /// A Software Return fader handle moved: both sides follow.
    private func swSideChanged(_ level: Double) {
        editor.swReturnLeftLevel = level
        editor.swReturnRightLevel = level
        editor.swReturnChannel.level = level
        swReturnThrottle.submit(-1, level) { value in await writeSWReturnLevel(value) }
        saveMixerState()
    }

    /// A Master fader handle moved: both sides follow.
    private func masterSideChanged(_ newLevel: Double) {
        editor.masterLeftLevel = newLevel
        editor.masterRightLevel = newLevel
        editor.masterLevel = newLevel
        scheduleMasterWrite(level: newLevel)
    }

    private var swReturnStrip: some View {
    MixerChannelStripView(
        channel: $editor.swReturnChannel,
        label: "Software Return",
        appState: appState,
        mixerMeterBaseIndex: selectedMixer * 2,
        onLevelChange: { level in
            swReturnThrottle.submit(-1, level) { value in await writeSWReturnLevel(value) }
            saveMixerState()
        },
        onMuteChange: { muted, isOption in
            if isOption {
                batchToggleMute(newValue: muted)
            } else {
                Task { await writeSWReturnMute(muted); saveMixerState() }
            }
        },
        onSoloChange: { solo, isOption in
            if isOption {
                batchApplySolo(newValue: solo)
            } else {
                Task { await writeSWReturnSolo(solo); saveMixerState() }
            }
        },
        onBatchLevelChange: { delta in
            batchApplyLevelDelta(delta: delta)
        },
        onBatchLevelDragStart: {
            beginBatchLevelDrag(fromChannel: -1)
        },
        softwareReturnSource: $editor.softwareReturnSource,
        softwareReturnPairCount: appState.softwareReturnPairCount,
        onSoftwareReturnSourceChange: { source in
            guard editor.canEdit(appState) else { return }
            editor.softwareReturnSource = source
            // The user's choice is saved as chosen, 1-2 included.
            appState.mixerPreferences.set(source, forKey: "mixerSoftwareReturnSource_\(selectedMixer)")
            Task { await writeSoftwareReturnSource(source); saveMixerState() }
        },
        showZoneColoring: appState.showMeterZoneColoring,
        stereoFader: true,
        // No pan: Apogee's Software Return had a stereo fader, solo and mute.
        showPan: false,
        stereoLeftLevel: $editor.swReturnLeftLevel,
        stereoRightLevel: $editor.swReturnRightLevel,
        onStereoLevelChange: { level in swSideChanged(level) },
        readoutEntry: readoutEntry(.softwareReturn)
    )
    }

    private var masterReadoutRow: some View {
        VStack(spacing: 3) {
            // The empty control row every strip reserves above its readout, so
            // Unity, Mute, Solo and Output share one baseline.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: mixerReadoutGapHeight)

            // The original Master value field edits the stereo fader. Preserve
            // that while keeping the readout display-only until double-clicked.
            EditableLevelReadout(
                value: Binding(
                    get: { MixerFaderLevel.played(editor.masterLevel) },
                    set: { newLevel in masterSideChanged(newLevel) }),
                range: -48...6,
                step: 1,
                entry: readoutEntry(.master))
            .maestroHelp("Master level for this mixer, applied to every input and Software Return: click to type a value")

            // The two rows other strips have below the value, so Master's
            // rows line up with them: a blank box where Mute and Solo sit,
            // and the output this mixer feeds where Software Return has its
            // menu. Neither is a control (the original's was a text label).
            // Faint, so it reads as an empty slot rather than a control
            // (owner, 2026-11-22). Apogee's Master had nothing here either.
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                .frame(maxWidth: .infinity)
                .frame(height: mixerControlRowHeight)
                .accessibilityHidden(true)
            Text(masterOutputLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                .maestroHelp("The output Mixer \(selectedMixer + 1) is routed to in Output Routing. None: Mixer \(selectedMixer + 1) is not routed to an output.")
        }
        // SwiftUI points map to physical pixels on Retina;
        // two points is the observed four-pixel correction.
        .offset(y: -2)
    }

    /// "Line 1/2" when this mixer is routed there in Output Routing, "None"
    /// when it feeds no output. Read from the saved routing, never from the
    /// unit; the page is rebuilt on return from Output Routing.
    private var masterOutputLabel: String {
        _ = appState.viewReloadToken
        return appState.converterRoutingSurface ? "" : appState.masterOutputLabel(mixer: selectedMixer)
    }

    /// The USB connection, or nil on ThunderBridge and in simulation.
    private var usbDevice: XPCDeviceConnection? { appState.device as? XPCDeviceConnection }

    private func writeLevel(channel: Int, level: Double) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        guard let element = mixerElement(channel: channel, includeUnrouted: true) else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelLevel, element: element),
                value: .float64(level)
            )
        } catch {
            print("[Maestro] Mixer level ch\(channel) failed: \(error)")
        }
    }

    private func writePan(channel: Int, pan: Double) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        guard let element = mixerElement(channel: channel, includeUnrouted: true) else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelPan, element: element),
                value: .float64(pan)
            )
        } catch {
            print("[Maestro] Mixer pan ch\(channel) failed: \(error)")
        }
    }

    private func writeMute(channel: Int, muted: Bool) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        guard let element = mixerElement(channel: channel, includeUnrouted: true) else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelMute, element: element),
                value: .bool(muted)
            )
        } catch {
            print("[Maestro] Mixer mute ch\(channel) failed: \(error)")
        }
    }

    private func writeSolo(channel: Int, solo: Bool) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        guard let element = mixerElement(channel: channel, includeUnrouted: true) else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelSolo, element: element),
                value: .bool(solo)
            )
        } catch {
            print("[Maestro] Mixer solo ch\(channel) failed: \(error)")
        }
    }

    private func writeMasterLevel(_ level: Double) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        if usbDevice != nil {
            await writeMasterFader()
            return
        }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelLevel, element: masterElement),
                value: .float64(level)
            )
        } catch {
            print("[Maestro] Mixer master level failed: \(error)")
        }
    }

    /// USB: write the Master strip from the faders as shown.
    private func writeMasterFader() async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        let level = MixerPairLink.usbUnitLevel(
            left: editor.masterLeftLevel, right: editor.masterRightLevel,
            savedLinked: true, linkedLevel: editor.masterLevel)
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelLevel, element: masterElement),
                value: .float64(level))
        } catch {
            print("[Maestro] Mixer master level failed: \(error)")
        }
    }

    private func scheduleMasterWrite(level: Double) {
        masterThrottle.submit(0, level) { value in
            await writeMasterLevel(value)
            saveMixerState()
        }
    }

    // MARK: - Software Return writes (P3F-38)

    // USB: the unit's own mixer is the authority for Software Return level, mute
    // and solo (strip 32), for every source. The helper's software stage is kept
    // neutral (0 dB, unmuted) so nothing is applied twice; it still carries pan
    // for USB playback 1-2.
    // ThunderBridge: the Software Return is a real mixer input (id 1000) driven
    // through setProperty with swReturnElement, like any other strip.
    private func writeSWReturnLevel(_ level: Double) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        if usbDevice != nil {
            _ = await writeSWReturnUnitLevel(linkedLevel: level)
        } else {
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelLevel, element: swReturnElement),
                    value: .float64(level)
                )
            } catch {
                print("[Maestro] Mixer SW Return level failed: \(error)")
            }
        }
    }

    /// USB: the one place the Software Return level reaches the unit. The unit
    /// has one fader per strip. The
    /// helper's software level is not touched here (it is held neutral by
    /// `writeSoftwareReturnSource`, after the unit has taken its values).
    private func writeSWReturnUnitLevel(linkedLevel: Double) async -> Bool {
        guard editor.canEdit(appState) else { return false }
        guard let xpcDev = usbDevice else { return false }
        let level = MixerPairLink.usbUnitLevel(
            left: editor.swReturnLeftLevel, right: editor.swReturnRightLevel,
            savedLinked: true, linkedLevel: linkedLevel)
        do {
            try await xpcDev.setProperty(
                PropertyAddress(selector: .mixerChannelLevel, element: swReturnElement),
                value: .float64(level))
            return true
        } catch {
            print("[Maestro] Mixer SW Return level failed: \(error)")
            return false
        }
    }

    /// Software Return has no pan (the original's strip had a stereo fader,
    /// solo and mute: og_source/maestro2/App/Controllers/APMixerSoftwareReturnViewController.m).
    /// The ThunderBridge card mixer still has the control and may hold a pan
    /// an earlier version wrote, so it is put back to centre wherever the
    /// return is rewritten. Over USB the unit's strip has none.
    private func centreSWReturnPanOnCard() async {
        guard editor.canEdit(appState), usbDevice == nil, let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelPan, element: swReturnElement),
                value: .float64(0))
        } catch {
            print("[Maestro] Mixer SW Return pan centre failed: \(error)")
        }
    }

    /// What the helper's software stage should do when this mixer's Software
    /// Return has `muted` and `source`: the other mixer and Output Routing
    /// count too (``USBHelperSoftwareReturn``).
    private func helperState(muted: Bool, source: UInt32) -> USBHelperSoftwareReturn.State {
        appState.usbHelperSoftwareReturn(editing: (mixer: selectedMixer, source: source, muted: muted))
    }

    /// Over USB the connection sends the unit's 0xB3 to strip 32 of this mixer
    /// and, when it lands, sets the helper's software mute by `helperState`
    /// (on only while a mixer on USB 1-2 feeds an output). ThunderBridge: the
    /// driver's mixer alone, unchanged.
    private func writeSWReturnMute(_ muted: Bool) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        do {
            let address = PropertyAddress(selector: .mixerChannelMute, element: swReturnElement)
            if let xpcDev = usbDevice {
                try await xpcDev.setSoftwareReturnMute(
                    address, muted: muted,
                    helperMuted: helperState(muted: muted, source: editor.softwareReturnSource).muted)
            } else {
                try await device.setProperty(address, value: .bool(muted))
            }
        } catch {
            print("[Maestro] Mixer SW Return mute failed: \(error)")
        }
    }

    /// Solo is the unit's 0xB2 to strip 32 only, on every connection. The USB
    /// helper has no solo and none is invented here: soloing Software Return
    /// silences the other strips in the unit's mixer, as in the original
    /// (og_source/maestrolink/Software/SymphonyIOMixer.cpp:305-315).
    private func writeSWReturnSolo(_ solo: Bool) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelSolo, element: swReturnElement),
                value: .bool(solo)
            )
        } catch {
            print("[Maestro] Mixer SW Return solo failed: \(error)")
        }
    }

    /// Route the selected USB playback stereo pair into this mixer's Software
    /// Return input, matching the legacy AEsR property.
    private func writeSoftwareReturnSource(_ source: UInt32) async {
        guard editor.canEdit(appState) else { return }
        // 8 pairs, or 32 while 64 channels run with unit B (ThunderBridge only).
        guard let device = appState.device,
              source < UInt32(appState.softwareReturnPairCount) else { return }
        // A saved DAW 17-64 shown as 1-2 before unit B is reported is not
        // sent: the card keeps its own source until then.
        let saved = UInt32(clamping: appState.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\(selectedMixer)"))
        let held = TwoUnitMixer.isHeld(shown: source, saved: saved, pairCount: appState.softwareReturnPairCount)
        do {
            let element = UInt32(selectedMixer + 1) << 16
            if !held {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerSoftwareReturnID, element: element),
                    value: .uint32(source))
            }
        } catch DeviceConnectionError.unsupportedProperty(_) {
            // Software-return routing is unavailable on some hardware paths;
            // keep the rest of the mixer usable without a false error.
        } catch {
            print("[Maestro] Mixer SW Return source failed: \(error)")
        }
        if let xpcDev = usbDevice {
            // Unit first, helper second: a helper left holding an attenuation
            // or mute by an older Maestro must not be neutralised before the
            // unit holds its values. If a unit write fails twice the helper is
            // left as it was.
            let level = MixerPairLink.usbUnitLevel(
                left: editor.swReturnLeftLevel, right: editor.swReturnRightLevel,
                savedLinked: true, linkedLevel: editor.swReturnLeftLevel)
            let element = swReturnElement
            // Read once: the unit and the helper must get the same mute even if
            // the user clicks Mute while these writes are in flight.
            let muted = editor.swReturnChannel.isMuted
            let writes: [(AudioPropertySelector, PropertyValue)] = [
                (.mixerChannelLevel, .float64(level)),
                (.mixerChannelMute, .bool(muted)),
                (.mixerChannelSolo, .bool(editor.swReturnChannel.isSoloed)),
            ]
            var unitOK = true
            for (selector, value) in writes {
                if await !xpcDev.setUnitMixerWithRetry(
                    PropertyAddress(selector: selector, element: element), value: value) {
                    unitOK = false
                }
            }
            guard unitOK else {
                print("[Maestro] SW Return write to the unit failed twice; the helper was left as it was")
                return
            }
            // Level neutral (the unit owns the fader); the helper's mute only
            // while a mixer on USB 1-2 feeds an output. Solo stays on the unit.
            xpcDev.applyHelperSoftwareReturn(helperState(muted: muted, source: source))
        } else {
            // ThunderBridge: the FPGA mixer processes every source. Mirror the
            // current persisted state into its software-return input controls.
            let swReturnChannel = editor.swReturnChannel
            await writeSWReturnLevel(swReturnChannel.level)
            await centreSWReturnPanOnCard()
            await writeSWReturnMute(swReturnChannel.isMuted)
            await writeSWReturnSolo(swReturnChannel.isSoloed)
        }
    }
}

/// Master meters observe only the mixer meter slots they render. Keeping this
/// separate from MixerView prevents each 20 Hz meter sample from rebuilding
/// the full horizontal strip collection.
private struct MixerMasterMetersView: View {
    let appState: AppState
    let mixerIndex: Int

    var body: some View {
        let baseIndex = 4 + mixerIndex * 2
        let levels = appState.mixerMeterLevels
        let left = baseIndex < levels.count ? levels[baseIndex] : -60.0
        let right = baseIndex + 1 < levels.count ? levels[baseIndex + 1] : -60.0
        let peaks = appState.mixerPeakHold
        let leftPeak = peaks.indices.contains(baseIndex) ? peaks[baseIndex] : -60
        let rightPeak = peaks.indices.contains(baseIndex + 1) ? peaks[baseIndex + 1] : -60
        HStack(alignment: .top, spacing: 4) {
            LEDMeterView(
                level: left,
                peak: leftPeak,
                label: "L",
                height: 200,
                width: 8,
                showScale: true,
                scaleOnLeft: true,
                rangeDB: 48,
                showZoneColoring: appState.showMeterZoneColoring,
                labelOffsetY: -10,
                isOver: appState.meterIsOver(.mixer, baseIndex),
                onClear: appState.clearMeters
            )
            LEDMeterView(
                level: right,
                peak: rightPeak,
                label: "R",
                height: 200,
                width: 8,
                rangeDB: 48,
                showZoneColoring: appState.showMeterZoneColoring,
                isOver: appState.meterIsOver(.mixer, baseIndex, offset: 1),
                onClear: appState.clearMeters
            )
        }
    }
}

/// A single mixer channel strip matching Input/Output tab styling:
/// Pill label → Pan knob → Pan value pill → (padding) → Fader + Meter (clipped) → (padding) → dB readout → Mute/Solo.
///
/// Evidence: `og_source/maestro2/App/Controllers/Mixer/`
struct MixerChannelStripView: View {
    @Binding var channel: MixerChannelState
    let label: String
    /// Meter inputs are read inside this child view rather than in MixerView.
    /// AppState is Observation-based, so keeping the read here prevents a
    /// 20 Hz meter update from invalidating the whole horizontal strip.
    var appState: AppState? = nil
    var inputMeterIndex: Int? = nil
    var mixerMeterBaseIndex: Int? = nil
    var preMuteMetering: Bool = true
    var meterLevel: Double = -60
    var meterLevelR: Double? = nil  // When set, renders stereo L/R meters
    let onLevelChange: (Double) -> Void
    var onPanChange: ((Double) -> Void)? = nil
    let onMuteChange: (Bool, _ isOption: Bool) -> Void
    let onSoloChange: (Bool, _ isOption: Bool) -> Void
    var isSelected: Bool = false
    var onBatchLevelChange: ((Double) -> Void)? = nil
    var onBatchLevelDragStart: (() -> Void)? = nil
    var onBatchPanChange: ((Double) -> Void)? = nil
    var onBatchPanDragStart: (() -> Void)? = nil
    var onPanOptionClick: (() -> Void)? = nil
    var onSelect: ((NSEvent.ModifierFlags) -> Void)? = nil
    var customLabel: String = ""
    var onCustomLabelChange: ((String) -> Void)? = nil
    var softwareReturnSource: Binding<UInt32>? = nil
    /// Software Return pairs offered: 8, or 32 with a second unit (64 channels).
    var softwareReturnPairCount: Int = 8
    var onSoftwareReturnSourceChange: ((UInt32) -> Void)? = nil
    var showZoneColoring: Bool = false
    /// Legacy Maestro draws a stereo return as one fader with a left and a
    /// right handle. The two always move together.
    var stereoFader: Bool = false
    /// Whether this strip exposes its pan control. Software Return has none;
    /// a strip without one still reserves the same lane.
    var showPan: Bool = true
    var stereoLeftLevel: Binding<Double>? = nil
    var stereoRightLevel: Binding<Double>? = nil
    /// A stereo fader handle or its readout moved: the new level for both sides.
    var onStereoLevelChange: ((Double) -> Void)? = nil
    /// Ties this strip's level readout into the page's one-at-a-time editing
    /// and Tab order.
    let readoutEntry: LevelReadoutEntry<MixerLevelReadout>
    var panReadoutEntry: LevelReadoutEntry<MixerPanReadout>? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// Height for the fader+meter area (matches Input/Output strip meter height).
    private let faderHeight: CGFloat = 200

    private var resolvedMeterLevels: (left: Double, right: Double?, leftPeak: Double,
                                      rightPeak: Double, leftOver: Bool, rightOver: Bool) {
        if let appState, let index = inputMeterIndex {
            let input = appState.mixerInputMeterPresentation(strip: index)
            // Match the strip's existing pre-/post-mute setting for the peak mark.
            func displayed(_ value: Double) -> Double {
                if preMuteMetering { return max(value, -60) }
                guard !channel.isMuted, value > -60 else { return -60 }
                return max(value + channel.level, -60)
            }
            let level = preMuteMetering ? max(input.level, -60)
                : (channel.isMuted ? -60 : max(input.level + channel.level, -60))
            return (level, nil, displayed(input.peak), -60, input.over, false)
        }
        if let appState, let baseIndex = mixerMeterBaseIndex {
            let levels = appState.mixerMeterLevels
            let peaks = appState.mixerPeakHold
            guard levels.indices.contains(baseIndex + 1) else { return (-60, -60, -60, -60, false, false) }
            return (levels[baseIndex], levels[baseIndex + 1],
                    peaks[baseIndex], peaks[baseIndex + 1],
                    appState.meterIsOver(.mixer, baseIndex),
                    appState.meterIsOver(.mixer, baseIndex, offset: 1))
        }
        return (meterLevel, meterLevelR, -60, -60, false, false)
    }

    private var panText: String { MixerValueConversion.panReadout(channel.pan) }

    var body: some View {
        let resolvedMeters = resolvedMeterLevels
        VStack(spacing: 3) {
            // Channel label — pill style matching Input/Output tabs, clickable for selection
            // An "N.A." channel's name is faded like the Input and Output tabs'
            // strips. Its controls still work: the daemon built the mixer's
            // channel list once from the boards' channel counts, whatever the
            // rate or format (`SymphonyIOMixer.cpp:142-152`), so the channel
            // and its 0xB0-0xB3 ID stay; only its name changes.
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(CardLayout.isNotApplicable(label) && !isSelected ? 0.45 : 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                )
                .onTapGesture {
                    onSelect?(NSEvent.modifierFlags)
                }

            if showPan {
                // Pan knob — larger, no built-in readout
                RotaryKnobView(
                    value: $channel.pan,
                    range: -1...1,
                    step: MixerValueConversion.panStep,
                    label: "",
                    unit: "",
                    size: 36,
                    defaultValue: 0,
                    arcColor: .orange,
                    bipolar: true,
                    externalReadout: true,
                    onBatchDrag: onBatchPanChange,
                    onBatchDragStart: onBatchPanDragStart,
                    onOptionClick: onPanOptionClick
                )
                .maestroHelp("Pan: \(panText) — Shift-click the name to select strips, double-click to center, Option+click center all, Option+drag all")
                .onChange(of: channel.pan) { _, newPan in
                    onPanChange?(newPan)
                }

                // Pan value — pill readout
                if let panReadoutEntry {
                    EditableLevelReadout(
                        value: $channel.pan,
                        range: -1...1,
                        step: MixerValueConversion.panStep,
                        entry: panReadoutEntry,
                        parseTypedValue: { MixerValueConversion.panValue(typed: $0) },
                        displayText: MixerValueConversion.panReadout)
                    .maestroHelp("Pan value: type 0, -13, +20, L13, R20 or C; Tab moves to the next visible strip")
                }

                // Breathing room between pan pill and fader (enough for thumb overtravel)
                Spacer().frame(height: 14)
            } else {
                // SW Return has no pan control, but it occupies the same
                // vertical pan lane so its stereo faders align with Master
                // and the ordinary mixer strips.
                Color.clear.frame(height: 87)
            }

            // Fader + Scale + Meter side by side — scale between fader and meter.
            // Breathing room spacers above/below prevent thumb overlapping pills.
            HStack(alignment: .top, spacing: 4) {
                FaderView(
                    value: stereoLeftLevel ?? $channel.level,
                    range: -48...6,
                    step: 1,
                    defaultValue: MixerValueConversion.faderDoubleClickResetValue(),
                    height: faderHeight,
                    showScale: false,
                        externalReadout: true,
                        onBatchDrag: onBatchLevelChange,
                        onBatchDragStart: onBatchLevelDragStart,
                        onUserChange: { newLevel in
                            if stereoLeftLevel != nil { onStereoLevelChange?(newLevel) }
                        },
                        thumbWidth: stereoFader ? 22 : 28
                    )
                if stereoFader {
                    FaderView(
                        value: stereoRightLevel ?? $channel.level,
                        range: -48...6,
                        step: 1,
                        defaultValue: MixerValueConversion.faderDoubleClickResetValue(),
                        height: faderHeight,
                        showScale: false,
                        externalReadout: true,
                        onBatchDrag: onBatchLevelChange,
                        onBatchDragStart: onBatchLevelDragStart,
                        onUserChange: { newLevel in
                            if stereoRightLevel != nil { onStereoLevelChange?(newLevel) }
                        },
                        thumbWidth: 22
                    )
                }

                if let rightLevel = resolvedMeters.right {
                    // Stereo: L meter with scale, R meter without
                    LEDMeterView(
                        level: resolvedMeters.left,
                        peak: resolvedMeters.leftPeak,
                        label: "L",
                        height: faderHeight,
                        width: 8,
                        showScale: true,
                        scaleOnLeft: true,
                        rangeDB: 48,
                        showZoneColoring: showZoneColoring,
                        labelOffsetY: -10,
                        isOver: resolvedMeters.leftOver,
                        onClear: appState.map { state in { state.clearMeters() } }
                    )
                    LEDMeterView(
                        level: rightLevel,
                        peak: resolvedMeters.rightPeak,
                        label: "R",
                        height: faderHeight,
                        width: 8,
                        rangeDB: 48,
                        showZoneColoring: showZoneColoring,
                        isOver: resolvedMeters.rightOver,
                        onClear: appState.map { state in { state.clearMeters() } }
                    )
                } else {
                    // Mono: single meter
                    LEDMeterView(
                        level: resolvedMeters.left,
                        peak: resolvedMeters.leftPeak,
                        label: "",
                        height: faderHeight,
                        width: 10,
                        showScale: true,
                        scaleOnLeft: true,
                        rangeDB: 48,
                        showZoneColoring: showZoneColoring,
                        isOver: resolvedMeters.leftOver,
                        onClear: appState.map { state in { state.clearMeters() } }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: mixerFaderMeterRowHeight, alignment: .top)
            .onChange(of: channel.level) { _, newLevel in
                onLevelChange(newLevel)
            }

            // Every strip keeps one empty control row above its readout, so
            // Unity, Mute, Solo and Output share one horizontal baseline.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: mixerReadoutGapHeight)

            if stereoLeftLevel != nil, stereoRightLevel != nil {
                // The legacy Software Return value field is editable and
                // controls the stereo fader.
                EditableLevelReadout(
                    value: Binding(
                        get: { MixerFaderLevel.played(stereoLeftLevel?.wrappedValue ?? channel.level) },
                        set: { newValue in onStereoLevelChange?(newValue) }),
                    range: -48...6,
                    step: 1,
                    entry: readoutEntry)
                .maestroHelp("Software Return level (the Mac's audio coming into this mixer): click to type a value")
            } else {
                // dB readout (level) — single readout, no duplicate
                EditableLevelReadout(value: Binding(get: { MixerFaderLevel.played(channel.level) }, set: { channel.level = MixerFaderLevel.played($0) }), range: -48...6, step: 1, entry: readoutEntry)
                    .maestroHelp("Fader Level: \(String(format: "%.0f", MixerFaderLevel.played(channel.level))) dB — Shift-click the name to select strips, click to edit")
            }

            // Mute / Solo buttons — at the very bottom
            // Option+Click M = batch mute all target channels
            // Option+Click S = clear all solos
            HStack(spacing: 3) {
                Button(action: {
                    channel.isMuted.toggle()
                    let isOption = NSEvent.modifierFlags.contains(.option)
                    onMuteChange(channel.isMuted, isOption)
                }) {
                    Text("M")
                        .font(.system(size: 9, weight: .bold))
                        .frame(maxWidth: .infinity)
                                    .frame(height: mixerControlRowHeight)
                        .background(RoundedRectangle(cornerRadius: 3).fill(channel.isMuted ? Color.red.opacity(0.8) : Color.gray.opacity(0.2)))
                        .foregroundStyle(channel.isMuted ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .maestroHelp("Mute (Option+Click: all channels)")

                Button(action: {
                    channel.isSoloed.toggle()
                    let isOption = NSEvent.modifierFlags.contains(.option)
                    onSoloChange(channel.isSoloed, isOption)
                }) {
                    Text("S")
                        .font(.system(size: 9, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: mixerControlRowHeight)
                        .background(RoundedRectangle(cornerRadius: 3).fill(channel.isSoloed ? Color.yellow.opacity(0.8) : Color.gray.opacity(0.2)))
                        .foregroundStyle(channel.isSoloed ? .black : .secondary)
                }
                .buttonStyle(.plain)
                .maestroHelp("Solo (Option+Click: clear all solos)")
            }

            // Mixer Custom Label — a user-editable label distinct from the
            // hardware/card label at the top of the strip.
            if let sourceBinding = softwareReturnSource {
                PillMenu(
                    text: sourceBinding.wrappedValue < UInt32(softwareReturnPairCount)
                        ? TwoUnitMixer.softwareReturnMenuName(sourceBinding.wrappedValue) : TwoUnitMixer.softwareReturnMenuName(0),
                    fontSize: 9,
                    pillHeight: 22,
                    toolTip: "Software Return source — selects the DAW stereo pair feeding this mixer",
                    options: (0..<UInt32(softwareReturnPairCount)).map { source in
                        (TwoUnitMixer.softwareReturnMenuName(source), {
                            sourceBinding.wrappedValue = source
                            onSoftwareReturnSourceChange?(source)
                        })
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 22, alignment: .center)
            } else if let onCustomLabelChange {
                TextField("", text: Binding(
                    get: { customLabel },
                    set: { onCustomLabelChange($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                .onSubmit {
                    NSApp.keyWindow?.endEditing(for: nil)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .onExitCommand {
                    NSApp.keyWindow?.endEditing(for: nil)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .maestroHelp("Mixer Custom Label — names this input channel in both mixers")
            }

        }
        // Stereo Software Return needs a wider cell than mono input strips;
        // otherwise its second thumb and the paired meters overlap neighbors.
        .frame(width: stereoFader ? 116 : 80)
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.controlBackgroundColor).opacity(colorScheme == .light ? 0.6 : 0.3))
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.4))
                .frame(width: 1)
        }
    }
}


/// Rate-limits a control's writes while it moves: the newest value is sent at
/// once, then at most one every `interval` while newer values keep arriving,
/// and the last value is always sent. One sender per key (a strip), so a
/// write is never overtaken by an older one.
@MainActor
final class ControlWriteThrottle {
    private var pending: [Int: Double] = [:]
    private var running: Set<Int> = []
    private let interval: Duration

    init(interval: Duration = .milliseconds(20)) { self.interval = interval }

    func submit(_ key: Int, _ value: Double, write: @escaping @MainActor (Double) async -> Void) {
        pending[key] = value
        guard running.insert(key).inserted else { return }
        Task { @MainActor in
            while let next = pending.removeValue(forKey: key) {
                await write(next)
                try? await Task.sleep(for: interval)
            }
            running.remove(key)
        }
    }
}
