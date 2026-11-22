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

/// What a change of the Mac's volume or mute control (the driver's on
/// ThunderBridge, "Maestro USB" over USB) means for the levels Maestro shows.
enum MacVolumeAdoption: Equatable {
    /// Nothing: whose level the control holds is not known yet, or the keys
    /// do nothing and the driver holds its control itself.
    case ignore
    /// USB, Speaker chosen in Line mode: the helper ignored the change, and
    /// the Mac's control is put back to the speaker's level and mute.
    case putBack
    /// It is this output's level or mute.
    case level(KeyboardVolumeOutput)
    /// A driver before build 142, or a helper before version 3: the speakers.
    case legacySpeaker
    /// A driver before build 142 in Line mode: Headphone 1.
    case legacyHeadphone1
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
            saved: keyboardVolumeSaved(for: unit),
            hasAnalogOutput: keyboardVolumeHasAnalogOutput(unit),
            convertersOnly: unit == .a && converterVolumeKeys,
            speakerMode: unit == .a ? speakerOutputMode : unitBSpeakerOutputMode)
    }

    /// The user changed a unit's Analog Out Format on the Output page. As in
    /// the original, setting it to Line makes Headphone 1 the Audio Output
    /// (`KeyboardVolumeOutput.afterUserChange`); the result is saved either
    /// way, so that leaving Line keeps the choice. Only a user's change does
    /// this: not a restored or recalled mode, nor one read from the unit.
    @MainActor
    func speakerModeChangedByUser(from old: UInt32, to new: UInt32, unit: DeviceUnit) {
        guard old != new, keyboardVolumeOutputAvailable, !(unit == .a && converterVolumeKeys) else { return }
        let hasAnalog = keyboardVolumeHasAnalogOutput(unit)
        let before = KeyboardVolumeOutput.resolve(saved: keyboardVolumeSaved(for: unit), hasAnalogOutput: hasAnalog,
                                                  convertersOnly: false, speakerMode: old)
        var after = before.afterUserChange(ofSpeakerModeFrom: old, to: new)
        if new == 0 {
            // Line moved the choice by itself: remember what it displaced.
            keyboardVolumeDisplacedByLine[unit] = after != before ? before : nil
        } else if old == 0 {
            // Leaving Line: put that choice back (see `afterLeavingLine`).
            after = after.afterLeavingLine(displaced: keyboardVolumeDisplacedByLine[unit])
            keyboardVolumeDisplacedByLine[unit] = nil
        }
        chooseKeyboardVolumeOutput(after, unit: unit, byUser: false)
    }

    /// Reset Defaults on the Output page: the Audio Output goes back to
    /// Speaker, Headphone 1 without an analog output card, as the original's
    /// reset did after setting the mode (SymphonyIO.cpp:1587-1597).
    @MainActor
    func resetKeyboardVolumeOutput(unit: DeviceUnit) {
        guard keyboardVolumeOutputAvailable, !(unit == .a && converterVolumeKeys) else { return }
        chooseKeyboardVolumeOutput(KeyboardVolumeOutput.defaultOutput(
            hasAnalogOutput: keyboardVolumeHasAnalogOutput(unit), convertersOnly: false), unit: unit)
    }

    /// What is saved for a unit: a choice made while its identity was being
    /// read first, then its settings store.
    func keyboardVolumeSaved(for unit: DeviceUnit) -> UInt32? {
        if connectionMode == .simulated { return keyboardVolumeSimulated[unit] }
        return keyboardVolumePending[unit]
            ?? keyboardVolumeStore(for: unit)?.value(for: Self.keyboardVolumeAddress)?.asUInt32
    }

    func keyboardVolumeIdentityPending(_ unit: DeviceUnit) -> Bool {
        (unit == .a ? unitAIdentityState : unitBIdentityState) == .pending
    }

    /// Save the choices made while a unit's identity was being read, now
    /// that its own settings store is in place.
    @MainActor
    func flushPendingKeyboardVolumeChoices() {
        for (unit, value) in keyboardVolumePending where !keyboardVolumeIdentityPending(unit) {
            if let store = keyboardVolumeStore(for: unit) {
                store.record(.uint32(value), for: Self.keyboardVolumeAddress)
            }
            keyboardVolumePending[unit] = nil
            keyboardVolumeRevision &+= 1
        }
    }

    /// Over USB with a helper before version 3 (or one older still): the
    /// keys always move the speakers, whatever is chosen.
    var usbKeysMoveSpeakerOnly: Bool {
        usbHelperOutdated || (usbHelperVersion.map { $0 < XPCDeviceConnection.audioOutputHelperVersion } ?? false)
    }

    /// Why Audio Output cannot be chosen although a Symphony I/O is
    /// connected; nil when it can, or when there is nothing to say.
    var keyboardVolumeUnavailableReason: String? {
        guard connectionMode == .hardware, device is XPCDeviceConnection, connectedUnit == nil,
              usbKeysMoveSpeakerOnly else { return nil }
        return "The installed USB helper is older than this version of Maestro, so the keys control the speaker. Reinstall Maestro with USB support to choose another output."
    }

    /// Ask the USB helper its version once per connection and helper start.
    @MainActor
    func refreshUSBHelperVersion() async {
        guard let xpc = device as? XPCDeviceConnection, connectionMode == .hardware else { return }
        let key = (ObjectIdentifier(xpc), xpc.helperEpoch)
        if let known = usbHelperVersionKey, known == key { return }
        let version = await xpc.helperVersionNumber()
        guard device === xpc else { return }
        usbHelperVersionKey = key
        // A helper that does not answer the question is an older one.
        let answered = version ?? 0
        if usbHelperVersion != answered { usbHelperVersion = answered }
        if usbKeysMoveSpeakerOnly {
            readASPVolume()
            readASPMute()
        }
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
        return device is XPCDeviceConnection && connectedUnit == nil && !usbHelperOutdated
            && (usbHelperVersion ?? 0) >= XPCDeviceConnection.audioOutputHelperVersion
    }

    /// The keys do nothing for unit A right now: None on converters, or
    /// Speaker while the outputs are in Line mode.
    var keyboardVolumeKeysDoNothing: Bool {
        keyboardVolumeOutputAvailable
            && keyboardVolumeOutput(for: .a).keysDoNothing(speakerMode: speakerOutputMode)
    }

    /// The Audio Output pop-up was changed.
    @MainActor
    func chooseKeyboardVolumeOutput(_ output: KeyboardVolumeOutput, unit: DeviceUnit, byUser: Bool = true) {
        guard keyboardVolumeEntries(for: unit).contains(output) else { return }
        // A choice the user made in the pop-up stands: leaving Line no longer
        // puts back the one Line displaced.
        if byUser { keyboardVolumeDisplacedByLine[unit] = nil }
        if connectionMode == .simulated {
            keyboardVolumeSimulated[unit] = output.rawValue
            keyboardVolumeRevision &+= 1
            return
        }
        if keyboardVolumeIdentityPending(unit) {
            // The unit's own settings store is not in place yet.
            keyboardVolumePending[unit] = output.rawValue
            keyboardVolumeRevision &+= 1
            return
        }
        guard let store = keyboardVolumeStore(for: unit) else { return }
        keyboardVolumePending[unit] = nil
        store.record(.uint32(output.rawValue), for: Self.keyboardVolumeAddress)
        keyboardVolumeRevision &+= 1
        keyboardVolumeRetryAfter = .distantPast
        Task { @MainActor in await self.serviceKeyboardVolumeOutput() }
    }

    /// Whether the driver or the helper serving now has been told that
    /// `output` is unit A's. Until then the level its volume control holds
    /// may belong to another output (the one an earlier session chose, while
    /// this unit's saved choice is not read yet), and must not be taken for
    /// this one's: a knob showing another output's level would send that
    /// level at the next nudge.
    func keyboardVolumeSettled(_ output: KeyboardVolumeOutput) -> Bool {
        guard let device, let sent = keyboardVolumeSent else { return false }
        return sent.connection == ObjectIdentifier(device) && sent.outputs[.a] == output
    }

    /// See `MacVolumeAdoption`.
    /// `mute`: the change is of the mute control. With Speaker chosen in Line
    /// mode the volume is not the speaker's, but the mute still is.
    static func macVolumeAdoption(thunderbolt: Bool, servingBuild: ServingDextBuild?, helperOutdated: Bool,
                                  output: KeyboardVolumeOutput, settled: Bool, speakerMode: UInt32,
                                  mute: Bool = false) -> MacVolumeAdoption {
        let nothing = mute ? output.muteKeyDoesNothing : output.keysDoNothing(speakerMode: speakerMode)
        if thunderbolt {
            // Not read yet: it is not known which rule the driver follows.
            guard let servingBuild else { return .ignore }
            guard KeyboardVolumeOutput.driverSupports(servingBuild) else {
                return speakerMode == 0 ? .legacyHeadphone1 : .legacySpeaker
            }
            // The driver holds its control where the keys do nothing.
            return settled && !nothing ? .level(output) : .ignore
        }
        if helperOutdated { return .legacySpeaker }
        guard settled else { return .ignore }
        return nothing ? .putBack : .level(output)
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
        // A Symphony I/O's choice is saved by its identity: nothing is sent
        // while that is still being read (the default would be sent first and
        // the saved choice a moment later).
        let converters = converterVolumeKeys
        if let tb = device as? ThunderboltDeviceConnection {
            guard KeyboardVolumeOutput.driverSupports(servingDextBuild),
                  converters || (connectedUnit == nil && unitAIdentityState != .pending) else { return nil }
            var outputs: [DeviceUnit: KeyboardVolumeOutput] = [.a: keyboardVolumeOutput(for: .a)]
            // Unit B only while the driver has it configured at 64 channels
            // (it refuses the choice otherwise).
            if !converters, unitB?.setupComplete == true, portSelection.selection == .ports1And2,
               unitBDevice != nil, unitBIdentityState != .pending {
                outputs[.b] = keyboardVolumeOutput(for: .b)
            }
            return KeyboardVolumeSent(connection: ObjectIdentifier(tb), epoch: tb.cardMixers.epoch,
                                      converters: converterVolumeKeys, outputs: outputs)
        }
        if let xpc = device as? XPCDeviceConnection {
            // Not while the unit is starting up, and not under an older helper.
            guard connectedUnit == nil, isHardwareInitialized, keyboardVolumeOutputAvailable,
                  unitAIdentityState != .pending, usbSettleRemainingNow <= 0 else { return nil }
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
        guard !keyboardVolumeServiceRunning else { return }
        keyboardVolumeServiceRunning = true
        defer { keyboardVolumeServiceRunning = false }
        await refreshUSBHelperVersion()
        flushPendingKeyboardVolumeChoices()
        guard let wanted = keyboardVolumeWanted(),
              wanted != keyboardVolumeSent, Date() >= keyboardVolumeRetryAfter else { return }
        // Only what differs, unless the driver or the helper is another one.
        let previous = keyboardVolumeSent.flatMap {
            $0.connection == wanted.connection && $0.epoch == wanted.epoch && $0.converters == wanted.converters
                ? $0.outputs : nil
        } ?? [:]
        var landed = previous
        var complete = true
        var adopt = false
        if let tb = device as? ThunderboltDeviceConnection {
            for unit in [DeviceUnit.a, .b] {
                guard let output = wanted.outputs[unit], previous[unit] != output else { continue }
                if await tb.setMonitorOutput(output, unit: unit) {
                    landed[unit] = output
                    adopt = adopt || unit == .a
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
                adopt = true
            } else {
                complete = false
            }
            guard device === xpc else { return }
        }
        keyboardVolumeSent = KeyboardVolumeSent(connection: wanted.connection, epoch: wanted.epoch,
                                                converters: wanted.converters, outputs: landed)
        keyboardVolumeRetryAfter = complete ? .distantPast : Date().addingTimeInterval(Self.keyboardVolumeRetryPause)
        // The Mac's control now holds the level of the output Maestro has for
        // unit A: what was skipped until that was certain is read now.
        if adopt {
            readASPVolume()
            readASPMute()
        }
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
