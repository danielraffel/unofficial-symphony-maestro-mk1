import Foundation
import MaestroCore
import MaestroDevice

final class ReplayDeferral: @unchecked Sendable {
    private let lock = NSLock()
    private var recallInFlight = false
    private var requestedDuringRecall = false

    func beginRecall() { lock.lock(); defer { lock.unlock() }; recallInFlight = true }
    func request() {
        lock.lock(); defer { lock.unlock() }
        if recallInFlight { requestedDuringRecall = true }
    }
    func finishRecall() -> Bool {
        lock.lock(); defer { lock.unlock() }
        recallInFlight = false
        let requested = requestedDuringRecall
        requestedDuringRecall = false
        return requested
    }
    func isInFlight() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return recallInFlight
    }
}

extension AppState {
    static func replayOutputSources(defaults: [UInt8: UInt8], saved: [UInt8: UInt8],
                                    complete: Bool, destinations: [UInt8]) -> [UInt8: UInt8] {
        var result = complete
            ? Dictionary(uniqueKeysWithValues: destinations.map { ($0, SymphonyIORoutingAddress.none) })
            : defaults
        for destination in destinations {
            if let source = saved[destination] { result[destination] = source }
        }
        return result
    }

    /// At 64 channels the health loop owns routing recall, including the
    /// initial connect. At 32 the existing single-unit path is unchanged.
    var usesTwoUnitReplay: Bool {
        // Only with a configured unit B: if 64 is selected but unit B never
        // finished its set-up, unit A's own replay must still run.
        transportType == .thunderbolt && connectedUnit == nil && converterSystem == nil
            && portSelection.selection == .ports1And2 && unitB != nil
    }

