import Foundation
import MaestroCore
import MaestroDevice

/// Two Symphony I/Os on ThunderBridge: unit A on port 1 (channels 1-32) and,
/// while 64 channels run, unit B on port 2 (channels 33-64).
///
/// The per-unit pages (Input, Output, Input Routing, Device Settings) read the
/// `unit…` members below instead of `device`, `cardLayout` and the meter
/// arrays. Each returns exactly what it did before unless unit B is present
/// and chosen in the picker, so with one unit nothing changes. The Mixer and
/// Output Routing are the card's and show both units at once.
extension AppState {

    var loopSyncVisible: Bool {
        SymphonyExtendedSelectors.supported(by: servingDextBuild) && LoopSyncSettings.available(in: SymphonyRoutingModel(
            topology: converterSystem == nil && connectedUnit == nil && transportType == .thunderbolt
                ? .symphonyOnly : .unknown,
            hostChannels: portSelection.selection?.channelCount ?? 0,
            unitBConfigured: unitPickerVisible && unitB?.setupComplete == true))
    }

    @MainActor
    func refreshLoopSync(restoring: Bool = false) async {
        guard !hardwareWritesSuspended, loopSyncVisible, !loopSyncBusy, let tb = device as? ThunderboltDeviceConnection else { return }
        loopSyncBusy = true
        defer { loopSyncBusy = false }
        let owner = unitBDevice
        do {
            var state = try await tb.loopSync()
            guard device === tb, unitBDevice === owner, loopSyncVisible else { return }
            if (restoring || loopSyncNeedsRestore), let saved = LoopSyncSettings.saved(in: .standard), saved != state.settings {
                state = try await tb.loopSync(saved)
            }
            guard device === tb, unitBDevice === owner, loopSyncVisible else { return }
            loopSyncState = state
            loopSyncNeedsRestore = false
            loopSyncError = nil
            refreshUnitB()
        } catch {
            guard device === tb, unitBDevice === owner else { return }
            loopSyncState = nil
            loopSyncError = "Loop Sync settings could not be read. They require the driver from this version of Maestro."
        }
    }

    @MainActor
    func setLoopSync(_ settings: LoopSyncSettings) async {
        guard loopSyncVisible, !loopSyncBusy, loopSyncState != nil,
              let tb = device as? ThunderboltDeviceConnection else { return }
        loopSyncBusy = true
        defer { loopSyncBusy = false }
        let owner = unitBDevice
        do {
            let state = try await tb.loopSync(settings)
            guard device === tb, unitBDevice === owner, loopSyncVisible else { return }
            loopSyncState = state
            if state.valid {
                settings.save(in: .standard)
                loopSyncError = nil
            } else { loopSyncError = "Clock configuration is not confirmed." }
            refreshUnitB()
        } catch {
            guard device === tb, unitBDevice === owner else { return }
            loopSyncState = nil
            loopSyncError = "The driver could not complete the clock change."
        }
    }

    // MARK: Which unit

    /// Unit B's card layout, from its own board types.
    /// Both units share the card's nominal sample rate, regardless of clock master.
    var unitBLayout: CardLayout? {
        guard let unitB else { return nil }
        var naming = unitBChannelNaming
        naming.sampleRate = channelNaming.sampleRate
        return unitB.layout(naming: naming)
    }

    /// Whether the Unit A / Unit B picker is shown (and unit B is usable).
    var unitPickerVisible: Bool {
        guard unitB != nil, unitBDevice != nil else { return false }
        if simulatedUnitB != nil { return true }
        return UnitPicker.isVisible(transport: transportType, unitB: unitB,
                                    portSelection: portSelection.selection,
                                    convertersPresent: converterSystem != nil)
    }

    /// The unit the per-unit pages show: the picker's choice while it is
    /// shown, unit A otherwise.
    var activeUnit: DeviceUnit { unitPickerVisible ? selectedUnit : .a }

    /// Unit B's inputs are on the Mixer and its outputs in Output Routing.
    var unitBOnCard: Bool { unitPickerVisible && unitBLayout != nil }

    /// Changes when unit B appears, goes or changes cards; 0 with one unit.
    var unitBLayoutToken: Int {
        guard unitBOnCard, let unitB else { return 0 }
        return (Int(unitB.slot1.rawValue) << 8 | Int(unitB.slot2.rawValue) | 1 << 16) << 40
    }

    // MARK: Per-unit members the pages read

