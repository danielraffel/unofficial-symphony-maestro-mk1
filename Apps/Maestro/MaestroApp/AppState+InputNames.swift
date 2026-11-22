import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// A presentation copy of the layout. Routing and mixer writes keep their
    /// existing layout and indices.
    func inputNamingLayout(for unit: DeviceUnit, channels: [InputChannelState]? = nil,
                           labels: [String]? = nil) -> CardLayout {
        let layout = unit == .b ? (unitBLayout ?? CardLayout(isKnown: false)) : cardLayout
        guard layout.isKnown else { return layout }

        // DAW edits and setup recalls can update the store while the page is open.
        _ = micPreObservationRevision
        _ = viewReloadToken
        let store = unit == .b ? unitBChannelStateStore : channelStateStore
        let states = channels ?? store.load(ChannelStateStore.inputKey) ?? []
        var levels = states.map { AnalogInputLevel(rawValue: $0.inputType) ?? .plus4dBu }
        // The simulated input page starts from these fixture levels before any
        // edits have been saved. Present the same fixtures on the other pages.
        if channels == nil, let presets = SimulatedDevice.simulatedAnalogLevels() {
            for (index, preset) in presets.prefix(layout.analogInputStripCount).enumerated() {
                guard let preset else { continue }
                let number = index + 1
                let backed = InputChannelLogic.isMicPreBacked(number: number,
                    micPreInstalled: InputChannelLogic.micPreIsUsable(primary: layout.slot1, secondary: layout.slot2),
                    hostAnalogInputChannels: layout.analogInputStripCount)
                guard InputChannelLogic.analogLevelOptions(number: number, micPreBacked: backed)
                    .contains(preset.level) else { continue }
                if levels.count <= index {
                    levels += Array(repeating: .plus4dBu, count: index + 1 - levels.count)
                }
                levels[index] = preset.level
            }
        }

        let savedLabels = UserDefaults.standard.string(forKey: mixerNamesKey(unit: unit)) ?? "[]"
        let custom = labels ?? (try? JSONDecoder().decode([String].self, from: Data(savedLabels.utf8))) ?? []
        return layout.namingAnalogInputs(levels: levels, labels: custom)
    }
}
