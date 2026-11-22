import Foundation
import MaestroCore

/// Why a setup file was not opened, and what to say when little of it was.
enum PresetOpenError: LocalizedError {
    case maestro2

    var errorDescription: String? { PresetPackageKind.maestro2Message }

    static let usbNamesOnlyNotice =
        "Only channel names were restored. Over USB, setup files don't hold routing, mixer or levels yet."
    static let usbNothingNotice = "Nothing in this setup file could be restored over USB."
}

extension AppState {
    /// The text under a mixer's Master fader: the first output the mixer is
    /// routed to in Output Routing (unit A's outputs, then unit B's), or
    /// "None". From the saved routing only: the default routes no mixer
    /// (see `mixersRoutedToOutput`), and the Mixer page never reads the unit
    /// for this.
    @MainActor
    func masterOutputLabel(mixer: Int) -> String {
        let twoUnits = unitBOnCard
        let softwarePairs = (device?.identifier.mode.channelCount ?? 16) / 2
        let mixerRowA = (twoUnits ? TwoUnitOutputRouting.rowCount - 2 : softwarePairs) + mixer
        let unitA = (rows: peripheralRoutingCache(direction: "output").loadMulti() ?? [:],
                     mixerRow: mixerRowA,
                     names: cardLayout.outputRoutingColumns.map(\.stereoName))
        guard twoUnits, let layoutB = unitBLayout else { return MasterOutputLabel.text(unitA: unitA) }
        return MasterOutputLabel.text(
            unitA: unitA,
            unitB: (rows: unitBOutputRoutingCache?.loadMulti() ?? [:],
                    mixerRow: TwoUnitOutputRouting.rowCount - 2 + mixer,
                    names: layoutB.outputRoutingColumns.map { "B " + $0.stereoName }))
    }
}