    var unitDevice: (any DeviceConnection)? { activeUnit == .b ? unitBDevice : device }
    var unitCardLayout: CardLayout { activeUnit == .b ? (unitBLayout ?? cardLayout) : cardLayout }
    var unitChannelStateStore: ChannelStateStore {
        activeUnit == .b ? unitBChannelStateStore : channelStateStore
    }
    var unitBChannelStateStore: ChannelStateStore {
        ChannelStateStore(layout: unitBLayout ?? CardLayout(isKnown: false),
                          isSimulatingCards: cardSimulation != nil || simulatedUnitB != nil, unit: .b,
                          identity: unitBIdentity,
                          awaitingIdentity: connectionMode == .hardware && unitBIdentityState == .pending && unitBDevice != nil,
                          allowLegacyMigration: allowsLegacyUnitState(unit: .b))
    }
    var unitPeripheralPrefix: String {
        get { activeUnit == .b ? unitBPeripheralPrefix : peripheralPrefix }
        set {
            if activeUnit == .b { unitBPeripheralPrefix = newValue } else { peripheralPrefix = newValue }
        }
    }
    var unitChannelNaming: CardLayout.ChannelNaming {
        get { activeUnit == .b ? unitBChannelNaming : channelNaming }
        set {
            if activeUnit == .b { unitBChannelNaming = newValue } else { channelNaming = newValue }
        }
    }
    var unitPrimaryBoardType: IOCardType { activeUnit == .b ? (unitB?.slot1 ?? .none) : primaryBoardType }
    var unitSecondaryBoardType: IOCardType { activeUnit == .b ? (unitB?.slot2 ?? .none) : secondaryBoardType }
    var unitPrimaryBoardSource: BoardDetectionSource {
        activeUnit == .b ? unitBBoardSource(slot: 0) : primaryBoardSource
    }
    var unitSecondaryBoardSource: BoardDetectionSource {
        activeUnit == .b ? unitBBoardSource(slot: 1) : secondaryBoardSource
    }
    func unitBBoardSource(slot: Int) -> BoardDetectionSource {
        if simulatedUnitB != nil { return .simulated }
        return unitB?.slotValid[slot] == true ? .detected : .unknown
    }

    var unitInputMeterLevels: [Double] { activeUnit == .b ? unitBInputMeterLevels : inputMeterLevels }
    var unitInputPeakHold: [Double] { activeUnit == .b ? unitBInputPeakHold : inputPeakHold }
    var unitOutputMeterLevels: [Double] { activeUnit == .b ? unitBOutputMeterLevels : outputMeterLevels }
    var unitOutputPeakHold: [Double] { activeUnit == .b ? unitBOutputPeakHold : outputPeakHold }
    var unitDigitalInputMeterLevels: [Double] {
        activeUnit == .b ? unitBDigitalInputMeterLevels : digitalInputMeterLevels
    }
    var unitDigitalInputPeakHold: [Double] {
        activeUnit == .b ? unitBDigitalInputPeakHold : digitalInputPeakHold
    }
    /// Unit B's digital output pairs, in the same board/pair order as unit A.
    var unitDigitalOutputMeterLevels: [Double] {
        activeUnit == .b ? unitBDigitalOutputMeterLevels : digitalOutputMeterLevels
    }
    var unitDigitalOutputPeakHold: [Double] {
        activeUnit == .b ? unitBDigitalOutputPeakHold : digitalOutputPeakHold
    }

    // MARK: Unit B's per-slot digital settings

    /// Unit B's optical formats, Replaces and Mirrors, under their own key.
    var unitBDigitalSettingsKey: String? {
        unitBLayout?.savedStateScope.map { unitPreferenceKey(legacy: "slotDigitalSettings.unitB.\($0)", category: "slotDigitalSettings", unit: .b) }
    }

    var unitBDigitalSettings: SlotDigitalSettings {
        guard let key = unitBDigitalSettingsKey else { return SlotDigitalSettings() }
        return SlotDigitalSettings.load(key: key)
    }

    /// `rememberDigitalSetting` for the unit the page shows.
    @MainActor
    func rememberUnitDigitalSetting(_ selector: AudioPropertySelector, slot: Int, value: UInt32) {
        saveDigitalSetting(selector, slot: slot, value: value, for: unitWriteTarget)
    }

    // MARK: Writes that wait

    /// The unit a page writes to, taken before the write awaits: its device,
    /// its saved channel state and its digital-settings key. Reading
    /// `activeUnit` or the stores again after the await could file unit B's
    /// values under unit A's keys if the user switched units, or unit B went,
    /// meanwhile.
    struct UnitWriteTarget {
        let unit: DeviceUnit
        let device: (any DeviceConnection)?
        let channelStore: ChannelStateStore
        let digitalSettingsKey: String?
    }

    /// The unit the page shows now, for a write that is about to await.
    var unitWriteTarget: UnitWriteTarget {
        UnitWriteTarget(unit: activeUnit, device: unitDevice, channelStore: unitChannelStateStore,
                        digitalSettingsKey: activeUnit == .b ? unitBDigitalSettingsKey : digitalSettingsKey)
    }

