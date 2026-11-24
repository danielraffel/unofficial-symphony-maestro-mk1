import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// Both routing grids reset the whole card layer, not the selected unit.
    /// Single-unit reset/start-up paths remain unchanged.
    @MainActor
    func resetTwoUnitRouting(input: Bool) async throws {
        guard unitBOnCard, unitBInputRoutingAllowed, converterSystem == nil, connectedUnit == nil,
              RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) == nil,
              unitBBoardSource(slot: 0) == .detected, unitBBoardSource(slot: 1) == .detected,
              let a = device as? ThunderboltDeviceConnection,
              let b = unitBDevice as? ThunderboltUnitBConnection, let bLayout = unitBLayout else {
            throw DeviceConnectionError.notConnected
        }
        beginRecall()
        var recallFinished = false
        defer { if !recallFinished { finishRecall() } }
        let aLayout = cardLayout
        let inputStore = symphonyCardInputStore
        // Older serving drivers still reset the peripheral input tables.
        // Both units' tables in the order the driver programmed them; none
        // is written while either is not known.
        guard let aOrder = thunderboltUnitOrder(unit: .a), let bOrder = thunderboltUnitOrder(unit: .b) else {
            throw DeviceConnectionError.notConnected
        }
        let cardWrites = input && symphonyCardInputs.channelCount == 0 ? []
            : ThunderboltPreset.cardReset(input: input, layouts: [aLayout, bLayout], orders: [aOrder, bOrder])
        let aInputCache = peripheralRoutingCache(direction: "input")
        let aOutputCache = peripheralRoutingCache(direction: "output")
        let bInputCache = unitBInputRoutingCache, bOutputCache = unitBOutputRoutingCache
        let planned: ([ThunderboltPreset.Write], [ThunderboltPreset.Write])
        do {
            planned = try await resetWrites()
        } catch {
            // Part of the reset may be on the card while the grids show what
            // is saved: put the saved routing and mixers back.
            await recoverFromFailedRecall(a)
            throw error
        }
        @Sendable func resetWrites() async throws -> ([ThunderboltPreset.Write], [ThunderboltPreset.Write]) {
          try await Task.detached {
            try a.withPresetLock {
                try b.withPresetLock {
                    let aWrites = try a.routingResetWrites(layout: aLayout, input: input, order: aOrder)
                    let bWrites = try b.routingResetWrites(layout: bLayout, input: input, order: bOrder)
                    do {
                        try a.applyPresetWrites(cardWrites + aWrites, layout: aLayout)
                    } catch {
                        try? b.applyPresetWrites([], layout: bLayout) { try a.writePresetMixer($0, value: $1) }
                        throw error
                    }
                    try b.applyPresetWrites(bWrites, layout: bLayout) { try a.writePresetMixer($0, value: $1) }
                    return (aWrites, bWrites)
                }
            }
          }.value
        }
        guard device === a, unitBDevice === b else { throw DeviceConnectionError.notConnected }
        if input {
            func grid(_ writes: [ThunderboltPreset.Write], layout: CardLayout) -> [Int: Int] {
                let routes: [SymphonyIODefaultRouting.Route] = writes.compactMap {
                    guard case .property(let address, let value) = $0, let source = value.asUInt32 else { return nil }
                    return (destination: UInt8(address.element), source: UInt8(source))
                }
                return SymphonyIODefaultRouting.inputGrid(routes, columns: layout.inputRoutingColumns)
            }
            aInputCache.save(grid(planned.0, layout: aLayout))
            bInputCache?.save(grid(planned.1, layout: bLayout))
            if !cardWrites.isEmpty {
                symphonyCardInputEdits = Dictionary(uniqueKeysWithValues: (0..<64).map { ($0, $0) })
                inputStore?.save(symphonyCardInputEdits)
            }
        } else {
            // Each output on the row of the DAW pair its XLink channel plays
            // (the unit's playback table in its channel order).
            func grid(_ layout: CardLayout, base: Int, order: ThunderboltUnitChannelOrder) -> [Int: Set<Int>] {
                var rows = Dictionary(uniqueKeysWithValues: (0..<34).map { ($0, Set<Int>()) })
                for (col, destination) in layout.outputRoutingColumns.enumerated() {
                    guard let channel = ThunderboltCardRouting.channel(
                        forDestination: destination.routingByte, slot1: order.slot1, slot2: order.slot2,
                        order: order.order) else { continue }
                    rows[(Int(channel) + base) / 2, default: []].insert(col)
                }
                return rows
            }
            aOutputCache.save(grid(aLayout, base: 0, order: aOrder))
            bOutputCache?.save(grid(bLayout, base: 32, order: bOrder))
            invalidateThunderboltOutputMeterMap()
        }
        symphonyCardInputNamingRevision += 1
        viewReloadToken = UUID()
        finishRecall()
        recallFinished = true
        if input { thunderboltInputRoutingDidChange() }
    }
}
