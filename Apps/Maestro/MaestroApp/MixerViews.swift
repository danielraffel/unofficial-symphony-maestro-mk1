import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice

/// Shared logical height for the link/Unity/output control rows.
private let mixerControlRowHeight: CGFloat = 22

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
    @State private var scrollPosition: ScrollPosition
    @AppStorage("rememberControlTabScrollPositions") private var rememberControlTabScrollPositions = true

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

    // Debounce timers for mixer writes — prevents audio clicks from rapid fader movement.
    // Original Maestro rate-limited at 50 Hz (20ms). We use 25ms debounce per channel.
    // Evidence: ApogeeDispatchQueue.cpp:18 — MAX_PROPERTY_CHANGES_PER_SECOND = 50.
    @State private var levelDebounce: [Int: Task<Void, Never>] = [:]
    @State private var panDebounce: [Int: Task<Void, Never>] = [:]
    @State private var masterDebounce: Task<Void, Never>?

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
                    .help(selectedMixer == index
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
                            channelLabel(for: i),
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
                    .help("Reset this mixer's faders, pans, mute/solo states, and software return to factory defaults")
                    Divider()
                    Toggle("Pre-Mute Metering", isOn: $preMuteMetering)
                        .help("When on, mixer meters show input signal even when a channel is muted — useful for seeing signal before unmuting. When off, meters drop to silence on mute (legacy behavior).")
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Channel Visibility")

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Spacer().frame(height: 8)

            // Channel strips — left-aligned horizontal scroll matching Input/Output tab layout.
            // Give the scroll container the available window height so its
            // indicator stays bottom-aligned while strips remain top-aligned.
            GeometryReader { viewport in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    Spacer().frame(width: 7)
                    // Input channel strips (filtered by visibility)
                    ForEach(Array(0..<min(editor.channels.count, channelCount)), id: \.self) { i in
                        if isChannelVisible(i) {
                            MixerChannelStripView(
                                channel: $editor.channels[i],
                                label: channelLabel(for: i),
                                appState: appState,
                                inputMeterIndex: i,
                                preMuteMetering: preMuteMetering,
                                onLevelChange: { level in
                                    levelDebounce[i]?.cancel()
                                    levelDebounce[i] = Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(25))
                                        guard !Task.isCancelled else { return }
                                        await writeLevel(channel: i, level: level)
                                        saveMixerState()
                                    }
                                },
                                onPanChange: { pan in
                                    panDebounce[i]?.cancel()
                                    panDebounce[i] = Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(25))
                                        guard !Task.isCancelled else { return }
                                        await writePan(channel: i, pan: pan)
                                        saveMixerState()
                                    }
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
                                showZoneColoring: appState.showMeterZoneColoring
                            )
                        }
                    }

                    // SW Return strip. Its own trailing separator is attached
                    // to the card below, so it cannot stretch to the scroll
                    // viewport's full height.
                    swReturnStrip

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
                                step: 0.5,
                                defaultValue: 0,
                                height: 200,
                                showScale: false,
                                externalReadout: true,
                                onUserChange: { newLevel in masterSideChanged(newLevel) },
                                thumbWidth: 22
                            )

                            FaderView(
                                value: $editor.masterRightLevel,
                                range: -48...6,
                                step: 0.5,
                                defaultValue: 0,
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
        .onAppear { installOutsideClickMonitor() }
        .onAppear {
            scrollRestorationPending = true
            restoreSessionScrollPosition()
        }
        .onDisappear {
            scrollRestorationGeneration += 1
            scrollObservationEnabled = false
            scrollRestorationPending = true
            removeOutsideClickMonitor()
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
            if appState.usbMixerLifecycleRestoreGeneration != appState.unitAGeneration {
                await syncMixerToHardware(recalling: true)
            }
            restoreSessionScrollPosition()
        }
        .onAppear { appState.startMeterPolling() }
        // Live board detection can refine the cached layout after construction.
        // Reconcile saved state when that happens; @State initializers only seed
        // the first lifetime of this view.
        .onChange(of: appState.cardLayoutToken) { _, _ in
            scrollRestorationPending = true
            initializeChannels()
            ensureNamesAndVisibility()
            restoreSessionScrollPosition()
            if appState.usbMixerLifecycleRestoreGeneration != appState.unitAGeneration {
                Task { await syncMixerToHardware(recalling: true) }
            }
        }

        .onChange(of: appState.deviceRecoveryCount) { _, _ in
            // USB recovered after power cycle/sleep — FPGA reset to defaults.
            // Reload persisted mixer state and re-sync to hardware.
            initializeChannels()
            if appState.usbMixerLifecycleRestoreGeneration != appState.unitAGeneration {
                Task {
                    guard !appState.usesTwoUnitReplay else { return }
                    await syncMixerToHardware()
                }
            }
            print("[Maestro] MixerView: Reloaded mixer state after recovery")
        }
        .onChange(of: appState.routingModeChangeCount) { _, _ in
            // Routing-mode and hardware-input mutes are serialized by
            // AppState; reload the snapshot without starting a second writer.
            initializeChannels()
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

    private func resetMixerDefaults() {
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
            await writeSWReturnPan(0)
            await writeSWReturnMute(false)
            await writeSWReturnSolo(false)
            await writeSoftwareReturnSource(0)
        }
    }

    // MARK: - Batch Operations

    /// Channels affected by batch operations: selected channels if any, otherwise all visible.
    private var batchTargetChannels: [Int] {
        if !selectedChannels.isEmpty {
            return selectedChannels.sorted()
        }
        return (0..<min(editor.channels.count, channelCount)).filter { isChannelVisible($0) }
    }

    /// Set mute to the same value for all target channels.
    private func batchToggleMute(newValue: Bool) {
        let targets = batchTargetChannels
        for i in targets {
            guard i < editor.channels.count else { continue }
            editor.channels[i].isMuted = newValue
            Task { await writeMute(channel: i, muted: newValue) }
        }
        // Also mute/unmute SW Return so option+click on any channel
        // includes SW Return, and option+click on SW Return itself
        // actually sends the XPC mute command to hardware.
        editor.swReturnChannel.isMuted = newValue
        Task { await writeSWReturnMute(newValue) }
        saveMixerState()
    }

    /// Clear all solos across all channels (no selection filter — solos are global).
    private func batchApplySolo(newValue: Bool) {
        for i in 0..<editor.channels.count {
            if editor.channels[i].isSoloed != newValue {
                editor.channels[i].isSoloed = newValue
                Task { await writeSolo(channel: i, solo: newValue) }
            }
        }
        // Also apply to SW Return solo
        if editor.swReturnChannel.isSoloed != newValue {
            editor.swReturnChannel.isSoloed = newValue
            Task { await writeSWReturnSolo(newValue) }
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
        // Include SW Return in batch (sentinel key -1)
        batchDragStartLevels[-1] = editor.swReturnChannel.level
    }

    /// Apply a delta to all target channel levels (clamped, preserves relative positions).
    private func batchApplyLevelDelta(delta: Double) {
        for (i, startLevel) in batchDragStartLevels {
            let newLevel = min(max(startLevel + delta, -48), 0)
            if i == -1 {
                // SW Return (sentinel key)
                editor.swReturnChannel.level = newLevel
                // One stereo fader: both handles follow.
                editor.swReturnLeftLevel = newLevel
                editor.swReturnRightLevel = newLevel
                Task { await writeSWReturnLevel(newLevel) }
            } else {
                guard i < editor.channels.count else { continue }
                editor.channels[i].level = newLevel
                levelDebounce[i]?.cancel()
                levelDebounce[i] = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(25))
                    guard !Task.isCancelled else { return }
                    await writeLevel(channel: i, level: newLevel)
                }
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
        // Include SW Return in batch (sentinel key -1)
        batchDragStartPans[-1] = editor.swReturnChannel.pan
    }

    /// Apply a delta to all target channel pans (clamped, preserves relative positions).
    private func batchApplyPanDelta(delta: Double) {
        for (i, startPan) in batchDragStartPans {
            let newPan = min(max(startPan + delta, -1.0), 1.0)
            if i == -1 {
                // SW Return (sentinel key)
                editor.swReturnChannel.pan = newPan
                Task { await writeSWReturnPan(newPan) }
            } else {
                guard i < editor.channels.count else { continue }
                editor.channels[i].pan = newPan
                panDebounce[i]?.cancel()
                panDebounce[i] = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(25))
                    guard !Task.isCancelled else { return }
                    await writePan(channel: i, pan: newPan)
                }
            }
        }
        saveMixerState()
    }

    /// Center all pans (including SW Return) — triggered by Option+click on any pan knob.
    private func batchCenterPans() {
        for i in batchTargetChannels {
            guard i < editor.channels.count else { continue }
            editor.channels[i].pan = 0
            Task { await writePan(channel: i, pan: 0) }
        }
        editor.swReturnChannel.pan = 0
        Task { await writeSWReturnPan(0) }
        saveMixerState()
    }

    /// Handle channel selection with modifier keys (Cmd, Shift, plain click).
    private func selectChannel(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            // Cmd+Click: toggle selection
            if selectedChannels.contains(index) {
                selectedChannels.remove(index)
            } else {
                selectedChannels.insert(index)
            }
        } else if modifiers.contains(.shift), let last = lastSelectedChannel {
            // Shift+Click: range select from last to clicked
            let lo = min(last, index)
            let hi = max(last, index)
            for i in lo...hi {
                selectedChannels.insert(i)
            }
        } else {
            // Plain click: select only this (or deselect if already sole selection)
            if selectedChannels == [index] {
                selectedChannels.removeAll()
            } else {
                selectedChannels = [index]
            }
        }
        lastSelectedChannel = index
    }

    private func customChannelLabel(for index: Int) -> String {
        let names = isUnitBChannel(index) ? decodeNames(unitBChannelNamesJSON) : decodeNames(channelNamesJSON)
        let local = localChannelIndex(index)
        return local < names.count ? names[local] : ""
    }

    private func channelLabel(for index: Int) -> String {
        // Board-aware default: analog channels get "Line N", digital get the
        // card's own label, both numbered by what the cards actually contribute.
        let layoutChannels = mixerChannels
        return index < layoutChannels.count ? layoutChannels[index].label : "Ch \(index + 1)"
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
        let vis = channelVisibility
        if index < vis.count {
            return vis[index]
        }
        return true // default visible
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
        // Two-unit lifecycle recall belongs to AppState even with this page closed.
        if recalling && appState.usesTwoUnitReplay { return }
        guard let device = appState.device else { return }
        let loaded = editor
        let routingMode = appState.mixerPreferences.integer(forKey: "routingMode")
        for i in 0..<min(editor.loadedChannelCount, min(editor.channels.count, channelCount)) {
            guard loaded.canEdit(appState), appState.device === device else { return }
            let ch = loaded.channels[i]
            let elem = mixerElement(channel: i)
            let effectiveMute = (routingMode == 0) ? true : ch.isMuted
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelLevel, element: elem),
                    value: .float64(ch.level))
                guard loaded.canEdit(appState), appState.device === device else { return }
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelMute, element: elem),
                    value: .bool(effectiveMute))
            } catch {
                // Non-critical — channel may not exist on this board config
            }
        }
        guard loaded.canEdit(appState), appState.device === device else { return }
        if usbDevice != nil {
            // USB: the unit's mixer owns Master and Software Return for every
            // source. The helper is written neutral inside writeSoftwareReturnSource.
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
        print("[Maestro] syncMixerToHardware: sent \(editor.channels.count) channels + master to mixer \(selectedMixer + 1) (\(routingMode == 0 ? "DAW" : "Direct Monitor"))")
    }

    /// Encode mixer element: (mixerID << 16) | channelIndex.
    /// Evidence: SymphonyIOControl.cpp:1904-1942 — (nMixer << 16) | (nChannel & 0xFFFF).
    /// selectedMixer is 0-based in UI; USB protocol mixer IDs are 1-based.
    private func mixerElement(channel: Int) -> UInt32 {
        // Strip index != hardware channel ID. Each slot owns a fixed 16-channel
        // XLink region whether or not its card fills it, so a card that supplies
        // fewer than 16 channels leaves a gap before the second slot's IDs.
        let layoutChannels = mixerChannels
        let hardwareIndex = channel < layoutChannels.count ? layoutChannels[channel].hardwareIndex : channel
        return (UInt32(selectedMixer + 1) << 16) | UInt32(hardwareIndex)
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
        Task { await writeSWReturnLevel(level) }
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
        label: "SW Return",
        appState: appState,
        mixerMeterBaseIndex: selectedMixer * 2,
        onLevelChange: { level in
            Task { await writeSWReturnLevel(level); saveMixerState() }
        },
        onPanChange: { pan in
            Task { await writeSWReturnPan(pan); saveMixerState() }
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
        onBatchPanChange: { delta in
            batchApplyPanDelta(delta: delta)
        },
        onBatchPanDragStart: {
            beginBatchPanDrag(fromChannel: -1)
        },
        onPanOptionClick: {
            batchCenterPans()
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
        // Keep SW Return pan available alongside the stereo fader. The
        // mixer model and ThunderBridge write path both support it.
        showPan: true,
        stereoLeftLevel: $editor.swReturnLeftLevel,
        stereoRightLevel: $editor.swReturnRightLevel,
        onStereoLevelChange: { level in swSideChanged(level) }
    )
    }

    private var masterReadoutRow: some View {
        VStack(spacing: 3) {
            // The empty control row every strip reserves above its readout, so
            // Unity, Mute, Solo and Output share one baseline.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: mixerControlRowHeight)

            // The original Master value field edits the stereo fader. Preserve
            // that while keeping the readout display-only until double-clicked.
            EditableLevelReadout(
                value: Binding(
                    get: { editor.masterLevel },
                    set: { newLevel in masterSideChanged(newLevel) }),
                range: -48...6,
                step: 0.5)
            .help("Master fader level: double-click to edit")
        }
        // SwiftUI points map to physical pixels on Retina;
        // two points is the observed four-pixel correction.
        .offset(y: -2)
    }

    /// The USB connection, or nil on ThunderBridge and in simulation.
    private var usbDevice: XPCDeviceConnection? { appState.device as? XPCDeviceConnection }

    private func writeLevel(channel: Int, level: Double) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelLevel, element: mixerElement(channel: channel)),
                value: .float64(level)
            )
        } catch {
            print("[Maestro] Mixer level ch\(channel) failed: \(error)")
        }
    }

    private func writePan(channel: Int, pan: Double) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelPan, element: mixerElement(channel: channel)),
                value: .float64(pan)
            )
        } catch {
            print("[Maestro] Mixer pan ch\(channel) failed: \(error)")
        }
    }

    private func writeMute(channel: Int, muted: Bool) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        let routingMode = appState.mixerPreferences.integer(forKey: "routingMode")
        let effectiveMute = (routingMode == 0) ? true : muted
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelMute, element: mixerElement(channel: channel)),
                value: .bool(effectiveMute)
            )
        } catch {
            print("[Maestro] Mixer mute ch\(channel) failed: \(error)")
        }
    }

    private func writeSolo(channel: Int, solo: Bool) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelSolo, element: mixerElement(channel: channel)),
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
        masterDebounce?.cancel()
        masterDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { return }
            await writeMasterLevel(level)
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

    private func writeSWReturnPan(_ pan: Double) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        if let xpcDev = usbDevice {
            // The unit's Software Return strip has no pan. Over USB the pan is a
            // balance in the helper, which only sees USB playback 1-2.
            if editor.softwareReturnSource == 0 { xpcDev.setSwReturnPan(pan) }
        } else {
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelPan, element: swReturnElement),
                    value: .float64(pan)
                )
            } catch {
                print("[Maestro] Mixer SW Return pan failed: \(error)")
            }
        }
    }

    private func writeSWReturnMute(_ muted: Bool) async {
        guard editor.canEdit(appState) else { return }
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelMute, element: swReturnElement),
                value: .bool(muted)
            )
        } catch {
            print("[Maestro] Mixer SW Return mute failed: \(error)")
        }
    }

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
            let writes: [(AudioPropertySelector, PropertyValue)] = [
                (.mixerChannelLevel, .float64(level)),
                (.mixerChannelMute, .bool(editor.swReturnChannel.isMuted)),
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
            xpcDev.setHelperNeutral()
            let otherMixer = selectedMixer == 0 ? 1 : 0
            let otherSource = UInt32(appState.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\(otherMixer)"))
            xpcDev.setSwReturnProcessing(source == 0 || otherSource == 0)
            if source == 0 { await writeSWReturnPan(editor.swReturnChannel.pan) }
        } else {
            // ThunderBridge: the FPGA mixer processes every source. Mirror the
            // current persisted state into its software-return input controls.
            let swReturnChannel = editor.swReturnChannel
            await writeSWReturnLevel(swReturnChannel.level)
            await writeSWReturnPan(swReturnChannel.pan)
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
        HStack(alignment: .top, spacing: 4) {
            LEDMeterView(
                level: left,
                peak: left,
                label: "L",
                height: 200,
                width: 8,
                showScale: true,
                scaleOnLeft: true,
                rangeDB: 48,
                showZoneColoring: appState.showMeterZoneColoring,
                labelOffsetX: 8,
                labelOffsetY: -10
            )
            LEDMeterView(
                level: right,
                peak: right,
                label: "R",
                height: 200,
                width: 8,
                rangeDB: 48,
                showZoneColoring: appState.showMeterZoneColoring
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
    /// Whether this strip exposes its pan control. SW Return enables this for
    /// the ThunderBridge mixer path; strips that use fixed stereo routing can
    /// still reserve the same lane by setting this false.
    var showPan: Bool = true
    var stereoLeftLevel: Binding<Double>? = nil
    var stereoRightLevel: Binding<Double>? = nil
    /// A stereo fader handle or its readout moved: the new level for both sides.
    var onStereoLevelChange: ((Double) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// Height for the fader+meter area (matches Input/Output strip meter height).
    private let faderHeight: CGFloat = 200

    private var resolvedMeterLevels: (left: Double, right: Double?) {
        if let appState, let index = inputMeterIndex {
            let rawInput = appState.mixerInputMeterLevel(strip: index)
            let level: Double
            if channel.isMuted && !preMuteMetering {
                level = -60.0
            } else if channel.isMuted {
                level = max(rawInput, -60.0)
            } else {
                level = max(rawInput + channel.level, -60.0)
            }
            return (level, nil)
        }
        if let appState, let baseIndex = mixerMeterBaseIndex {
            guard baseIndex + 1 < appState.mixerMeterLevels.count else {
                return (-60.0, -60.0)
            }
            return (
                appState.mixerMeterLevels[baseIndex],
                appState.mixerMeterLevels[baseIndex + 1]
            )
        }
        return (meterLevel, meterLevelR)
    }

    /// Format pan as "0" at center, "+N"/"-N" otherwise.
    private var panText: String {
        let intPan = Int(round(channel.pan * 100))
        if intPan == 0 { return "0" }
        return String(format: "%+d", intPan)
    }

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
                    step: 0.05,
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
                .help("Pan: \(panText) — double-click to center, Option+click center all, Option+drag all")
                .onChange(of: channel.pan) { _, newPan in
                    onPanChange?(newPan)
                }

                // Pan value — pill readout ("0" at center, not "+0")
                Text(panText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))

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
                    step: 0.5,
                    defaultValue: 0,
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
                        step: 0.5,
                        defaultValue: 0,
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
                        peak: resolvedMeters.left,
                        label: "L",
                        height: faderHeight,
                        width: 8,
                        showScale: true,
                        scaleOnLeft: true,
                        rangeDB: 48,
                        showZoneColoring: showZoneColoring,
                        labelOffsetX: 8,
                        labelOffsetY: -10
                    )
                    LEDMeterView(
                        level: rightLevel,
                        peak: rightLevel,
                        label: "R",
                        height: faderHeight,
                        width: 8,
                        rangeDB: 48,
                        showZoneColoring: showZoneColoring
                    )
                } else {
                    // Mono: single meter
                    LEDMeterView(
                        level: resolvedMeters.left,
                        peak: resolvedMeters.left,
                        label: "",
                        height: faderHeight,
                        width: 10,
                        showScale: true,
                        scaleOnLeft: true,
                        rangeDB: 48,
                        showZoneColoring: showZoneColoring
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
                .frame(height: mixerControlRowHeight)

            if stereoLeftLevel != nil, stereoRightLevel != nil {
                // The legacy Software Return value field is editable and
                // controls the stereo fader.
                EditableLevelReadout(
                    value: Binding(
                        get: { stereoLeftLevel?.wrappedValue ?? channel.level },
                        set: { newValue in onStereoLevelChange?(newValue) }),
                    range: -48...6,
                    step: 0.5)
                .help("Software Return fader level: double-click to edit")
            } else {
                // dB readout (level) — single readout, no duplicate
                EditableLevelReadout(value: $channel.level, range: -48...6, step: 0.5)
                    .help("Fader Level: \(String(format: "%.1f", channel.level)) dB — double-click to edit")
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
                .help("Mute (Option+Click: all channels)")

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
                .help("Solo (Option+Click: clear all solos)")
            }

            // Mixer Custom Label — a user-editable label distinct from the
            // hardware/card label at the top of the strip.
            if let sourceBinding = softwareReturnSource {
                PillMenu(
                    text: sourceBinding.wrappedValue < UInt32(softwareReturnPairCount)
                        ? TwoUnitMixer.softwareReturnName(sourceBinding.wrappedValue) : "1-2",
                    fontSize: 9,
                    pillHeight: 22,
                    toolTip: "Software Return source — selects the DAW stereo pair feeding this mixer",
                    options: (0..<UInt32(softwareReturnPairCount)).map { source in
                        (TwoUnitMixer.softwareReturnName(source), {
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
                .help("Mixer Custom Label — names this input channel in both mixers")
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

/// Compact legacy-style dB readout. It is display-only until double-clicked,
/// then accepts a bounded, half-dB value and commits with Return (Escape
/// cancels). Keeping this outside FaderView also lets the parent align one
/// readout beneath a stereo fader pair, as the original Maestro did.
private struct EditableLevelReadout: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    private func formatted(_ number: Double) -> String {
        String(format: step >= 1 ? "%.0f" : "%.1f", number)
    }

    private func finishEditing(commit: Bool) {
        if commit, let parsed = Double(editText), parsed.isFinite {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            value = (clamped / step).rounded() * step
        }
        fieldFocused = false
        isEditing = false
        NSApp.keyWindow?.endEditing(for: nil)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $editText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { finishEditing(commit: true) }
                    .onExitCommand { finishEditing(commit: false) }
                    .onAppear {
                        DispatchQueue.main.async {
                            fieldFocused = true
                            // Wait for AppKit to install the field editor before
                            // selecting, so the first keystroke replaces the
                            // displayed value instead of appending to it.
                            DispatchQueue.main.async {
                            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                            }
                        }
                    }
            } else {
                Text(formatted(value))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onTapGesture {
                        editText = formatted(value)
                        isEditing = true
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
    }
}
