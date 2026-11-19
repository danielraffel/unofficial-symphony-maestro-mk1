import Foundation
import MaestroCore

/// OFF receipts are already resolved to a physical port and MicPre channel by
/// the driver. ON is deliberately absent: observation never authorizes replay.
/// Original daemon path: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp
/// SetProperty:670-721 updates m_afPhantomPower for HAL and Maestro alike;
/// 2099-2107 saves it, and ApplySettingsToHardware:2259-2298 restores it.
public enum PhantomObservation {
    public static func apply(_ receipts: [UInt64], to store: ChannelStateStore) -> Bool {
        guard receipts.count == 16, store.identity != nil, !store.isSimulating else { return false }
        let key = "halPhantomOffReceipts"
        var seen: [UInt64] = store.load(key) ?? Array(repeating: 0, count: 8)
        if seen.count != 8 { seen = Array(repeating: 0, count: 8) }
        let offset = store.unit == .b ? 8 : 0
        var changed = false
        var receiptsAcknowledged = false
        var states = store.load(ChannelStateStore.inputKey, as: [InputChannelState].self)
        if states != nil {
            for channel in 0..<min(8, states!.count) {
                let receipt = receipts[offset + channel]
                guard receipt != 0, receipt != seen[channel] else { continue }
                states![channel].phantom = false
                states![channel].phantomProvenance = nil
                seen[channel] = receipt
                changed = true
                receiptsAcknowledged = true
            }
        }
        // A receipt can arrive before this unit has any saved channel rows.
        // Acknowledge it anyway so an old OFF cannot erase a later explicit ON.
        for channel in 0..<8 {
            let receipt = receipts[offset + channel]
            guard receipt != 0, receipt != seen[channel] else { continue }
            seen[channel] = receipt
            receiptsAcknowledged = true
        }
        if receiptsAcknowledged {
            // Save OFF first: interruption must never acknowledge a receipt
            // while leaving its old ON authorized. Persist receipts so reopening
            // the app does not revoke a later explicit Maestro ON.
            if changed, let states { store.save(states, for: ChannelStateStore.inputKey) }
            store.save(seen, for: key)
        }
        return changed
    }
}
