import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


// MARK: - Status Bar

/// Persistent status bar above the detail pane.
/// Shows clock lock status, source, sample rate, and system status.
///
/// Evidence: `og_source/maestro2/App/Views/APMaestroFullViewWindow.m` — toolbar items
struct StatusBarView: View {
    @Environment(AppState.self) private var appState
    @State private var clockLocked: Bool = false
    @State private var clockSourceDisplayName: String = "Internal"
    @State private var sampleRate: Double?

    var body: some View {
        HStack(spacing: 16) {
            // Clock lock indicator
            HStack(spacing: 4) {
                Image(systemName: clockLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(clockLocked ? .green : .red)
                    .font(.system(size: 11))
                Text(PortStatusMessage.clock(locked: clockLocked, link: appState.transportType == .thunderbolt ? appState.thunderboltPortLink : .other))   // Apogee's wording (SymphonyIO.cpp:2961-2968)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .maestroHelp(clockLocked
                ? "Clock Status: the Symphony I/O is locked to its clock source."
                : "Clock Status: the Symphony I/O is not locked to its clock source. Check Clock Source in Device Settings > Clock.")

            Divider().frame(height: 14)

            // Sample rate, then clock source: the order of Device Settings > Clock
            HStack(spacing: 4) {
                Image(systemName: "waveform.badge.microphone")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(formatSampleRate(sampleRate))
                    .font(.system(size: 11, design: .monospaced))
            }
            .contentShape(Rectangle())
            .maestroHelp("Sample Rate. Change it in Device Settings > Clock.")

            Divider().frame(height: 14)

            // Clock source
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(shownClockSourceName)
                    .font(.system(size: 11))
            }
            .contentShape(Rectangle())
            .maestroHelp("Clock Source: where the Symphony I/O takes its clock from. Change it in Device Settings > Clock.")

            Spacer()

            // System status + reconnect
            HStack(spacing: 4) {
                if hasConnectionIssue {
                    Button {
                        Task { await appState.reconnectHardware() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text(appState.endpointStatusMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .maestroHelp(appState.portStatusMessage ?? appState.endpointStatusMessage)
                } else {
                    if appState.connectionMode == .hardware {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Text(appState.endpointStatusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            // Clear Meters — resets all peak hold and over indicators (fixed position, far right)
            Button {
                appState.clearMeters()
            } label: {
                Text("Clear Meters")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .maestroHelp("Clear all peak hold and over indicators (Cmd+K)")

        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 6)
        .background(.bar)
        .task(id: statusSourceID) {
            await observeStatus()
        }
        // Optical channel names follow the rate (`CardLayout.ChannelNaming`).
        .onChange(of: sampleRate) { _, rate in
            if let rate, rate > 0 { appState.channelNaming.sampleRate = rate }
        }
    }

    private var hasConnectionIssue: Bool {
        appState.statusMessage.contains("not responding")
            || appState.statusMessage.contains("No hardware")
            || appState.statusMessage.contains("error")
            || appState.endpointDisconnected
    }

    private struct StatusSourceID: Hashable {
        let connection: ObjectIdentifier?
        let audioConnection: ObjectIdentifier?
        let ready: Bool
        let disconnected: Bool
        let reload: UUID
    }

    private var statusSourceID: StatusSourceID {
        StatusSourceID(connection: appState.device.map { ObjectIdentifier($0) },
                       audioConnection: statusConnection.map { ObjectIdentifier($0) },
                       ready: appState.isHardwareInitialized,
                       disconnected: appState.connectionMode == .disconnected,
                       reload: appState.viewReloadToken)
    }

    /// The source the unit reports (`AppState.reportedClockSource`, from the
    /// front panel sync); otherwise what the bar showed before ("Internal" once
    /// connected, a dash while not).
    private var shownClockSourceName: String {
        guard clockSourceDisplayName != "—" else { return clockSourceDisplayName }
        return appState.reportedClockSourceName(sampleRate: sampleRate) ?? clockSourceDisplayName
    }

    private var statusConnection: CoreAudioDeviceConnection? {
        (appState.device as? CoreAudioDeviceConnection) ?? appState.meterDevice
    }

    private func observeStatus() async {
        sampleRate = nil
        clockLocked = false
        clockSourceDisplayName = "—"
        guard appState.isHardwareInitialized,
              appState.connectionMode != .disconnected,
              let device = appState.device else { return }

        if let conn = statusConnection {
            do {
                let observation = try conn.observeNominalSampleRate()
                defer { observation.stop() }
                for await rate in observation.rates {
                    guard !Task.isCancelled else { return }
                    sampleRate = rate
                    clockSourceDisplayName = "Internal" // Avoid unstable HAL clock-source-name query during device reconnects
                    clockLocked = appState.clockLockSuppressed ? true : conn.isClockLocked
                }
            } catch {
                print("[Maestro] Status rate observation failed: \(error)")
                // Keep all status fields current even if this HAL device refuses
                // listener registration. The normal path remains event-driven.
                while !Task.isCancelled {
                    await loadStatus()
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { break }
                }
            }
        } else {
            // Explicit card simulation uses the existing connection observer.
            let address = PropertyAddress(selector: .sampleRate)
            let observer = PropertyObserver()
            await device.addListener(observer, for: address)
            await loadStatus()
            for await _ in observer.stream {
                guard !Task.isCancelled else { break }
                await loadStatus()
            }
            await device.removeListener(observer, for: address)
            observer.finish()
        }
    }

    private func loadStatus() async {
        guard !Task.isCancelled, appState.device != nil else { return }
        guard let conn = statusConnection else {
            // No HAL device behind this connection (card simulation, or a
            // transport that presents none). Ask the connection directly rather
            // than leaving the bar on its initial state, which reads as a red
            // "Unlocked" on a device that is in fact internally clocked.
            if let device = appState.device {
                if let rate = (try? await device.getProperty(
                        PropertyAddress(selector: .sampleRate)))?.asFloat64, rate > 0 {
                    sampleRate = rate
                    clockSourceDisplayName = "Internal"
                }
                // `.clockStatus` is 0 when the PLL is locked.
                if let status = (try? await device.getProperty(
                        PropertyAddress(selector: .clockStatus)))?.asUInt32 {
                    clockLocked = (status == 0)
                }
            }
            return
        }
        if let rate = conn.nominalSampleRate { sampleRate = rate }
        clockSourceDisplayName = "Internal" // Avoid unstable HAL clock-source-name query during device reconnects
        // A rate change unlocks the PLL momentarily; see AppState.clockLockSuppressed.
        clockLocked = appState.clockLockSuppressed ? true : conn.isClockLocked
        print("[Maestro] loadStatus: rate=\(sampleRate ?? 0) clockSrc=\(clockSourceDisplayName) locked=\(clockLocked)")
    }

    private func formatSampleRate(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate > 0 else { return "—" }
        if rate >= 1000 {
            return "\(String(format: "%.1f", rate / 1000)) kHz"
        }
        return "\(Int(rate)) Hz"
    }
}

// MARK: - Monitor Toolbar

/// Simplified monitor controls in the macOS toolbar — mute icon + knob for Speaker, HP1, HP2.
/// Full controls (Dim, Mono, routing) remain on the Output tab.
struct MonitorToolbarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.undoManager) private var undoManager

    @State private var isLoading = true
    @State private var undoSpeakerLevel: Double = -20
    @State private var undoHP1Level: Double = -20
    @State private var undoHP2Level: Double = -20

    var body: some View {
        @Bindable var state = appState
        let um = undoManager
        let prevSpeakerLevel = undoSpeakerLevel
        let prevHP1Level = undoHP1Level
        let prevHP2Level = undoHP2Level
        let convertersOnly = appState.converterVolumeKeys
        let speakerControlsEnabled = convertersOnly || SpeakerOutputLogic.speakerControlsEnabled(
            mode: appState.speakerOutputMode,
            analogOutputChannels: appState.cardLayout.analogOutputStripCount)
        HStack(spacing: 12) {
            // Speaker: mute icon + knob
            HStack(spacing: 4) {
                muteButton(
                    icon: appState.speakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    muted: appState.speakerMuted,
                    wide: true
                ) {
                    guard !appState.hardwareWritesSuspended else { return }
                    appState.speakerMuted.toggle()
                    let muted = appState.speakerMuted
                    let prev = !muted
                    um?.registerUndo(withTarget: appState) { s in
                        Task { @MainActor in
                            guard !s.hardwareWritesSuspended else { return }
                            s.speakerMuted = prev
                            try? await s.device?.setProperty(
                                PropertyAddress(selector: .outputMute), value: .bool(prev))
                        }
                    }
                    um?.setActionName("Speaker Mute")
                    Task { await writeProperty(.outputMute, value: .bool(muted)) }
                    appState.writeASPMute(muted)
                }
                .maestroHelp(convertersOnly ? ConverterMonitorText.mute
                      : appState.speakerMuted ? "Speaker: Unmute" : "Speaker: Mute")
                .disabled(!speakerControlsEnabled)
                .opacity(speakerControlsEnabled ? 1 : 0.4)

                RotaryKnobView(
                    value: $state.speakerLevel,
                    range: -64...0,
                    step: 1,
                    label: "",
                    unit: "dB",
                    size: 28,
                    defaultValue: -20,
                    arcColor: appState.speakerMuted ? .red.opacity(0.4) : Color(red: 0.52, green: 0.69, blue: 0.98),
                    externalReadout: true,
                    onUserChange: { level in
                        guard !isLoading else { return }
                        // Writes are suspended: the unit keeps its level.
                        guard !appState.hardwareWritesSuspended else { appState.speakerLevel = prevSpeakerLevel; return }
                        um?.registerUndo(withTarget: appState) { s in
                            Task { @MainActor in
                                guard !s.hardwareWritesSuspended else { return }
                                s.speakerLevel = prevSpeakerLevel
                                try? await s.device?.setProperty(
                                    PropertyAddress(selector: .outputLevel),
                                    value: .uint32(UInt32(max(0, -prevSpeakerLevel))))
                            }
                        }
                        um?.setActionName("Speaker Level")
                        undoSpeakerLevel = level
                        Task { await writeProperty(.outputLevel, value: .uint32(UInt32(max(0, -level)))) }
                        appState.writeASPVolume(level)
                    }
                )
                .maestroHelp(convertersOnly ? ConverterMonitorText.volume
                      : "Speaker level — drag to adjust, double-tap to reset")
                .disabled(!speakerControlsEnabled)
                .opacity(speakerControlsEnabled ? 1 : 0.4)
            }

            Divider().frame(height: 20)

            // HP1: mute icon + knob
            HStack(spacing: 4) {
                muteButton(
                    icon: appState.hp1Muted ? "speaker.slash.fill" : "headphones",
                    muted: appState.hp1Muted
                ) {
                    guard !appState.hardwareWritesSuspended else { return }
                    appState.hp1Muted.toggle()
                    let muted = appState.hp1Muted
                    let prev = !muted
                    um?.registerUndo(withTarget: appState) { s in
                        Task { @MainActor in
                            guard !s.hardwareWritesSuspended else { return }
                            s.hp1Muted = prev
                            try? await s.device?.setProperty(
                                PropertyAddress(selector: .headphone1Mute), value: .bool(prev))
                        }
                    }
                    um?.setActionName("Headphone 1 Mute")
                    Task { await writeProperty(.headphone1Mute, value: .bool(muted)) }
                }
                .maestroHelp(appState.hp1Muted ? "HP 1: Unmute" : "HP 1: Mute")

                RotaryKnobView(
                    value: $state.hp1Level,
                    range: -64...0,
                    step: 1,
                    label: "",
                    unit: "dB",
                    size: 28,
                    defaultValue: -20,
                    arcColor: appState.hp1Muted ? .red.opacity(0.4) : Color(red: 0.52, green: 0.69, blue: 0.98),
                    externalReadout: true,
                    onUserChange: { level in
                        guard !isLoading else { return }
                        // Writes are suspended: the unit keeps its level.
                        guard !appState.hardwareWritesSuspended else { appState.hp1Level = prevHP1Level; return }
                        um?.registerUndo(withTarget: appState) { s in
                            Task { @MainActor in
                                guard !s.hardwareWritesSuspended else { return }
                                s.hp1Level = prevHP1Level
                                try? await s.device?.setProperty(
                                    PropertyAddress(selector: .headphone1Level),
                                    value: .uint32(UInt32(max(0, -prevHP1Level))))
                            }
                        }
                        um?.setActionName("Headphone 1 Level")
                        undoHP1Level = level
                        Task { await writeProperty(.headphone1Level, value: .uint32(UInt32(max(0, -level)))) }
                    }
                )
                .maestroHelp("Headphone 1 level — drag to adjust, double-tap to reset")
            }
            .symphonyOnly(convertersOnly)

            Divider().frame(height: 20)

            // HP2: mute icon + knob
            HStack(spacing: 4) {
                muteButton(
                    icon: appState.hp2Muted ? "speaker.slash.fill" : "headphones",
                    muted: appState.hp2Muted
                ) {
                    guard !appState.hardwareWritesSuspended else { return }
                    appState.hp2Muted.toggle()
                    let muted = appState.hp2Muted
                    let prev = !muted
                    um?.registerUndo(withTarget: appState) { s in
                        Task { @MainActor in
                            guard !s.hardwareWritesSuspended else { return }
                            s.hp2Muted = prev
                            try? await s.device?.setProperty(
                                PropertyAddress(selector: .headphone2Mute), value: .bool(prev))
                        }
                    }
                    um?.setActionName("Headphone 2 Mute")
                    Task { await writeProperty(.headphone2Mute, value: .bool(muted)) }
                }
                .maestroHelp(appState.hp2Muted ? "HP 2: Unmute" : "HP 2: Mute")

                RotaryKnobView(
                    value: $state.hp2Level,
                    range: -64...0,
                    step: 1,
                    label: "",
                    unit: "dB",
                    size: 28,
                    defaultValue: -20,
                    arcColor: appState.hp2Muted ? .red.opacity(0.4) : Color(red: 0.52, green: 0.69, blue: 0.98),
                    externalReadout: true,
                    onUserChange: { level in
                        guard !isLoading else { return }
                        // Writes are suspended: the unit keeps its level.
                        guard !appState.hardwareWritesSuspended else { appState.hp2Level = prevHP2Level; return }
                        um?.registerUndo(withTarget: appState) { s in
                            Task { @MainActor in
                                guard !s.hardwareWritesSuspended else { return }
                                s.hp2Level = prevHP2Level
                                try? await s.device?.setProperty(
                                    PropertyAddress(selector: .headphone2Level),
                                    value: .uint32(UInt32(max(0, -prevHP2Level))))
                            }
                        }
                        um?.setActionName("Headphone 2 Level")
                        undoHP2Level = level
                        Task { await writeProperty(.headphone2Level, value: .uint32(UInt32(max(0, -level)))) }
                    }
                )
                .maestroHelp("Headphone 2 level — drag to adjust, double-tap to reset")
            }
            .symphonyOnly(convertersOnly)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        // Sleep or wake validation: a change would never reach the unit.
        .disabled(appState.hardwareWritesSuspended)
        .task(id: appState.viewReloadToken) {
            await loadMonitorState()
        }
    }

    // MARK: - Mute Button

    private func muteButton(icon: String, muted: Bool, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: wide ? 34 : 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(muted ? Color.red.opacity(0.25) : Color.gray.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(muted ? .red : .secondary)
    }

    // MARK: - Hardware I/O

    private func writeProperty(_ selector: AudioPropertySelector, value: PropertyValue) async {
        do {
            try await appState.device?.setProperty(PropertyAddress(selector: selector), value: value)
        } catch {
            print("[Maestro] ERROR: writeProperty \(selector) failed: \(error)")
        }
    }

    private func loadMonitorState() async {
        defer { isLoading = false }
        guard appState.device != nil else { return }
        let deadline = Date().addingTimeInterval(30)
        while !appState.isHardwareInitialized {
            if Date() > deadline {
                print("[Maestro] loadMonitorState: timed out waiting for hardware init")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        do {
            if let attenuation = (try await appState.device?.getProperty(PropertyAddress(selector: .outputLevel)))?.asUInt32 {
                let level = -Double(attenuation)
                appState.speakerLevel = level
                undoSpeakerLevel = level
            }
        } catch {
            print("[Maestro] ERROR: loadMonitorState outputLevel failed: \(error)")
        }
        do {
            if let mute = (try await appState.device?.getProperty(PropertyAddress(selector: .outputMute)))?.asBool {
                appState.speakerMuted = mute
                if mute {
                    print("[Maestro] Hardware muted on startup — sending auto-unmute")
                    appState.speakerMuted = false
                    try await appState.device?.setProperty(
                        PropertyAddress(selector: .outputMute), value: .bool(false))
                }
            }
        } catch {
            print("[Maestro] ERROR: loadMonitorState outputMute failed: \(error)")
        }
        do {
            if let attenuation = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone1Level)))?.asUInt32 {
                let level = -Double(attenuation)
                appState.hp1Level = level
                undoHP1Level = level
            }
        } catch DeviceConnectionError.unsupportedProperty(_) {
        } catch {
            print("[Maestro] ERROR: loadMonitorState headphone1Level failed: \(error)")
        }
        do {
            if let mute = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone1Mute)))?.asBool {
                appState.hp1Muted = mute
            }
        } catch DeviceConnectionError.unsupportedProperty(_) {
        } catch {
            print("[Maestro] ERROR: loadMonitorState headphone1Mute failed: \(error)")
        }
        do {
            if let attenuation = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone2Level)))?.asUInt32 {
                let level = -Double(attenuation)
                appState.hp2Level = level
                undoHP2Level = level
            }
        } catch DeviceConnectionError.unsupportedProperty(_) {
        } catch {
            print("[Maestro] ERROR: loadMonitorState headphone2Level failed: \(error)")
        }
        do {
            if let mute = (try await appState.device?.getProperty(PropertyAddress(selector: .headphone2Mute)))?.asBool {
                appState.hp2Muted = mute
            }
        } catch DeviceConnectionError.unsupportedProperty(_) {
        } catch {
            print("[Maestro] ERROR: loadMonitorState headphone2Mute failed: \(error)")
        }
    }
}

// MARK: - Converters only (no Symphony I/O)

/// Text for the monitor controls when the cable has converters only. The
/// AD-16X, DA-16X, DD-16X and Rosetta 800 have no speaker or headphone outputs
/// (their user guides; Apogee's software had no monitor controls for them).
enum ConverterMonitorText {
    static let unsupported = "Not supported on converters. Speaker and headphone "
        + "controls need a Symphony I/O; these converters have no speaker or headphone outputs."
    /// Input and output strip settings (reference levels, Soft Limit, trims).
    static let channelSetting = "Not supported on converters. This is a Symphony I/O setting; "
        + "set levels on the converter's front panel."
    static let volume = "Volume — what the Mac's volume keys control on converters: "
        + "the level of Mixer 1, which reaches the converters only where Output Routing sends it "
        + "(by default every DAW output goes straight to its converter output). "
        + "Outputs routed directly are not affected. Master in the Mixer is separate."
    static let mute = "Mute — silences Mixer 1 (the Mac's mute key does the same)."
}

extension View {
    /// Greys out a Symphony I/O-only control when the cable has converters
    /// only. The tooltip sits on an overlay because macOS does not show the
    /// tooltip of a disabled control. Unchanged on a Symphony I/O.
    @ViewBuilder
    func symphonyOnly(_ convertersOnly: Bool, help: String = ConverterMonitorText.unsupported) -> some View {
        if convertersOnly {
            self.disabled(true)
                .opacity(0.4)
                .overlay(Color.clear.contentShape(Rectangle()).maestroHelp(help))
        } else {
            self
        }
    }
}
