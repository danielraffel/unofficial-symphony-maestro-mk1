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

struct MonitorMutesSettled {
    weak var connection: (any DeviceConnection)?
    let generation: UUID
    let recoveryCount: UInt32?
    var outputs: Set<MonitorMutesAtConnect.Output>
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
/// Mutes use the same connect boundary as levels. The USB helper remains the
/// speaker owner, while ThunderBridge restores all three outputs towards mute.
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
        // Nothing is saved while the unit's levels are being found out, and
        // the step is owed until it has run on this connection.
        monitorLevelsSettled = nil
        monitorMutesSettled = nil
        monitorLevelsOwed = tb
        func admitted() -> Bool {
            device === tb && transportType == .thunderbolt && connectionMode == .hardware
                && isHardwareInitialized && !hardwareWritesSuspended
                && connectedUnit == nil && converterSystem == nil && unitAIdentity != nil
        }
        guard admitted() else { return }
        let recovery = await Task.detached(priority: .utility) { tb.linkState()?.recoveryCount }.value
        guard admitted(), let recovery else { return }
        // The driver's echo of a level written below is not a Mac volume change.
        suppressMacVolumeOverlay()
        let applied = await tb.applySavedMonitorLevels()
        guard admitted() else { return }
        // Ran: converters (nil) have nothing to do either. A mute that could
        // not be read or written is tried again by the health loop, after a
        // pause.
        if monitorLevelsOwed === tb, applied?.mutesOwed != true { monitorLevelsOwed = nil }
        if applied?.mutesOwed == true { monitorMutesRetryAfter = Date().addingTimeInterval(5) }
        guard let result = applied else { return }
        if let mode = result.speakerMode, mode != speakerOutputMode { speakerOutputMode = mode }
        // Recording starts with the levels the unit has now, so the shown
        // levels below are saved as they are adopted (`noteMonitorLevel`).
        monitorLevelsSettled = MonitorLevelsSettled(connection: tb, recoveryCount: recovery,
                                                    outputs: Set(result.settled.keys))
        monitorMutesSettled = MonitorMutesSettled(connection: tb, generation: unitAGeneration,
                                                  recoveryCount: recovery,
                                                  outputs: Set(result.mutesSettled.keys))
        for output in MonitorLevelsAtConnect.Output.allCases {
            guard let attenuation = result.settled[output] else { continue }
            let dB = -Double(attenuation)
            let keys = Self.keyboardOutput(output)
            // The driver has moved the Mac's volume control with the write
            // when this is the keys' output: its echo is not a Mac change.
            if result.written.contains(output) { writeASPVolume(dB, output: keys) }
            setKeyboardVolumeLevel(dB, of: keys)
        }
        let keptSpeakerMuted = speakerMuted
        for output in MonitorMutesAtConnect.Output.allCases {
            guard let muted = result.mutesSettled[output] else { continue }
            switch output {
            case .speakers:
                if !(keptSpeakerMuted && tb.savedMonitorMute(.speakers) == nil && !muted) {
                    speakerMuted = muted
                }
            case .headphone1: hp1Muted = muted
            case .headphone2: hp2Muted = muted
            }
            if result.mutesWritten.contains(output) {
                let keys: KeyboardVolumeOutput = switch output {
                case .speakers: .speakers
                case .headphone1: .headphone1
                case .headphone2: .headphone2
                }
                if output == .speakers || keys == keyboardVolumeOutput(for: .a) {
                    writeASPMute(muted, output: keys)
                }
            }
        }
        if !result.written.isEmpty {
            print("[Maestro] Levels at connect: turned down to the saved level: "
                + result.written.map { "\($0) -\(result.settled[$0] ?? 0) dB" }.joined(separator: ", "))
        }
    }

    /// The health loop: run the connect step again where it was owed and
    /// could not run (asleep, link state unreadable, identity not read yet).
    @MainActor
    func serviceMonitorLevels() async {
        guard let tb = monitorLevelsOwed, device === tb, Date() >= monitorMutesRetryAfter else { return }
        await applyMonitorLevelsAtConnect(tb)
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

    func noteMonitorMute(_ output: MonitorMutesAtConnect.Output, muted: Bool) {
        guard let settled = monitorMutesSettled,
              settled.outputs.contains(output),
              let connection = device,
              settled.connection === connection,
              settled.generation == unitAGeneration,
              transportType == (connection is XPCDeviceConnection ? .usb : .thunderbolt),
              connectionMode == .hardware, isHardwareInitialized,
              !hardwareWritesSuspended, connectedUnit == nil, converterSystem == nil,
              unitAIdentity != nil,
              output != .speakers || speakerOutputMode != SpeakerOutputLogic.line else { return }
        if let recovery = settled.recoveryCount,
           (connection as? ThunderboltDeviceConnection)?.lastLinkState?.recoveryCount != recovery { return }
        if let tb = connection as? ThunderboltDeviceConnection {
            tb.recordSavedMonitorMute(output, muted: muted)
        } else if let xpc = connection as? XPCDeviceConnection {
            xpc.recordSavedMonitorMute(output, muted: muted)
        }
    }

    @MainActor
    func applyMonitorMutesAtConnect(_ xpc: XPCDeviceConnection) async -> Bool {
        monitorMutesSettled = nil
        guard device === xpc, transportType == .usb, connectionMode == .hardware,
              isHardwareInitialized, !hardwareWritesSuspended, connectedUnit == nil,
              converterSystem == nil, unitAIdentity != nil else { return false }
        let oldHP1 = hp1Muted
        let oldHP2 = hp2Muted
        let values = await xpc.applySavedMonitorMutes()
        guard device === xpc else { return false }
        monitorMutesSettled = MonitorMutesSettled(connection: xpc, generation: unitAGeneration,
                                                  recoveryCount: nil, outputs: Set(values.settled.keys))
        // The shown mute changed while the step ran (the user, the Mac's mute
        // control or a view reading the unit): which of that and the step's
        // own write the unit ended at is not known, so the unit is asked and
        // its answer is shown and saved. Nothing is unmuted here. An answer
        // that cannot be believed leaves the step owed.
        var owed = values.owed
        for output in [MonitorMutesAtConnect.Output.headphone1, .headphone2] {
            let selector: AudioPropertySelector = output == .headphone1 ? .headphone1Mute : .headphone2Mute
            let shown = output == .headphone1 ? hp1Muted : hp2Muted
            let before = output == .headphone1 ? oldHP1 : oldHP2
            var muted = values.settled[output]
            if shown != before, muted != nil {
                let raw = await xpc.restoreReadBelievedByte(PropertyAddress(selector: selector))
                guard device === xpc else { return false }
                muted = raw == 0 ? false : raw == 1 ? true : nil
                if let muted { xpc.recordSavedMonitorMute(output, muted: muted) } else {
                    owed = true
                    monitorMutesSettled?.outputs.remove(output)
                }
            }
            guard let muted else { continue }
            if output == .headphone1 { hp1Muted = muted } else { hp2Muted = muted }
            // The Mac's mute control is told of a muted headphone where it is
            // the keys' output, so a later read of that control cannot bring
            // back "unmuted" and erase the saved mute. Only once this helper
            // is known to move that headphone: until then its mute may still
            // be the speakers', and the control is told when the keys' output
            // settles (`applyUSBKeyboardVolumeOutput`).
            let keys: KeyboardVolumeOutput = output == .headphone1 ? .headphone1 : .headphone2
            if muted, keyboardVolumeSettled(keys), keyboardVolumeSent?.epoch == xpc.helperEpoch {
                writeASPMute(true, output: keys)
            }
        }
        return owed
    }
}
