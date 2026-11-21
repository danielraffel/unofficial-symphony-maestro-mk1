import Foundation
import MaestroCore
import MaestroDevice

/// The VBus size that has reached the driver: to which connection, in which
/// driver state, and the size.
struct VBusSent: Equatable {
    let connection: ObjectIdentifier
    /// The connection's card ledger epoch, which changes with the driver
    /// instance, a link recovery and a card re-init.
    let epoch: UInt64
    let channels: VBusChannels
}

// Device Settings › Connection › VBus (`VBusChannels`). The driver holds the
// size only while it runs: a driver that starts, or replaces another after an
// update, has no VBus channels. So the choice is saved here, per card, and
// sent to the driver on connect, after a recovery or a driver restart, and
// when it changes. The original's daemon did the same with its saved value
// (og_source/symphonymk1/ext/maestrolink/Software/SymphonyController.cpp:2881,
// ApplySettingsToHardware; saved at :3312-3314, None when nothing is saved,
// SymphonyDeviceServer.cpp:331).
extension AppState {
    /// The pause after a size the driver did not take, and how long a change
    /// is given before the size is sent again.
    static let vbusRetryPause: TimeInterval = 5
    /// How often Maestro sends a size again by itself when the driver could
    /// not add the channels or the change did not finish. Each attempt stops
    /// audio on the device for a moment, so it does not go on for ever.
    static let vbusMaxRetries = 3

    /// The pop-up is shown on ThunderBridge and the PCIe card only (with a
    /// Symphony I/O or with converters), never over USB.
    var vbusShown: Bool {
        connectionMode == .hardware && device is ThunderboltDeviceConnection
    }

    /// Whether the driver now serving the card has VBus.
    var vbusDriverSupports: Bool { VBusChannels.driverSupports(servingDextBuild) }

    /// Why the pop-up is disabled; nil when it can be used.
    var vbusUnavailableReason: String? {
        vbusShown ? VBusChannels.unavailableReason(servingBuild: servingDextBuild) : nil
    }

    /// The card the choice is saved for: the Core Audio device UID.
    var vbusDeviceUID: String? {
        (device as? ThunderboltDeviceConnection)?.identifier.deviceUID
    }

    /// The saved choice for the connected card; None without one.
    var vbusChoice: VBusChannels {
        _ = vbusRevision   // the pop-up follows a change
        guard let uid = vbusDeviceUID else { return .none }
        return VBusChannels.saved(in: vbusDefaults, deviceUID: uid)
    }

    /// The hardware channels of the ThunderBridge device, which the VBus
    /// channels follow: 32, or 64 while both ports run.
    var thunderboltHardwareChannels: Int { portSelection.selection?.channelCount ?? 32 }

    /// The software meters' peaks for the hardware channels only: with VBus
    /// on, the Core Audio device has more channels than the hardware, and
    /// they come after it.
    func hardwareSoftwarePeaks(_ peaks: [Float]?) -> [Float]? {
        guard let peaks else { return nil }
        guard device is ThunderboltDeviceConnection else { return peaks }
        return VBusChannels.hardwareOnly(peaks, hardwareChannels: thunderboltHardwareChannels)
    }

    /// The line under the pop-up while the device is not what was chosen.
    var vbusStatusLine: String? {
        guard vbusShown, vbusDriverSupports, let state = vbusState else { return nil }
        return state.statusLine(chosen: vbusChoice, retrying: vbusRetries < Self.vbusMaxRetries)
    }

    /// The diagnostics report's VBus line; nil when not on ThunderBridge/PCIe.
    var vbusReportLine: String? {
        guard vbusShown else { return nil }
        return VBusState.reportLine(chosen: vbusChoice, state: vbusState, driverSupports: vbusDriverSupports)
    }

    /// The pop-up was changed.
    @MainActor
    func chooseVBus(_ channels: VBusChannels) {
        guard vbusShown, vbusDriverSupports, let uid = vbusDeviceUID else { return }
        channels.save(in: vbusDefaults, deviceUID: uid)
        vbusRevision &+= 1
        // Sent again even when it is the size already sent: after a change
        // the driver could not make, choosing it again is how to retry.
        vbusSent = nil
        vbusRetries = 0
        vbusRetryAfter = .distantPast
        Task { @MainActor in await self.serviceVBus() }
    }

    /// What to send, for the connection now serving: nil when nothing can be.
    @MainActor
    func vbusWanted() -> VBusSent? {
        guard connectionMode == .hardware, !hardwareWritesSuspended, vbusDriverSupports,
              let tb = device as? ThunderboltDeviceConnection else { return nil }
        return VBusSent(connection: ObjectIdentifier(tb), epoch: tb.cardMixers.epoch, channels: vbusChoice)
    }

    /// Send the saved size where the driver now serving has not been told it,
    /// and follow the driver until the device has it. Called on each healthy
    /// health-loop cycle and when the choice changes; it does nothing when
    /// everything is already there.
    @MainActor
    func serviceVBus() async {
        guard !vbusServiceRunning else { return }
        vbusServiceRunning = true
        defer { vbusServiceRunning = false }
        guard let wanted = vbusWanted(), let tb = device as? ThunderboltDeviceConnection else {
            if !(device is ThunderboltDeviceConnection), vbusState != nil { vbusState = nil; vbusSent = nil }
            return
        }
        if wanted != vbusSent {
            // Another driver state or another choice: the retries start again.
            if vbusSent != nil, vbusRetries != 0 { vbusRetries = 0 }
            guard Date() >= vbusRetryAfter else { return }
            await sendVBus(wanted, to: tb)
            return
        }
        // Sent: follow the driver until Core Audio has made the change.
        if let state = vbusState, state.published == wanted.channels.rawValue, !state.publishFailed {
            if vbusRetries != 0 { vbusRetries = 0 }
            return
        }
        let givenUp = vbusRetries >= Self.vbusMaxRetries
        if givenUp, vbusState?.publishFailed == true { return }   // shown; the user chooses again
        if let reply = await tb.vbus(nil), device === tb, reply != vbusState { vbusState = reply }
        guard device === tb, let state = vbusState,
              state.publishFailed || state.published != wanted.channels.rawValue else { return }
        // The driver could not add the channels, or the change has not
        // finished in the time it was given (Core Audio dropped it): the
        // size is sent again, a few times, with the pause between.
        guard !givenUp, Date() >= vbusSentAt.addingTimeInterval(Self.vbusRetryPause) else { return }
        vbusRetries += 1
        print("[Maestro] VBus: the device does not have \(wanted.channels.label) yet; sending it again (\(vbusRetries) of \(Self.vbusMaxRetries))")
        await sendVBus(wanted, to: tb)
    }

    /// Send the saved size. It is sent whatever the driver has, None
    /// included, as the original's daemon did at start-up; the driver does
    /// nothing when it already has that size.
    @MainActor
    private func sendVBus(_ wanted: VBusSent, to tb: ThunderboltDeviceConnection) async {
        let reply = await tb.vbus(wanted.channels)
        guard device === tb else { return }
        guard let reply else {
            vbusRetryAfter = Date().addingTimeInterval(Self.vbusRetryPause)
            print("[Maestro] VBus: the driver did not take \(wanted.channels.label); trying again")
            return
        }
        if vbusState != reply { vbusState = reply }
        vbusSent = wanted
        vbusSentAt = Date()   // the change is given `vbusRetryPause` before the size is sent again
        vbusRetryAfter = .distantPast
        print("[Maestro] VBus: \(wanted.channels.label) sent to the driver")
    }
}
