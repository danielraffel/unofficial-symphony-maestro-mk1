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
                Text(clockLocked ? "Locked" : "Unlocked")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 14)

            // Clock source
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(clockSourceDisplayName)
                    .font(.system(size: 11))
            }

            Divider().frame(height: 14)

            // Sample rate
            HStack(spacing: 4) {
                Image(systemName: "waveform.badge.microphone")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(formatSampleRate(sampleRate))
                    .font(.system(size: 11, design: .monospaced))
            }

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
                    .help("Click to reconnect to hardware")
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
                appState.inputPeakHold = Array(repeating: -60.0, count: appState.inputPeakHold.count)
                appState.outputPeakHold = Array(repeating: -60.0, count: appState.outputPeakHold.count)
                appState.digitalInputPeakHold = Array(repeating: -60.0, count: 24)
                appState.digitalOutputPeakHold = Array(repeating: -60.0, count: 24)
                Task {
                    do {
                        try await appState.device?.setProperty(
                            PropertyAddress(selector: .peaksClear), value: .uint32(1))
                    } catch {
                        print("[Maestro] ERROR: Clear Meters failed: \(error)")
                    }
                }
            } label: {
                Text("Clear Meters")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Clear all peak hold and over indicators (Cmd+K)")

        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 6)
        .background(.bar)
        .task(id: statusSourceID) {
            await observeStatus()
        }
    }

    private var hasConnectionIssue: Bool {
        appState.statusMessage.contains("not responding")
            || appState.statusMessage.contains("No hardware")
            || appState.statusMessage.contains("error")
            || appState.endpointStatusMessage == "Symphony Disconnected"
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
        let speakerControlsEnabled = SpeakerOutputLogic.speakerControlsEnabled(
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
                    appState.speakerMuted.toggle()
                    let muted = appState.speakerMuted
                    let prev = !muted
                    um?.registerUndo(withTarget: appState) { s in
                        Task { @MainActor in
                            s.speakerMuted = prev
                            try? await s.device?.setProperty(
                                PropertyAddress(selector: .outputMute), value: .bool(prev))
                        }
                    }
                    um?.setActionName("Speaker Mute")
                    Task { await writeProperty(.outputMute, value: .bool(muted)) }
                    appState.writeASPMute(muted)
                }
                .help(appState.speakerMuted ? "Speaker: Unmute" : "Speaker: Mute")
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
                        um?.registerUndo(withTarget: appState) { s in
                            Task { @MainActor in
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
                .help("Speaker level — drag to adjust, double-tap to reset")
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
                    appState.hp1Muted.toggle()
                    let muted = appState.hp1Muted
                    let prev = !muted
                    um?.registerUndo(withTarget: appState) { s in
                        Task { @MainActor in
                            s.hp1Muted = prev
                            try? await s.device?.setProperty(
                                PropertyAddress(selector: .headphone1Mute), value: .bool(prev))
                        }
                    }
                    um?.setActionName("Headphone 1 Mute")
                    Task { await writeProperty(.headphone1Mute, value: .bool(muted)) }
                }
                .help(appState.hp1Muted ? "HP 1: Unmute" : "HP 1: Mute")

                RotaryKnobView(
                    value: $state.hp1Level,
                    range: -127...0,
                    step: 1,
                    label: "",
                    unit: "dB",
                    size: 28,
                    defaultValue: -20,
                    arcColor: appState.hp1Muted ? .red.opacity(0.4) : Color(red: 0.52, green: 0.69, blue: 0.98),
                    externalReadout: true,
                    onUserChange: { level in
                        guard !isLoading else { return }
                        um?.registerUndo(withTarget: appState) { s in
                            Task { @MainActor in
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
                .help("Headphone 1 level — drag to adjust, double-tap to reset")
            }

            Divider().frame(height: 20)

            // HP2: mute icon + knob
            HStack(spacing: 4) {
                muteButton(
                    icon: appState.hp2Muted ? "speaker.slash.fill" : "headphones",
                    muted: appState.hp2Muted
                ) {
                    appState.hp2Muted.toggle()
                    let muted = appState.hp2Muted
                    let prev = !muted
                    um?.registerUndo(withTarget: appState) { s in
                        Task { @MainActor in
                            s.hp2Muted = prev
                            try? await s.device?.setProperty(
                                PropertyAddress(selector: .headphone2Mute), value: .bool(prev))
                        }
                    }
                    um?.setActionName("Headphone 2 Mute")
                    Task { await writeProperty(.headphone2Mute, value: .bool(muted)) }
                }
                .help(appState.hp2Muted ? "HP 2: Unmute" : "HP 2: Mute")

                RotaryKnobView(
                    value: $state.hp2Level,
                    range: -127...0,
                    step: 1,
                    label: "",
                    unit: "dB",
                    size: 28,
                    defaultValue: -20,
                    arcColor: appState.hp2Muted ? .red.opacity(0.4) : Color(red: 0.52, green: 0.69, blue: 0.98),
                    externalReadout: true,
                    onUserChange: { level in
                        guard !isLoading else { return }
                        um?.registerUndo(withTarget: appState) { s in
                            Task { @MainActor in
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
                .help("Headphone 2 level — drag to adjust, double-tap to reset")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
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
