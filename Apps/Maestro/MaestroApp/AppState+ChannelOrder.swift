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

    /// The serving build was read again on the same connection
    /// (`refreshServingDextBuild`, a rediscovery). A build once known is not
    /// replaced by a failed read (nil, or `.olderThanBuildReporting`, which a
    /// failed build read also gives): the order and every build-gated
    /// feature would flap with it. A different build is a different driver:
    /// what the old one reported is dropped and read again. When the order
    /// follows (from not known to known, a build without selector 17), it is
    /// handled as any order change.
    @MainActor
    func noteServingDextBuild(_ build: ServingDextBuild?, from tb: ThunderboltDeviceConnection) {
        let old = servingDextBuild
        guard build != old, device === tb else { return }
        if case .build? = old, !Self.isKnownBuild(build) { return }
        let before = (thunderboltUnitOrder(unit: .a), thunderboltUnitOrder(unit: .b))
        if case .build(let was)? = old, case .build(let now)? = build, was != now {
            thunderboltAppliedChannelOrder = nil
            Task { @MainActor [weak self] in await self?.refreshThunderboltChannelOrder(tb) }
        }
        servingDextBuild = build
        let after = (thunderboltUnitOrder(unit: .a), thunderboltUnitOrder(unit: .b))
        if before != after {
            print("[Maestro] ThunderBridge channel order after the driver build was read: A \(Self.describe(before.0)) → "
                + "\(Self.describe(after.0)), B \(Self.describe(before.1)) → \(Self.describe(after.1))")
            thunderboltChannelOrderDidChange(tb, wasKnown: before.0 != nil)
        }
        runChannelOrderResetIfNeeded()
    }

    private static func isKnownBuild(_ build: ServingDextBuild?) -> Bool {
        if case .build? = build { return true }
        return false
    }

    /// The order a unit's tables follow changed: what was drawn and numbered
    /// from the old one is worked out again, and what was written in it is
    /// owed again. From not known to known the skipped writes are already
    /// owed (they wait on `thunderboltChannelOrderUnknownReason`), except a
    /// headphone crosspoint, which is written again from what is saved.
    @MainActor
    private func thunderboltChannelOrderDidChange(_ tb: ThunderboltDeviceConnection, wasKnown: Bool) {
        invalidateThunderboltInputMeterMap()
        invalidateThunderboltOutputMeterMap()
        symphonyCardInputNamingRevision += 1
        viewReloadToken = UUID()
        guard connectionMode == .hardware else { return }
        // A headphone follows the XLink channel of the output it plays, which
        // the order decides: one skipped while it was not known, or written
        // in the old order, is written again in this one.
        if wasKnown || thunderboltHeadphoneCrosspointOwed {
            thunderboltHeadphoneCrosspointOwed = false
            Task { @MainActor [weak self] in await self?.reapplySavedThunderboltHeadphones(tb) }
        }
        guard wasKnown else { return }
        // As after a link recovery: the strips are numbered from the new
        // table until a replay lands, and the mixers are owed a whole write.
        thunderboltInputRoutingWritten = false
        tb.cardMixers.noteOwed()
        invalidateCardOutputTable(tb)
        if usesTwoUnitReplay { twoUnitReplayNeeded = true } else { inputRoutingReplayNeeded = true }
    }

    /// Write both headphones' saved sources again on ThunderBridge (the
    /// crosspoint half; `syncDeviceSettingsToHardware` writes them at
    /// connect). The two-unit replay writes its own.
    @MainActor
    func reapplySavedThunderboltHeadphones(_ tb: ThunderboltDeviceConnection) async {
        guard device === tb, connectionMode == .hardware, !usesTwoUnitReplay, !hardwareWritesSuspended else { return }
        let saved: [(SymphonyIOHeadphoneRouting.Headphone, AudioPropertySelector)] =
            [(.headphone1, .headphone1RoutingID), (.headphone2, .headphone2RoutingID)]
        for (headphone, selector) in saved {
            guard device === tb,
                  let id = tb.settingsStore.value(for: PropertyAddress(selector: selector))?.asUInt32 else { continue }
            await HeadphoneCrosspoint.apply(headphone, sourceID: id, device: tb,
                                            cachedRoutes: cachedOutputRouteMap(),
                                            transport: .thunderbolt, state: self)
        }
    }

    /// The one-time analog-first routing reset (`ChannelOrderRoutingReset`),
    /// for the units connected now. When it runs, the stores it removed are
    /// read again empty, per direction that moved: inputs, the card's input
    /// routes go back to straight through and the next input sync writes the
    /// defaults; outputs, the output restore writes the default table. A
    /// direction that did not move keeps its routing and is not rewritten.
    @MainActor
    func runChannelOrderResetIfNeeded() {
        guard connectionMode == .hardware, cardSimulation == nil, simulatedUnitB == nil else { return }
        let units = [thunderboltUnitOrder(unit: .a), unitBOnCard ? thunderboltUnitOrder(unit: .b) : nil]
        guard let outcome = ChannelOrderRoutingReset.runIfNeeded(
            transport: transportType, serving: servingDextBuild, units: units) else { return }
        print("[Maestro] Routing reset to the defaults once for the analog-first channel order (driver 150): "
            + "inputs \(outcome.inputsMoved ? "moved" : "kept"), outputs \(outcome.outputsMoved ? "moved" : "kept"), "
            + "\(outcome.removed.count) saved routing entries removed")
        channelOrderResetNotice = outcome.notice
        channelOrderResetAlert = outcome.notice
        symphonyCardInputNamingRevision += 1
        viewReloadToken = UUID()
        if outcome.inputsMoved {
            symphonyCardInputEdits = [:]
            symphonyCardInputVersion &+= 1
            thunderboltInputRoutingWritten = false
            invalidateThunderboltInputMeterMap()
            if usesTwoUnitReplay { twoUnitReplayNeeded = true } else { inputRoutingReplayNeeded = true }
        }
        if outcome.outputsMoved {
            outputRoutingSaved()
            if let tb = device as? ThunderboltDeviceConnection {
                invalidateCardOutputTable(tb)
                // The headphones follow the outputs' default table now.
                Task { @MainActor [weak self] in await self?.reapplySavedThunderboltHeadphones(tb) }
            }
            if usesTwoUnitReplay { twoUnitReplayNeeded = true }
        }
    }

    /// The routing pages' caption was dismissed: it is not shown again.
    func dismissChannelOrderResetNotice() {
        channelOrderResetNotice = nil
        UserDefaults.standard.removeObject(forKey: ChannelOrderRoutingReset.noticePendingKey)
    }

    /// The one-time alert was closed; the caption stays until dismissed.
    func acknowledgeChannelOrderResetAlert() {
        channelOrderResetAlert = nil
        UserDefaults.standard.removeObject(forKey: ChannelOrderRoutingReset.alertPendingKey)
    }
}