    /// Unit B whatever the picker shows, for the card's own pages (Output
    /// Routing) that show both units at once.
    var unitBWriteTarget: UnitWriteTarget {
        UnitWriteTarget(unit: .b, device: unitBDevice, channelStore: unitBChannelStateStore,
                        digitalSettingsKey: unitBDigitalSettingsKey)
    }

    /// Whether the unit a target was taken from is still connected as it
    /// was: unit A always, unit B while the same connection is there.
    func isCurrent(_ target: UnitWriteTarget) -> Bool {
        guard target.unit == .b else { return true }
        guard let device = target.device, let current = unitBDevice else { return false }
        return device === current
    }

    /// Remember a digital setting for the unit `target` was taken from.
    @MainActor
    func saveDigitalSetting(_ selector: AudioPropertySelector, slot: Int, value: UInt32,
                            for target: UnitWriteTarget) {
        guard let key = target.digitalSettingsKey else { return }
        SlotDigitalSettings.remember(selector, slot: slot, value: value, key: key)
    }

    /// Name a slot's S/PDIF Coax Replaces on the unit `target` was taken
    /// from, while that unit is still there.
    @MainActor
    func setSPDIFReplaceNaming(slot: Int, value: UInt32, for target: UnitWriteTarget) {
        guard slot >= 0, slot < 2, value <= 8, isCurrent(target) else { return }
        if target.unit == .b {
            unitBChannelNaming.spdifReplace[slot] = value
        } else {
            channelNaming.spdifReplace[slot] = value
        }
    }

    /// Unit B's channel names follow its saved optical formats and Replaces
    /// (the driver starts it at ADAT/SMUX; the replay puts these back).
    func refreshUnitBNamingFromSaved() {
        let saved = unitBDigitalSettings
        var naming = CardLayout.ChannelNaming(sampleRate: channelNaming.sampleRate)
        for slot in 0..<2 {
            if let format = saved.opticalFormat[slot], format <= 1 { naming.opticalIsSPDIF[slot] = format == 1 }
            if let replace = saved.spdifReplace[slot], replace <= 8 { naming.spdifReplace[slot] = replace }
        }
        if naming != unitBChannelNaming { unitBChannelNaming = naming }
    }

    // MARK: Mixer (both units' inputs while 64 channels run)

    /// Every hardware-input strip on the Mixer: unit A's, then unit B's.
    var mixerStripChannels: [CardLayout.MixerChannel] {
        guard unitBOnCard else { return cardLayout.mixerChannels }
        guard let layoutB = unitBLayout else { return cardLayout.mixerChannels }
        let bNumbers = (device is XPCDeviceConnection) ? nil : thunderboltMixerInputNumbers(unit: .b)
        return TwoUnitMixer.unitBChannels(layout: layoutB, prefix: unitBPeripheralPrefix,
                                          inputNumbers: bNumbers)
            .reduce(into: cardLayout.mixerChannels) { result, channel in result.append(channel) }
    }

    /// Resolve Mixer strips to the current ThunderBridge receive slots. This
    /// is computed from the saved capture tables on every use, independently
    /// of the throttled meter-word refresh.
    func thunderboltMixerInputNumbers(unit: DeviceUnit = .a) -> [Int?] {
        let layout = unit == .a ? cardLayout : unitBLayout
        guard let layout else { return [] }
        return ThunderboltInputMeterMap.mixerInputs(layout: layout, routes: thunderboltCaptureRoutes(unit: unit))
    }

    func thunderboltCaptureRoutes(unit: DeviceUnit = .a) -> [ThunderboltInputMeterMap.Route] {
        let layout = unit == .a ? cardLayout : unitBLayout
        guard let layout else { return [] }
        let slot1 = unit == .a ? thunderboltCaptureSlot1 : unitB?.slot1
        // The saved routing is the other input; whatever changes it calls
        // `invalidateThunderboltInputMeterMap`, which empties this cache.
        let key = ThunderboltCaptureRoutesKey(layout: layout, slot1: slot1, written: thunderboltInputRoutingWritten)
        if let cached = thunderboltCaptureRoutesCache[unit], cached.key == key { return cached.routes }
        let cache = unit == .a ? peripheralRoutingCache(direction: "input") : unitBInputRoutingCache
        let replayed = thunderboltInputRoutingWritten ? InputRoutingReplay.writes(
            saved: cache?.load() ?? [:], columns: layout.inputRoutingColumns, pairCount: 16) : []
        let routes = ThunderboltInputMeterMap.currentRoutes(slot1: slot1, replayed: replayed)
        thunderboltCaptureRoutesCache[unit] = (key, routes)
        return routes
    }