    @MainActor
    func replayUnitBSettings() async {
        guard usesTwoUnitReplay, twoUnitReplayNeeded, !twoUnitReplayRunning,
              !recallInFlight,
              !twoUnitSleeping, connectionMode == .hardware, isHardwareInitialized,
              let tb = device as? ThunderboltDeviceConnection,
              let b = unitBDevice as? ThunderboltUnitBConnection,
              let layoutB = unitBLayout, unitBInputRoutingAllowed,
              RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) == nil,
              unitBBoardSource(slot: 0) == .detected, unitBBoardSource(slot: 1) == .detected else { return }
        twoUnitReplayRunning = true
        defer { twoUnitReplayRunning = false }
        let link = await Task.detached(priority: .utility) { tb.linkState() }.value
        let bGeneration = await Task.detached(priority: .utility) { tb.readUnitBState()?.generation }.value
        guard device === tb, unitBDevice === b, let link, let bGeneration else { return }
        let plan = makeTwoUnitReplay(tb: tb, b: b, layoutB: layoutB)
        let replayDeferral = self.replayDeferral
        twoUnitReplayNeeded = false
        do {
            try await Task.detached(priority: .utility) {
                try tb.replayTwoUnits(plan, unitB: b, recoveryCount: link.recoveryCount,
                                      unitBGeneration: bGeneration,
                                      shouldContinue: { !replayDeferral.isInFlight() })
            }.value
            guard device === tb, unitBDevice === b else { return }
            if let mode = tb.settingsStore.value(for: PropertyAddress(selector: .speakerOutputMode))?.asUInt32 {
                speakerOutputMode = mode
            }
            refreshUnitBNamingFromSaved()
            invalidateThunderboltInputMeterMap()
            symphonyCardInputNamingRevision += 1
            symphonyCardInputEdits = symphonyCardInputStore?.load() ?? [:]
            await refreshChannelNaming()
            print("[Maestro] Two-unit routing, mixers and headphones restored")
        } catch {
            // Retry on the next healthy poll; no tight bus retry loop.
            twoUnitReplayNeeded = true
            print("[Maestro] Two-unit replay refused: \(error)")
        }
    }

    /// Capture saved values on the main actor; all hardware work uses the
    /// immutable plan on the connection's serial owner off the main actor.
    func makeTwoUnitReplay(tb: ThunderboltDeviceConnection, b: ThunderboltUnitBConnection,
                           layoutB: CardLayout) -> TwoUnitReplay {
        var plan = TwoUnitReplay()
        plan.unitBBoards = [layoutB.slot1.rawValue, layoutB.slot2.rawValue]
        let cacheA = peripheralRoutingCache(direction: "input")
        _ = ThunderboltInputRoutingMigration.run(routingKey: cacheA.key)
        for (unit, layout, cache) in [(DeviceUnit.a, cardLayout, Optional(cacheA)), (.b, layoutB, unitBInputRoutingCache)] {
            let writes = InputRoutingReplay.writes(saved: cache?.load() ?? [:],
                                                   columns: layout.inputRoutingColumns, pairCount: 16)
            for write in writes {
                plan.tables.append(.unit(unit, PropertyAddress(selector: .routing, scope: .input,
                                                              element: UInt32(write.destination)),
                                         .uint32(UInt32(write.source))))
            }
        }
        for command in symphonyCardInputs.commands(edits: symphonyCardInputStore?.load() ?? [:]) {
            plan.card.append(.card(.cardInput(command)))
        }
        let outputCache = peripheralRoutingCache(direction: "output")
        Self.migrateMainPairToMixer(cache: outputCache, mixerRow: tb.identifier.mode.channelCount / 2,
                                   board1: primaryBoardType, board2: secondaryBoardType)
        let savedA = outputCache.loadMulti() ?? [:]
        let completeA = (0..<TwoUnitOutputRouting.rowCount).allSatisfy { savedA[$0] != nil }
        let defaultsA = SymphonyIODefaultRouting.thunderboltOutputRoutes(
            board0Outputs: primaryBoardType.totalOutputChannels,
            board1Outputs: secondaryBoardType.totalOutputChannels)
        let defaultSourcesA = Dictionary(uniqueKeysWithValues: defaultsA.map { ($0.destination, $0.source) })
        if !savedA.isEmpty {
            let sources = cachedOutputRouteMap()
            let destinations = cardLayout.outputRoutingColumns.flatMap { [$0.routingByte, $0.routingByte &+ 1] }
            let merged = Self.replayOutputSources(defaults: defaultSourcesA, saved: sources,
                                                  complete: completeA, destinations: destinations)
            for destination in destinations {
                    let source = merged[destination] ?? SymphonyIORoutingAddress.none
                    if let route = ThunderboltCardRouting.route(destination: destination, source: source, unitBActive: true) {
                        plan.card.append(.card(.output(route)))
                    }
            }
        }
        if let rows = unitBOutputRoutingCache?.loadMulti() {
            let completeB = (0..<TwoUnitOutputRouting.rowCount).allSatisfy { rows[$0] != nil }
            for (index, column) in layoutB.outputRoutingColumns.enumerated() {
                let row = rows.keys.sorted().last { rows[$0]?.contains(index) == true }
                    ?? (completeB ? nil : ThunderboltCardRouting.channel(forDestination: column.routingByte).map {
                        TwoUnitOutputRouting.defaultRow(unitBChannel: Int($0))
                    })
                if let routes = Self.unitBRoutePair(destLeft: column.routingByte, gridRow: row) {
                    plan.card += routes.map { .card(.output($0)) }
                }
            }
        }
        // Card coefficients and return selection must recover with pages closed.
        // og_source/maestrolink/Software/SymphonyCard.cpp:1031-1044.
        for mixer in 0..<2 {
            let a = MixerStateSnapshot(channelCount: cardLayout.mixerChannels.count, mixer: mixer, store: channelStateStore)
            let b = MixerStateSnapshot(channelCount: layoutB.mixerChannels.count, mixer: mixer, store: unitBChannelStateStore)
            let base = UInt32(mixer + 1) << 16
            func put(_ selector: AudioPropertySelector, _ value: PropertyValue, _ channel: Int = 0) {
                plan.card.append(.card(.property(PropertyAddress(selector: selector, element: base | UInt32(channel)), value)))
            }
            if a.softwareReturnSource < 32 { put(.mixerSoftwareReturnID, .uint32(a.softwareReturnSource)) }
            let ids = cardLayout.mixerChannels.map(\.hardwareIndex) + layoutB.mixerChannels.map { 32 + $0.hardwareIndex } + [1000]
            let channels = a.channels + b.channels + [a.swReturnChannel]
            for (id, state) in zip(ids, channels) {
                put(.mixerChannelLevel, .float64(state.level), id)
                put(.mixerChannelPan, .float64(state.pan), id)
                put(.mixerChannelMute, .bool(state.isMuted || (id != 1000 && UserDefaults.standard.integer(forKey: "routingMode") == 0)), id)
                put(.mixerChannelSolo, .bool(state.isSoloed), id)
            }
            put(.mixerChannelLevel, .float64(a.masterLevel), 2000)
        }
        // Keep B5's departure: B monitor settings are read, never host-replayed.
        for (unit, store) in [(DeviceUnit.a, tb.settingsStore), (.b, b.settingsStore)] {
            for entry in store.entries() {
                if unit == .b && ThunderboltUnitBConnection.monitorSelectors.contains(entry.address.selector) { continue }
                plan.settings.append(.unit(unit, entry.address, entry.value))
            }
        }
        // Preserve connect's analog-only recall for both units. No phantom
        // or preamp type is introduced here; those have their own identity gate.
        for (unit, layout, store, digital) in [
            (DeviceUnit.a, cardLayout, channelStateStore, rememberedDigitalSettings),
            (.b, layoutB, unitBChannelStateStore, unitBDigitalSettings)
        ] {
            let inputs: [InputChannelState] = store.load(ChannelStateStore.inputKey) ?? []
            let outputs: [OutputChannelState] = store.load(ChannelStateStore.outputKey) ?? []
            for (index, state) in inputs.prefix(layout.analogInputStripCount).enumerated() {
                let level = AnalogInputLevel(rawValue: state.inputType) ?? .plus4dBu
                if !level.isPreampLevel {
                    plan.settings.append(.unit(unit, PropertyAddress(selector: .analogIOType, scope: .input, element: UInt32(index)),
                                               .uint32(InputChannelLogic.analogIOTypeWithTrim(level: level, trim: state.trim))))
                }
                plan.settings.append(.unit(unit, PropertyAddress(selector: .digitalRefLevel, scope: .input, element: UInt32(index)), .uint32(state.digitalRefLevel)))
                let softLimit = InputChannelLogic.coerceSoftLimit(state.softLimit, card: layout.cardForAnalogInputStrip(index))
                plan.settings.append(.unit(unit, PropertyAddress(selector: .softLimit, scope: .input, element: UInt32(index)), .uint32(softLimit)))
            }
            for (index, state) in outputs.prefix(layout.analogOutputStripCount).enumerated() {
                let trim = UInt32(UInt8(bitPattern: Int8(clamping: Int((state.trim * 10).rounded()))))
                plan.settings.append(.unit(unit, PropertyAddress(selector: .analogIOType, scope: .output, element: UInt32(index)), .uint32(trim << 8 | state.analogRefLevel)))
                plan.settings.append(.unit(unit, PropertyAddress(selector: .digitalRefLevel, scope: .output, element: UInt32(index)), .uint32(state.digitalRefLevel)))
            }
            for write in digital.writes(layout: layout) {
                plan.settings.append(.unit(unit, write.address, .uint32(write.value)))
            }
        }
        return plan
    }

    /// Invalidate synchronously so even an already-running detached plan stops
    /// at its next write. Wake must obtain a new configured B connection.
    func suspendTwoUnitReplay() {
        guard usesTwoUnitReplay || unitBDevice is ThunderboltUnitBConnection else { return }
        twoUnitSleeping = true
        twoUnitReplayNeeded = true
        (unitBDevice as? ThunderboltUnitBConnection)?.invalidate()
        applyUnitB(nil, from: nil)
    }

    func wakeTwoUnitReplay() {
        twoUnitSleeping = false
        if usesTwoUnitReplay { twoUnitReplayNeeded = true }
    }
}
