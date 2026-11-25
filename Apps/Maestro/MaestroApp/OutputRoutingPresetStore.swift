import Foundation
import MaestroCore

/// Where Symphony I/O Output Routing presets live. Unit A's tables keep their
/// key (`outputRoutingPresets`); unit B's halves of two-unit presets, with
/// unit B's card scope, are under their own key; presets the earlier per-unit
/// grid saved for unit B alone keep `outputRoutingPresets.unitB`. The rule for
/// what each action touches is ``OutputRoutingPresets``.
enum OutputRoutingPresetStore {
    static let unitAKey = "outputRoutingPresets"
    static let unitBHalvesKey = "outputRoutingPresets.twoUnit.unitB"
    static let legacyUnitBKey = "outputRoutingPresets.unitB"

    static func load(defaults: UserDefaults = .standard) -> OutputRoutingPresets {
        var halves: [String: OutputRoutingPresets.UnitBHalf] = [:]
        if let data = defaults.data(forKey: unitBHalvesKey),
           let decoded = try? JSONDecoder().decode([String: OutputRoutingPresets.UnitBHalf].self, from: data) {
            halves = decoded
        }
        return OutputRoutingPresets(
            unitA: PresetManager.loadMultiRoutingPresetsAsSet(key: unitAKey),
            unitB: halves,
            legacyUnitB: PresetManager.loadMultiRoutingPresetsAsSet(key: legacyUnitBKey))
    }

    /// Write back whatever changed between `old` and `new`.
    static func store(_ new: OutputRoutingPresets, replacing old: OutputRoutingPresets) {
        sync(old.unitA, new.unitA, key: unitAKey)
        sync(old.legacyUnitB, new.legacyUnitB, key: legacyUnitBKey)
        if new.unitB != old.unitB, let data = try? JSONEncoder().encode(new.unitB) {
            UserDefaults.standard.set(data, forKey: unitBHalvesKey)
        }
    }

    private static func sync(_ old: [String: [Int: Set<Int>]], _ new: [String: [Int: Set<Int>]], key: String) {
        for name in old.keys where new[name] == nil {
            PresetManager.deleteRoutingPreset(name: name, key: key)
        }
        for (name, rows) in new where old[name] != rows {
            PresetManager.saveMultiRoutingPreset(name: name, routes: rows, key: key)
        }
    }
}
