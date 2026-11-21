import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    private final class PresetCaptureWarnings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    /// Refuse unknown boards and converters before touching hardware or preferences.
    @MainActor
    private func requireSymphonyPreset() throws {
        guard connectedUnit == nil, converterSystem == nil, cardLayout.isKnown,
              RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) == nil else {
            throw ThunderboltPreset.RecallError.unsupported("this recall requires Symphony I/O with known cards.")
        }
    }

    @MainActor
    func saveThunderboltPresetBundle(to url: URL, connection: ThunderboltDeviceConnection) async throws {
        try requireSymphonyPreset()
        let layout = cardLayout
        if unitBOnCard && !unitBInputRoutingAllowed {
            throw ThunderboltPreset.RecallError.unsupported("unit B is not configured at 64 channels.")
        }
        var metadata = MaestroPreset()
        metadata.inputChannelStates = channelStateStore.load(ChannelStateStore.inputKey)
            ?? Array(repeating: InputChannelState(), count: layout.analogInputStripCount)
        metadata.outputChannelStates = channelStateStore.load(ChannelStateStore.outputKey)
            ?? Array(repeating: OutputChannelState(), count: layout.analogOutputStripCount)
        if let names = UserDefaults.standard.string(forKey: mixerNamesKey()) {
            metadata.channelNames = (try? JSONDecoder().decode([String].self, from: Data(names.utf8))) ?? []
        }
        var seed = ThunderboltPreset(layout: layout, metadata: metadata)
        if let identity = unitAIdentity {
            seed.unitID = withUnsafeBytes(of: identity.bigEndian) { Data($0) }
        }
        // The card-input table only when the serving driver supports it (>= 132).
        if symphonyCardInputs.channelCount > 0 {
            let cardInputs = symphonyCardInputStore?.load() ?? [:]
            seed.cardInputRoutes = (0..<(unitBOnCard ? 64 : 32)).map { cardInputs[$0] ?? $0 }
        }
        seed.mixers = (0..<2).map {
            ThunderboltPreset.Mixer(snapshot: MixerStateSnapshot(channelCount: layout.mixerChannelCount,
                                                                 mixer: $0, store: channelStateStore, preferences: mixerPreferences))
        }
        let saved = cachedOutputRouteMap()
        seed.outputRoutes = (0..<32).map { channel in
            let destination = UInt8(channel + 32)
            return saved[destination] ?? UInt8(channel)
        }
        let b = unitBOnCard ? unitBDevice as? ThunderboltUnitBConnection : nil
        let bLayout = unitBLayout
        var bSeed: ThunderboltPreset?
        if let bLayout, b != nil {
            seed.version = 2
            seed.outputRoutes += unitBOutputSources(layout: bLayout)
            var metadata = MaestroPreset()
            if let names = UserDefaults.standard.string(forKey: mixerNamesKey(unit: .b)) {
                metadata.channelNames = (try? JSONDecoder().decode([String].self, from: Data(names.utf8))) ?? []
            }
            let store = unitBChannelStateStore
            metadata.inputChannelStates = store.load(ChannelStateStore.inputKey)
                ?? Array(repeating: InputChannelState(), count: bLayout.analogInputStripCount)
            metadata.outputChannelStates = store.load(ChannelStateStore.outputKey)
                ?? Array(repeating: OutputChannelState(), count: bLayout.analogOutputStripCount)
            var value = ThunderboltPreset(layout: bLayout, metadata: metadata)
            if let identity = unitBIdentity {
                value.unitID = withUnsafeBytes(of: identity.bigEndian) { Data($0) }
            }
            value.outputRoutes = Array(0..<32)
            value.mixers = (0..<2).map {
                ThunderboltPreset.Mixer(snapshot: MixerStateSnapshot(channelCount: bLayout.mixerChannelCount, mixer: $0, store: store))
            }
            bSeed = value
        }
        let capturedSeed = seed, capturedBSeed = bSeed
        // Fixed lock order: card/A, then B. All hardware work is off MainActor.
        let warnings = PresetCaptureWarnings()
        let preset = try await Task.detached {
            try connection.withPresetLock {
                if let b, let bLayout, let capturedBSeed {
                    return try b.withPresetLock {
                        var captured = try connection.capturePreset(capturedSeed, layout: layout, onSkipped: warnings.add)
                        captured.unitB = .init(try b.capturePreset(capturedBSeed, layout: bLayout, onSkipped: warnings.add))
                        return captured
                    }
                }
                return try connection.capturePreset(capturedSeed, layout: layout, onSkipped: warnings.add)
            }
        }.value
        try preset.writeBundle(to: url)
        if !warnings.all.isEmpty { statusMessage = "Saved with skipped settings: " + warnings.all.joined(separator: ", ") }
    }

    /// Recall a bundle. If it fails after its first write, the unit may hold
    /// part of the bundle while the pages show what is saved: no output is
    /// left on a card mixer, and the restore puts the saved routing and
    /// mixers back (`recoverFromFailedRecall`).
    @MainActor
    func loadThunderboltPresetBundle(from url: URL, connection: ThunderboltDeviceConnection) async throws {
        recallWritesStarted = false
        do {
            try await recallThunderboltPresetBundle(from: url, connection: connection)
        } catch {
            if recallWritesStarted { await recoverFromFailedRecall(connection) }
            throw error
        }
    }

    @MainActor
    private func recallThunderboltPresetBundle(from url: URL, connection: ThunderboltDeviceConnection) async throws {
        guard !hardwareWritesSuspended else { throw DeviceConnectionError.notConnected }
        try requireSymphonyPreset()
        let (preset, legacy) = try ThunderboltPreset.loadBundle(from: url, layout: cardLayout)
        beginRecall()
        defer { finishRecall() }
        let layout = cardLayout
        let b = unitBOnCard ? unitBDevice as? ThunderboltUnitBConnection : nil
        let bLayout = unitBLayout
        let bStore = unitBChannelStateStore
        let bDigitalKey = unitBDigitalSettingsKey
        let recallWarnings = PresetCaptureWarnings()
        let cardInputSupported = if case .build(let build) = servingDextBuild { build >= 132 } else { false }
        let admissionFence = await Task.detached(priority: .utility) {
            (connection.linkState()?.recoveryCount, connection.readUnitBState()?.generation)
        }.value
        let skip = preset.unitBSkipReason(layout: bLayout, configured: b != nil && unitBInputRoutingAllowed
            && unitBBoardSource(slot: 0) == .detected && unitBBoardSource(slot: 1) == .detected)
        let recallB = preset.unitB != nil && skip == nil
        let cardChannels = unitBOnCard && unitBInputRoutingAllowed && skip == nil ? 64 : 32
        recallWritesStarted = true
        try await Task.detached {
            try connection.withPresetLock {
                let aWrites = try connection.presetWrites(preset, layout: layout, legacy: legacy, channels: cardChannels,
                                                          onSkipped: recallWarnings.add)
                if recallB, let b, let bLayout, let saved = preset.unitB {
                    try b.withPresetLock {
                        let bWrites = try b.presetWrites(saved, layout: bLayout, cardInputSupported: cardInputSupported,
                                                         onSkipped: recallWarnings.add)
                        do { try connection.applyPresetWrites(aWrites, layout: layout,
                                                               recoveryCount: admissionFence.0) }
                        catch {
                            // Card routing may already have changed B's feed.
                            // Finish both units even when A's recall failed.
                            try? b.applyPresetWrites([], layout: bLayout, cardWrite: { try connection.writePresetMixer($0, value: $1) },
                                                      unitBGeneration: admissionFence.1)
                            throw error
                        }
                        try b.applyPresetWrites(bWrites, layout: bLayout,
                                                cardWrite: { try connection.writePresetMixer($0, value: $1) },
                                                unitBGeneration: admissionFence.1)
                    }
                } else {
                    try connection.applyPresetWrites(aWrites, layout: layout, recoveryCount: admissionFence.0)
                }
            }
        }.value
        await refreshAfterRecall()
        guard !hardwareWritesSuspended, device === connection else { throw DeviceConnectionError.notConnected }
        let completionFence = await Task.detached(priority: .utility) {
            (connection.linkState()?.recoveryCount, connection.readUnitBState()?.generation)
        }.value
        guard !hardwareWritesSuspended, device === connection, admissionFence.0 == completionFence.0,
              !recallB || admissionFence.1 == completionFence.1 else {
            throw ThunderboltPreset.RecallError.failed("the link or unit-B generation changed; recall was only partially applied")
        }
        // The persistence commit is part of the same ordered transaction: do
        // not let a recovery or B replacement make the stores newer than the
        // hardware that was actually recalled.
        let commitFence = await Task.detached(priority: .utility) {
            (connection.linkState()?.recoveryCount, connection.readUnitBState()?.generation)
        }.value
        guard admissionFence.0 == commitFence.0,
              !recallB || admissionFence.1 == commitFence.1 else {
            throw ThunderboltPreset.RecallError.failed("the link or unit-B generation changed before persistence")
        }
        if recallB, let saved = preset.unitB, let bLayout, unitBDevice === b {
            if !saved.metadata.channelNames.isEmpty {
                UserDefaults.standard.set(String(data: try JSONEncoder().encode(saved.metadata.channelNames), encoding: .utf8), forKey: mixerNamesKey(unit: .b))
            }
            bStore.save(saved.metadata.inputChannelStates.enumerated().map { $0.element.recalled(identity: bStore.identity, boardSlot: 1, channel: $0.offset) }, for: ChannelStateStore.inputKey)
            bStore.save(saved.metadata.outputChannelStates, for: ChannelStateStore.outputKey)
            try bStore.saveMixerPreset(saved.mixers, sourceCount: 32)
            if let bDigitalKey {
                for digital in PresetDigitalWrites.writes(for: saved.metadata, layout: bLayout) {
                    SlotDigitalSettings.remember(digital.address.selector, slot: Int(digital.address.element), value: digital.value, key: bDigitalKey)
                }
            }
            unitBInputRoutingCache?.save(SymphonyIODefaultRouting.inputGrid(
                saved.inputRoutes.enumerated().map { (destination: UInt8(192 + $0.offset), source: $0.element) },
                columns: bLayout.inputRoutingColumns))
        }
        let warningText = recallWarnings.all
        statusMessage = (skip.map { "Unit A loaded. " + $0 } ?? "Settings loaded.")
            + (warningText.isEmpty ? "" : " " + warningText.joined(separator: " "))
        // Commit the app's copy only after hardware recall and ready read-back.
        // No view needs to be open for any of the writes above.
        // beginRecall remains active through this synchronous MainActor commit;
        // replay stays deferred until finishRecall. Do not take the blocking
        // hardware owner here after the detached transaction has released it.
        let meta = preset.metadata
        if !meta.inputChannelStates.isEmpty { channelStateStore.save(meta.inputChannelStates.enumerated().map { $0.element.recalled(identity: legacy ? nil : unitAIdentity, boardSlot: 1, channel: $0.offset) }, for: ChannelStateStore.inputKey) }
        if !meta.outputChannelStates.isEmpty { channelStateStore.save(meta.outputChannelStates, for: ChannelStateStore.outputKey) }
        if !meta.channelNames.isEmpty {
            UserDefaults.standard.set(String(data: try JSONEncoder().encode(meta.channelNames), encoding: .utf8), forKey: mixerNamesKey())
        }
        for digital in PresetDigitalWrites.writes(for: meta, layout: cardLayout) {
            rememberDigitalSetting(digital.address.selector, slot: Int(digital.address.element), value: digital.value)
        }
        try channelStateStore.saveMixerPreset(preset.mixers, sourceCount: cardChannels == 64 ? 32 : 8)
        if !legacy {
            persistPresetRoutes(preset, productID: connection.identifier.productID, recalledChannels: cardChannels)
            if let routes = preset.cardInputRoutes {
                let applied = try ThunderboltPreset.cardTable(routes, channels: cardChannels)
                symphonyCardInputEdits.merge(Dictionary(uniqueKeysWithValues: applied.enumerated().map {
                    ($0.offset, $0.element >= cardChannels ? -1 : $0.element)
                })) { _, new in new }
                symphonyCardInputStore?.save(symphonyCardInputEdits)
            }
        }
        if !legacy, cardChannels == 64, let bLayout {
            let sources = try ThunderboltPreset.cardTable(preset.outputRoutes.map(Int.init), channels: 64)
            unitBOutputRoutingCache?.save(outputGrid(sources: Array(sources.dropFirst(32)).map(UInt8.init), layout: bLayout, channels: 64))
        }
        if let mode = preset.globals[AudioPropertySelector.speakerOutputMode.rawValue] { speakerOutputMode = mode }
        await refreshChannelNaming()
        viewReloadToken = UUID()
    }

    @MainActor
    private func persistPresetRoutes(_ preset: ThunderboltPreset, productID: UInt16, recalledChannels: Int) {
        var input: [Int: Int] = [:]
        for pair in 0..<16 {
            if let column = cardLayout.inputRoutingColumns.firstIndex(where: { $0.routingByte == preset.inputRoutes[pair * 2] }) {
                input[pair] = column
            }
        }
        peripheralRoutingCache(direction: "input").save(input)
        let channels = unitBOnCard ? 64 : 32
        peripheralRoutingCache(direction: "output").save(
            outputGrid(sources: preset.outputRoutes.prefix(32).map { Int($0) >= recalledChannels && $0 < 64 ? SymphonyIORoutingAddress.none : $0 }, layout: cardLayout, channels: channels, unitA: true))
    }

    private func outputGrid(sources: [UInt8], layout: CardLayout, channels: Int, unitA: Bool = false) -> [Int: Set<Int>] {
        var output = Dictionary(uniqueKeysWithValues: (0..<(channels / 2 + 2)).map { ($0, Set<Int>()) })
        for (column, destination) in layout.outputRoutingColumns.enumerated() {
            let source = sources[Int(destination.routingByte) - 32]
            let row: Int?
            if Int(source) < channels { row = Int(source) / 2 }
            else if source == SymphonyIORoutingAddress.mixer0Base { row = channels / 2 }
            else if source == SymphonyIORoutingAddress.mixer1Base { row = channels / 2 + 1 }
            else { row = nil }
            if let row { output[row, default: []].insert(column) }
        }
        if unitA && channels == 64 {
            let pairs = (device?.identifier.mode.channelCount ?? 32) / 2
            return Dictionary(uniqueKeysWithValues: output.compactMap { row, columns in
                TwoUnitOutputRouting.unitARow(gridRow: row, unitAPairs: pairs).map { ($0, columns) }
            })
        }
        return output
    }

    private func unitBOutputSources(layout: CardLayout) -> [UInt8] {
        var sources = Array(UInt8(32)..<UInt8(64))
        guard let rows = unitBOutputRoutingCache?.loadMulti() else { return sources }
        for (col, destination) in layout.outputRoutingColumns.enumerated() {
            let complete = (0..<34).allSatisfy { rows[$0] != nil }
            let row = rows.first { $0.value.contains(col) }?.key
            if row == nil && !complete { continue }
            for side in 0..<2 {
                let source: UInt8
                if let row, row < 32 { source = UInt8(row * 2 + side) }
                else if row == 32 { source = SymphonyIORoutingAddress.mixer0Base + UInt8(side) }
                else if row == 33 { source = SymphonyIORoutingAddress.mixer1Base + UInt8(side) }
                else { source = SymphonyIORoutingAddress.none }
                sources[Int(destination.routingByte) - 32 + side] = source
            }
        }
        return sources
    }
}
