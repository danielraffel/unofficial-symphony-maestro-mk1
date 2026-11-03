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
    /// Strip state, one entry per entry in `layout.mixerChannels`.
    /// Restored before the first body evaluation so SW Return and Master never
    /// render on their own while the input strips are still being prepared.
    @State private var channels: [MixerChannelState]
    @State private var masterLevel: Double
    @State private var masterLeftLevel: Double
    @State private var masterRightLevel: Double
    @State private var masterFadersLinked: Bool
    @State private var swReturnChannel: MixerChannelState
    @State private var swReturnLeftLevel: Double
    @State private var swReturnRightLevel: Double
    @State private var swReturnFadersLinked: Bool
    @State private var softwareReturnSource: UInt32
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
        let snapshot = MixerStateSnapshot(
            channelCount: appState.cardLayout.mixerChannels.count,
            mixer: 0,
            store: appState.channelStateStore)
        _channels = State(initialValue: snapshot.channels)
        _swReturnChannel = State(initialValue: snapshot.swReturnChannel)
        let swLevel = snapshot.swReturnChannel.level
        _swReturnLeftLevel = State(initialValue: UserDefaults.standard.object(forKey: "mixerSWReturnLeftLevel_0") as? Double ?? swLevel)
        _swReturnRightLevel = State(initialValue: UserDefaults.standard.object(forKey: "mixerSWReturnRightLevel_0") as? Double ?? swLevel)
        _swReturnFadersLinked = State(initialValue: UserDefaults.standard.object(forKey: "mixerSWReturnFadersLinked") as? Bool ?? true)
        _softwareReturnSource = State(initialValue: snapshot.softwareReturnSource)
        _masterLevel = State(initialValue: snapshot.masterLevel)
        _masterLeftLevel = State(initialValue: UserDefaults.standard.object(forKey: "mixerMasterLeftLevel_0") as? Double ?? snapshot.masterLevel)
        _masterRightLevel = State(initialValue: UserDefaults.standard.object(forKey: "mixerMasterRightLevel_0") as? Double ?? snapshot.masterLevel)
        _masterFadersLinked = State(initialValue: UserDefaults.standard.object(forKey: "mixerMasterFadersLinked") as? Bool ?? true)
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
    @AppStorage("mixerChannelNames") private var channelNamesJSON: String = "[]"

    // P3F-16: Channel visibility — stored in UserDefaults
    @AppStorage("mixerChannelVisibility") private var channelVisibilityJSON: String = "[]"

    /// When enabled, mixer meters show input signal level regardless of mute state.
    /// When disabled, meters drop to silence when a channel is muted (post-mute metering).
    @AppStorage("mixerPreMuteMetering") private var preMuteMetering: Bool = true

    /// Symphony IO MKI has 2 usable low-latency mixers.
    /// Evidence: SymphonyIOVendorSpecific.h — kSymphonyIOMixerCount.
    private let mixerCount = 2

    private var channelNames: [String] {
        get {
            (try? JSONDecoder().decode([String].self, from: Data(channelNamesJSON.utf8))) ?? []
        }
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
    private var mixerChannels: [CardLayout.MixerChannel] { layout.mixerChannels }

    private var channelCount: Int { mixerChannels.count }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar row — Mixer selector + channel visibility (matches Input/Output toolbar style)
            HStack {
                Button("Mix 1") { selectedMixer = 0; initializeChannels(); Task { await syncMixerToHardware() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selectedMixer == 0 ? .accentColor : nil)

                Button("Mix 2") { selectedMixer = 1; initializeChannels(); Task { await syncMixerToHardware() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selectedMixer == 1 ? .accentColor : nil)

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
                    ForEach(Array(0..<min(channels.count, channelCount)), id: \.self) { i in
                        if isChannelVisible(i) {
                            MixerChannelStripView(
                                channel: $channels[i],
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
                    MixerChannelStripView(
                        channel: $swReturnChannel,
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
                        softwareReturnSource: $softwareReturnSource,
                        onSoftwareReturnSourceChange: { source in
                            softwareReturnSource = source
                            Task { await writeSoftwareReturnSource(source); saveMixerState() }
                        },
                        showZoneColoring: appState.showMeterZoneColoring,
                        stereoFader: true,
                        // Keep SW Return pan available alongside the linked or
                        // independent stereo faders. The mixer model and
                        // ThunderBridge write path both support this control.
                        showPan: true,
                        stereoLeftLevel: $swReturnLeftLevel,
                        stereoRightLevel: $swReturnRightLevel,
                        stereoFadersLinked: $swReturnFadersLinked,
                        onStereoLeftLevelChange: { level in
                            swReturnLeftLevel = level
                            if swReturnFadersLinked {
                                swReturnRightLevel = level
                                Task { await writeSWReturnLevel(level) }
                            } else {
                                Task { await writeSWReturnSideLevel(side: 0, level: level) }
                            }
                            swReturnChannel.level = swReturnFadersLinked ? level : swReturnChannel.level
                            saveMixerState()
                        },
                        onStereoRightLevelChange: { level in
                            swReturnRightLevel = level
                            if swReturnFadersLinked {
                                swReturnLeftLevel = level
                                Task { await writeSWReturnLevel(level) }
                            } else {
                                Task { await writeSWReturnSideLevel(side: 1, level: level) }
                            }
                            swReturnChannel.level = swReturnFadersLinked ? level : swReturnChannel.level
                            saveMixerState()
                        },
                        onStereoLinkChange: { linked in
                            swReturnFadersLinked = linked
                            if linked {
                                let level = (swReturnLeftLevel + swReturnRightLevel) / 2.0
                                swReturnLeftLevel = level
                                swReturnRightLevel = level
                                swReturnChannel.level = level
                                Task { await writeSWReturnLevel(level) }
                            } else {
                                Task {
                                    await writeSWReturnSideLevel(side: 0, level: swReturnLeftLevel)
                                    await writeSWReturnSideLevel(side: 1, level: swReturnRightLevel)
                                }
                            }
                            saveMixerState()
                        }
                    )

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
                                value: $masterLeftLevel,
                                range: -48...6,
                                step: 0.5,
                                defaultValue: 0,
                                height: 200,
                                showScale: false,
                                externalReadout: true,
                                onUserChange: { newLevel in
                                    // Keep the editable readout driven by the
                                    // same state as the fader even when the
                                    // control's gesture is the mutation source.
                                    masterLeftLevel = newLevel
                                    if masterFadersLinked { masterRightLevel = newLevel; masterLevel = newLevel }
                                    scheduleMasterSideWrite(side: 0, level: newLevel)
                                },
                                thumbWidth: 22
                            )

                            FaderView(
                                value: $masterRightLevel,
                                range: -48...6,
                                step: 0.5,
                                defaultValue: 0,
                                height: 200,
                                showScale: false,
                                externalReadout: true,
                                onUserChange: { newLevel in
                                    masterRightLevel = newLevel
                                    if masterFadersLinked { masterLeftLevel = newLevel; masterLevel = newLevel }
                                    scheduleMasterSideWrite(side: 1, level: newLevel)
                                },
                                thumbWidth: 22
                            )

                            // Keep meter observation inside this child view so
                            // 20 Hz meter updates do not rebuild every strip.
                            MixerMasterMetersView(
                                appState: appState,
                                mixerIndex: selectedMixer
                            )
                        }

                        // Reserve the same link row used by channel strips. The
                        // link button sits above Unity instead of overlapping the
                        // meter, so every Unity/Mute/Solo/Output row aligns.
                        // Master needs a small final optical adjustment to align
                        // its Link/Unity group with the other strips.
                        VStack(spacing: 3) {
                            Button {
                                masterFadersLinked.toggle()
                                if masterFadersLinked {
                                    let level = (masterLeftLevel + masterRightLevel) / 2.0
                                    masterLeftLevel = level
                                    masterRightLevel = level
                                    masterLevel = level
                                    Task { await writeMasterLevel(level); saveMixerState() }
                                } else {
                                    Task {
                                        await writeMasterSideLevel(side: 0, level: masterLeftLevel)
                                        await writeMasterSideLevel(side: 1, level: masterRightLevel)
                                    }
                                    saveMixerState()
                                }
                                } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(masterFadersLinked ? Color.accentColor : Color(.controlBackgroundColor))
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                                    Image(systemName: "link")
                                        .foregroundStyle(masterFadersLinked ? Color.white : Color.secondary)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: mixerControlRowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .frame(height: mixerControlRowHeight)
                            .contentShape(Rectangle())
                            .accessibilityLabel(masterFadersLinked ? "Unlink left and right master faders" : "Link left and right master faders")
                                .help(masterFadersLinked ? "Unlink left and right master faders" : "Link left and right master faders")

                            if masterFadersLinked {
                                // The original Master value field edits the
                                // linked stereo pair. Preserve that behavior
                                // while keeping the readout display-only until
                                // double-clicked.
                                EditableLevelReadout(
                                    value: Binding(
                                        get: { masterLevel },
                                        set: { newLevel in
                                            masterLevel = newLevel
                                            masterLeftLevel = newLevel
                                            masterRightLevel = newLevel
                                            scheduleMasterSideWrite(side: 0, level: newLevel)
                                        }),
                                    range: -48...6,
                                    step: 0.5)
                                .help("Master fader level: double-click to edit")
                        } else {
                            HStack(spacing: 3) {
                                EditableLevelReadout(value: Binding(
                                    get: { masterLeftLevel },
                                    set: { newValue in
                                        masterLeftLevel = newValue
                                        scheduleMasterSideWrite(side: 0, level: newValue)
                                    }), range: -48...6, step: 0.5)
                                    .help("Left master fader level: double-click to edit")
                                EditableLevelReadout(value: Binding(
                                    get: { masterRightLevel },
                                    set: { newValue in
                                        masterRightLevel = newValue
                                        scheduleMasterSideWrite(side: 1, level: newValue)
                                    }), range: -48...6, step: 0.5)
                                    .help("Right master fader level: double-click to edit")
                            }
                            }
                        }
                        // SwiftUI points map to physical pixels on Retina;
                        // two points is the observed four-pixel correction.
                        .offset(y: -2)

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
        .navigationTitle("Mixer \(selectedMixer + 1)")
        .task {
            // Local state is already complete; only hardware synchronization
            // waits for this task. No partial strip layout is exposed meanwhile.
            ensureNamesAndVisibility()
            await syncMixerToHardware()
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
            Task { await syncMixerToHardware() }
        }

        .onChange(of: appState.deviceRecoveryCount) { _, _ in
            // USB recovered after power cycle/sleep — FPGA reset to defaults.
            // Reload persisted mixer state and re-sync to hardware.
            initializeChannels()
            Task {
                await syncMixerToHardware()
                // Re-sync SW Return to proxy
                await writeSWReturnMute(swReturnChannel.isMuted)
                await writeSWReturnLevel(swReturnChannel.level)
                await writeSWReturnPan(swReturnChannel.pan)
                await writeSoftwareReturnSource(softwareReturnSource)
            }
            print("[Maestro] MixerView: Re-synced mixer state after USB recovery")
        }
        .onChange(of: appState.routingModeChangeCount) { _, _ in
            Task { await syncMixerToHardware() }
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
        channels = Array(repeating: empty, count: channels.count)
        swReturnChannel = empty
        swReturnLeftLevel = 0
        swReturnRightLevel = 0
        softwareReturnSource = 0
        masterLevel = 0
        masterLeftLevel = 0
        masterRightLevel = 0
        saveMixerState()
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
        return (0..<min(channels.count, channelCount)).filter { isChannelVisible($0) }
    }

    /// Set mute to the same value for all target channels.
    private func batchToggleMute(newValue: Bool) {
        let targets = batchTargetChannels
        for i in targets {
            guard i < channels.count else { continue }
            channels[i].isMuted = newValue
            Task { await writeMute(channel: i, muted: newValue) }
        }
        // Also mute/unmute SW Return so option+click on any channel
        // includes SW Return, and option+click on SW Return itself
        // actually sends the XPC mute command to hardware.
        swReturnChannel.isMuted = newValue
        Task { await writeSWReturnMute(newValue) }
        saveMixerState()
    }

    /// Clear all solos across all channels (no selection filter — solos are global).
    private func batchApplySolo(newValue: Bool) {
        for i in 0..<channels.count {
            if channels[i].isSoloed != newValue {
                channels[i].isSoloed = newValue
                Task { await writeSolo(channel: i, solo: newValue) }
            }
        }
        // Also apply to SW Return solo
        if swReturnChannel.isSoloed != newValue {
            swReturnChannel.isSoloed = newValue
            Task { await writeSWReturnSolo(newValue) }
        }
        saveMixerState()
    }

    /// Snapshot current levels for batch drag start.
    private func beginBatchLevelDrag(fromChannel: Int) {
        batchDragStartLevels = [:]
        for i in batchTargetChannels {
            guard i < channels.count else { continue }
            batchDragStartLevels[i] = channels[i].level
        }
        // Include SW Return in batch (sentinel key -1)
        batchDragStartLevels[-1] = swReturnChannel.level
    }

    /// Apply a delta to all target channel levels (clamped, preserves relative positions).
    private func batchApplyLevelDelta(delta: Double) {
        for (i, startLevel) in batchDragStartLevels {
            let newLevel = min(max(startLevel + delta, -48), 0)
            if i == -1 {
                // SW Return (sentinel key)
                swReturnChannel.level = newLevel
                Task { await writeSWReturnLevel(newLevel) }
            } else {
                guard i < channels.count else { continue }
                channels[i].level = newLevel
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
            guard i < channels.count else { continue }
            batchDragStartPans[i] = channels[i].pan
        }
        // Include SW Return in batch (sentinel key -1)
        batchDragStartPans[-1] = swReturnChannel.pan
    }

    /// Apply a delta to all target channel pans (clamped, preserves relative positions).
    private func batchApplyPanDelta(delta: Double) {
        for (i, startPan) in batchDragStartPans {
            let newPan = min(max(startPan + delta, -1.0), 1.0)
            if i == -1 {
                // SW Return (sentinel key)
                swReturnChannel.pan = newPan
                Task { await writeSWReturnPan(newPan) }
            } else {
                guard i < channels.count else { continue }
                channels[i].pan = newPan
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
            guard i < channels.count else { continue }
            channels[i].pan = 0
            Task { await writePan(channel: i, pan: 0) }
        }
        swReturnChannel.pan = 0
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
        let names = channelNames
        return index < names.count ? names[index] : ""
    }

    private func channelLabel(for index: Int) -> String {
        // Board-aware default: analog channels get "Line N", digital get the
        // card's own label, both numbered by what the cards actually contribute.
        let channels = mixerChannels
        return index < channels.count ? channels[index].label : "Ch \(index + 1)"
    }

    private func setCustomChannelLabel(_ value: String, for index: Int) {
        var names = channelNames
        if names.count <= index {
            names.append(contentsOf: Array(repeating: "", count: index + 1 - names.count))
        }
        names[index] = value
        if let data = try? JSONEncoder().encode(names) {
            channelNamesJSON = String(data: data, encoding: .utf8) ?? "[]"
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
        let count = channelCount
        var names = channelNames
        if names.count < count {
            names.append(contentsOf: Array(repeating: "", count: count - names.count))
            if let data = try? JSONEncoder().encode(names) {
                channelNamesJSON = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
        var vis = channelVisibility
        if vis.count < count {
            vis.append(contentsOf: Array(repeating: true, count: count - vis.count))
            if let data = try? JSONEncoder().encode(vis) {
                channelVisibilityJSON = String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    private func initializeChannels() {
        let snapshot = MixerStateSnapshot(
            channelCount: channelCount,
            mixer: selectedMixer,
            store: appState.channelStateStore)
        channels = snapshot.channels
        swReturnChannel = snapshot.swReturnChannel
        softwareReturnSource = snapshot.softwareReturnSource
        masterLevel = snapshot.masterLevel
        let swLevel = snapshot.swReturnChannel.level
        swReturnLeftLevel = UserDefaults.standard.object(forKey: "mixerSWReturnLeftLevel_\(selectedMixer)") as? Double ?? swLevel
        swReturnRightLevel = UserDefaults.standard.object(forKey: "mixerSWReturnRightLevel_\(selectedMixer)") as? Double ?? swLevel
        masterLeftLevel = UserDefaults.standard.object(forKey: "mixerMasterLeftLevel_\(selectedMixer)") as? Double ?? snapshot.masterLevel
        masterRightLevel = UserDefaults.standard.object(forKey: "mixerMasterRightLevel_\(selectedMixer)") as? Double ?? snapshot.masterLevel
    }

    /// Persist current mixer channel states to UserDefaults.
    private func saveMixerState() {
        appState.channelStateStore.save(channels, for: ChannelStateStore.mixerKey(selectedMixer))
        if let data = try? JSONEncoder().encode(swReturnChannel) {
            UserDefaults.standard.set(data, forKey: "mixerState_swReturn")
        }
        UserDefaults.standard.set(masterLevel, forKey: "mixerMasterLevel_\(selectedMixer)")
        UserDefaults.standard.set(swReturnLeftLevel, forKey: "mixerSWReturnLeftLevel_\(selectedMixer)")
        UserDefaults.standard.set(swReturnRightLevel, forKey: "mixerSWReturnRightLevel_\(selectedMixer)")
        UserDefaults.standard.set(masterLeftLevel, forKey: "mixerMasterLeftLevel_\(selectedMixer)")
        UserDefaults.standard.set(masterRightLevel, forKey: "mixerMasterRightLevel_\(selectedMixer)")
        UserDefaults.standard.set(swReturnFadersLinked, forKey: "mixerSWReturnFadersLinked")
        UserDefaults.standard.set(masterFadersLinked, forKey: "mixerMasterFadersLinked")
        UserDefaults.standard.set(softwareReturnSource, forKey: "mixerSoftwareReturnSource_\(selectedMixer)")
        // Keep the ThunderBridge SW Return meters in step with the faders/pan/mute.
        appState.refreshSoftwareReturnMeterGains()
    }

    /// Send all mixer channel states to hardware on startup/mixer switch.
    /// The FPGA doesn't persist mixer state — it powers up with defaults that
    /// may not match the UI, causing silent channels until user interaction.
    private func syncMixerToHardware() async {
        guard let device = appState.device else { return }
        let routingMode = UserDefaults.standard.integer(forKey: "routingMode")
        for i in 0..<min(channels.count, channelCount) {
            let ch = channels[i]
            let elem = mixerElement(channel: i)
            let effectiveMute = (routingMode == 0) ? true : ch.isMuted
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelLevel, element: elem),
                    value: .float64(ch.level))
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelMute, element: elem),
                    value: .bool(effectiveMute))
            } catch {
                // Non-critical — channel may not exist on this board config
            }
        }
        // Master level
        do {
            let masterElem = (UInt32(selectedMixer + 1) << 16) | 2000
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelLevel, element: masterElem),
                value: .float64(masterLevel))
        } catch {}
        if !masterFadersLinked {
            await writeMasterSideLevel(side: 0, level: masterLeftLevel)
            await writeMasterSideLevel(side: 1, level: masterRightLevel)
        }
        await writeSoftwareReturnSource(softwareReturnSource)
        // USB 1–2 is processed in the proxy rather than by the FPGA mixer.
        // Restore its persisted controls on normal startup and mixer switches,
        // not only after USB recovery.
        if device is XPCDeviceConnection, softwareReturnSource == 0 {
            await writeSWReturnMute(swReturnChannel.isMuted)
            if swReturnFadersLinked {
                await writeSWReturnLevel(swReturnLeftLevel)
            } else {
                await writeSWReturnSideLevel(side: 0, level: swReturnLeftLevel)
                await writeSWReturnSideLevel(side: 1, level: swReturnRightLevel)
            }
            await writeSWReturnPan(swReturnChannel.pan)
            await writeSWReturnSolo(swReturnChannel.isSoloed)
        } else if !swReturnFadersLinked {
            await writeSWReturnSideLevel(side: 0, level: swReturnLeftLevel)
            await writeSWReturnSideLevel(side: 1, level: swReturnRightLevel)
        }
        print("[Maestro] syncMixerToHardware: sent \(channels.count) channels + master to mixer \(selectedMixer + 1) (\(routingMode == 0 ? "DAW" : "Direct Monitor"))")
    }

    /// Encode mixer element: (mixerID << 16) | channelIndex.
    /// Evidence: SymphonyIOControl.cpp:1904-1942 — (nMixer << 16) | (nChannel & 0xFFFF).
    /// selectedMixer is 0-based in UI; USB protocol mixer IDs are 1-based.
    private func mixerElement(channel: Int) -> UInt32 {
        // Strip index != hardware channel ID. Each slot owns a fixed 16-channel
        // XLink region whether or not its card fills it, so a card that supplies
        // fewer than 16 channels leaves a gap before the second slot's IDs.
        let channels = mixerChannels
        let hardwareIndex = channel < channels.count ? channels[channel].hardwareIndex : channel
        return (UInt32(selectedMixer + 1) << 16) | UInt32(hardwareIndex)
    }

    /// Master fader element: (mixerID << 16) | 2000.
    /// Evidence: SymphonyIOVendorSpecific.h — kSymphonyIOMixerChannelID_MasterOutput = 2000.
    private var masterElement: UInt32 {
        (UInt32(selectedMixer + 1) << 16) | 2000
    }

    /// Software return element: (mixerID << 16) | 1000.
    /// Evidence: SymphonyIOVendorSpecific.h — kSymphonyIOMixerChannelID_SoftwareReturnInput = 1000.
    /// USB protocol mixer IDs are 1-based.
    private var swReturnElement: UInt32 {
        (UInt32(selectedMixer + 1) << 16) | 1000
    }

    /// Legacy CoreAudio mixer descriptors identify stereo sides with the
    /// SoftwareReturn/Master bit plus side number (1 = L, 2 = R).  The
    /// reserved 1000/2000 IDs remain the linked-pair form.
    private func stereoMixerElement(base: UInt32, side: Int) -> UInt32 {
        let bit = base == 1000 ? 0x1000 : 0x2000
        return (UInt32(selectedMixer + 1) << 16) | UInt32(bit | (side == 0 ? 1 : 2))
    }

    private func writeLevel(channel: Int, level: Double) async {
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
        guard let device = appState.device else { return }
        let routingMode = UserDefaults.standard.integer(forKey: "routingMode")
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
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelLevel, element: masterElement),
                value: .float64(level)
            )
        } catch {
            print("[Maestro] Mixer master level failed: \(error)")
        }
    }

    private func writeMasterSideLevel(side: Int, level: Double) async {
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .mixerChannelLevel,
                                element: stereoMixerElement(base: 2000, side: side)),
                value: .float64(level))
        } catch {
            print("[Maestro] Mixer master side \(side + 1) failed: \(error)")
        }
    }

    private func scheduleMasterSideWrite(side: Int, level: Double) {
        masterDebounce?.cancel()
        masterDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { return }
            if masterFadersLinked {
                await writeMasterLevel(level)
            } else {
                await writeMasterSideLevel(side: side, level: level)
            }
            saveMixerState()
        }
    }

    // MARK: - Software Return writes (P3F-38)

    // On USB the software return is a software gain/pan in the proxy render callback
    // (the USB audio path bypasses the FPGA mixer). On Thunderbolt audio flows through
    // the FPGA, so the SW return is a real FPGA mixer input channel (id 1000) driven by
    // the same 0xB0-0xB3 vendor commands as normal strips — route it through setProperty
    // with swReturnElement, exactly like writeLevel/Pan/Mute/Solo. (Entitlement landed
    // 2026-07-14 → the dext IOUserClient path now works.)
    private func writeSWReturnLevel(_ level: Double) async {
        guard let device = appState.device else { return }
        if let xpcDev = device as? XPCDeviceConnection, softwareReturnSource == 0 {
            xpcDev.setSwReturnLevel(level)
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

    private func writeSWReturnSideLevel(side: Int, level: Double) async {
        guard let device = appState.device else { return }
        if let xpcDev = device as? XPCDeviceConnection, softwareReturnSource == 0 {
            xpcDev.setSwReturnChannelLevel(channel: side, dB: level)
        } else {
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelLevel,
                                    element: stereoMixerElement(base: 1000, side: side)),
                    value: .float64(level))
            } catch {
                print("[Maestro] Mixer SW Return side \(side + 1) failed: \(error)")
            }
        }
    }

    private func writeSWReturnPan(_ pan: Double) async {
        guard let device = appState.device else { return }
        if let xpcDev = device as? XPCDeviceConnection, softwareReturnSource == 0 {
            xpcDev.setSwReturnPan(pan)
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
        guard let device = appState.device else { return }
        if let xpcDev = device as? XPCDeviceConnection, softwareReturnSource == 0 {
            xpcDev.setSwReturnMute(muted)
        } else {
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelMute, element: swReturnElement),
                    value: .bool(muted)
                )
            } catch {
                print("[Maestro] Mixer SW Return mute failed: \(error)")
            }
        }
    }

    private func writeSWReturnSolo(_ solo: Bool) async {
        guard let device = appState.device else { return }
        if let xpcDev = device as? XPCDeviceConnection, softwareReturnSource == 0 {
            let mixer = UInt16(selectedMixer + 1)
            xpcDev.sendMixerParam(usbCmd: 0xB2, mixer: mixer, channel: 1000, value: solo ? 1 : 0)
        } else {
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .mixerChannelSolo, element: swReturnElement),
                    value: .bool(solo)
                )
        } catch {
            print("[Maestro] Mixer SW Return solo failed: \(error)")
        }
        }
    }

    /// Route the selected USB playback stereo pair into this mixer's Software
    /// Return input, matching the legacy AEsR property.
    private func writeSoftwareReturnSource(_ source: UInt32) async {
        guard let device = appState.device,
              SymphonyIOSoftwareReturnSource(rawValue: source) != nil else { return }
        do {
            let element = UInt32(selectedMixer + 1) << 16
            try await device.setProperty(
                PropertyAddress(selector: .mixerSoftwareReturnID, element: element),
                value: .uint32(source))
        } catch DeviceConnectionError.unsupportedProperty(_) {
            // Software-return routing is unavailable on some hardware paths;
            // keep the rest of the mixer usable without a false error.
        } catch {
            print("[Maestro] Mixer SW Return source failed: \(error)")
        }
        if let xpcDev = device as? XPCDeviceConnection {
            let otherMixer = selectedMixer == 0 ? 1 : 0
            let otherSource = UInt32(UserDefaults.standard.integer(
                forKey: "mixerSoftwareReturnSource_\(otherMixer)"))
            xpcDev.setSwReturnProcessing(source == 0 || otherSource == 0)
        }
        if device is XPCDeviceConnection && source == 0 {
            // The USB proxy owns the default pair's fader/pan/mute. Clear any
            // stale FPGA controls left behind by a previously selected pair.
            // ThunderBridge source 0 is different: it is the card FPGA's
            // actual host-playback return, so it must restore the persisted
            // mixer state instead of being reset when Maestro opens.
            try? await device.setProperty(
                PropertyAddress(selector: .mixerChannelLevel, element: swReturnElement),
                value: .float64(0))
            try? await device.setProperty(
                PropertyAddress(selector: .mixerChannelPan, element: swReturnElement),
                value: .float64(0))
            try? await device.setProperty(
                PropertyAddress(selector: .mixerChannelMute, element: swReturnElement),
                value: .bool(false))
            try? await device.setProperty(
                PropertyAddress(selector: .mixerChannelSolo, element: swReturnElement),
                value: .bool(false))
        } else {
            // Non-default pairs, and the ThunderBridge default pair, are
            // processed by the FPGA mixer. Mirror the current persisted state
            // into its software-return input controls.
            if swReturnFadersLinked {
                await writeSWReturnLevel(swReturnChannel.level)
            } else {
                await writeSWReturnSideLevel(side: 0, level: swReturnLeftLevel)
                await writeSWReturnSideLevel(side: 1, level: swReturnRightLevel)
            }
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
    var onSoftwareReturnSourceChange: ((UInt32) -> Void)? = nil
    var showZoneColoring: Bool = false
    /// Legacy Maestro draws independent L/R faders for stereo returns. They are
    /// linked by default, but the link control below can now address each side
    /// independently using the side-specific mixer element.
    var stereoFader: Bool = false
    /// Whether this strip exposes its pan control. SW Return enables this for
    /// the ThunderBridge mixer path; strips that use fixed stereo routing can
    /// still reserve the same lane by setting this false.
    var showPan: Bool = true
    var stereoLeftLevel: Binding<Double>? = nil
    var stereoRightLevel: Binding<Double>? = nil
    var stereoFadersLinked: Binding<Bool>? = nil
    var onStereoLeftLevelChange: ((Double) -> Void)? = nil
    var onStereoRightLevelChange: ((Double) -> Void)? = nil
    var onStereoLinkChange: ((Bool) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// Height for the fader+meter area (matches Input/Output strip meter height).
    private let faderHeight: CGFloat = 200

    private var resolvedMeterLevels: (left: Double, right: Double?) {
        if let appState, let index = inputMeterIndex {
            let rawInput = index < appState.inputMeterLevels.count
                ? appState.inputMeterLevels[index] : -60.0
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
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
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
                            if stereoLeftLevel != nil { onStereoLeftLevelChange?(newLevel) }
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
                            if stereoRightLevel != nil { onStereoRightLevelChange?(newLevel) }
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

            // Reserve the same link row in every strip. Stereo strips use it for
            // the link control; mono strips leave it empty. This keeps Unity,
            // Mute, Solo, and Output on one shared horizontal baseline instead
            // of floating the stereo controls over the meter or pushing them
            // below the neighboring channels.
            if let linked = stereoFadersLinked {
                    Button {
                        onStereoLinkChange?(!linked.wrappedValue)
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(linked.wrappedValue ? Color.accentColor : Color(.controlBackgroundColor))
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                            Image(systemName: "link")
                                .foregroundStyle(linked.wrappedValue ? Color.white : Color.secondary)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: mixerControlRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .frame(height: mixerControlRowHeight)
                    .contentShape(Rectangle())
                    .accessibilityLabel(linked.wrappedValue ? "Unlink left and right faders" : "Link left and right faders")
                    .help(linked.wrappedValue ? "Unlink left and right faders" : "Link left and right faders")
            } else {
                // Keep mono strips on the same control-row grid without
                // showing a meaningless link affordance.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: mixerControlRowHeight)
            }

            if let left = stereoLeftLevel, let right = stereoRightLevel,
               let linked = stereoFadersLinked {
                if linked.wrappedValue {
                        // The legacy Software Return value field is editable and
                        // controls the linked stereo pair. Keep that behavior
                        // when the two faders are linked.
                        EditableLevelReadout(
                            value: Binding(
                                get: { left.wrappedValue },
                                set: { newValue in
                                    left.wrappedValue = newValue
                                    right.wrappedValue = newValue
                                    channel.level = newValue
                                    onStereoLeftLevelChange?(newValue)
                                }),
                            range: -48...6,
                            step: 0.5)
                        .help("Software Return fader level: double-click to edit")
                } else {
                    HStack(spacing: 3) {
                        EditableLevelReadout(value: Binding(
                            get: { left.wrappedValue },
                            set: { newValue in
                                left.wrappedValue = newValue
                                onStereoLeftLevelChange?(newValue)
                            }), range: -48...6, step: 0.5)
                            .help("Left Software Return fader level: double-click to edit")
                        EditableLevelReadout(value: Binding(
                            get: { right.wrappedValue },
                            set: { newValue in
                                right.wrappedValue = newValue
                                onStereoRightLevelChange?(newValue)
                            }), range: -48...6, step: 0.5)
                            .help("Right Software Return fader level: double-click to edit")
                    }
                }
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
                    text: SymphonyIOSoftwareReturnSource(rawValue: sourceBinding.wrappedValue)?.displayName ?? "1-2",
                    fontSize: 9,
                    pillHeight: 22,
                    toolTip: "Software Return source — selects the DAW stereo pair feeding this mixer",
                    options: SymphonyIOSoftwareReturnSource.allCases.map { source in
                        (source.displayName, {
                            sourceBinding.wrappedValue = source.rawValue
                            onSoftwareReturnSourceChange?(source.rawValue)
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
