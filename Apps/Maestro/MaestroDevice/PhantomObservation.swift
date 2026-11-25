import Foundation
import MaestroCore

/// OFF receipts are already resolved to a physical port and MicPre channel by
/// the driver. Observed ON is display state and does not authorize replay.
/// Original daemon path: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp
/// SetProperty:670-721 updates m_afPhantomPower for HAL and Maestro alike;
/// 2099-2107 saves it, and ApplySettingsToHardware:2259-2298 restores it.
public enum PhantomObservation {
    /// Resolve a driver receipt for display. The caller supplies the last
    /// generation seen for this channel in the same driver epoch.
    public static func observedState(generation: UInt64, isOn: Bool,
                                     lastSeenGeneration: UInt64,
                                     servingBuild: ServingDextBuild?) -> Bool? {
        guard generation > lastSeenGeneration else { return nil }
        if isOn {
            guard case .build(let build) = servingBuild, build >= 144 else { return nil }
        }
        return isOn
    }

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

/// dext 153: what the 48V buttons show beyond Maestro's own saved phantom.
/// A DAW's phantom ON is shown (lit) but is never saved, never becomes
/// `InputChannelState.phantom` or provenance, and so never reaches
/// `restoresPhantom` or a settings replay.
public enum PhantomDisplay {
    public static let minimumDriverBuild = 153

    public static func driverSupports(_ build: ServingDextBuild?) -> Bool {
        if case .build(let value) = build { return value >= minimumDriverBuild }
        return false
    }

    /// A0..7 then B0..7: true where the driver's record says a DAW switched
    /// phantom on and the unit took it, with nothing from Maestro since.
    public static func observedOn(_ records: [MicPreEditRecord], servingBuild: ServingDextBuild?) -> [Bool] {
        guard records.count == 16, driverSupports(servingBuild) else { return Array(repeating: false, count: 16) }
        return records.map { $0.phantom == true }
    }

    /// Maestro's own accepted ON, made while the unit's identity was not yet
    /// known, gets its provenance once the identity is known in the same
    /// connection: only for a channel still in Mic whose driver state says the
    /// unit has phantom on and whose record shows no DAW phantom edit since
    /// Maestro's ON. Nothing is sent here; a later replay restores it
    /// as it does any ON Maestro made with the identity known.
    /// - Returns: true when a strip changed.
    @discardableResult
    public static func finishProvenance(channels: Set<Int>, records: [MicPreEditRecord], unit: DeviceUnit,
                                        identity: UInt64, servingBuild: ServingDextBuild?,
                                        states: inout [InputChannelState]) -> Bool {
        guard records.count == 16, driverSupports(servingBuild), identity != 0, identity != UInt64.max else {
            return false
        }
        let offset = unit == .b ? 8 : 0
        var changed = false
        for channel in channels.sorted() where channel >= 0 && channel < 8 && states.indices.contains(channel) {
            // Review m4: the unit has it on, and no DAW switched phantom on
            // this channel since Maestro's own 0xC6 (which clears the record's
            // phantom bits): the ON on the unit is Maestro's.
            guard records[offset + channel].driverPhantom == true, records[offset + channel].phantom == nil,
                  states[channel].inputType == AnalogInputLevel.mic.rawValue else { continue }
            let provenance = PhantomProvenance(unitID: identity, boardSlot: 1, channel: channel)
            guard !states[channel].phantom || states[channel].phantomProvenance != provenance else { continue }
            states[channel].phantom = true
            states[channel].phantomProvenance = provenance
            changed = true
        }
        return changed
    }
}

/// Diagnostics: each 8MicPre channel's 48V as the driver, Maestro and the
/// DAW see it, and whether the unit's identity is known (Maestro's own ON is
/// restored only with it).
public enum MicPrePhantomReport {
    /// - Parameters:
    ///   - records: the unit's eight driver records, nil when not read.
    ///   - saved: the unit's saved strips, nil when there are none.
    ///   - pending: channels whose Maestro ON waits for the identity.
    public static func lines(unit: String, identityKnown: Bool, servingBuild: ServingDextBuild?,
                             records: ArraySlice<MicPreEditRecord>?, saved: [InputChannelState]?,
                             observed: ArraySlice<Bool>, pending: Set<Int>, identity: UInt64?) -> [String] {
        var lines = ["8MicPre 48V, unit \(unit) (unit identity \(identityKnown ? "known" : "not known")):"]
        let driverHasState = PhantomDisplay.driverSupports(servingBuild)
        let records = records.map(Array.init)
        let observed = Array(observed)
        for channel in 0..<8 {
            let driver: String
            if !driverHasState {
                driver = "not reported (driver before build \(PhantomDisplay.minimumDriverBuild))"
            } else if let records, channel < records.count, let on = records[channel].driverPhantom {
                driver = on ? "on" : "off"
            } else {
                driver = "unknown"
            }
            let maestro: String
            if let saved, channel < saved.count {
                let state = saved[channel]
                if !state.phantom {
                    maestro = "off"
                } else if state.restoresPhantom(identity: identity, boardSlot: 1, channel: channel) {
                    maestro = "on"
                } else {
                    maestro = pending.contains(channel) ? "on (identity pending)" : "on (not restored)"
                }
            } else {
                maestro = "no saved strip"
            }
            let daw = channel < observed.count && observed[channel] ? ", shown on (set from a DAW)" : ""
            lines.append("  Ch \(channel + 1): driver \(driver), Maestro \(maestro)\(daw)")
        }
        return lines
    }
}