    /// The table the two-unit replay is about to write: numbered from the
    /// saved routing whatever is on the units now, because the replay writes
    /// the tables and the mixers in one plan.
    func savedThunderboltCaptureRoutes(unit: DeviceUnit) -> [ThunderboltInputMeterMap.Route] {
        let layout = unit == .a ? cardLayout : unitBLayout
        guard let layout else { return [] }
        let slot1 = unit == .a ? thunderboltCaptureSlot1 : unitB?.slot1
        let cache = unit == .a ? peripheralRoutingCache(direction: "input") : unitBInputRoutingCache
        let replayed = InputRoutingReplay.writes(saved: cache?.load() ?? [:],
                                                 columns: layout.inputRoutingColumns, pairCount: 16)
        return ThunderboltInputMeterMap.currentRoutes(slot1: slot1, replayed: replayed)
    }

    /// Unit B cannot be there: USB, or a port selection that is not 64
    /// channels. Unknown (nil port selection at launch) is not absent.
    var unitBKnownAbsent: Bool {
        if transportType == .usb { return true }
        if let selection = portSelection.selection, selection != .ports1And2 { return true }
        return false
    }

    /// Software Return pairs the Mixer offers: 8, or 32 with unit B.
    var softwareReturnPairCount: Int {
        TwoUnitMixer.softwareReturnPairCount(
            // The original offered every pair of the ports in use
            // (SymphonyCard.cpp:739-753): 32 with converters on port 2 too.
            unitBActive: unitBOnCard || cardLayout.converterLayout?.port2Counted == true,
            oneUnitPairs: TwoUnitMixer.oneUnitPairs(card: transportType == .thunderbolt, build: servingDextBuild))
    }

    /// Mixer strip states for `mixer`: unit A's saved strips (`unitA`), then
    /// unit B's from unit B's own store.
    func mixerStripStates(unitA: [MixerChannelState], mixer: Int) -> [MixerChannelState] {
        guard unitBOnCard, let layout = unitBLayout else { return unitA }
        let aCount = cardLayout.mixerChannels.count
        let a = Array(unitA.prefix(aCount))
        let b = MixerStateSnapshot(channelCount: layout.mixerChannels.count, mixer: mixer,
                                   store: unitBChannelStateStore).channels
        return a + b
    }

    /// Save Mixer strips: unit A's under unit A's key, unit B's under unit B's.
    func saveMixerStrips(_ channels: [MixerChannelState], mixer: Int) {
        guard unitBOnCard else {
            channelStateStore.save(channels, for: ChannelStateStore.mixerKey(mixer))
            return
        }
        let aCount = cardLayout.mixerChannels.count
        channelStateStore.save(Array(channels.prefix(aCount)), for: ChannelStateStore.mixerKey(mixer))
        unitBChannelStateStore.save(Array(channels.dropFirst(aCount)), for: ChannelStateStore.mixerKey(mixer))
    }

    // MARK: Input Routing (unit B's own P2P table)

    var unitBInputRoutingAllowed: Bool {
        let model = SymphonyRoutingModel(
            topology: converterSystem == nil ? .symphonyOnly : .unknown,
            hostChannels: portSelection.selection?.channelCount ?? 0,
            unitBConfigured: unitPickerVisible && unitB?.setupComplete == true)
        return model.allows(.unitRouting, at: .peripheral(.init(port: .two)!))
    }

    var unitBInputRoutingCache: RoutingStateCache? {
        guard device != nil,
              let direction = Self.unitBInputRoutingDirection(
                cardScope: unitBLayout?.savedStateScope,
                simulating: cardSimulation != nil || simulatedUnitB != nil) else { return nil }
        return peripheralRoutingCache(direction: direction.hasPrefix("input") ? "input" : "output", unit: .b)
    }

    static func unitBInputRoutingDirection(cardScope: String?, simulating: Bool) -> String? {
        guard let cardScope else { return nil }
        return "input.unitB." + (simulating ? "sim:" : "") + cardScope
    }

    // MARK: Output Routing (unit B's outputs, XLink TX 32-63)

    /// Unit B's saved output routes, rows in the 64-channel grid's numbering
    /// (DAW pairs 0-31, Mixer 1 = 32, Mixer 2 = 33), columns in unit B's own
    /// output columns. Its own key, per unit B card pair as its channel state
    /// is: unit A's saved table is never touched, and a unit B with other
    /// cards does not inherit the columns. Nil until unit B's cards are known.
    var unitBOutputRoutingCache: RoutingStateCache? {
        guard device != nil,
              let direction = Self.unitBOutputRoutingDirection(
                cardScope: unitBLayout?.savedStateScope,
                simulating: cardSimulation != nil || simulatedUnitB != nil) else { return nil }
        return peripheralRoutingCache(direction: direction.hasPrefix("input") ? "input" : "output", unit: .b)
    }

    /// The routing cache direction for unit B's outputs with these cards.
    static func unitBOutputRoutingDirection(cardScope: String?, simulating: Bool) -> String? {
        guard let cardScope else { return nil }
        return "output.unitB." + (simulating ? "sim:" : "") + cardScope
    }

