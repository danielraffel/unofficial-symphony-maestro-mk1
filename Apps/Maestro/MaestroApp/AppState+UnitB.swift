import Foundation
import MaestroCore
import MaestroDevice

/// Two Symphony I/Os on ThunderBridge: unit A on port 1 (channels 1-32) and,
/// while 64 channels run, unit B on port 2 (channels 33-64).
///
/// The per-unit pages (Input, Output, Device Settings, System Setup) read the
/// `unit…` members below instead of `device`, `cardLayout` and the meter
/// arrays. Each returns exactly what it did before unless unit B is present
/// and chosen in the picker, so with one unit nothing changes. The Mixer and
/// Output Routing are the card's and show both units at once.
extension AppState {

    // MARK: Which unit

    /// Unit B's card layout, from its own board types.
    /// Its rate is unit A's (Loop Sync slave), so names follow unit A's rate.
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
                          isSimulatingCards: cardSimulation != nil || simulatedUnitB != nil, unit: .b)
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
        activeUnit == .b ? unitBSource(slot: 0) : primaryBoardSource
    }
    var unitSecondaryBoardSource: BoardDetectionSource {
        activeUnit == .b ? unitBSource(slot: 1) : secondaryBoardSource
    }
    private func unitBSource(slot: Int) -> BoardDetectionSource {
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
    /// Unit B's digital output pairs are not metered separately (as unit A's
    /// on ThunderBridge, these stay at silence).
    var unitDigitalOutputMeterLevels: [Double] {
        activeUnit == .b ? Array(repeating: -60.0, count: 24) : digitalOutputMeterLevels
    }
    var unitDigitalOutputPeakHold: [Double] {
        activeUnit == .b ? Array(repeating: -60.0, count: 24) : digitalOutputPeakHold
    }

    // MARK: Unit B's per-slot digital settings

    /// Unit B's optical formats, Replaces and Mirrors, under their own key.
    var unitBDigitalSettingsKey: String? {
        unitBLayout?.savedStateScope.map { "slotDigitalSettings.unitB.\($0)" }
    }

    private var unitBDigitalSettings: SlotDigitalSettings {
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
        return TwoUnitMixer.channels(unitA: cardLayout, unitB: unitBLayout, prefixB: unitBPeripheralPrefix)
    }

    /// Unit B cannot be there: USB, or a port selection that is not 64
    /// channels. Unknown (nil port selection at launch) is not absent.
    var unitBKnownAbsent: Bool {
        if transportType == .usb { return true }
        if let selection = portSelection.selection, selection != .ports1And2 { return true }
        return false
    }

    /// Software Return pairs the Mixer offers: 8, or 32 with unit B.
    var softwareReturnPairCount: Int { TwoUnitMixer.softwareReturnPairCount(unitBActive: unitBOnCard) }

    /// The input meter of Mixer strip `strip`: unit A's strips read unit A's
    /// meters, unit B's (after them) read unit B's.
    func mixerInputMeterLevel(strip: Int) -> Double {
        let aCount = unitBOnCard ? cardLayout.mixerChannels.count : Int.max
        if strip < aCount {
            return strip < inputMeterLevels.count ? inputMeterLevels[strip] : -60.0
        }
        let b = strip - aCount
        return b < unitBInputMeterLevels.count ? unitBInputMeterLevels[b] : -60.0
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

    // MARK: Output Routing (unit B's outputs, XLink TX 32-63)

    /// Unit B's saved output routes, rows in the 64-channel grid's numbering
    /// (DAW pairs 0-31, Mixer 1 = 32, Mixer 2 = 33), columns in unit B's own
    /// output columns. Its own key, per unit B card pair as its channel state
    /// is: unit A's saved table is never touched, and a unit B with other
    /// cards does not inherit the columns. Nil until unit B's cards are known.
    var unitBOutputRoutingCache: RoutingStateCache? {
        guard let device,
              let direction = Self.unitBOutputRoutingDirection(
                cardScope: unitBLayout?.savedStateScope,
                simulating: cardSimulation != nil || simulatedUnitB != nil) else { return nil }
        return RoutingStateCache(direction: direction, productID: device.identifier.productID)
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
        for route in routes { try tb.setCardOutputRoute(route) }
    }

    /// Put unit B's saved output routes back on the card.
    @MainActor
    func syncUnitBOutputRouting() async {
        guard unitBOnCard, let layout = unitBLayout, let routes = unitBOutputRoutingCache?.loadMulti() else { return }
        let columns = layout.outputRoutingColumns
        var written = 0
        for (row, cols) in routes.sorted(by: { $0.key < $1.key }) {
            for col in cols.sorted() where col >= 0 && col < columns.count {
                do {
                    try await writeUnitBOutputRoutePair(destLeft: columns[col].routingByte, gridRow: row)
                    written += 1
                } catch {
                    print("[Maestro] Unit B output route \(row) → \(col) failed: \(error)")
                }
            }
        }
        if written > 0 { print("[Maestro] Unit B: wrote \(written) saved output route(s)") }
    }

    /// Save Software Return 1-2 for each mixer whose saved source is beyond
    /// the one-unit pairs. Only when unit B is known to be gone.
    func resetSoftwareReturnSourcesBeyondOneUnit(defaults: UserDefaults = .standard) {
        for mixer in 0..<2 {
            let key = "mixerSoftwareReturnSource_\(mixer)"
            let saved = UInt32(clamping: defaults.integer(forKey: key))
            if TwoUnitMixer.resetsSavedSoftwareReturn(saved, unitBKnownAbsent: true) {
                defaults.set(0, forKey: key)
                print("[Maestro] Mixer \(mixer + 1) Software Return: DAW \(TwoUnitMixer.softwareReturnName(saved)) "
                      + "is unit B's; back to 1-2")
            }
        }
    }

    // MARK: Meters

    /// Unit B's meters from the card's meter words (called from the
    /// ThunderBridge meter poll with its word → dB function).
    func updateUnitBMeters(dB: (Int) -> Double) {
        guard unitBOnCard, let layout = unitBLayout else { return }
        let host = (0..<UnitBMeterMap.inputWordCount).map(dB)
        let words = UnitBMeterMap.inputWords(layout: layout)
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
        unitBOutputMeterLevels = smoothMeterLevels(
            unitBOutputMeterLevels, raw: UnitBMeterMap.outputLevels(dB: dB, count: outputs))
        unitBInputPeakHold = advancePeakHold(unitBInputPeakHold, levels: unitBInputMeterLevels)
        unitBDigitalInputPeakHold = advancePeakHold(unitBDigitalInputPeakHold, levels: unitBDigitalInputMeterLevels)
        unitBOutputPeakHold = advancePeakHold(unitBOutputPeakHold, levels: unitBOutputMeterLevels)
    }

    // MARK: Lifecycle

    /// Ask the driver about unit B (no bus access) and follow what it says.
    func refreshUnitB() {
        guard simulatedUnitB == nil else { return }
        guard let tb = device as? ThunderboltDeviceConnection, connectedUnit == nil else {
            applyUnitB(nil, from: nil)
            return
        }
        let state = tb.readUnitBState()
        applyUnitB(state?.info, from: tb, confirmedAbsent: state?.present == false)
    }

    /// The same, with the read off the main thread (the health loop's call:
    /// user-client calls can wait behind a link recovery).
    @MainActor
    func refreshUnitBOffMain(_ tb: ThunderboltDeviceConnection) async {
        guard simulatedUnitB == nil else { return }
        let state = await Task.detached(priority: .utility) { tb.readUnitBState() }.value
        guard (device as? ThunderboltDeviceConnection) === tb, connectedUnit == nil else { return }
        applyUnitB(state?.info, from: tb, confirmedAbsent: state?.present == false)
    }

    /// Follow unit B appearing, changing or going. On appearing (or on a new
    /// connection), its connection is made and its saved settings are put back
    /// once. On going, the pages return to unit A. `confirmedAbsent`: the
    /// driver answered that unit B is not there (not a failed read, which can
    /// happen during a link recovery).
    func applyUnitB(_ info: SecondUnitInfo?, from tb: ThunderboltDeviceConnection?, confirmedAbsent: Bool = false) {
        let owner = tb.map { ObjectIdentifier($0) }
        let newConnection = info != nil && owner != unitBOwner
        guard info != unitB || newConnection || (info == nil && unitBDevice != nil) else { return }
        let appeared = info != nil && (unitB == nil || newConnection)
        unitB = info
        guard let info, let tb else {
            if unitBDevice != nil {
                print("[Maestro] Unit B: gone (64 channels stopped or port 2 lost)")
                // The driver puts a Software Return beyond DAW 1-16 back to
                // 1-2 when two units end; save the same, once it says so.
                if confirmedAbsent { resetSoftwareReturnSourcesBeyondOneUnit() }
            }
            let oldDevice = unitBDevice
            Task { await oldDevice?.disconnect() }
            unitBDevice = nil
            unitBMonitor = UnitBMonitorState()
            unitBOwner = nil
            selectedUnit = .a
            unitBInputMeterLevels = []
            unitBOutputMeterLevels = []
            return
        }
        if newConnection || unitBDevice == nil {
            let connection = tb.makeUnitBConnection(settingsStore: .persistent(for: tb.identifier, unit: .b))
            let oldDevice = unitBDevice
            Task { await oldDevice?.disconnect() }
            unitBDevice = connection
            let monitor = UnitBMonitorState()
            unitBMonitor = monitor
            Task { @MainActor in await monitor.refresh(from: connection) }
            unitBOwner = owner
            unitBPeripheralPrefix = connection.settingsStore.value(for: PropertyAddress(selector: .prefix))?.asString
                .map(CardLayout.peripheralPrefix) ?? info.prefix(after: peripheralPrefix)
        }
        if appeared {
            refreshUnitBNamingFromSaved()
            print("[Maestro] Unit B: " + info.reportLines(unitAPrefix: peripheralPrefix).joined(separator: "; "))
            // AppState lives on the main actor in practice (as the C
            // callbacks above it assume); the replay runs there.
            nonisolated(unsafe) let state = self
            Task { @MainActor in await state.replayUnitBSettings() }
        }
    }

    /// Put unit B's saved settings back, as the connect replay does for unit
    /// A: its device settings, analog channel settings (port 2), optical
    /// formats, and its output routes on the card.
    @MainActor
    func replayUnitBSettings() async {
        guard connectionMode == .hardware, let b = unitBDevice as? ThunderboltUnitBConnection,
              let layout = unitBLayout else { return }
        let settings = await b.reapplyStoredSettings()
        let store = unitBChannelStateStore
        let channels = await AnalogChannelSettingsReplay.apply(
            inputs: store.load(ChannelStateStore.inputKey) ?? [],
            outputs: store.load(ChannelStateStore.outputKey) ?? [],
            layout: layout, device: b)
        var digital = 0
        for write in unitBDigitalSettings.writes(layout: layout) {
            if (try? await b.setProperty(write.address, value: .uint32(write.value))) != nil { digital += 1 }
        }
        await syncUnitBOutputRouting()
        print("[Maestro] Unit B: re-applied \(settings.applied) setting(s), \(channels.applied) analog channel "
              + "setting(s), \(digital) digital setting(s)"
              + (settings.failed.isEmpty && channels.failed == 0 ? "" : "; refused \(settings.failed.count + channels.failed)"))
    }

    /// Global clear reaches both peripherals, as in
    /// og_source/maestrolink/Software/SymphonyController.cpp:316-331.
    @MainActor
    func clearMeters() {
        inputPeakHold = Array(repeating: -60, count: inputPeakHold.count)
        outputPeakHold = Array(repeating: -60, count: outputPeakHold.count)
        digitalInputPeakHold = Array(repeating: -60, count: 24)
        digitalOutputPeakHold = Array(repeating: -60, count: 24)
        unitBInputPeakHold = Array(repeating: -60, count: unitBInputPeakHold.count)
        unitBOutputPeakHold = Array(repeating: -60, count: unitBOutputPeakHold.count)
        unitBDigitalInputPeakHold = Array(repeating: -60, count: 24)
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
