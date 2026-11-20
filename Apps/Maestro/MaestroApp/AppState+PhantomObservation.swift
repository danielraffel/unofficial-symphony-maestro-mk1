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
    }
}
