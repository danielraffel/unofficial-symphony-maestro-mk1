import Foundation
import MaestroCore
import MaestroDevice

/// What has been sent as the volume keys' output: to which connection, in
/// which driver state (or helper), for which kind of cable, and the choices.
struct KeyboardVolumeSent: Equatable {
    let connection: ObjectIdentifier
    /// ThunderBridge: the connection's card ledger epoch, which changes with
    /// the driver instance, a link recovery and a card re-init. USB: the
    /// helper's epoch.
    let epoch: UInt64
    let converters: Bool
    var outputs: [DeviceUnit: KeyboardVolumeOutput]
}

// Device Settings › Volume Keys › Audio Output: which output of each unit the
// Mac's volume and mute keys move. The choice is saved per unit with the
// unit's other device settings (`DeviceSettingsStore`, under
// `.keyboardVolumeOutputID`), as the original saved `monitorOutput` per unit
// (og_source/symphonymk1/ext/maestrolink/Software/SymphonyIO.cpp:5146,
// restored at :4949), and is sent to the driver (selector 15) or the USB
// helper ("setMonitorOutput") on connect, after a recovery or a driver
// restart, and when it changes.
extension AppState {
    static let keyboardVolumeAddress = PropertyAddress(selector: .keyboardVolumeOutputID)
    /// The pause after a choice the driver or the helper did not take.
    static let keyboardVolumeRetryPause: TimeInterval = 5

    /// Where a unit's choice is saved; nil when that unit is not connected.
    func keyboardVolumeStore(for unit: DeviceUnit) -> DeviceSettingsStore? {
        switch unit {
        case .a:
            if let tb = device as? ThunderboltDeviceConnection { return tb.settingsStore }
            return (device as? XPCDeviceConnection)?.settingsStore
        case .b:
            return (unitBDevice as? ThunderboltUnitBConnection)?.settingsStore
        }
    }

    /// Whether a unit has an analog output card. A unit whose cards are not
    /// known yet counts as having one (Speaker stays offered and chosen).
    func keyboardVolumeHasAnalogOutput(_ unit: DeviceUnit) -> Bool {
        switch unit {
        case .a:
            guard primaryBoardSource == .detected || secondaryBoardSource == .detected else { return true }
            return cardLayout.analogOutputStripCount > 0
        case .b:
            guard let layout = unitBLayout else { return true }
            return layout.analogOutputStripCount > 0
        }
    }

    /// The pop-up's entries for a unit.
    func keyboardVolumeEntries(for unit: DeviceUnit) -> [KeyboardVolumeOutput] {
        KeyboardVolumeOutput.entries(hasAnalogOutput: keyboardVolumeHasAnalogOutput(unit),
                                     convertersOnly: unit == .a && converterVolumeKeys)
    }

    /// A unit's choice: the saved one if the unit offers it, the default
    /// otherwise.
    func keyboardVolumeOutput(for unit: DeviceUnit) -> KeyboardVolumeOutput {
        _ = keyboardVolumeRevision   // the pop-up follows a change
        return KeyboardVolumeOutput.resolve(
            saved: keyboardVolumeStore(for: unit)?.value(for: Self.keyboardVolumeAddress)?.asUInt32,
            hasAnalogOutput: keyboardVolumeHasAnalogOutput(unit),
            convertersOnly: unit == .a && converterVolumeKeys)
    }

    /// The speaker mode a unit's Speaker entry is named after.
    func keyboardVolumeSpeakerMode(for unit: DeviceUnit) -> UInt32 {
        unit == .a ? speakerOutputMode : (unitBSpeakerOutputMode ?? SpeakerOutputLogic.stereo)
    }

    /// Read unit B's speaker mode, for the name of its Speaker entry.
    @MainActor
    func refreshUnitBSpeakerMode() async {
        guard let b = unitBDevice,
              let mode = (try? await b.getProperty(PropertyAddress(selector: .speakerOutputMode)))?.asUInt32,
              unitBDevice === b else { return }
        if unitBSpeakerOutputMode != mode { unitBSpeakerOutputMode = mode }
    }

