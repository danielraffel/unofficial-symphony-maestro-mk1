import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// The user chose a clock source for unit A in Device Settings. A card's
    /// digital input is remembered for this unit; any other choice clears it
    /// (Internal and Word Clock are kept by the driver's own control).
    @MainActor
    func rememberClockSourceChoice(_ key: UInt32) {
        guard connectionMode == .hardware, let identity = unitAIdentity,
              let tb = device as? ThunderboltDeviceConnection,
              let decoded = ClockSourceMenu.decode(key) else { return }
        if decoded.boardInput != nil {
            SavedBoardClock.store(.init(key: key, control: tb.clockControlValue()), identity: identity)
        } else {
            SavedBoardClock.store(nil, identity: identity)
        }
    }

    /// At connect: put a remembered card input back as the clock source, as
    /// the original did. The driver starts the unit on what its clock control
    /// holds, which is never a card input.
    @MainActor
    func replaySavedBoardClock(_ tb: ThunderboltDeviceConnection) async {
        guard connectionMode == .hardware, let identity = unitAIdentity,
              connectedUnit == nil, !usesTwoUnitReplay, !unitBFollowsUnitA else { return }
        let saved = SavedBoardClock.load(identity: identity)
        guard saved != nil else { return }
        let control = await Task.detached(priority: .utility) { tb.clockControlValue() }.value
        guard device === tb, unitAIdentity == identity else { return }
        // The optical row's key depends on the card's optical format.
        await refreshChannelNaming()
        guard device === tb, unitAIdentity == identity else { return }
        let offered = clockSourceChoices(sampleRate: channelNaming.sampleRate).map(\.id)
        switch SavedBoardClock.decide(saved: saved, controlNow: control, offered: offered) {
        case .send(let key):
            do {
                try await tb.setProperty(PropertyAddress(selector: .clockSource), value: .uint32(key))
                guard device === tb else { return }
                reportedClockSource = key
                print("[Maestro] clock: saved card input \(String(key, radix: 16)) sent as clock source")
            } catch {
                print("[Maestro] clock: saved card input not accepted: \(error)")
            }
        case .forget:
            SavedBoardClock.store(nil, identity: identity)
            print("[Maestro] clock: the clock control changed since a card input was chosen; saved choice dropped")
        case .wait:
            print("[Maestro] clock: saved card input kept, not sent (control unreadable or card not present)")
        case nil:
            break
        }
    }
}