    /// The card's TDM slot for one side of a 64-channel grid row.
    static func unitBSlot(gridRow row: Int, side: Int) -> UInt8? {
        if row >= 0 && row < TwoUnitOutputRouting.dawPairCount {
            return ThunderboltCardRouting.playbackSlot(channel: row * 2 + side)
        }
        if row == TwoUnitOutputRouting.mixer1Row { return ThunderboltCardRouting.mixerSlot(mixer: 0, side: side) }
        if row == TwoUnitOutputRouting.mixer2Row { return ThunderboltCardRouting.mixerSlot(mixer: 1, side: side) }
        return nil
    }

    /// The two card routes for a unit B output pair: `row` nil clears it.
    static func unitBRoutePair(destLeft: UInt8, gridRow row: Int?) -> [ThunderboltCardRouting.Route]? {
        var routes: [ThunderboltCardRouting.Route] = []
        for side in 0..<2 {
            let slot = row.flatMap { unitBSlot(gridRow: $0, side: side) }
            if row != nil && slot == nil { return nil }
            guard let route = ThunderboltCardRouting.unitBRoute(destination: destLeft &+ UInt8(side), slot: slot) else {
                return nil
            }
            routes.append(route)
        }
        return routes
    }

    /// Route one of unit B's output pairs on the card (0xB5 with XLink TX
    /// 32-63), through unit A's connection: the card's routing is not a unit's.
    @MainActor
    func writeUnitBOutputRoutePair(destLeft: UInt8, gridRow row: Int?) async throws {
        guard let routes = Self.unitBRoutePair(destLeft: destLeft, gridRow: row) else {
            throw DeviceConnectionError.transportError("No unit B card route for output \(destLeft)")
        }
        guard let tb = device as? ThunderboltDeviceConnection else {
            if simulatedUnitB != nil { return }
            throw DeviceConnectionError.notConnected
        }
        guard let b = unitBDevice as? ThunderboltUnitBConnection else {
            throw DeviceConnectionError.notConnected
        }
        outputRouteEdits &+= 1
        // A route from a mixer that is not written is deferred by the
        // connection: the output is disabled until the two-unit replay has
        // written that mixer and sends the saved route.
        let deferred = try await Task.detached(priority: .userInitiated) {
            try await Self.sendUnitBRoutes(routes, unitB: b, card: tb)
        }.value
        if deferred {
            outputRouteDeferredSinceSave = true
            twoUnitReplayNeeded = true
            updateRestoreStatus()
        }
    }

    /// Unit B's card routes through the one chokepoint; true when any was
    /// deferred (its output is then disabled).
    nonisolated static func sendUnitBRoutes(_ routes: [ThunderboltCardRouting.Route],
                                            unitB: ThunderboltUnitBConnection,
                                            card: ThunderboltDeviceConnection) async throws -> Bool {
        let deferred = DeferredFlag()
        try await unitB.applyOutputRouting(routes) { route in
            if try card.setCardOutputRoute(route) == .deferred {
                _ = try card.setCardOutputRoute(CardOutputTableOrder.disabled(route))
                deferred.set()
            }
        }
        return deferred.isSet
    }

    /// A complete B output table, used by Reset Routing and the routing preset.
    /// The captured connections never follow a later unit-picker change.
    @MainActor
    func applyUnitBOutputRouting(_ rows: [Int: Set<Int>], target: UnitWriteTarget) async throws {
        invalidateThunderboltOutputMeterMap()
        guard target.unit == .b, isCurrent(target) else { throw DeviceConnectionError.notConnected }
        guard unitBOnCard, let layout = unitBLayout, unitBOutputRoutingWritable else {
            throw DeviceConnectionError.notConnected
        }
        let columns = layout.outputRoutingColumns
        guard rows.allSatisfy({ row, cols in
            (0..<TwoUnitOutputRouting.rowCount).contains(row) && cols.allSatisfy { columns.indices.contains($0) }
        }) else { throw DeviceConnectionError.transportError("Invalid unit B output preset") }
        // A whole table: saved with its empty rows, so an output it leaves
        // unrouted stays unrouted when the grid is read back.
        let table = TwoUnitOutputRouting.completeTable(rows)
        // The second-unit simulation has no card to write; it keeps the table.
        if simulatedUnitB != nil, !(device is ThunderboltDeviceConnection) {
            unitBOutputRoutingCache?.save(table)
            return
        }
        guard let b = unitBDevice as? ThunderboltUnitBConnection,
              let card = device as? ThunderboltDeviceConnection else {
            throw DeviceConnectionError.notConnected
        }
        var writes: [ThunderboltCardRouting.Route] = []
        for (col, column) in columns.enumerated() {
            let owners = rows.filter { $0.value.contains(col) }.map(\.key)
            guard owners.count <= 1,
                  let pair = Self.unitBRoutePair(destLeft: column.routingByte, gridRow: owners.first) else {
                throw DeviceConnectionError.transportError("Invalid unit B output route")
            }
            writes += pair
        }
        let plannedWrites = writes
        outputRouteEdits &+= 1
        let deferred = try await Task.detached {
            try await Self.sendUnitBRoutes(plannedWrites, unitB: b, card: card)
        }.value
        guard unitBDevice === b else { throw DeviceConnectionError.notConnected }
        unitBOutputRoutingCache?.save(table)
        outputRouteEdits &+= 1
        if deferred {
            twoUnitReplayNeeded = true
            updateRestoreStatus()
        }
    }

