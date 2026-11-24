import Foundation
import MaestroCore
import MaestroDevice

/// See `AppState.monitorLevelsSettled`.
struct MonitorLevelsSettled {
    /// Weak, so a later connection allocated at the same address is never
    /// taken for this one.
    weak var connection: ThunderboltDeviceConnection?
    let recoveryCount: UInt32
    let outputs: Set<MonitorLevelsAtConnect.Output>
}

/// A4: speaker and headphone levels at connect, ThunderBridge/PCIe.
///
/// The original owned these levels on the Mac and wrote them at every connect
/// (`SymphonyIO::ApplySettingsToHardware`,
/// og_source/maestrolink/Software/SymphonyIO.cpp:4670, :4677). Ours puts each
/// of unit A's outputs at the QUIETER of the level saved on this Mac and the
/// unit's own (`MonitorLevelsAtConnect`), so a Symphony I/O that was
/// power-cycled comes back at the user's lower level instead of its -20 dB
/// default, and nothing is ever made louder than the unit had it.
///
/// Mutes are left to `SpeakerMuteAdoption` (a muted speaker stays muted).
/// Dim, mono and the speaker set are already written at connect with the
/// other settings this Mac owns (`DeviceSettingsStore.ownedSettings`). Unit B
/// and converters are not touched. USB is not changed here: its helper keeps
/// and writes the speaker level itself.
extension AppState {
    static func keyboardOutput(_ output: MonitorLevelsAtConnect.Output) -> KeyboardVolumeOutput {
        switch output {
        case .speakers: .speakers
        case .headphone1: .headphone1
        case .headphone2: .headphone2
        }
    }

    /// Run the connect step for unit A and adopt what it settled on. Called
    /// at connect (`syncDeviceSettingsToHardware`) and after a link recovery
    /// in place (the unit power-cycled under a running driver).
    @MainActor
    func applyMonitorLevelsAtConnect(_ tb: ThunderboltDeviceConnection) async {
        // Nothing is saved while the unit's levels are being found out.
        monitorLevelsSettled = nil
        func admitted() -> Bool {
            device === tb && transportType == .thunderbolt && connectionMode == .hardware
                && isHardwareInitialized && !hardwareWritesSuspended
                && connectedUnit == nil && converterSystem == nil && unitAIdentity != nil
        }
        guard admitted() else { return }
        let recovery = await Task.detached(priority: .utility) { tb.linkState()?.recoveryCount }.value
        guard admitted(), let recovery else { return }
        guard let result = await tb.applySavedMonitorLevels(), admitted() else { return }
        if let mode = result.speakerMode, mode != speakerOutputMode { speakerOutputMode = mode }
        // Recording starts with the levels the unit has now, so the shown
        // levels below are saved as they are adopted (`noteMonitorLevel`).
        monitorLevelsSettled = MonitorLevelsSettled(connection: tb, recoveryCount: recovery,
                                                    outputs: Set(result.settled.keys))
        for output in MonitorLevelsAtConnect.Output.allCases {
            guard let attenuation = result.settled[output] else { continue }
            let dB = -Double(attenuation)
            let keys = Self.keyboardOutput(output)
            // The driver has moved the Mac's volume control with the write
            // when this is the keys' output: its echo is not a Mac change.
            if result.written.contains(output) { writeASPVolume(dB, output: keys) }
            setKeyboardVolumeLevel(dB, of: keys)
        }
        if !result.written.isEmpty {
            print("[Maestro] Levels at connect: turned down to the saved level: "
                + result.written.map { "\($0) -\(result.settled[$0] ?? 0) dB" }.joined(separator: ", "))
        }
    }

    /// A shown level changed: save it as the output's level when it is known
    /// to be unit A's real level on this connection (see
    /// `monitorLevelsSettled`). Never the speakers in Line, never converters.
    func noteMonitorLevel(_ output: MonitorLevelsAtConnect.Output, dB: Double) {
        guard let settled = monitorLevelsSettled, settled.outputs.contains(output),
              let tb = device as? ThunderboltDeviceConnection,
              settled.connection === tb,
              tb.lastLinkState?.recoveryCount == settled.recoveryCount,
              transportType == .thunderbolt, connectionMode == .hardware,
              !hardwareWritesSuspended, connectedUnit == nil, converterSystem == nil,
              output != .speakers || speakerOutputMode != SpeakerOutputLogic.line,
              let attenuation = MonitorLevelsAtConnect.attenuation(dB: dB) else { return }
        tb.recordSavedMonitorLevel(output, attenuation: attenuation)
    }
}
