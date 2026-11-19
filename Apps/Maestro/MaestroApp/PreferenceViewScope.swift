import Foundation
import MaestroCore
import MaestroDevice

/// An editor may write only while its loaded snapshot belongs to this lifetime.
/// Readiness is part of identity: pending -> resolved must rebuild local state.
struct PreferenceViewScope: Equatable, Hashable {
    let key: String?
    let generation: UUID
    let isWritable: Bool
}

extension AppState {
    func preferenceViewScope(for unit: DeviceUnit) -> PreferenceViewScope {
        let preferences = unit == .a ? mixerPreferences : unitBChannelStateStore.mixerPreferences
        return PreferenceViewScope(key: preferences.storageKey,
            generation: unit == .a ? unitAGeneration : unitBGeneration,
            isWritable: preferences.isWritable)
    }

    var mixerViewScopes: [PreferenceViewScope] {
        [preferenceViewScope(for: .a)] + (unitBOnCard ? [preferenceViewScope(for: .b)] : [])
    }
}