    /// Unit B's cards are known well enough to write its output table: both
    /// slots detected, or simulated in the second-unit simulation.
    var unitBOutputRoutingWritable: Bool {
        let wanted: BoardDetectionSource = simulatedUnitB != nil ? .simulated : .detected
        return unitBBoardSource(slot: 0) == wanted && unitBBoardSource(slot: 1) == wanted
    }

    /// The card scope a two-unit Output Routing preset records for unit B
    /// (simulated cards apart from real ones, as unit B's routing cache).
    var unitBOutputPresetScope: String? {
        guard let scope = unitBLayout?.savedStateScope else { return nil }
        return (cardSimulation != nil || simulatedUnitB != nil ? "sim:" : "") + scope
    }

    /// Save Software Return 1-2 for each mixer whose saved source is beyond
    /// the one-unit pairs. Only when unit B is known to be gone.
    func resetSoftwareReturnSourcesBeyondOneUnit() {
        let defaults = mixerPreferences
        for mixer in 0..<2 {
            let key = "mixerSoftwareReturnSource_\(mixer)"
            let saved = UInt32(clamping: defaults.integer(forKey: key))
            // Only beyond the pairs on offer now (16 on the card with driver
            // 144, 32 with converters on port 2), not beyond the old 8.
            if TwoUnitMixer.resetsSavedSoftwareReturn(saved, unitBKnownAbsent: true),
               saved >= UInt32(softwareReturnPairCount) {
                defaults.set(0, forKey: key)
                print("[Maestro] Mixer \(mixer + 1) Software Return: DAW \(TwoUnitMixer.softwareReturnName(saved)) "
                      + "is unit B's; back to 1-2")
            }
        }
    }

    // MARK: Meters

    /// Unit B's meters from the card's meter words (called from the
    /// ThunderBridge meter poll with its word → dB function).
    func updateUnitBMeters(dB: (Int) -> Double, isOver: (Int) -> Bool,
                           pollCount: Int, preferUnitRead: Bool) -> Set<Int> {
        guard unitBOnCard, let layout = unitBLayout else { return [] }
        let host = (0..<UnitBMeterMap.inputWordCount).map(dB)
        let words = UnitBMeterMap.inputWords(layout: layout,
                                             routes: thunderboltCaptureRoutes(unit: .b))
        let count = layout.mixerChannels.count
        if unitBInputMeterLevels.count != count {
            unitBInputMeterLevels = Array(repeating: -60.0, count: count)
            unitBInputPeakHold = Array(repeating: -60.0, count: count)
        }
        let outputs = 32
        if unitBOutputMeterLevels.count != outputs {
            unitBOutputMeterLevels = Array(repeating: -60.0, count: outputs)
            unitBOutputPeakHold = Array(repeating: -60.0, count: outputs)
        }
        unitBInputMeterLevels = smoothMeterLevels(
            unitBInputMeterLevels, raw: ThunderboltInputMeterMap.stripLevels(host: host, words: words, count: count))
        unitBDigitalInputMeterLevels = smoothMeterLevels(
            unitBDigitalInputMeterLevels, raw: ThunderboltInputMeterMap.digitalLevels(host: host, words: words))
        if !preferUnitRead {
            refreshUnitBOutputMeterWords(layout: layout, pollCount: pollCount)
            unitBOutputMeterLevels = smoothMeterLevels(
                unitBOutputMeterLevels, raw: unitBOutputLevels(dB: dB, layout: layout))
            unitBDigitalOutputMeterLevels = smoothMeterLevels(
                unitBDigitalOutputMeterLevels, raw: unitBDigitalOutputLevels(dB: dB, layout: layout))
        }
        return Self.cardMixerInputOvers(words, count: count, isOver: isOver)
    }

    private func unitBOutputTable(layout: CardLayout) -> [UInt8: UInt8]? {
        guard layout.isKnown else { return nil }
        return TwoUnitOutputRouting.table(
            saved: unitBOutputRoutingCache?.loadMulti() ?? [:],
            columns: layout.outputRoutingColumns)
    }

