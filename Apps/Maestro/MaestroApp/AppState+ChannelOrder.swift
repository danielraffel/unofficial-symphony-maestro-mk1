import Foundation
import MaestroCore
import MaestroDevice

/// ThunderBridge tables in the order the serving driver programs
/// (`ThunderboltUnitChannelOrder`): every default table, XLink channel and
/// headphone source the app computes for a unit comes through here, so they
/// all follow the same order and slot types.
extension AppState {
    /// The capture table the serving driver programs for `unit`
    /// (`SymphonyIODefaultRouting.thunderboltInputRoutes(slot1:slot2:order:)`).
    func thunderboltDefaultInputRoutes(unit: DeviceUnit = .a) -> [SymphonyIODefaultRouting.Route] {
        let order = thunderboltDisplayOrder(unit: unit)
        return SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: order.slot1, slot2: order.slot2, order: order.order)
    }

    /// The default output table for `unit` (board outputs 32-63 in order):
    /// card by card, from the fitted cards' output counts as before; analog
    /// first, the driver's playback table.
    func thunderboltDefaultOutputRoutes(unit: DeviceUnit = .a) -> [SymphonyIODefaultRouting.Route] {
        let order = thunderboltDisplayOrder(unit: unit)
        if order.order == .cardByCard, let layout = unit == .a ? cardLayout : unitBLayout {
            return SymphonyIODefaultRouting.thunderboltOutputRoutes(
                board0Outputs: layout.slot1.totalOutputChannels, board1Outputs: layout.slot2.totalOutputChannels)
        }
        return SymphonyIODefaultRouting.thunderboltOutputRoutes(slot1: order.slot1, slot2: order.slot2, order: order.order)
    }

    /// The XLink TX channel (0-31 of `unit`) that plays on board output
    /// `destination`; nil when none does.
    func thunderboltXLinkChannel(forDestination destination: UInt8, unit: DeviceUnit = .a) -> UInt8? {
        let order = thunderboltDisplayOrder(unit: unit)
        return ThunderboltCardRouting.channel(forDestination: destination, slot1: order.slot1,
                                              slot2: order.slot2, order: order.order)
    }

    /// Unit A's card route for one (destination, source) pair, in its order.
    func thunderboltCardRoute(destination: UInt8, source: UInt8, unitBActive: Bool) -> ThunderboltCardRouting.Route? {
        let order = thunderboltDisplayOrder(unit: .a)
        return ThunderboltCardRouting.route(destination: destination, source: source, unitBActive: unitBActive,
                                            slot1: order.slot1, slot2: order.slot2, order: order.order)
    }

    /// Unit A's XLink channels no board output reaches: written disabled
    /// with the whole table.
    var thunderboltUnreachedChannels: [UInt8] {
        let order = thunderboltDisplayOrder(unit: .a)
        return ThunderboltCardRouting.unreachedChannels(slot1: order.slot1, slot2: order.slot2, order: order.order)
    }

    /// Why ThunderBridge routing cannot be written yet because the driver
    /// has not said which order it programmed; nil when it can.
    var thunderboltChannelOrderUnknownReason: String? {
        guard transportType == .thunderbolt else { return nil }
        if thunderboltUnitOrder(unit: .a) == nil { return "the driver has not reported its channel order yet" }
        if unitBOnCard, thunderboltUnitOrder(unit: .b) == nil {
            return "the driver has not reported the second unit's channel order yet"
        }
        return nil
    }
}