    /// Whether the pop-up can be offered: a driver or helper that can be told
    /// the choice is serving a unit that has one. An older driver moves the
    /// speakers (Headphone 1 in Line mode) by itself; an older helper always
    /// the speakers.
    var keyboardVolumeOutputAvailable: Bool {
        if connectionMode == .simulated { return true }
        guard connectionMode == .hardware else { return false }
        if device is ThunderboltDeviceConnection {
            return KeyboardVolumeOutput.driverSupports(servingDextBuild)
                && (connectedUnit == nil || converterVolumeKeys)
        }
        return device is XPCDeviceConnection && !usbHelperOutdated && connectedUnit == nil
    }

    /// The keys do nothing for unit A right now: None on converters, or
    /// Speaker while the outputs are in Line mode.
    var keyboardVolumeKeysDoNothing: Bool {
        keyboardVolumeOutputAvailable
            && keyboardVolumeOutput(for: .a).keysDoNothing(speakerMode: speakerOutputMode)
    }

    /// The Audio Output pop-up was changed.
    @MainActor
    func chooseKeyboardVolumeOutput(_ output: KeyboardVolumeOutput, unit: DeviceUnit) {
        guard keyboardVolumeEntries(for: unit).contains(output),
              let store = keyboardVolumeStore(for: unit) else { return }
        store.record(.uint32(output.rawValue), for: Self.keyboardVolumeAddress)
        keyboardVolumeRevision &+= 1
        keyboardVolumeRetryAfter = .distantPast
        Task { @MainActor in await self.serviceKeyboardVolumeOutput() }
    }

    /// The level and mute Maestro shows for an output of unit A.
    func keyboardVolumeLevel(of output: KeyboardVolumeOutput) -> (dB: Double, muted: Bool)? {
        switch output {
        case .speakers, .mixer1Level: return (speakerLevel, speakerMuted)
        case .headphone1: return (hp1Level, hp1Muted)
        case .headphone2: return (hp2Level, hp2Muted)
        case .none: return nil
        }
    }

    func setKeyboardVolumeLevel(_ dB: Double, of output: KeyboardVolumeOutput) {
        switch output {
        case .speakers, .mixer1Level: if speakerLevel != dB { speakerLevel = dB }
        case .headphone1: if hp1Level != dB { hp1Level = dB }
        case .headphone2: if hp2Level != dB { hp2Level = dB }
        case .none: break
        }
    }

    func setKeyboardVolumeMute(_ muted: Bool, of output: KeyboardVolumeOutput) {
        switch output {
        case .speakers, .mixer1Level: if speakerMuted != muted { speakerMuted = muted }
        case .headphone1: if hp1Muted != muted { hp1Muted = muted }
        case .headphone2: if hp2Muted != muted { hp2Muted = muted }
        case .none: break
        }
    }

    /// What the choices to send are, for the connection now serving: nil when
    /// nothing can or need be sent.
    @MainActor
    func keyboardVolumeWanted() -> KeyboardVolumeSent? {
        guard connectionMode == .hardware, !hardwareWritesSuspended else { return nil }
        if let tb = device as? ThunderboltDeviceConnection {
            guard KeyboardVolumeOutput.driverSupports(servingDextBuild),
                  connectedUnit == nil || converterVolumeKeys else { return nil }
            var outputs: [DeviceUnit: KeyboardVolumeOutput] = [.a: keyboardVolumeOutput(for: .a)]
            // Unit B only while the driver has it configured at 64 channels
            // (it refuses the choice otherwise).
            if !converterVolumeKeys, unitB?.setupComplete == true, portSelection.selection == .ports1And2,
               unitBDevice != nil {
                outputs[.b] = keyboardVolumeOutput(for: .b)
            }
            return KeyboardVolumeSent(connection: ObjectIdentifier(tb), epoch: tb.cardMixers.epoch,
                                      converters: converterVolumeKeys, outputs: outputs)
        }
        if let xpc = device as? XPCDeviceConnection {
            // Not while the unit is starting up, and not under an older helper.
            guard connectedUnit == nil, isHardwareInitialized, !usbHelperOutdated,
                  usbSettleRemainingNow <= 0 else { return nil }
            return KeyboardVolumeSent(connection: ObjectIdentifier(xpc), epoch: xpc.helperEpoch,
                                      converters: false, outputs: [.a: keyboardVolumeOutput(for: .a)])
        }
        return nil
    }

