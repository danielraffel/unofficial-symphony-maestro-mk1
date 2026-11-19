import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// B4a owns unit A only. Refuse before touching hardware or preferences.
    @MainActor
    private func requireSingleUnitPreset() throws {
        guard connectedUnit == nil, !unitBOnCard, portSelection.selection != .ports1And2,
              selectedUnit == .a, cardLayout.isKnown,
              RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) == nil else {
            throw ThunderboltPreset.RecallError.unsupported("this recall requires one Symphony I/O on unit A with known cards.")
        }
    }

    @MainActor
    func saveThunderboltPresetBundle(to url: URL, connection: ThunderboltDeviceConnection) async throws {
        try requireSingleUnitPreset()
        let layout = cardLayout
        var metadata = MaestroPreset()
        metadata.inputChannelStates = channelStateStore.load(ChannelStateStore.inputKey)
            ?? Array(repeating: InputChannelState(), count: layout.analogInputStripCount)
        metadata.outputChannelStates = channelStateStore.load(ChannelStateStore.outputKey)
            ?? Array(repeating: OutputChannelState(), count: layout.analogOutputStripCount)
        if let names = UserDefaults.standard.string(forKey: "mixerChannelNames") {
            metadata.channelNames = (try? JSONDecoder().decode([String].self, from: Data(names.utf8))) ?? []
        }
        var seed = ThunderboltPreset(layout: layout, metadata: metadata)
        seed.routingMode = UserDefaults.standard.integer(forKey: "routingMode")
        seed.mixers = (0..<2).map {
            ThunderboltPreset.Mixer(snapshot: MixerStateSnapshot(channelCount: layout.mixerChannelCount,
                                                                 mixer: $0, store: channelStateStore))
        }
        let saved = cachedOutputRouteMap()
        seed.outputRoutes = (0..<32).map { channel in
            let destination = UInt8(channel + 32)
            return saved[destination] ?? ThunderboltCardRouting.mainPairDefaultSource(forDestination: destination) ?? UInt8(channel)
        }
        // Off the main actor: the capture is many bus round trips (the window
        // must not freeze while it runs).
        let capturedSeed = seed
        let preset = try await Task.detached { try connection.capturePreset(capturedSeed, layout: layout) }.value
        try preset.writeBundle(to: url)
    }

    @MainActor
    func loadThunderboltPresetBundle(from url: URL, connection: ThunderboltDeviceConnection) async throws {
        try requireSingleUnitPreset()
        let (preset, legacy) = try ThunderboltPreset.loadBundle(from: url, layout: cardLayout)
        let layout = cardLayout
        // Off the main actor: the recall is many bus writes plus the unlock
        // read-back (the window must not freeze while it runs).
        try await Task.detached { try connection.recallPreset(preset, layout: layout, legacy: legacy) }.value
        // Commit the app's copy only after hardware recall and ready read-back.
        // No view needs to be open for any of the writes above.
        let meta = preset.metadata
        if !meta.inputChannelStates.isEmpty { channelStateStore.save(meta.inputChannelStates, for: ChannelStateStore.inputKey) }
        if !meta.outputChannelStates.isEmpty { channelStateStore.save(meta.outputChannelStates, for: ChannelStateStore.outputKey) }
        UserDefaults.standard.set(String(data: try JSONEncoder().encode(meta.channelNames), encoding: .utf8), forKey: "mixerChannelNames")
        for digital in PresetDigitalWrites.writes(for: meta, layout: cardLayout) {
            rememberDigitalSetting(digital.address.selector, slot: Int(digital.address.element), value: digital.value)
        }
        for (index, mixer) in preset.mixers.enumerated() {
            channelStateStore.save(mixer.channels, for: ChannelStateStore.mixerKey(index))
            UserDefaults.standard.set(mixer.source, forKey: "mixerSoftwareReturnSource_\(index)")
            UserDefaults.standard.set(mixer.master, forKey: "mixerMasterLevel_\(index)")
            UserDefaults.standard.set(try JSONEncoder().encode(mixer.softwareReturn), forKey: "mixerState_swReturn")
        }
        if !legacy {
            UserDefaults.standard.set(preset.routingMode, forKey: "routingMode")
            persistPresetRoutes(preset, productID: connection.identifier.productID)
        }
        if let mode = preset.globals[AudioPropertySelector.speakerOutputMode.rawValue] { speakerOutputMode = mode }
        if let level = preset.globals[AudioPropertySelector.outputLevel.rawValue] { speakerLevel = -Double(level) }
        if let mute = preset.globals[AudioPropertySelector.outputMute.rawValue] { speakerMuted = mute != 0 }
        await refreshChannelNaming()
        viewReloadToken = UUID()
    }

    @MainActor
    private func persistPresetRoutes(_ preset: ThunderboltPreset, productID: UInt16) {
        var input: [Int: Int] = [:]
        for pair in 0..<16 {
            if let column = cardLayout.inputRoutingColumns.firstIndex(where: { $0.routingByte == preset.inputRoutes[pair * 2] }) {
                input[pair] = column
            }
        }
        RoutingStateCache(direction: "input", productID: productID).save(input)
        var output: [Int: Set<Int>] = Dictionary(uniqueKeysWithValues: (0..<18).map { ($0, Set<Int>()) })
        for (column, destination) in cardLayout.outputRoutingColumns.enumerated() {
            let source = preset.outputRoutes[Int(destination.routingByte) - 32]
            let row: Int?
            if source < 32 { row = Int(source) / 2 }
            else if source == SymphonyIORoutingAddress.mixer0Base { row = 16 }
            else if source == SymphonyIORoutingAddress.mixer1Base { row = 17 }
            else { row = nil }
            if let row { output[row, default: []].insert(column) }
        }
        RoutingStateCache(direction: "output", productID: productID).save(output)
    }
}