extension AppState {
    /// Read which order the serving driver programmed each unit's tables in
    /// (selector 17) and, when it changed, renumber everything that follows
    /// it: the grids and names, the meter maps, the output table and the
    /// input routing replay. Then the one-time analog-first reset may run.
    /// Called at connect (before any routing is written), on every healthy
    /// probe, and first thing after a link recovery (which can switch a unit
    /// from card by card to analog first: the Symphony powered on after
    /// Start, a card read on recovery).
    @MainActor
    func refreshThunderboltChannelOrder(_ tb: ThunderboltDeviceConnection) async {
        let applied = await Task.detached(priority: .utility) { tb.appliedChannelOrder() }.value
        guard device === tb else { return }
        // A failed read keeps what this connection last read: a build-150
        // driver always answers, and a different driver is a new connection
        // (or a new serving build, which decides the order by itself).
        if let applied, applied != thunderboltAppliedChannelOrder {
            let before = (thunderboltUnitOrder(unit: .a), thunderboltUnitOrder(unit: .b))
            thunderboltAppliedChannelOrder = applied
            let after = (thunderboltUnitOrder(unit: .a), thunderboltUnitOrder(unit: .b))
            if before != after {
                print("[Maestro] ThunderBridge channel order: A \(Self.describe(before.0)) → \(Self.describe(after.0)), "
                    + "B \(Self.describe(before.1)) → \(Self.describe(after.1))")
                thunderboltChannelOrderDidChange(tb, wasKnown: before.0 != nil)
            }
        }
        runChannelOrderResetIfNeeded()
    }

    private static func describe(_ order: ThunderboltUnitChannelOrder?) -> String {
        guard let order else { return "unknown" }
        return "\(order.order == .analogFirst ? "analog first" : "card by card") (\(order.slot1?.caseName ?? "?")+\(order.slot2?.caseName ?? "?"))"
    }

    /// The order a unit's tables follow changed: what was drawn and numbered
    /// from the old one is worked out again, and what was written in it is
    /// owed again. From not known to known the skipped writes are already
    /// owed (they wait on `thunderboltChannelOrderUnknownReason`).
    @MainActor
    private func thunderboltChannelOrderDidChange(_ tb: ThunderboltDeviceConnection, wasKnown: Bool) {
        invalidateThunderboltInputMeterMap()
        invalidateThunderboltOutputMeterMap()
        symphonyCardInputNamingRevision += 1
        viewReloadToken = UUID()
        guard wasKnown, connectionMode == .hardware else { return }
        invalidateCardOutputTable(tb)
        if usesTwoUnitReplay { twoUnitReplayNeeded = true } else { inputRoutingReplayNeeded = true }
    }

    /// The one-time analog-first routing reset (`ChannelOrderRoutingReset`),
    /// for the units connected now. When it runs, the stores it removed are
    /// read again empty: the card's input routes go back to straight through,
    /// and the next input sync and output restore write the defaults.
    @MainActor
    func runChannelOrderResetIfNeeded() {
        guard connectionMode == .hardware, cardSimulation == nil, simulatedUnitB == nil else { return }
        let units = [thunderboltUnitOrder(unit: .a), unitBOnCard ? thunderboltUnitOrder(unit: .b) : nil]
        guard let removed = ChannelOrderRoutingReset.runIfNeeded(
            transport: transportType, serving: servingDextBuild, units: units) else { return }
        print("[Maestro] Routing reset to the defaults once for the analog-first channel order (driver 150): "
            + "\(removed.count) saved routing entries removed")
        symphonyCardInputEdits = [:]
        symphonyCardInputVersion &+= 1
        channelOrderResetNotice = ChannelOrderRoutingReset.noticeText
        thunderboltInputRoutingWritten = false
        invalidateThunderboltInputMeterMap()
        outputRoutingSaved()
        symphonyCardInputNamingRevision += 1
        viewReloadToken = UUID()
        if let tb = device as? ThunderboltDeviceConnection { invalidateCardOutputTable(tb) }
        if usesTwoUnitReplay { twoUnitReplayNeeded = true } else { inputRoutingReplayNeeded = true }
    }

    /// The routing pages' notice was dismissed: it is not shown again.
    func dismissChannelOrderResetNotice() {
        channelOrderResetNotice = nil
        UserDefaults.standard.removeObject(forKey: ChannelOrderRoutingReset.noticePendingKey)
    }
}
