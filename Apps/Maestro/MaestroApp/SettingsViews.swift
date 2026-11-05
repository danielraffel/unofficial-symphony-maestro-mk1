import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice

/// Device Settings view — optical format, S/PDIF config, meter display, front panel.
///
/// Evidence: `og_source/maestro2/App/Controllers/APDeviceSettingsTabRowViewController.m`
struct DeviceSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var opticalFormatCard1: UInt32? // 0=ADAT/SMUX, 1=S/PDIF; nil=unavailable
    @State private var opticalFormatCard2: UInt32?
    @State private var isWritingOpticalFormat = false
    @State private var settingsLoadGeneration = UUID()
    @State private var peakHoldMode: UInt32 = 0
    @State private var overHoldMode: UInt32 = 0
    // meterBank picker removed — front panel bank switching is done via physical button.
    // Seeds match the daemon's own initializer: bank 1 shows analog INPUT 1-8,
    // bank 2 shows analog OUTPUT 1-8 -- inputs on the left column, outputs on the
    // right. A rack with no analog in/out is corrected by the card-aware clamp in
    // `loadSettings()` (the daemon's `ResetMeterSourceToDefault`).
    // Evidence: og_source/maestrolink/Software/SymphonyIO.cpp:181-182, 289-290, 1722-1723
    @State private var meterBank1Source: UInt32 = 1  // eMetersShowValues_AnalogInput_1_8
    @State private var meterBank2Source: UInt32 = 0  // eMetersShowValues_AnalogOutput_1_8
    @State private var peripheralPrefix: String = "A"
    @State private var deviceMode: UInt32 = 1        // 1=Symphony
    @State private var errorMessage: String?
    @State private var isLoading = true
    /// Whether the AIM explainer popover is showing.
    @State private var showAIMInfo = false

    /// Hover text for the AIM info button — the one fact that matters at a glance.
    private static let aimExplainer =
        "The Symphony I/O runs in one of four Audio Interface Modes at a time. "
        + "The mode can only be changed on the unit itself, not from this app."


    // Preferences — stored locally
    @EnvironmentObject private var updates: UpdateController
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .auto
    @AppStorage("autoLaunchEnabled") private var autoLaunchEnabled = false
    @AppStorage("popupsEnabled") private var popupsEnabled = true
    @AppStorage("usbHealthCheckEnabled") private var usbHealthCheckEnabled = false
    @AppStorage("autoRecoverMixerState") private var autoRecoverMixerState = true
    @AppStorage("routingMode") private var routingMode: Int = 0  // 0=DAW, 1=Direct Monitor
    @AppStorage("autoSwitchToSymphony") private var autoSwitchToSymphony = true
    @AppStorage("preferredUSBOutput") private var preferredUSBOutput = 0  // 0=Maestro USB, 1=USB Audio (Apple)
    @AppStorage("rememberControlTabScrollPositions") private var rememberControlTabScrollPositions = true
    /// User-editable insert names -- see `InsertLabels`. Shared across channels,
    /// which is why they are edited here rather than on an individual strip.
    @AppStorage("micPreInsertLabels") private var insertLabelsJSON: String = "{}"

    private let deviceModeNames: [UInt32: String] = [
        0: "DFU", 1: "Symphony", 2: "Standalone",
        3: "Pro Tools HD", 4: "USB Audio 16ch",
        5: "USB Audio 32ch", 6: "USB Audio 8ch"
    ]

    // P3F-52: eMaestroEnum_MetersShowValues — source options for each front panel meter bank.
    // Evidence: og_source/generic/mAEstroTypes.h lines 17-39
    private let allMeterSourceOptions: [(UInt32, String)] = [
        (0, "Analog Out 1-8"),
        (1, "Analog In 1-8"),
        (2, "Digital Out 1-8"),
        (3, "Digital In 1-8"),
        (4, "Analog Out 9-16"),
        (5, "Analog In 9-16"),
        (6, "Digital Out 9-16"),
        (7, "Digital In 9-16"),
    ]

    /// The installed cards' layout — capability gating on this page comes from here.
    private var layout: CardLayout { appState.cardLayout }

    /// The optical format selector follows the direction provided by the card.
    /// AD16 is output-only, so reading `opticalInFormat` for that slot reports
    /// an unavailable value even though the card's optical output is present.
    /// Cards with optical input keep the legacy input selector; output-only
    /// cards use the matching output selector.
    private func opticalFormatSelector(card: UInt32) -> AudioPropertySelector {
        let board = layout.card(atSlot: Int(card))
        return board.opticalFormatUsesInput ? .opticalInFormat : .opticalOutFormat
    }

    private var settingsLoadID: DeviceSettingsLoadID {
        DeviceSettingsLoadID(reloadToken: appState.viewReloadToken,
                             cardLayoutToken: appState.cardLayoutToken,
                             deviceID: appState.device.map(ObjectIdentifier.init))
    }

    /// Meter bank sources the installed cards can actually feed. A 16x16 has no
    /// digital channels, so "Digital In/Out" meters nothing; an A16 IP has no
    /// analog outputs at all.
    private var meterSourceOptions: [(UInt32, String)] {
        let available = allMeterSourceOptions.filter { layout.hasMeterSource($0.0) }
        return available.isEmpty ? allMeterSourceOptions : available
    }

    var body: some View {
        Form {
            // P3F-17: Optical format — per card (matching original Maestro 2)
            // Per slot, and only for a module that HAS optical ports — a 16x16
            // has none at all (user guide p. 11), so a format picker for it
            // writes a setting nothing can act on.
            if layout.hasOpticalPorts(slot: 0) || layout.hasOpticalPorts(slot: 1) {
                Section("Optical Format") {
                    if layout.hasOpticalPorts(slot: 0) {
                        Picker("Card 1", selection: opticalFormatSelection(card: 0)) {
                            if opticalFormatCard1 == nil {
                                Text("Unavailable").tag(nil as UInt32?)
                            }
                            Text("ADAT/SMUX").tag(UInt32(0) as UInt32?)
                            Text("S/PDIF").tag(UInt32(1) as UInt32?)
                        }
                    }

                    if layout.hasOpticalPorts(slot: 1) {
                        Picker("Card 2", selection: opticalFormatSelection(card: 1)) {
                            if opticalFormatCard2 == nil {
                                Text("Unavailable").tag(nil as UInt32?)
                            }
                            Text("ADAT/SMUX").tag(UInt32(0) as UInt32?)
                            Text("S/PDIF").tag(UInt32(1) as UInt32?)
                        }
                    }
                }
                .disabled(isLoading || isWritingOpticalFormat)
            }

            // S/PDIF Coax Replace/Mirror removed from Device Settings — controls are in
            // Input tab (SPDIF Replace) and Output tab (SPDIF Mirrors) inline with DIGITAL section.
            // Evidence: og_source APDeviceSettingsTabRowViewController.m has no SPDIF segments.

            // P3F-52: Front panel meter bank source selection
            Section("Front Panel") {
                // P3F-52: Per-bank source selection (eMaestroEnum_MetersShowValues).
                // Element 1 = bank 1, element 2 = bank 2.
                // Evidence: og_source/generic/mAEstroTypes.h:17-39,
                //           og_source/maestro2/App/Controllers/APDeviceMetersViewController.m:205-246
                Picker("Bank 1 Source", selection: $meterBank1Source) {
                    ForEach(meterSourceOptions, id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .onChange(of: meterBank1Source) { _, newValue in
                    guard !isLoading else { return }
                    Task {
                        do {
                            try await appState.device?.setProperty(
                                PropertyAddress(selector: .metersShowInput, element: 1),
                                value: .uint32(newValue)
                            )
                        } catch {
                            print("[Maestro] ERROR: meterBank1Source setProperty failed: \(error)")
                        }
                    }
                }

                Picker("Bank 2 Source", selection: $meterBank2Source) {
                    ForEach(meterSourceOptions, id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .onChange(of: meterBank2Source) { _, newValue in
                    guard !isLoading else { return }
                    Task {
                        do {
                            try await appState.device?.setProperty(
                                PropertyAddress(selector: .metersShowInput, element: 2),
                                value: .uint32(newValue)
                            )
                        } catch {
                            print("[Maestro] ERROR: meterBank2Source setProperty failed: \(error)")
                        }
                    }
                }
            }
            .disabled(isLoading)

            // Peak Hold / Over Hold deliberately DO NOT live here. They used to
            // appear on this tab and again in System Setup, bound to the same
            // state -- the issue #1 reporter spotted the duplication ("Meters
            // settings duplicated on this page"). The User's Guide puts them in
            // System Setup (p. 77, "found in Maestro's System Setup tab window");
            // this tab's Meters section is the FRONT PANEL meter view, which is
            // the "Front Panel" section above (Guide p. 65 item 2).
            //
            // Clearing meters is not lost with them: it is on the toolbar as
            // Clear Meters (Cmd+K), which is also where Apogee puts it.

            Section("Naming") {
                Picker("Peripheral Prefix", selection: $peripheralPrefix) {
                    ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init), id: \.self) { letter in
                        Text(letter).tag(letter)
                    }
                }
                .onChange(of: peripheralPrefix) { _, newValue in
                    guard !isLoading else { return }
                    Task { await writeProperty(.prefix, value: .string(newValue)) }
                }
            }
            .disabled(isLoading)

            // Insert Labels — User's Guide p.65 item 4: "If you have a Mic Pre
            // module installed, this section lets you customize the Insert
            // labels." Shown only with a usable MicPre, exactly as the Guide
            // describes and as the rest of the MicPre surface is gated.
            //
            // Names are keyed by INSERT and shared across every channel: the
            // daemon re-notifies all eight channels after one rename
            // (SymphonyIOBoard_MicPre8ch.cpp:590-593). Clearing a field restores
            // the default, matching the daemon's empty-string behaviour.
            //
            // These are app-side. Legacy held them in daemon memory as
            // kmAEstroPropertyInsertNameForID ('AEiv'); with no daemon they live
            // in UserDefaults, and the user-visible behaviour is the same.
            if InputChannelLogic.micPreIsUsable(
                primary: appState.primaryBoardType, secondary: appState.secondaryBoardType) {
                Section("Insert Labels") {
                    ForEach(1...InsertLabels.count, id: \.self) { id in
                        insertLabelField(UInt32(id))
                    }
                    if insertLabels.hasAnyCustom {
                        Button("Reset Insert Labels") {
                            var labels = insertLabels
                            labels.resetAll()
                            saveInsertLabels(labels)
                        }
                        .help("Restore the default names, Insert 1 through Insert 8.")
                    }
                }
            }

// P3F-20: Audio Interface Mode display + device info
            Section("Device") {
                LabeledContent("Audio Interface Mode") {
                    HStack(spacing: 5) {
                        Text(deviceModeNames[deviceMode] ?? "Unknown")
                        // The mode is read-only here -- it can only be changed on the
                        // unit itself -- so the how-to is one tap away rather than a
                        // permanent caption line under a row nobody can act on.
                        Button { showAIMInfo.toggle() } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .help(Self.aimExplainer)
                        .accessibilityLabel("About Audio Interface Mode")
                        .popover(isPresented: $showAIMInfo, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(Self.aimExplainer)
                                Text("Maestro works in Symphony and USB modes. What each "
                                     + "of the four modes is for is in Help.")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 300, alignment: .leading)
                            .padding(14)
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                if let device = appState.device {
                    LabeledContent("Model", value: device.identifier.displayName)
                    LabeledContent("Mode", value: device.identifier.mode.displayName)
                    LabeledContent("Channels", value: "\(device.identifier.mode.channelCount)")
                }
            }

            // Auto-launch and notifications
            Section("Preferences") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .help("Auto follows your Mac’s appearance. Light and Dark apply only to Maestro.")
                .unredacted()

                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                    .help("On by default. Turn this off to stop scheduled update checks; Maestro only connects when you choose Check for Updates.")
                    .unredacted()
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
                    .unredacted()
                Text("Updates download from the [Unofficial Symphony Maestro GitHub repository](https://github.com/danielraffel/unofficial-symphony-maestro-mk1). Installing an update may briefly interrupt audio and require an administrator password. Updates are never installed automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remember Input, Output, and Mixer scroll positions", isOn: $rememberControlTabScrollPositions)
                    .help("Keep each wide control tab at its current horizontal position until Maestro quits")

                Toggle("Launch Maestro automatically when connecting a device", isOn: $autoLaunchEnabled)
                    .onChange(of: autoLaunchEnabled) { _, enabled in
                        AutoLaunchManager.shared.setEnabled(enabled)
                    }
                    .help("Install a LaunchAgent that opens Maestro when a Symphony IO is plugged in")

                Toggle("Display pop-ups", isOn: $popupsEnabled)
                    .help("Show floating volume overlay when adjusting levels via media keys")

                Toggle("USB connection health check", isOn: $usbHealthCheckEnabled)
                    .onChange(of: usbHealthCheckEnabled) { _, enabled in
                        if enabled { appState.startUSBHealthCheck() }
                        else { appState.stopUSBHealthCheck() }
                    }
                    .help("Periodically verify USB connectivity and automatically recover stale connections. Enable if your device disconnects during sleep/wake or after cable bumps.")

                Toggle("Auto-recover mixer state on USB reconnect", isOn: $autoRecoverMixerState)
                    .help("Automatically restore mixer settings when USB connection recovers after power cycle or sleep/wake.")

                Toggle("Automatically switch to Symphony when connected", isOn: $autoSwitchToSymphony)
                    .help("When you plug in the Symphony I/O, make it your Mac's output device automatically instead of having to pick it in the Sound menu.")

                if autoSwitchToSymphony {
                    Picker("Preferred USB output", selection: $preferredUSBOutput) {
                        Text("Maestro USB (Recommended)").tag(0)
                        Text("USB Audio (No Keyboard Volume)").tag(1)
                    }
                    .help("Which device to select when the Symphony is connected over USB. 'Maestro USB' is recommended — it has working volume keys/slider. 'USB Audio' is Apple's raw device (lowest-latency recording, but no keyboard volume control).")
                }

                Picker("Monitoring Mode", selection: $routingMode) {
                    Text("DAW").tag(0)
                    Text("Direct Monitor").tag(1)
                }
                .pickerStyle(.segmented)
                // Hardware-backed, unlike the rest of this section, so it carries
                // the load gate itself rather than inheriting one from the Section.
                .disabled(isLoading)
                .onChange(of: routingMode) { _, newMode in
                    guard !isLoading else { return }
                    if let xpcDev = appState.device as? XPCDeviceConnection {
                        xpcDev.setRoutingMode(newMode)
                        if newMode == 0 {
                            // DAW: force-mute all HW inputs on both mixers
                            for mixerID: UInt16 in 1...2 {
                                for ch: UInt16 in 0..<32 {
                                    xpcDev.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 1)
                                }
                            }
                        } else {
                            // Direct Monitor: restore persisted mute state
                            for mixerIdx in 0..<2 {
                                let key = "mixerState_\(mixerIdx)"
                                let mixerID = UInt16(mixerIdx + 1)
                                if let data = UserDefaults.standard.data(forKey: key),
                                   let saved = try? JSONDecoder().decode([MixerChannelState].self, from: data) {
                                    for (ch, state) in saved.enumerated() {
                                        xpcDev.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: UInt16(ch), value: state.isMuted ? 1 : 0)
                                    }
                                } else {
                                    for ch: UInt16 in 0..<32 {
                                        xpcDev.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 0)
                                    }
                                }
                            }
                        }
                    }
                    appState.routingModeChangeCount += 1
                }
                .help("DAW mode disables hardware input passthrough — your DAW controls what you hear. Direct Monitor enables zero-latency 1:1 input-to-output passthrough for monitoring without a DAW.")
            }

            if let error = errorMessage {
                Section("Status") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Device Settings")
        .redacted(reason: isLoading ? .placeholder : [])
        // Redaction is cosmetic -- it greys the content out and still delivers every
        // click. Combined with the `guard !isLoading` in each onChange, that silently
        // THREW AWAY the user's change: the picker moved to the new value, nothing was
        // written, and the load had already taken its reading so nothing corrected the
        // picker back. Reported as "sometimes it doesn't fire and the app shows the new
        // rate while the device stays on the old one". The window is not small -- the
        // loaders wait up to 30 s for hardware init and then do USB reads that fail
        // slowly. Placeholder content must not be operable.
        //
        // .disabled is therefore on the hardware-backed Sections individually rather
        // than on the Form: disabling the Form also inerts the app-side preferences
        // and Rescan, and Rescan is exactly what someone reaches for during a load
        // that is taking 30 s. Only the controls whose onChange would drop the write
        // need to refuse the click.
        .animation(.easeIn(duration: 0.15), value: isLoading)
        .task(id: settingsLoadID) {
            await loadSettings()
        }
    }

    /// Only user selections write hardware. Assigning a readback while loading
    /// must never send an optical-format change or silently select ADAT.
    private func opticalFormatSelection(card: UInt32) -> Binding<UInt32?> {
        Binding {
            card == 0 ? opticalFormatCard1 : opticalFormatCard2
        } set: { newValue in
            guard !isLoading, !isWritingOpticalFormat, let newValue, newValue <= 1 else { return }
            guard let device = appState.device, device.isConnected else {
                setOpticalReadback(nil, card: card)
                errorMessage = "Device not connected. Optical format is unavailable."
                return
            }
            let loadID = settingsLoadID
            isWritingOpticalFormat = true
            Task { await writeOpticalFormat(newValue, card: card, device: device, loadID: loadID) }
        }
    }

    private func setOpticalReadback(_ value: UInt32?, card: UInt32) {
        let validValue = value.flatMap { $0 <= 1 ? $0 : nil }
        if card == 0 { opticalFormatCard1 = validValue }
        else { opticalFormatCard2 = validValue }
    }

    /// Keep showing confirmed hardware state until the write and readback finish.
    /// Only one optical write may run at a time; reconnect/reload invalidates its result.
    private func writeOpticalFormat(_ format: UInt32, card: UInt32,
                                    device: any DeviceConnection, loadID: DeviceSettingsLoadID) async {
        defer { isWritingOpticalFormat = false }
        guard settingsLoadID == loadID else { return }
        let address = PropertyAddress(selector: opticalFormatSelector(card: card), element: card)
        do {
            try await device.setProperty(address, value: .uint32(format))
            // USB acknowledges the vendor write before the card's optical
            // register is always visible to the next read.  A single
            // immediate read can therefore put the picker back on the old
            // value while the menu still shows the user's new checkmark.
            // Poll briefly for the confirmed value instead of presenting a
            // transiently stale readback as truth.
            var actual: UInt32?
            for attempt in 0..<4 {
                if attempt > 0 {
                    try await Task.sleep(for: .milliseconds(75))
                }
                if let value = try await device.getProperty(address).asUInt32,
                   value <= 1 {
                    actual = value
                    if value == format { break }
                }
            }
            guard let actual else {
                throw DeviceConnectionError.transportError("Optical format readback was unavailable")
            }
            guard settingsLoadID == loadID else { return }
            setOpticalReadback(actual, card: card)
            errorMessage = actual == format ? nil : "Card \(card + 1) did not confirm the requested optical format."
        } catch {
            guard settingsLoadID == loadID else { return }
            // A failed reply cannot tell us whether the hardware changed.
            setOpticalReadback(nil, card: card)
            errorMessage = "Card \(card + 1) optical format is unavailable: \(error.localizedDescription)"
        }
    }

    private func readSetting(_ selector: AudioPropertySelector, element: UInt32 = 0) async throws -> PropertyValue? {
        try Task.checkCancellation()
        do {
            let value = try await appState.device?.getProperty(PropertyAddress(selector: selector, element: element))
            try Task.checkCancellation()
            return value
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private func loadSettings() async {
        // Re-asserted, not just relied on from the initial @State: .task(id:) re-runs
        // on every preset load, and after the first run isLoading was already false --
        // so a reload left the panel live over content that was being replaced under
        // the user's cursor. isLoading is meant to be true exactly while a load is in
        // flight, which is what .disabled(isLoading) and the guards below assume.
        let generation = UUID()
        settingsLoadGeneration = generation
        isLoading = true
        opticalFormatCard1 = nil
        opticalFormatCard2 = nil
        defer {
            if settingsLoadGeneration == generation { isLoading = false }
        }
        guard appState.device != nil else { return }
        // P3G-25 pattern: add 30-second timeout guard to prevent permanent spinner
        // if hardware initialization never completes (daemon crash, device unplugged, etc.).
        let deadline = Date().addingTimeInterval(30)
        while !appState.isHardwareInitialized {
            if Date() > deadline {
                print("[Maestro] loadSettings: timed out waiting for hardware init")
                return
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        if layout.hasOpticalPorts(slot: 0) {
            do {
                if let fmt = (try await readSetting(opticalFormatSelector(card: 0), element: 0))?.asUInt32 {
                    opticalFormatCard1 = fmt <= 1 ? fmt : nil
                }
            } catch is CancellationError {
                return
            } catch {
                print("[Maestro] ERROR: loadSettings opticalInFormat card1 failed: \(error)")
            }
        }
        if layout.hasOpticalPorts(slot: 1) {
            do {
                if let fmt = (try await readSetting(opticalFormatSelector(card: 1), element: 1))?.asUInt32 {
                    opticalFormatCard2 = fmt <= 1 ? fmt : nil
                }
            } catch is CancellationError {
                return
            } catch {
                print("[Maestro] ERROR: loadSettings opticalInFormat card2 failed: \(error)")
            }
        }
        do {
            if let mode = (try await readSetting(.deviceMode))?.asUInt32 {
                deviceMode = mode
            }
        } catch is CancellationError {
            return
        } catch {
            print("[Maestro] ERROR: loadSettings deviceMode failed: \(error)")
        }
        // P3G-35 / P3F-52: Read meter display state on init.
        do {
            if let src = (try await readSetting(.metersShowInput, element: 1))?.asUInt32 {
                meterBank1Source = src
            }
        } catch is CancellationError {
            return
        } catch {
            print("[Maestro] ERROR: loadSettings meterBank1Source failed: \(error)")
        }
        do {
            if let src = (try await readSetting(.metersShowInput, element: 2))?.asUInt32 {
                meterBank2Source = src
            }
        } catch is CancellationError {
            return
        } catch {
            print("[Maestro] ERROR: loadSettings meterBank2Source failed: \(error)")
        }
        // A bank set to a source these cards cannot feed shows a blank popup and
        // a dead front-panel bank. Fall back to the card-aware default.
        // Evidence: `SymphonyIOMonitorDefaults.meterSourceBank1/2`.
        let options = meterSourceOptions
        if !options.contains(where: { $0.0 == meterBank1Source }) {
            meterBank1Source = UInt32(SymphonyIOMonitorDefaults.meterSourceBank1(
                hasAnalogInputs: layout.slot1.analogInputChannels
                    + layout.slot2.analogInputChannels > 0).rawValue)
        }
        if !options.contains(where: { $0.0 == meterBank2Source }) {
            meterBank2Source = UInt32(SymphonyIOMonitorDefaults.meterSourceBank2(
                hasAnalogOutputs: layout.slot1.analogOutputChannels
                    + layout.slot2.analogOutputChannels > 0).rawValue)
        }
        do {
            if let peak = (try await readSetting(.peakHoldMode))?.asUInt32 {
                peakHoldMode = peak
            }
        } catch is CancellationError {
            return
        } catch {
            print("[Maestro] ERROR: loadSettings peakHoldMode failed: \(error)")
        }
        do {
            if let over = (try await readSetting(.oversHoldMode))?.asUInt32 {
                overHoldMode = over
            }
        } catch is CancellationError {
            return
        } catch {
            print("[Maestro] ERROR: loadSettings oversHoldMode failed: \(error)")
        }
        do {
            if let pfx = (try await readSetting(.prefix))?.asString,
               !pfx.isEmpty {
                peripheralPrefix = String(pfx.prefix(1))
            }
        } catch is CancellationError {
            return
        } catch {
            print("[Maestro] ERROR: loadSettings prefix failed: \(error)")
        }
    }

// MARK: Insert labels

    private var insertLabels: InsertLabels {
        guard let data = insertLabelsJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return InsertLabels() }
        return InsertLabels(storage: dict)
    }

    private func saveInsertLabels(_ labels: InsertLabels) {
        guard let data = try? JSONEncoder().encode(labels.storage),
              let json = String(data: data, encoding: .utf8) else { return }
        insertLabelsJSON = json
    }

    /// One insert's name field. Binding writes through `InsertLabels`, which
    /// trims, caps the length, and treats an emptied field as "use the default"
    /// rather than storing a blank that would render as an empty menu row.
    @ViewBuilder
    private func insertLabelField(_ id: UInt32) -> some View {
        let binding = Binding<String>(
            get: { insertLabels[id] },
            set: { newValue in
                var labels = insertLabels
                labels[id] = newValue
                saveInsertLabels(labels)
            }
        )
        LabeledContent("\(id)") {
            // .labelsHidden(): inside a Form, SwiftUI renders a TextField's title
            // as a visible label NEXT to the field, so the default name showed up
            // twice per row — once greyed inside the box as the prompt and again
            // beside it. The title is still set because VoiceOver reads it.
            TextField(InsertLabels.defaultName(id), text: binding)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .help("Name for insert \(id). This name is shared by every channel. "
                      + "Clear the field to go back to \"\(InsertLabels.defaultName(id))\".")
        }
    }

    private func writeProperty(_ selector: AudioPropertySelector, value: PropertyValue) async {
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: selector),
                value: value
            )
            errorMessage = nil
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

}

/// Parsed firmware/device info from the 'AEt1' (versionString) daemon property.
/// The daemon returns an XML plist string with nested dicts for USB Daemon and Symphony I/O.
private struct FirmwareInfo {
    var deviceName: String?
    var firmwareVersion: String?
    var fpgaVersion: String?
    var hardwareID: String?
    var ioBoard1Type: String?
    var ioBoard1Version: String?
    var ioBoard2Type: String?
    var ioBoard2Version: String?
    var xmosVersion: String?

    static func parse(_ xmlString: String) -> FirmwareInfo? {
        guard let data = xmlString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }

        // The daemon returns an array of dicts (root is <array>).
        // Each dict may have a "Children" array of component dicts.
        // Each component dict has "name" (String) and "info" (dict with properties).
        // Screenshot confirmed structure: [{ "Children": [{ "name": "USB Daemon", "info": { "version": "1.23.0" } },
        //   { "name": "Symphony I/O", "info": { "FPGA version": "v73", "Hardware ID": "...",
        //     "IOBoard1 Type": "8ch Analog-Optical", "IOBoard1 version": "v33", ... } }] }]
        var info = FirmwareInfo()
        info.deviceName = "Symphony I/O"

        func processItems(_ items: [[String: Any]]) {
            for item in items {
                let name = item["name"] as? String ?? ""
                let itemInfo = item["info"] as? [String: Any] ?? [:]
                if name == "USB Daemon" {
                    info.firmwareVersion = itemInfo["version"] as? String
                } else {
                    // Symphony I/O or similar hardware component
                    if let v = itemInfo["FPGA version"] as? String { info.fpgaVersion = v }
                    if let v = itemInfo["Hardware ID"] as? String { info.hardwareID = v }
                    if let v = itemInfo["XMOS version"] as? String { info.xmosVersion = v }
                    if let v = itemInfo["IOBoard1 Type"] as? String { info.ioBoard1Type = v }
                    if let v = itemInfo["IOBoard1 version"] as? String { info.ioBoard1Version = v }
                    if let v = itemInfo["IOBoard2 Type"] as? String { info.ioBoard2Type = v }
                    if let v = itemInfo["IOBoard2 version"] as? String { info.ioBoard2Version = v }
                }
                if let children = item["Children"] as? [[String: Any]] {
                    processItems(children)
                }
            }
        }

        if let rootArray = plist as? [[String: Any]] {
            processItems(rootArray)
        } else if let rootDict = plist as? [String: Any] {
            processItems([rootDict])
        }

        guard info.firmwareVersion != nil || info.fpgaVersion != nil || info.hardwareID != nil else { return nil }
        return info
    }

    /// Construct FirmwareInfo from static device knowledge when daemon XML is unavailable.
    /// On macOS 26, the daemon is broken and USB vendor reads fail, so we populate
    /// what we can from the USBDeviceIdentifier and any firmware version string we got.
    static func fromDevice(_ device: any DeviceConnection, firmwareVersion: String) -> FirmwareInfo {
        var info = FirmwareInfo()
        info.deviceName = device.identifier.displayName
        if firmwareVersion != "—" {
            info.firmwareVersion = firmwareVersion
        }
        return info
    }

    /// Board type the daemon's version XML reported for a slot, if it can be
    /// mapped onto a known module. A value here came off the device, so it counts
    /// as a live detection.
    func xmlBoardType(slot: Int) -> IOCardType? {
        let label = slot == 1 ? ioBoard1Type : ioBoard2Type
        guard let label, !label.isEmpty else { return nil }
        return IOCardType.fromLegacyLabel(label)
    }

    /// Build the Device Info panel's content.
    ///
    /// Board types are passed in as `BoardTypeReading`s rather than strings so the
    /// panel can say whether each slot was actually read back or is a stale cache.
    func report(
        connectionMode: String,
        board1: BoardTypeReading,
        board2: BoardTypeReading,
        deviceModel: String? = nil,
        mode: String? = nil,
        channelCount: Int? = nil
    ) -> DeviceInfoReport {
        DeviceInfoReport(
            deviceName: deviceName ?? "Symphony I/O",
            connection: connectionMode,
            firmwareVersion: firmwareVersion,
            fpgaVersion: fpgaVersion,
            hardwareID: hardwareID,
            xmosVersion: xmosVersion,
            board1: board1,
            board1Version: ioBoard1Version,
            board2: board2,
            board2Version: ioBoard2Version,
            deviceModel: deviceModel,
            mode: mode,
            channelCount: channelCount
        )
    }
}

/// System Setup view — clock, sample rate, word clock, keyboard volume, device info.
/// Mode-aware: shows different controls for Symphony/Standalone/Pro Tools HD modes.
///
/// Evidence: `og_source/maestro2/App/Controllers/APSystemSetupTabRowViewController.m`
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` — clock and sample rate properties
struct SystemSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var sampleRate: Double = 0
    @State private var clockSource: UInt32 = 1  // 1 = Internal (legacy eSymphonyIOClockSource enum; 0 = Unknown)
    @State private var clockLocked: Bool = false
    @State private var firmwareVersion: String = "—"
    @State private var parsedFirmware: FirmwareInfo?
    /// Slot 1 board type WITH its provenance — detected this session, restored
    /// from cache, simulated, or genuinely unknown. Card detection (`0xA1`, a
    /// `0xC0` vendor EP0 read) currently fails on USB, so this is very often
    /// `.cached`; the panel must say so rather than presenting it as measured.
    @State private var board1Reading: BoardTypeReading = .unknown
    /// Slot 2 board type with its provenance. See `board1Reading`.
    @State private var board2Reading: BoardTypeReading = .unknown
    @State private var showCopied: Bool = false
    /// Separate from `showCopied` so the two Copy buttons do not flash each other's
    /// checkmark.
    @State private var showSoftwareCopied: Bool = false
    @State private var dextActionInFlight = false
    @State private var dextActionStatus: String?
    @State private var showDextActionAlert = false
    @State private var dextAlertTitle = "ThunderBridge Driver"
    @State private var dextAlertMessage = ""
    @State private var deviceMode: UInt32 = 1  // 1=Symphony
    @State private var wordClockOut: UInt32 = 0 // P3D-03: 0=normal, 1=divide-by-2
    // Keyboard Volume Control removed — legacy daemon-only pref, no USB opcode.
    // Volume keys are now handled by ASP/proxy directly.
    @State private var peakHoldMode: UInt32 = 0   // 0=Off, 1=2sec, 2=Infinite
    @State private var overHoldMode: UInt32 = 0   // 0=Off, 1=2sec, 2=Infinite
    @State private var errorMessage: String?
    @State private var isLoading = true
    /// Set for the whole duration of a rate write, including the windows that wait
    /// for the virtual device to follow and for a DAW to take the rate back, so the
    /// reconcile loop leaves the picker alone until the write has resolved.
    @State private var rateWriteInFlight = false
    /// The in-flight rate write, cancelled when a new selection supersedes it.
    @State private var rateWriteTask: Task<Void, Never>?
    /// Which write is the current one.
    ///
    /// A write is not instantaneous -- up to about eight seconds across the set,
    /// the follow window and the DAW watch -- and the picker stays live throughout,
    /// so a second selection can arrive while the first is still resolving. A Bool
    /// cannot express "still the current write": the superseded write's own
    /// `defer` would lower the flag while the new one was mid-flight, and its
    /// watch windows would report a rate the user had already replaced as though
    /// something else on the Mac had taken it back. Every write compares its
    /// generation before touching shared state, so a superseded one stays silent.
    @State private var rateWriteGeneration = 0

    /// A rate this view put into `sampleRate` itself, so the picker's onChange can
    /// tell it apart from one the user picked. Without it, reading the hardware's
    /// rate and showing it writes it straight back -- a pointless hardware write
    /// on every refresh, and it clears whatever the last error said.
    @State private var programmaticRate: Double?

    // Keys are the legacy eSymphonyIOClockSource enum values (SymphonyIOVendorSpecific.h:857-865),
    // sent verbatim as ClockMode pData[0]. The old dict was off-by-one with invented digital
    // "sources" (AES/EBU, S/PDIF, ADAT, Optical S/PDIF are board sub-sources, not clock sources).
    // Note: Loop Sync (3) and IO Board 1/2 (4/5) currently send default flags/boardIndex — the
    // isMaster/loopSync and board-index wiring is a known follow-up (CS2 gap); Internal and Word
    // Clock are fully correct.
    private let clockSourceNames: [UInt32: String] = [
        1: "Internal",
        2: "Word Clock",
        3: "Loop Sync",
        4: "IO Board 1",
        5: "IO Board 2"
    ]

    /// Fallback rates shown when device doesn't report available rates.
    private static let defaultRates: [Double] = [
        44100, 48000, 88200, 96000, 176400, 192000
    ]

    /// Rates queried from the actual device — updated in loadStatus().
    @State private var availableRates: [Double] = defaultRates

    /// Peak Hold and Over Hold are NOT the same list. Over Hold carries a fourth
    /// mode, Auto Clear (`eSymphonyIOMeteringLEDOverHold_AutoClear` = 3,
    /// SymphonyIOVendorSpecific.h:706-712), which Peak Hold has no equivalent of.
    ///
    /// One shared 3-value list used to drive both pickers here, so Auto Clear was
    /// unreachable. Both now come from the MaestroCore enums, whose `wireValue`
    /// is pinned by tests and whose case order IS the wire order -- legacy binds
    /// the popup's selectedIndex straight to the property
    /// (APSystemMetersViewController.m:69-74), so order is load-bearing.
    private var peakHoldOptions: [(UInt32, String)] {
        MeterDisplaySettings.PeakHoldMode.allCases.map { ($0.wireValue, $0.rawValue) }
    }

    private var overHoldOptions: [(UInt32, String)] {
        MeterDisplaySettings.OverHoldMode.allCases.map { ($0.wireValue, $0.rawValue) }
    }

    /// Is the device in Pro Tools HD mode?
    private var isProToolsMode: Bool { deviceMode == 3 }
    /// Is the device in Standalone mode?
    private var isStandaloneMode: Bool { deviceMode == 2 }

    var body: some View {
        Form {
            // P3F-21: Mode-aware Clock section
            Section("Clock") {
                // Sample Rate
                Picker("Sample Rate", selection: $sampleRate) {
                    if availableRates.isEmpty {
                        // Keep the initial 0-valued selection valid while the
                        // asynchronous device query is still in flight.
                        Text("Loading…").tag(0.0)
                    } else {
                        ForEach(availableRates, id: \.self) { rate in
                            Text(formatSampleRate(rate)).tag(rate)
                        }
                    }
                }
                .disabled(isLoading || isProToolsMode)
                .onChange(of: sampleRate) { _, newRate in
                    guard !isLoading else { return }
                    if let mine = programmaticRate, abs(mine - newRate) < 1.0 {
                        programmaticRate = nil
                        return
                    }
                    // One writer at a time, and the flag goes up HERE rather than
                    // inside the task: between this closure and the task's first
                    // line the reconcile loop could otherwise get a turn, read the
                    // not-yet-changed hardware, and snap the picker back.
                    rateWriteTask?.cancel()
                    rateWriteInFlight = true
                    rateWriteGeneration += 1
                    let generation = rateWriteGeneration
                    rateWriteTask = Task {
                        await writeSampleRate(newRate, generation: generation)
                    }
                }

                // Clock Source
                Picker("Clock Source", selection: $clockSource) {
                    ForEach(Array(clockSourceNames.keys.sorted()), id: \.self) { key in
                        Text(clockSourceNames[key] ?? "Unknown").tag(key)
                    }
                }
                .disabled(isProToolsMode)
                .onChange(of: clockSource) { _, newSource in
                    guard !isLoading else { return }
                    Task { await writeClockSource(newSource) }
                }

                if isProToolsMode {
                    Text("Clock settings are controlled by Pro Tools")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Clock Lock Status
                HStack {
                    Text("Clock Status")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(clockLocked ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(clockLocked ? "Locked" : "Unlocked")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isLoading)

            // P3D-03: Word clock output config
            if !isProToolsMode {
                Section("Word Clock Output") {
                    Picker("Word Clock Divide", selection: $wordClockOut) {
                        Text("1:1 (Normal)").tag(UInt32(0))
                        Text("1:2 (Divide)").tag(UInt32(1))
                    }
                    .pickerStyle(.menu)
                    // Disabled: 'AEwd' word-clock divide was an Ensemble-only HAL property
                    // (mAEstro.h:1036-1039); there is no vendor EP0 opcode for it on Symphony IO
                    // MKI, so setProperty(.wordClockDivide) throws .unsupportedProperty and the
                    // control never reaches hardware. Inert until a real mechanism is found.
                    .disabled(true)
                    .onChange(of: wordClockOut) { _, newValue in
                        guard !isLoading else { return }
                        Task {
                            do {
                                try await appState.device?.setProperty(
                                    PropertyAddress(selector: .wordClockDivide),
                                    value: .uint32(newValue)
                                )
                            } catch {
                                print("[Maestro] ERROR: wordClockDivide setProperty failed: \(error)")
                            }
                        }
                    }
                }
                .disabled(isLoading)
            }

            // Meters — Peak Hold and Over Hold (matching original Maestro 2 System Setup)
            Section("Meters") {
                Picker("Peak Hold", selection: $peakHoldMode) {
                    ForEach(peakHoldOptions, id: \.0) { val, name in
                        Text(name).tag(val)
                    }
                }
                .onChange(of: peakHoldMode) { _, newValue in
                    guard !isLoading else { return }
                    Task {
                        do {
                            try await appState.device?.setProperty(
                                PropertyAddress(selector: .peakHoldMode),
                                value: .uint32(newValue)
                            )
                        } catch {
                            print("[Maestro] ERROR: peakHoldMode setProperty failed: \(error)")
                        }
                    }
                }

                Picker("Over Hold", selection: $overHoldMode) {
                    ForEach(overHoldOptions, id: \.0) { val, name in
                        Text(name).tag(val)
                    }
                }
                .onChange(of: overHoldMode) { _, newValue in
                    guard !isLoading else { return }
                    Task {
                        do {
                            try await appState.device?.setProperty(
                                PropertyAddress(selector: .oversHoldMode),
                                value: .uint32(newValue)
                            )
                        } catch {
                            print("[Maestro] ERROR: oversHoldMode setProperty failed: \(error)")
                        }
                    }
                }

                @Bindable var mutableAppState = appState
                Toggle("Meter Zone Coloring", isOn: $mutableAppState.showMeterZoneColoring)
                    .help("When enabled, idle meter segments show a muted green/yellow/red gradient indicating their dB zone. When disabled, idle segments are a uniform gray.")
            }
            .disabled(isLoading)

            Section {
                if appState.connectionMode == .hardware {
                    if let info = parsedFirmware {
                        LabeledContent("Device Name", value: info.deviceName ?? "Symphony I/O")
                        LabeledContent("Connection", value: appState.transportType == .thunderbolt ? "Thunderbolt (ThunderBridge)" : "USB Hardware")
                        if let fw = info.firmwareVersion { LabeledContent("Firmware", value: fw) }
                        if let fpga = info.fpgaVersion { LabeledContent("FPGA Version", value: fpga) }
                        if let hw = info.hardwareID { LabeledContent("Hardware ID", value: hw) }
                        // Board types, with provenance. Never present a cached
                        // value as a measurement — card detection fails on USB.
                        LabeledContent("IOBoard 1",
                                       value: DeviceInfoReport.boardLine(board1Reading, version: info.ioBoard1Version))
                            .help(board1Reading.detailedText)
                        LabeledContent("IOBoard 2",
                                       value: DeviceInfoReport.boardLine(board2Reading, version: info.ioBoard2Version))
                            .help(board2Reading.detailedText)
                        if let notice = boardDetectionNotice {
                            Label(notice, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let xmos = info.xmosVersion { LabeledContent("XMOS Version", value: xmos) }
                    } else {
                        LabeledContent("Firmware Version", value: firmwareVersion)
                    }

                    if let device = appState.device {
                        LabeledContent("Device Model", value: device.identifier.displayName)
                        LabeledContent("Mode", value: device.identifier.mode.displayName)
                        LabeledContent("Channel Count", value: "\(device.identifier.mode.channelCount)")
                    }

                    // Same action as the View > Rescan menu item; one concept,
                    // one name. This copy is gated on connectionMode == .hardware
                    // so it is only ever visible once a device is ALREADY found,
                    // which is why the menu item exists as well.
                    Button("Rescan") {
                        Task { await appState.reconnectHardware() }
                    }
                    .help("Re-establish the link to Symphony and rebuild the audio "
                          + "path. Same as View > Rescan (⌘R).")
                } else if appState.connectionMode == .simulated, let sim = appState.cardSimulation {
                    // Card-simulation harness: say so, and name the forced boards
                    // with their `simulated` provenance so a screenshot of this
                    // panel is self-describing.
                    LabeledContent("Device Name", value: "Symphony I/O (simulated)")
                    LabeledContent("Connection", value: "Card simulation — no hardware")
                    LabeledContent("IOBoard 1", value: DeviceInfoReport.boardLine(board1Reading, version: nil))
                        .help(board1Reading.detailedText)
                    LabeledContent("IOBoard 2", value: DeviceInfoReport.boardLine(board2Reading, version: nil))
                        .help(board2Reading.detailedText)
                    if let notice = boardDetectionNotice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let device = appState.device {
                        LabeledContent("Device Model", value: device.identifier.displayName)
                        LabeledContent("Mode", value: device.identifier.mode.displayName)
                        LabeledContent("Channel Count", value: "\(device.identifier.mode.channelCount)")
                    }
                    LabeledContent("Simulated Channels",
                                   value: "\(sim.totalInputChannels) in / \(sim.totalOutputChannels) out")
                } else {
                    LabeledContent("Connection", value: "Offline")
                }
            } header: {
                HStack {
                    Text("Device Info")
                    Spacer()
                    if appState.connectionMode == .hardware {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(currentDeviceReport().clipboardText, forType: .string)
                            showCopied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                showCopied = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                Text(showCopied ? "Copied!" : "Copy")
                            }
                            .foregroundStyle(showCopied ? .green : .secondary)
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Copy device info to clipboard")
                    }
                }
            }

            // Device Info answers "what hardware is this". This answers "what code is
            // running", which is the other half of any bug report and was previously
            // spread across the About box and `systemextensionsctl list` in a terminal.
            Section {
                let info = appState.softwareInfoReport
                LabeledContent("Maestro", value: info.versionLine)
                LabeledContent("macOS", value: info.osVersion)
                LabeledContent("Audio Path", value: info.audioPath)
                if let pciDeviceIdentifier = info.pciDeviceIdentifier {
                    LabeledContent("PCI Device", value: pciDeviceIdentifier)
                }
                LabeledContent("Maestro ThunderBridge Driver Extension") {
                    HStack(spacing: 8) {
                        Text(info.dextStatusLine)
                            .foregroundStyle(info.dextNeedsAction ? .orange : .primary)
                        if info.dextNeedsAction {
                            let needsSettings = info.dextUpgradePending
                                || info.dextAwaitingApproval
                                || info.dextAwaitingReboot
                                || (info.installedDextVersion != nil && !info.dextEnabled)
                            let actionTitle = needsSettings
                                ? "Open Driver Settings…"
                                : (dextActionInFlight ? "Working…" : "Install / Approve…")
                            Button(actionTitle) {
                                UserDefaults.standard.removeObject(forKey: "maestro.thunderbridge.lastPrompt")
                                if needsSettings {
                                    openDriverExtensions()
                                } else {
                                    dextActionInFlight = true
                                    dextActionStatus = "Requesting driver activation…"
                                    SystemExtensionInstaller.shared.activate()
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.5))
                                        appState.refreshInstalledDexts()
                                        dextActionInFlight = false
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(dextActionInFlight)
                            .help("Register or request approval for the embedded ThunderBridge driver")
                        } else {
                            // Keep the settings shortcut available even when the
                            // extension is healthy, so users can review its state
                            // without needing to manufacture an error first.
                            Button("Open Driver Settings…", action: openDriverExtensions)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Open macOS Login Items & Extensions for the Maestro driver")
                        }
                    }
                }
                if info.dextNeedsAction && info.installedDextVersion != nil {
                    Text("To enable or disable: open System Settings → Login Items & Extensions → By App → Maestro → Driver Extension.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let dextActionStatus {
                    Label(dextActionStatus, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notice = info.dextNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("App Path", value: info.appPath)
                    .help(info.appPath)
            } header: {
                HStack {
                    Text("Software Info")
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.softwareInfoReport.clipboardText, forType: .string)
                        showSoftwareCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            showSoftwareCopied = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showSoftwareCopied ? "checkmark" : "doc.on.doc")
                            Text(showSoftwareCopied ? "Copied!" : "Copy")
                        }
                        .foregroundStyle(showSoftwareCopied ? .green : .secondary)
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy software info to clipboard")
                }
            }

            if let error = errorMessage {
                Section("Status") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("System Setup")
        .redacted(reason: isLoading ? .placeholder : [])
        // Redaction is cosmetic -- it greys the content out and still delivers every
        // click. Combined with the `guard !isLoading` in each onChange, that silently
        // THREW AWAY the user's change: the picker moved to the new value, nothing was
        // written, and the load had already taken its reading so nothing corrected the
        // picker back. Reported as "sometimes it doesn't fire and the app shows the new
        // rate while the device stays on the old one". The window is not small -- the
        // loaders wait up to 30 s for hardware init and then do USB reads that fail
        // slowly. Placeholder content must not be operable.
        //
        // .disabled is therefore on the hardware-backed Sections individually rather
        // than on the Form: disabling the Form also inerts the app-side preferences
        // and Rescan, and Rescan is exactly what someone reaches for during a load
        // that is taking 30 s. Only the controls whose onChange would drop the write
        // need to refuse the click.
        .animation(.easeIn(duration: 0.15), value: isLoading)
        .task(id: appState.viewReloadToken) {
            await loadProperties()
        }
        .task { await reconcileSampleRate() }
        // Same reason as the About box: pick up an activation that finished after launch.
        .onAppear {
            appState.refreshInstalledDexts()
            if let status = SystemExtensionInstaller.shared.lastStatus {
                presentDextStatus(status, showAlert: true)
            }
            SystemExtensionInstaller.shared.onStatusChange = { status in
                presentDextStatus(status, showAlert: true)
                dextActionInFlight = false
                appState.refreshInstalledDexts()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // The user may have enabled or disabled the extension in System Settings
            // while Maestro remained open. Refresh the database when we return so the
            // row and action link never require a relaunch to become accurate.
            appState.refreshInstalledDexts()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // System Settings can present Driver Extensions as a sheet without
            // deactivating this window. Keep the foreground status live with a tiny
            // plist read, and stop immediately when Maestro is no longer active.
            while !Task.isCancelled {
                appState.refreshInstalledDexts()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert(dextAlertTitle, isPresented: $showDextActionAlert) {
            switch dextAlertTitle {
            case "Enable the Maestro ThunderBridge Driver Extension", "Maestro ThunderBridge Driver Extension Setup Failed":
                Button("Open Driver Extensions…", action: openDriverExtensions)
                Button("Later", role: .cancel) { }
            default:
                Button("OK", role: .cancel) { }
            }
        } message: {
            Text(dextAlertMessage)
        }
    }

    private func openDriverExtensions() {
        let driverExtensions = "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.system_extension.driver_extension.extension-point"
        if let url = URL(string: driverExtensions), NSWorkspace.shared.open(url) { return }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }

    private func presentDextStatus(_ status: SystemExtensionInstaller.Status, showAlert: Bool) {
        switch status {
        case .needsUserApproval:
            dextActionStatus = "Maestro ThunderBridge driver extension approval is required in System Settings."
            dextAlertTitle = "Enable the Maestro ThunderBridge Driver Extension"
            dextAlertMessage = "macOS has installed the Maestro ThunderBridge driver extension, but it needs your approval. Open Driver Extensions, choose Maestro Symphony Thunderbridge, and turn it on."
        case .willCompleteAfterReboot:
            dextActionStatus = "Restart required to finish enabling the Maestro ThunderBridge driver extension."
            dextAlertTitle = "Restart Required"
            dextAlertMessage = "The ThunderBridge driver will finish installing after you restart your Mac."
        case .upgradePending:
            dextActionStatus = "Maestro ThunderBridge driver extension update is pending; reconnect ThunderBridge after closing audio applications."
            dextAlertTitle = "Driver Update Pending"
            dextAlertMessage = "macOS already has a Maestro ThunderBridge driver extension activation in progress. Close audio applications, then disconnect and reconnect the ThunderBridge to finish the update."
        case .failed(let message):
            dextActionStatus = "Maestro ThunderBridge driver extension setup failed: \(message)"
            dextAlertTitle = "Maestro ThunderBridge Driver Extension Setup Failed"
            dextAlertMessage = "Maestro could not finish setting up its ThunderBridge driver extension. Open Driver Extensions to check its state, then try again.\n\n\(message)"
        case .notBundled:
            dextActionStatus = "This app does not contain the Maestro ThunderBridge driver extension. Reinstall Maestro."
            dextAlertTitle = "Driver Not Installed"
            dextAlertMessage = "This copy of Maestro does not include the ThunderBridge driver. Install the signed Maestro package, then reopen the app."
        case .activating:
            dextActionStatus = "Requesting driver activation…"
        case .activated:
            dextActionStatus = "Driver activation completed."
            UserDefaults.standard.removeObject(forKey: "maestro.thunderbridge.lastPrompt")
        }
        if showAlert {
            switch status {
            case .needsUserApproval, .willCompleteAfterReboot, .upgradePending, .failed, .notBundled:
                let token: String
                switch status {
                case .needsUserApproval: token = "approval"
                case .willCompleteAfterReboot: token = "reboot"
                case .upgradePending: token = "upgrade"
                case .failed: token = "failed"
                case .notBundled: token = "missing"
                default: token = ""
                }
                if UserDefaults.standard.string(forKey: "maestro.thunderbridge.lastPrompt") != token {
                    UserDefaults.standard.set(token, forKey: "maestro.thunderbridge.lastPrompt")
                    showDextActionAlert = true
                }
            case .activating, .activated:
                break
            }
        }
    }

    // MARK: - Device Info report

    /// The Device Info panel's content as one value.
    ///
    /// This page is the only place that knows all of it: the firmware XML it parsed, and
    /// the board readings it resolved against that XML. The About box copies the same
    /// report via `appState.deviceInfoSnapshot`, which `loadProperties` publishes.
    private func currentDeviceReport() -> DeviceInfoReport {
        let device = appState.device
        return (parsedFirmware ?? FirmwareInfo()).report(
            connectionMode: appState.transportType == .thunderbolt
                ? "Thunderbolt (ThunderBridge)" : "USB Hardware",
            board1: board1Reading,
            board2: board2Reading,
            deviceModel: device?.identifier.displayName,
            mode: device?.identifier.mode.displayName,
            channelCount: device?.identifier.mode.channelCount
        )
    }

    // MARK: - Board Detection Provenance

    /// One-line honesty notice under the board rows, or nil when both slots were
    /// genuinely read back from the hardware this session.
    private var boardDetectionNotice: String? {
        let sources = [board1Reading.source, board2Reading.source]
        if sources.allSatisfy(\.isTrustworthy) { return nil }
        if sources.contains(.simulated) {
            return "Card simulation is active — the board types above are forced for testing and are not this unit's real hardware."
        }
        if sources.allSatisfy({ $0 == .unknown }) {
            return "I/O card detection did not succeed and there is no stored value, so the installed boards are unknown."
        }
        return "I/O card detection did not succeed this session. Board types above are the last stored values, not read from the hardware."
    }


    /// Establish what each option-board slot may honestly claim.
    ///
    /// Attempts a live `0xA1` read for each slot. That read is a `0xC0` vendor
    /// EP0 read, which currently returns `kIOReturnNotResponding` on USB and has
    /// no handler in `MaestroVolumeProxy.c`, so on a USB unit it is expected to
    /// fail — in which case we fall back to the value `AppState` restored from
    /// `UserDefaults` and label it as cached. If there is no cache entry either,
    /// the slot is reported unknown rather than "None", because an empty slot and
    /// a failed read are not the same claim.
    ///
    /// Building the detection mechanism itself is out of scope here; this only
    /// stops the panel presenting a guess as a measurement.
    private func loadBoardReadings(device: any DeviceConnection) async {
        let simulating = SimulatedDevice.isSimulatingCards()
        let defaults = UserDefaults.standard

        func liveRead(_ selector: AudioPropertySelector) async -> IOCardType? {
            guard let raw = (try? await device.getProperty(PropertyAddress(selector: selector)))?.asUInt32,
                  raw <= UInt32(UInt8.max),
                  let card = IOCardType(rawValue: UInt8(raw))
            else { return nil }
            return card
        }

        // The daemon's version XML is an on-device source too, when it works.
        let xml1 = parsedFirmware?.xmlBoardType(slot: 1)
        let xml2 = parsedFirmware?.xmlBoardType(slot: 2)

        let live1 = await liveRead(.primaryBoardType) ?? xml1
        let live2 = await liveRead(.secondaryBoardType) ?? xml2

        // A cache entry only counts if the key actually exists — AppState's
        // in-memory default is `.none`, which would otherwise masquerade as a
        // cached "empty slot".
        let cached1 = defaults.object(forKey: "cachedPrimaryBoardType") != nil
            ? appState.primaryBoardType : nil
        let cached2 = defaults.object(forKey: "cachedSecondaryBoardType") != nil
            ? appState.secondaryBoardType : nil

        board1Reading = .resolve(live: live1, cached: cached1, isSimulated: simulating)
        board2Reading = .resolve(live: live2, cached: cached2, isSimulated: simulating)
    }

    private func loadProperties() async {
        // See loadSettings: .task(id:) re-runs per preset load and isLoading is false
        // by then, so it has to be re-asserted here rather than left to @State.
        isLoading = true
        defer { isLoading = false }
        guard let device = appState.device else {
            errorMessage = "No device connected"
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while !appState.isHardwareInitialized {
            if Date() > deadline {
                print("[Maestro] loadProperties: timed out waiting for hardware init")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Use CoreAudio standard APIs for sample rate / lock — daemon returns 'who?' on MKI.
        // clockSource is NOT read from CoreAudio because CoreAudio returns arbitrary IDs
        // (not the 0-5 Apogee enum), so the picker selection would break.
        // Leave clockSource at 0 (Internal) until we have proper ID↔enum mapping.
        // When XPC path is active, meterDevice is a CoreAudioDeviceConnection to the real
        // USB device — use it to read sample rate and clock lock status.
        let caDev = (device as? CoreAudioDeviceConnection) ?? appState.meterDevice
        if let conn = caDev {
            if let rate = conn.nominalSampleRate, abs(rate - sampleRate) >= 1.0 {
                programmaticRate = rate
                sampleRate = rate
            }
            clockLocked = appState.clockLockSuppressed ? true : conn.isClockLocked
            // Query actual available rates from the device
            let deviceRates = conn.availableSampleRates
            if !deviceRates.isEmpty {
                availableRates = deviceRates
            }
        } else if let rate = (try? await device.getProperty(
                    PropertyAddress(selector: .sampleRate)))?.asFloat64,
                  rate > 0, abs(rate - sampleRate) >= 1.0 {
            // No CoreAudio connection (card simulation, or a transport that does
            // not present a HAL device): ask the connection itself. Without this
            // `sampleRate` stays at its initial 0, which matches no Picker tag, so
            // the Sample Rate row renders EMPTY rather than showing the rate the
            // status bar is already displaying.
            programmaticRate = rate
            sampleRate = rate
        }
        if caDev == nil,
           let status = (try? await device.getProperty(
                PropertyAddress(selector: .clockStatus)))?.asUInt32 {
            // `.clockStatus` is 0 when the PLL is locked. Same reason as the rate
            // above: without this the row stays at its initial `false` and claims
            // an internally-clocked device is unlocked.
            clockLocked = (status == 0)
        }
        // Try reading firmware info. The daemon's 'AEt1' (versionString) returns an XML plist
        // with full component details — but the daemon is broken on macOS 26.
        // The XPC path can read 'AEve' (version) which returns 3 bytes (major.minor.build),
        // but USB vendor reads may fail on MKI firmware. Fall back to static device info.
        do {
            if let ver = (try await device.getProperty(PropertyAddress(selector: .versionString))).asString,
               !ver.isEmpty {
                firmwareVersion = ver
                parsedFirmware = FirmwareInfo.parse(ver)
            }
        } catch {
            // versionString not available (expected on XPC path)
        }
        if parsedFirmware == nil {
            // Try raw firmware version (3 bytes → "major.minor.build")
            do {
                if let ver = (try await device.getProperty(PropertyAddress(selector: .version))).asString,
                   !ver.isEmpty {
                    firmwareVersion = ver
                }
            } catch {
                // USB vendor reads may fail on MKI — use static info
            }
            parsedFirmware = FirmwareInfo.fromDevice(device, firmwareVersion: firmwareVersion)
        }
        await loadBoardReadings(device: device)
        // Hand the assembled report to AppState so the About box can copy hardware and
        // software in one button without duplicating the provenance logic above.
        appState.deviceInfoSnapshot = currentDeviceReport()
        do {
            if let mode = (try await device.getProperty(PropertyAddress(selector: .deviceMode))).asUInt32 {
                deviceMode = mode
            }
        } catch {
            print("[Maestro] ERROR: loadProperties deviceMode failed: \(error)")
        }
        do {
            if let wc = (try await device.getProperty(PropertyAddress(selector: .wordClockDivide))).asUInt32 {
                wordClockOut = min(wc, 1) // Clamp to 0=normal, 1=divide
                print("[Maestro] loadProperties: wordClockDivide raw=\(wc) → \(wordClockOut)")
            }
        } catch {
            print("[Maestro] ERROR: loadProperties wordClockDivide failed: \(error)")
        }
        // Peak Hold and Over Hold mode
        do {
            if let ph = (try await device.getProperty(PropertyAddress(selector: .peakHoldMode))).asUInt32 {
                peakHoldMode = ph
            }
        } catch {
            print("[Maestro] ERROR: loadProperties peakHoldMode failed: \(error)")
        }
        do {
            if let oh = (try await device.getProperty(PropertyAddress(selector: .oversHoldMode))).asUInt32 {
                overHoldMode = oh
            }
        } catch {
            print("[Maestro] ERROR: loadProperties oversHoldMode failed: \(error)")
        }
        errorMessage = nil
    }

    /// Change the sample rate on the real hardware, then confirm both ends moved.
    ///
    /// The target is deliberately the REAL device, never the "Maestro USB" virtual
    /// one: over USB the rate belongs to the UAC2 clock in the hardware, so the
    /// virtual device follows it. Apogee's daemon worked the same way -- in USB
    /// Audio mode it sent no rate command at all, only recording the time of the
    /// change (og_source/maestrolink/Software/SymphonyIO.cpp:1897-1902, and the
    /// comment at :6536-6539). There is no XPC fallback for the same reason: a
    /// vendor rate command is not how this hardware takes its rate, so a fallback
    /// that "succeeds" and changes nothing is worse than no fallback.
    /// Keep the picker showing what the hardware is actually doing, for as long as
    /// this view is on screen.
    ///
    /// Every other path that moves the picker is event-shaped: a load reads once,
    /// and a write watches for a couple of seconds. Anything that changes the rate
    /// outside those windows left the picker stale indefinitely -- the front panel,
    /// another app, Audio MIDI Setup, or a DAW writing its project rate back after
    /// the write's own watch window has closed (see
    /// reportIfSomethingTookTheRateBack). A stale picker is worse than a slow one:
    /// it is the app stating a fact about the hardware that is not true.
    ///
    /// Deliberately a poll and not a property listener, for the reason given on
    /// CoreAudioDeviceConnection.waitForNominalSampleRate -- a listener's lifetime
    /// and Sendable requirements buy nothing here, where a HAL read is cheap and
    /// 2 s of staleness is invisible. The task is tied to the view, so it stops
    /// when the panel closes.
    private func reconcileSampleRate() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !isLoading, !rateWriteInFlight, !isProToolsMode else { continue }
            guard let conn = (appState.device as? CoreAudioDeviceConnection) ?? appState.meterDevice,
                  let actual = conn.nominalSampleRate,
                  abs(actual - sampleRate) >= 1.0
            else { continue }
            programmaticRate = actual
            sampleRate = actual
        }
    }

    private func writeSampleRate(_ rate: Double, generation: Int) async {
        /// True while this write is still the one the user is waiting on.
        func isCurrent() -> Bool { generation == rateWriteGeneration }
        // meterDevice is a CoreAudioDeviceConnection to the real USB device even when
        // the primary device connection is XPC.
        guard let conn = (appState.device as? CoreAudioDeviceConnection) ?? appState.meterDevice else {
            errorMessage = "Cannot set the sample rate: no CoreAudio connection to the hardware."
            rateWriteInFlight = false
            return
        }
        // Only the current write may lower the flag; a superseded one leaving would
        // re-open the reconcile loop on top of the write that replaced it.
        defer { if isCurrent() { rateWriteInFlight = false } }
        do {
            let settled = try await conn.setNominalSampleRateAndWait(rate)
            guard isCurrent() else { return }
            // Ours, not the user's: without the sentinel this assignment re-enters
            // onChange as though it were a fresh selection. Armed ONLY when it will
            // actually move the picker -- on the ordinary success path `sampleRate`
            // is already `settled`, no onChange fires, and a sentinel left armed
            // then swallows the user's next deliberate selection of that same rate.
            if abs(settled - sampleRate) >= 1.0 {
                programmaticRate = settled
                sampleRate = settled
            }
            guard abs(settled - rate) < 1.0 else {
                errorMessage = "The hardware stayed at \(formatSampleRate(settled)) — "
                    + "it would not accept \(formatSampleRate(rate))."
                return
            }
            errorMessage = nil
            if let tbDevice = appState.device as? ThunderboltDeviceConnection,
               let health = tbDevice.readTimingHealth() {
                print("[Maestro] TB timing health after rate change: rate=\(health.sampleRate) frame=\(health.frameReadback)/\(health.expectedFrame) latency=\(health.inputLatency)/\(health.outputLatency) safety=\(health.inputSafety)/\(health.outputSafety) int=0x\(String(health.intStatus, radix: 16)) xlink=0x\(String(health.xlinkStatus, radix: 16))")
            }
            // The PLL re-acquires over the next few seconds; do not let a refresh
            // in that window report the clock as unlocked.
            appState.suppressClockLockReporting()
            clockLocked = true
            await confirmVirtualDeviceFollowed(rate, isCurrent: isCurrent)
            guard isCurrent() else { return }
            await reportIfSomethingTookTheRateBack(rate, from: conn, isCurrent: isCurrent)
        } catch {
            guard isCurrent() else { return }
            errorMessage = "Error setting sample rate: \(error.localizedDescription)"
        }
    }

    /// The virtual device follows the hardware, it does not lead. If it does not
    /// arrive, say so: otherwise the picker looks correct while anything playing
    /// through "Maestro USB" is silent, which is the failure this whole path
    /// exists to remove.
    ///
    /// Two things make this more than a wait. The driver notices a rate mismatch
    /// from its IO callback, so with nothing playing through "Maestro USB" it will
    /// not notice until the next playback -- so after a short grace period we ask
    /// it directly. And a device that was never going to be asked is not a device
    /// that failed, so the alarming wording is reserved for a driver that had the
    /// question put to it, has audio running, and still disagrees.
    private func confirmVirtualDeviceFollowed(_ rate: Double, isCurrent: () -> Bool) async {
        guard let asp = CoreAudioDeviceConnection.findDevice(named: AppState.aspUSBDeviceName)
        else { return }   // not installed — nothing to follow

        // Playing through it? Then its own follower is already on this, and the
        // change lands within a configuration change.
        if await CoreAudioDeviceConnection.waitForNominalSampleRate(
            of: asp, toReach: rate, timeoutMilliseconds: 750) != nil { return }

        // Idle, or slow. Ask it directly -- it accepts a rate that agrees with the
        // hardware and refuses one that does not, so this cannot desync anything.
        CoreAudioDeviceConnection.nudgeNominalSampleRate(of: asp, to: rate)
        if await CoreAudioDeviceConnection.waitForNominalSampleRate(
            of: asp, toReach: rate, timeoutMilliseconds: 2250) != nil { return }

        // Three seconds have passed; if the user has since picked a different rate
        // this complaint is about a rate nobody is waiting for any more.
        guard isCurrent() else { return }

        let stuck = CoreAudioDeviceConnection.nominalSampleRate(of: asp)
            .map(formatSampleRate) ?? "an unknown rate"
        switch CoreAudioDeviceConnection.isDeviceRunning(asp) {
        case .some(true):
            errorMessage = "The hardware is at \(formatSampleRate(rate)) but “Maestro USB” is "
                + "still at \(stuck), and audio is playing through it — that audio is silent or wrong "
                + "until they agree. Stopping and restarting playback will move it."
        case .some(false):
            errorMessage = "The hardware is at \(formatSampleRate(rate)) but “Maestro USB” is "
                + "still at \(stuck). Nothing is playing through it, so nothing is broken yet — it "
                + "should pick the rate up when playback next starts."
        case .none:
            // Could not tell whether it is running, so imply neither. The
            // actionable half is true in both cases.
            errorMessage = "The hardware is at \(formatSampleRate(rate)) but “Maestro USB” is "
                + "still at \(stuck). Anything playing through it will be silent or wrong until "
                + "they agree; stopping and restarting playback will move it."
        }
    }

    /// The set succeeded and then something else undid it.
    ///
    /// A DAW holding the Symphony pins it to the *project* sample rate and writes
    /// that rate back about 200 ms after anyone else changes it. Every earlier
    /// check passes: the set returns noErr, the front panel shows the new rate,
    /// and "Maestro USB" dutifully follows -- then the DAW writes 48 kHz and the
    /// whole stack follows it back down. Measured 2026-09-12 against Logic Pro:
    /// five attempts, five reverts to the same constant whatever the rate was
    /// before, and with Logic suspended the change held indefinitely.
    ///
    /// So this is checked last, after the follow window, and the process is named.
    /// "It would not accept that rate" would be a lie pointing at the interface.
    private func reportIfSomethingTookTheRateBack(
        _ rate: Double, from conn: CoreAudioDeviceConnection, isCurrent: () -> Bool
    ) async {
        // Watch past the write-back, not just up to it. Returning early on the
        // first matching read would sample the window the DAW has not reached yet.
        var actual = rate
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(200))
            guard let now = conn.nominalSampleRate else { continue }
            if abs(now - rate) >= 1.0 { actual = now; break }
        }
        guard abs(actual - rate) >= 1.0 else { return }
        // The user picked something else while this was watching: the rate did not
        // get "taken back", it got superseded, and blaming another app for the
        // user's own second click is exactly the wrong story to tell.
        guard isCurrent() else { return }

        programmaticRate = actual
        sampleRate = actual

        let holders = conn.otherOutputClients
        if holders.isEmpty {
            errorMessage = "The hardware moved to \(formatSampleRate(rate)) and then went back "
                + "to \(formatSampleRate(actual)). Something else on this Mac is setting the "
                + "rate — an app playing through “Symphony I/O : USB Audio” will hold it at its "
                + "own rate."
        } else {
            let names = ListFormatter.localizedString(byJoining: holders.map(\.name))
            let verb = holders.count == 1 ? "is" : "are"
            let them = holders.count == 1 ? "it" : "them"
            errorMessage = "\(names) \(verb) playing through “Symphony I/O : USB Audio” and put "
                + "it back to \(formatSampleRate(actual)). Change the rate there — a DAW holds "
                + "its project rate — or quit \(them), then set \(formatSampleRate(rate)) here."
        }
    }

    private func writeClockSource(_ source: UInt32) async {
        guard let device = appState.device else { return }
        do {
            try await device.setProperty(
                PropertyAddress(selector: .clockSource),
                value: .uint32(source)
            )
            errorMessage = nil
        } catch {
            errorMessage = "Error setting clock source: \(error.localizedDescription)"
        }
    }

    private func formatSampleRate(_ rate: Double) -> String {
        if rate >= 1000 {
            return "\(String(format: "%.1f", rate / 1000)) kHz"
        }
        return "\(Int(rate)) Hz"
    }
}