    /// Send the choices that have not reached the driver or the helper serving
    /// now. Called on each healthy health-loop cycle and when a choice changes;
    /// it does nothing when everything is already there.
    @MainActor
    func serviceKeyboardVolumeOutput() async {
        guard !keyboardVolumeServiceRunning, let wanted = keyboardVolumeWanted(),
              wanted != keyboardVolumeSent, Date() >= keyboardVolumeRetryAfter else { return }
        keyboardVolumeServiceRunning = true
        defer { keyboardVolumeServiceRunning = false }
        // Only what differs, unless the driver or the helper is another one.
        let previous = keyboardVolumeSent.flatMap {
            $0.connection == wanted.connection && $0.epoch == wanted.epoch && $0.converters == wanted.converters
                ? $0.outputs : nil
        } ?? [:]
        var landed = previous
        var complete = true
        if let tb = device as? ThunderboltDeviceConnection {
            for unit in [DeviceUnit.a, .b] {
                guard let output = wanted.outputs[unit], previous[unit] != output else { continue }
                if await tb.setMonitorOutput(output, unit: unit) {
                    landed[unit] = output
                    // None on converters: the driver has put the mixer level
                    // back to 0 dB, unmuted, and holds its controls there.
                    if output == .none, device === tb {
                        speakerLevel = 0
                        speakerMuted = false
                    }
                } else {
                    complete = false
                    print("[Maestro] Volume keys: the driver did not take \(output) for unit \(unit == .a ? "A" : "B"); trying again")
                }
            }
            guard device === tb else { return }
        } else if let xpc = device as? XPCDeviceConnection, let output = wanted.outputs[.a] {
            if await applyUSBKeyboardVolumeOutput(output, to: xpc) {
                landed[.a] = output
            } else {
                complete = false
            }
            guard device === xpc else { return }
        }
        keyboardVolumeSent = KeyboardVolumeSent(connection: wanted.connection, epoch: wanted.epoch,
                                                converters: wanted.converters, outputs: landed)
        keyboardVolumeRetryAfter = complete ? .distantPast : Date().addingTimeInterval(Self.keyboardVolumeRetryPause)
    }

    /// USB: make `output` the one the helper's volume and mute move. When the
    /// helper already moves it, nothing is sent. Otherwise the helper is given
    /// the output's own level and mute (read from the unit), Maestro shows
    /// them, and the Mac's "Maestro USB" volume is set to them, so that the
    /// next key press steps from that output's level and not from the level
    /// of the output chosen before.
    @MainActor
    private func applyUSBKeyboardVolumeOutput(_ output: KeyboardVolumeOutput, to xpc: XPCDeviceConnection) async -> Bool {
        if await xpc.keyboardVolumeOutputInHelper() == output {
            // Speaker in Line mode: the keys move nothing, and the Mac's
            // control may have drifted while Maestro was closed. It is put
            // back to the speaker's own level and mute, read from the unit.
            guard device === xpc, output.keysDoNothing(speakerMode: speakerOutputMode) else { return true }
            guard let state = await xpc.keyboardVolumeState(of: .speakers), device === xpc else { return false }
            setKeyboardVolumeLevel(-Double(state.attenuation), of: .speakers)
            setKeyboardVolumeMute(state.muted, of: .speakers)
            showSpeakerLevelOnMacVolume()
            return true
        }
        guard device === xpc, let state = await xpc.setKeyboardVolumeOutput(output), device === xpc else {
            print("[Maestro] Volume keys: the USB helper did not take \(output); trying again")
            return false
        }
        let dB = -Double(state.attenuation)
        setKeyboardVolumeLevel(dB, of: output)
        setKeyboardVolumeMute(state.muted, of: output)
        writeASPVolume(dB, output: output)
        writeASPMute(state.muted, output: output)
        print("[Maestro] Volume keys: USB output \(output), level \(Int(dB)) dB, muted \(state.muted)")
        return true
    }
}
