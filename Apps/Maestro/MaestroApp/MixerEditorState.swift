import Foundation
import MaestroCore
import MaestroDevice

/// Local editor snapshot. Pending edits are blocked, and an old view/task cannot
/// save into a newly resolved scope. Original UID-based restore:
/// og_source/maestrolink/Software/SymphonyIOMixer.cpp:1000-1075,1372-1389.
@MainActor
struct MixerEditorState {
    let scopes: [PreferenceViewScope]
    let loadedChannelCount: Int
    let loadedMaster: Bool
    let loadedReturn: Bool
    var channels: [MixerChannelState]
    var masterLevel: Double
    var masterLeftLevel: Double
    var masterRightLevel: Double
    var swReturnChannel: MixerChannelState
    var swReturnLeftLevel: Double
    var swReturnRightLevel: Double
    var softwareReturnSource: UInt32

    init(appState: AppState, selectedMixer: Int) {
        scopes = appState.mixerViewScopes
        let saved: [MixerChannelState]? = appState.channelStateStore.load(ChannelStateStore.mixerKey(selectedMixer))
        loadedChannelCount = saved?.count ?? 0
        loadedMaster = appState.mixerPreferences.object(forKey: "mixerMasterLevel_\(selectedMixer)") != nil
        loadedReturn = appState.mixerPreferences.object(forKey: "mixerState_swReturn") != nil
            || appState.mixerPreferences.object(forKey: "mixerSWReturnLeftLevel_\(selectedMixer)") != nil
        let snapshot = MixerStateSnapshot(
            channelCount: appState.cardLayout.mixerChannels.count,
            mixer: selectedMixer,
            store: appState.channelStateStore, preferences: appState.mixerPreferences)
        channels = appState.mixerStripStates(unitA: snapshot.channels, mixer: selectedMixer)
        softwareReturnSource = TwoUnitMixer.shownSoftwareReturnSource(
            snapshot.softwareReturnSource, pairCount: appState.softwareReturnPairCount)
        masterLevel = snapshot.masterLevel
        masterLeftLevel = snapshot.masterLevel
        masterRightLevel = snapshot.masterLevel
        let swLevel = appState.mixerPreferences.object(forKey: "mixerSWReturnLeftLevel_\(selectedMixer)") as? Double
            ?? snapshot.swReturnChannel.level
        var swReturn = snapshot.swReturnChannel
        swReturn.level = swLevel
        swReturnChannel = swReturn
        swReturnLeftLevel = swLevel
        swReturnRightLevel = swLevel
    }

    func canEdit(_ appState: AppState) -> Bool {
        scopes.allSatisfy(\.isWritable) && scopes == appState.mixerViewScopes
    }

    func save(appState: AppState, selectedMixer: Int) {
        guard canEdit(appState) else { return }
        appState.saveMixerStrips(channels, mixer: selectedMixer)
        if let data = try? JSONEncoder().encode(swReturnChannel) {
            appState.mixerPreferences.set(data, forKey: "mixerState_swReturn")
        }
        appState.mixerPreferences.set(masterLevel, forKey: "mixerMasterLevel_\(selectedMixer)")
        appState.mixerPreferences.set(masterLeftLevel, forKey: "mixerMasterLeftLevel_\(selectedMixer)")
        appState.mixerPreferences.set(masterRightLevel, forKey: "mixerMasterRightLevel_\(selectedMixer)")
        appState.mixerPreferences.set(swReturnLeftLevel, forKey: "mixerSWReturnLeftLevel_\(selectedMixer)")
        appState.mixerPreferences.set(swReturnRightLevel, forKey: "mixerSWReturnRightLevel_\(selectedMixer)")
        // The pairs can no longer be unlinked. Older versions read these flags.
        appState.mixerPreferences.set(true, forKey: "mixerSWReturnFadersLinked")
        appState.mixerPreferences.set(true, forKey: "mixerMasterFadersLinked")
        let sourceKey = "mixerSoftwareReturnSource_\(selectedMixer)"
        appState.mixerPreferences.set(
            TwoUnitMixer.sourceToSave(shown: softwareReturnSource,
                                      saved: UInt32(clamping: appState.mixerPreferences.integer(forKey: sourceKey)),
                                      pairCount: appState.softwareReturnPairCount),
            forKey: sourceKey)
        // Keep the ThunderBridge SW Return meters in step with the faders/pan/mute.
        appState.refreshSoftwareReturnMeterGains()
    }
}
