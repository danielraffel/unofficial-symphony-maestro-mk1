import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// Consume only driver-resolved OFF receipts. No write, bus read, or ON
    /// authority is created here. Unknown identity waits for normal discovery.
    func applyPhantomObservations(_ link: LinkState?) {
        guard connectedUnit == nil, converterSystem == nil, cardSimulation == nil,
              let receipts = link?.phantomOffReceipts, receipts.count == 16 else { return }
        var changed = false
        if cardLayout.slot2 == .micPre8,
           receipts[0..<8].contains(where: { $0 != 0 }) {
            changed = PhantomObservation.apply(receipts, to: channelStateStore)
        }
        if unitBLayout?.slot2 == .micPre8,
           receipts[8..<16].contains(where: { $0 != 0 }) {
            let changedB = PhantomObservation.apply(receipts, to: unitBChannelStateStore)
            changed = changed || changedB
        }
        if changed { phantomObservationRevision += 1 }
        applyMicPreDAWObservations(link)
    }

    /// DAW edits of either unit's 8MicPre, resolved by the driver to a
    /// physical unit and channel. Same admission as the OFF receipts above.
    func applyMicPreDAWObservations(_ link: LinkState?) {
        updatePhantomObservedOn(link)
        guard connectedUnit == nil, converterSystem == nil, cardSimulation == nil,
              let records = link?.micPreEdits, records.count == 16 else { return }
        var changed = false
        if cardLayout.slot2 == .micPre8, records[0..<8].contains(where: { $0.stamp != 0 }) {
            changed = MicPreDAWObservation.apply(records, to: channelStateStore)
        }
        if unitBLayout?.slot2 == .micPre8,
           records[8..<16].contains(where: { $0.stamp != 0 }) {
            let changedB = MicPreDAWObservation.apply(records, to: unitBChannelStateStore)
            changed = changed || changedB
        }
        if changed { micPreObservationRevision &+= 1 }
    }

    /// dext 153: which 48V buttons a DAW lit, from the current records (no
    /// stamps: the driver clears the bits when Maestro sets phantom itself).
    func updatePhantomObservedOn(_ link: LinkState?) {
        var observed = Array(repeating: false, count: 16)
        if connectedUnit == nil, converterSystem == nil, cardSimulation == nil,
           let records = link?.micPreEdits, records.count == 16 {
            let all = PhantomDisplay.observedOn(records, servingBuild: servingDextBuild)
            if cardLayout.slot2 == .micPre8 { for i in 0..<8 { observed[i] = all[i] } }
            if unitBLayout?.slot2 == .micPre8 { for i in 8..<16 { observed[i] = all[i] } }
            dropPendingPhantomProvenance(after: records)
        }
        if observed != phantomObservedOn { phantomObservedOn = observed }
    }

    /// Review m4: a DAW switched phantom on a channel after Maestro's own ON
    /// (Maestro's 0xC6 clears the record's phantom bits, so any phantom bit
    /// now is later): that ON is no longer Maestro's to finish.
    func dropPendingPhantomProvenance(after records: [MicPreEditRecord]) {
        guard records.count == 16 else { return }
        for unit in [DeviceUnit.a, .b] {
            guard let channels = pendingPhantomProvenance[unit]?.channels else { continue }
            let offset = unit == .b ? 8 : 0
            for channel in channels where channel < 8 && records[offset + channel].phantom != nil {
                pendingPhantomProvenance[unit]?.channels.remove(channel)
            }
        }
    }

    /// The driver's records read now (nil with nothing pending or no driver).
    func freshPhantomRecords(for unit: DeviceUnit) async -> [MicPreEditRecord]? {
        guard pendingPhantomProvenance[unit]?.channels.isEmpty == false,
              let tb = device as? ThunderboltDeviceConnection else { return nil }
        return await Task.detached(priority: .utility) { tb.linkState()?.micPreEdits }.value
    }

    func phantomObserved(unit: DeviceUnit, channel: Int) -> Bool {
        guard channel >= 0, channel < 8 else { return false }
        return phantomObservedOn[(unit == .b ? 8 : 0) + channel]
    }

    /// Maestro just set this channel's phantom itself: the DAW's ON is old news
    /// (the driver clears it too; this saves waiting for the next read).
    func clearPhantomObserved(unit: DeviceUnit, channel: Int) {
        guard channel >= 0, channel < 8 else { return }
        let index = (unit == .b ? 8 : 0) + channel
        if phantomObservedOn[index] { phantomObservedOn[index] = false }
    }

    func identityGeneration(_ unit: DeviceUnit) -> UUID { unit == .b ? unitBGeneration : unitAGeneration }

    /// Maestro's ON was accepted while the unit had no known identity.
    func notePendingPhantomProvenance(unit: DeviceUnit, channel: Int) {
        let generation = identityGeneration(unit)
        var entry = pendingPhantomProvenance[unit]
        if entry?.generation != generation { entry = (generation, []) }
        entry!.channels.insert(channel)
        pendingPhantomProvenance[unit] = entry
    }

    func dropPendingPhantomProvenance(unit: DeviceUnit, channel: Int) {
        pendingPhantomProvenance[unit]?.channels.remove(channel)
    }

    /// Whether the strip keeps showing Maestro's own ON with no provenance yet.
    func pendingPhantomOn(unit: DeviceUnit, channel: Int) -> Bool {
        guard let entry = pendingPhantomProvenance[unit], entry.generation == identityGeneration(unit) else { return false }
        return entry.channels.contains(channel)
    }

    /// The identity is known now, in the connection the ON was made in: give
    /// that ON its provenance where the driver says the unit still has it on
    /// and the strip is still Mic. Saves state only; never writes the unit.
    /// `records`: read just before (`freshPhantomRecords`); nil grants nothing.
    func finishPendingPhantomProvenance(unit: DeviceUnit, identity: UInt64, records: [MicPreEditRecord]?) {
        guard let records, records.count == 16 else { pendingPhantomProvenance[unit] = nil; return }
        dropPendingPhantomProvenance(after: records)
        guard let entry = pendingPhantomProvenance.removeValue(forKey: unit),
              entry.generation == identityGeneration(unit), !entry.channels.isEmpty else { return }
        let store = unit == .b ? unitBChannelStateStore : channelStateStore
        guard store.identity == identity,
              var states = store.load(ChannelStateStore.inputKey, as: [InputChannelState].self) else { return }
        if PhantomDisplay.finishProvenance(channels: entry.channels, records: records, unit: unit,
                                           identity: identity, servingBuild: servingDextBuild, states: &states) {
            store.save(states, for: ChannelStateStore.inputKey)
        }
    }

    /// Diagnostics block: 48V per 8MicPre channel, driver and app view.
    var micPrePhantomDiagnostics: String? {
        guard connectionMode == .hardware, transportType == .thunderbolt, connectedUnit == nil,
              converterSystem == nil else { return nil }
        let records = (device as? ThunderboltDeviceConnection)?.lastLinkState?.micPreEdits
        var lines: [String] = []
        for unit in [DeviceUnit.a, .b] {
            let layout = unit == .a ? cardLayout : unitBLayout
            guard layout?.slot2 == .micPre8 else { continue }
            let store = unit == .a ? channelStateStore : unitBChannelStateStore
            let offset = unit == .b ? 8 : 0
            let pending = pendingPhantomProvenance[unit].flatMap {
                $0.generation == identityGeneration(unit) ? $0.channels : nil } ?? []
            lines += MicPrePhantomReport.lines(
                unit: unit == .a ? "A" : "B",
                identityKnown: (unit == .a ? unitAIdentity : unitBIdentity) != nil,
                servingBuild: servingDextBuild,
                records: records.flatMap { $0.count == 16 ? $0[offset..<offset + 8] : nil },
                saved: store.load(ChannelStateStore.inputKey, as: [InputChannelState].self),
                observed: phantomObservedOn[offset..<offset + 8], pending: pending,
                identity: store.identity)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