    private func refreshUnitBOutputMeterWords(layout: CardLayout, pollCount: Int = 0) {
        guard unitBOutputMeterWordsPollStamp < 0
                || pollCount < unitBOutputMeterWordsPollStamp
                || pollCount - unitBOutputMeterWordsPollStamp >= 40
                || unitBOutputMeterLayout != layout else { return }
        unitBOutputMeterWordsPollStamp = pollCount
        unitBOutputMeterLayout = layout
        unitBOutputMeterWords = unitBOutputTable(layout: layout).map {
            ThunderboltOutputMeterMap.words(layout: layout, table: $0, unitBActive: true, unitB: true)
        } ?? nil
    }

    private func unitBOutputWords(layout: CardLayout) -> ThunderboltOutputMeterMap.Words? {
        guard [0, 1].allSatisfy({ source in
            let value = unitBBoardSource(slot: source)
            return value == .detected || value == .simulated
        }) else { return nil }
        return unitBOutputMeterWords
    }

    private func unitBOutputLevels(dB: (Int) -> Double, layout: CardLayout) -> [Double] {
        guard let words = unitBOutputWords(layout: layout) else { return UnitBMeterMap.outputLevels(dB: dB, count: 32) }
        return ThunderboltOutputMeterMap.levels(words.analog, count: 32, level: dB)
    }

    private func unitBDigitalOutputLevels(dB: (Int) -> Double, layout: CardLayout) -> [Double] {
        guard let words = unitBOutputWords(layout: layout) else { return Array(repeating: -60, count: CardLayout.digitalMeterSlots) }
        return ThunderboltOutputMeterMap.levels(words.digital, level: dB)
    }

    /// Both copy paths use the live connection's cache, even before Device Settings opens.
    var unitBDeviceInfoReportLines: [String] {
        guard let unitB, unitBDevice != nil else { return [] }
        return unitB.reportLines(unitAPrefix: peripheralPrefix) + unitBDeviceInfo.reportLines
    }

    // MARK: Lifecycle

    /// Ask the driver about unit B (no bus access) and follow what it says.
    func refreshUnitB() {
        guard simulatedUnitB == nil, !twoUnitSleeping else { return }
        guard let tb = device as? ThunderboltDeviceConnection, connectedUnit == nil else {
            applyUnitB(nil, from: nil)
            return
        }
        let state = tb.readUnitBState()
        applyUnitB(state?.info, from: tb, confirmedAbsent: state?.present == false)
        // No bus access here: unit B's identity is read once, off the main
        // thread, by refreshUnitBOffMain (the health loop).
    }

    /// The same, with the read off the main thread (the health loop's call:
    /// user-client calls can wait behind a link recovery).
    @MainActor
    func refreshUnitBOffMain(_ tb: ThunderboltDeviceConnection) async {
        guard simulatedUnitB == nil, !hardwareWritesSuspended else { return }
        let parentGeneration = unitAGeneration
        let initialBGeneration = unitBGeneration
        let state = await Task.detached(priority: .utility) { tb.readUnitBState() }.value
        guard unitAGeneration == parentGeneration, unitBGeneration == initialBGeneration, !Task.isCancelled else { return }
        guard (device as? ThunderboltDeviceConnection) === tb, connectedUnit == nil else { return }
        applyUnitB(state?.info, from: tb, confirmedAbsent: state?.present == false)
        // Once per unit-B connection: the health loop calls this every few
        // seconds and must not put a vendor read on the bus each time.
        guard state?.present == true, !unitBIdentityAttempted,
              SymphonyIdentityReader.isSupported(layout: cardLayout, unit: .b) else { return }
        guard let captured = unitBDevice as? ThunderboltUnitBConnection else { return }
        await resolveUnitIdentity(for: .b, connection: captured) {
            await tb.readHardwareUniqueID(port: ThunderboltUnitBConnection.port)
        }
    }

