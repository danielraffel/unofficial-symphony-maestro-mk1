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
        guard connectedUnit == nil, converterSystem == nil, cardSimulation == nil,
              let records = link?.micPreEdits, records.count == 16 else { return }
        var changed = false
        if cardLayout.slot2 == .micPre8, records[0..<8].contains(where: { $0.stamp != 0 }) {
            changed = MicPreDAWObservation.apply(records, to: channelStateStore,
                                                 stripCount: cardLayout.analogInputStripCount)
        }
        if let layoutB = unitBLayout, layoutB.slot2 == .micPre8,
           records[8..<16].contains(where: { $0.stamp != 0 }) {
            let changedB = MicPreDAWObservation.apply(records, to: unitBChannelStateStore,
                                                      stripCount: layoutB.analogInputStripCount)
            changed = changed || changedB
        }
        if changed { micPreObservationRevision &+= 1 }
    }
}