    /// Follow unit B appearing, changing or going. On appearing (or on a new
    /// connection), its connection is made and its saved settings are put back
    /// once. On going, the pages return to unit A. `confirmedAbsent`: the
    /// driver answered that unit B is not there (not a failed read, which can
    /// happen during a link recovery).
    func applyUnitB(_ info: SecondUnitInfo?, from tb: ThunderboltDeviceConnection?, confirmedAbsent: Bool = false) {
        let owner = tb.map { ObjectIdentifier($0) }
        // Board or configured-state changes invalidate the per-connection readings;
        // ordinary prefix/clock/error-count changes do not identify a replacement.
        let changedHardware = info != nil && unitB != nil &&
            (info?.slot1 != unitB?.slot1 || info?.slot2 != unitB?.slot2 ||
             info?.slotValid != unitB?.slotValid || info?.setupComplete != unitB?.setupComplete)
        let newConnection = info != nil && (owner != unitBOwner || changedHardware)
        guard info != unitB || newConnection || (info == nil && unitBDevice != nil) else { return }
        let appeared = info != nil && (unitB == nil || newConnection)
        unitB = info
        guard let info, let tb else {
            invalidateUnitBIdentity()
            unitBIdentityAttempted = false
            loopSyncState = nil
            loopSyncError = nil
            if unitBDevice != nil {
                print("[Maestro] Unit B: gone (64 channels stopped or port 2 lost)")
                // The driver puts a Software Return beyond DAW 1-16 back to
                // 1-2 when two units end; save the same, once it says so.
                if confirmedAbsent { resetSoftwareReturnSourcesBeyondOneUnit() }
            }
            let oldDevice = unitBDevice
            (oldDevice as? ThunderboltUnitBConnection)?.invalidate()
            Task { await oldDevice?.disconnect() }
            unitBDevice = nil
            unitBMonitor = UnitBMonitorState()
            unitBDeviceInfo = SymphonyDeviceInfo()
            unitBOwner = nil
            selectedUnit = .a
            unitBInputMeterLevels = []
            unitBOutputMeterLevels = []
            unitBDigitalOutputMeterLevels = Array(repeating: -60, count: CardLayout.digitalMeterSlots)
            unitBDigitalOutputPeakHold = Array(repeating: -60, count: CardLayout.digitalMeterSlots)
            unitBOutputMeterWords = nil
            unitBOutputMeterLayout = nil
            unitBOutputMeterWordsPollStamp = -1
            return
        }
        if newConnection || unitBDevice == nil {
            if newConnection {
                invalidateUnitBIdentity()
                unitBIdentityAttempted = false
            }
            let connection = tb.makeUnitBConnection(settingsStore: DeviceSettingsStore())
            let oldDevice = unitBDevice
            (oldDevice as? ThunderboltUnitBConnection)?.invalidate()
            Task { await oldDevice?.disconnect() }
            unitBDevice = connection
            unitBOutputMeterWords = nil
            unitBOutputMeterLayout = nil
            unitBOutputMeterWordsPollStamp = -1
            unitBDeviceInfo = SymphonyDeviceInfo()
            nonisolated(unsafe) let infoOwner = self
            Task { @MainActor in
                let info = await connection.readDeviceInfo()
                guard infoOwner.unitBDevice === connection else { return }
                infoOwner.unitBDeviceInfo = info
            }
            let monitor = UnitBMonitorState()
            unitBMonitor = monitor
            Task { @MainActor in
                await monitor.refresh(from: connection)
            }
            unitBOwner = owner
            unitBPeripheralPrefix = connection.settingsStore.value(for: PropertyAddress(selector: .prefix))?.asString
                .map(CardLayout.peripheralPrefix) ?? info.prefix(after: peripheralPrefix)
        }
        if appeared {
            loopSyncNeedsRestore = true
            refreshUnitBNamingFromSaved()
            print("[Maestro] Unit B: " + info.reportLines(unitAPrefix: peripheralPrefix).joined(separator: "; "))
            // One owner: the health loop waits for both configured links and
            // restores tables, card routes/mixers, then names/meters/headphones.
            twoUnitReplayNeeded = true
            // Loop Sync topology restored on appearance (B9); the replay itself
            // stays with the health loop (B7).
            nonisolated(unsafe) let state = self
            Task { @MainActor in
                await state.refreshLoopSync(restoring: true)
            }
        }
    }

    /// Global clear reaches both peripherals, as in
    /// og_source/maestrolink/Software/SymphonyController.cpp:316-331.
    @MainActor
    func clearMeters() {
        clearDisplayedMeterHolds()
        let devices = [device, unitBDevice].compactMap { $0 }
        Task {
            for device in devices {
                do {
                    try await device.setProperty(PropertyAddress(selector: .peaksClear), value: .uint32(1))
                } catch { print("[Maestro] ERROR: Clear Meters failed: \(error)") }
            }
        }
    }

    // MARK: Simulation (debug only)

    /// `-MaestroSimulateSecondUnit "analogADDA16+optical"` (or "16x16"):
    /// shows a second unit with those cards, no hardware.
    func applySecondUnitSimulation(_ info: SecondUnitInfo, identifier: USBDeviceIdentifier) {
        simulatedUnitB = info
        unitB = info
        let config = CardConfiguration(slot1: info.slot1, slot2: info.slot2)
        unitBDevice = (try? SimulatedDevice.symphonyIO(configuration: config)) ?? SimulatedDevice.symphonyIO32ch()
        unitBPeripheralPrefix = info.prefix(after: peripheralPrefix)
        refreshUnitBNamingFromSaved()
        print("[Maestro] SECOND UNIT SIMULATION: \(info.slot1.productName) + \(info.slot2.productName) — no hardware")
    }
}

/// Set from the connection's serial owner, read after it returns.
final class DeferredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// What the capture routes of a unit are worked out from, besides its saved
/// Input Routing: a cached answer is used only while these are unchanged.
struct ThunderboltCaptureRoutesKey: Equatable {
    let layout: CardLayout
    let slot1: IOCardType?
    let written: Bool
}
