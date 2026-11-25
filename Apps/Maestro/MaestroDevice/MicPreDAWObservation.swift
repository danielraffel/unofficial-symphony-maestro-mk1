import Foundation
import MaestroCore

/// One host-originated MicPre edit record from the ThunderBridge driver
/// (selector 5's second optional tail, `kSymphonyMicPreEditWords`). The driver
/// writes it after the unit took a change a DAW made through Core Audio, already
/// resolved to a physical port and MicPre channel, so no host-channel or route
/// mapping happens here. The stamp moves on each such edit and carries only
/// that edit's fields; a Maestro write of a field clears that field's valid bit.
/// Bits: Drivers/Thunderbolt/Source/SymphonyThunderbridgeShared.h (kMicPreEdit*).
public struct MicPreEditRecord: Sendable, Equatable {
    public let stamp: UInt64
    public let fields: UInt32

    public init(stamp: UInt64, fields: UInt32) {
        self.stamp = stamp
        self.fields = fields
    }

    static let typeMask: UInt32 = 0x7
    static let typeValid: UInt32 = 1 << 3
    static let phaseBit: UInt32 = 1 << 4
    static let phaseValid: UInt32 = 1 << 5
    static let highPassBit: UInt32 = 1 << 6
    static let highPassValid: UInt32 = 1 << 7
    static let gainShift: UInt32 = 8
    static let gainMask: UInt32 = 0x7F << 8
    static let gainValid: UInt32 = 1 << 15
    static let gainInstrument: UInt32 = 1 << 16
    static let insertOff: UInt32 = 1 << 17
    /// dext 153: a HAL phantom switch the unit took (display only).
    static let phantomBit: UInt32 = 1 << 18
    static let phantomValid: UInt32 = 1 << 19
    /// dext 153: the driver's phantom state, added when the record is read.
    static let statePhantom: UInt32 = 1 << 20
    static let statePhantomKnown: UInt32 = 1 << 21

    /// The input type in the 0x20 wire enum (the encoding `InputChannelState`
    /// stores), or nil when the record carries no type.
    public var inputType: AnalogInputLevel? {
        fields & Self.typeValid != 0 ? AnalogInputLevel(rawValue: fields & Self.typeMask) : nil
    }
    public var phase: Bool? { fields & Self.phaseValid != 0 ? fields & Self.phaseBit != 0 : nil }
    public var highPass: Bool? { fields & Self.highPassValid != 0 ? fields & Self.highPassBit != 0 : nil }
    /// Gain in dB and whether it is the Instrument stage's.
    public var gain: (value: Int, instrument: Bool)? {
        guard fields & Self.gainValid != 0 else { return nil }
        return (Int((fields & Self.gainMask) >> Self.gainShift), fields & Self.gainInstrument != 0)
    }
    /// The driver released this channel's insert and switched its return off
    /// (a type change whose last step then failed).
    public var insertReleased: Bool { fields & Self.insertOff != 0 }
    /// dext 153: phantom a DAW switched and the unit took, nil when the record
    /// carries none (or Maestro set phantom since). Display only: never a
    /// strip's `phantom`, never provenance, never replayed.
    public var phantom: Bool? { fields & Self.phantomValid != 0 ? fields & Self.phantomBit != 0 : nil }
    /// dext 153: the driver's phantom state for this channel (the last 0xC6
    /// the unit took from Maestro or a DAW), nil while the driver does not know it.
    public var driverPhantom: Bool? {
        fields & Self.statePhantomKnown != 0 ? fields & Self.statePhantom != 0 : nil
    }
    /// Phantom is deliberately not an edit: `apply` never writes it to a strip.
    var hasEdit: Bool { inputType != nil || phase != nil || highPass != nil || gain != nil || insertReleased }
}

/// DAW edits of the 8MicPre (polarity, high-pass, input type, gain) reflected in
/// Maestro's saved strips. The original daemon saved HAL and Maestro changes
/// alike (og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp
/// SetProperty:370-730, saved at 2099-2107). Like `PhantomObservation`, this
/// never authorises phantom ON: a type change applies Maestro's own level rules,
/// which clear phantom when leaving Mic, and no record carries a phantom ON.
public enum MicPreDAWObservation {
    public static let seenKey = "halMicPreEditStamps"

    /// Apply one unit's eight records (`records[0..<8]`) to its strips. Pure:
    /// `seen` holds the last stamp applied per MicPre channel. A channel with
    /// no saved strip is acknowledged and left alone, as front-panel gains are
    /// (`FrontPanelSync.applyGain`): creating default strips would make the next
    /// settings replay send +4 dBu, gain 0 and phantom OFF to every channel.
    /// - Returns: true when any strip changed.
    @discardableResult
    public static func apply(_ records: ArraySlice<MicPreEditRecord>, seen: inout [UInt64],
                             to states: inout [InputChannelState]) -> Bool {
        if seen.count != 8 { seen = Array(repeating: 0, count: 8) }
        var changed = false
        for (channel, record) in records.prefix(8).enumerated() {
            guard record.stamp != 0, record.stamp != seen[channel] else { continue }
            seen[channel] = record.stamp
            guard record.hasEdit, states.indices.contains(channel) else { continue }
            let before = states[channel]
            if let level = record.inputType, states[channel].inputType != level.rawValue {
                // Same dependent rules as a change made in Maestro: phantom,
                // group, insert and insert return cleared, trim clamped.
                InputChannelLogic.applyLevelChange(&states[channel], to: level)
            }
            if record.insertReleased {
                states[channel].insert = InputChannelLogic.insertNone
                states[channel].insertReturn = false
            }
            if let phase = record.phase { states[channel].phase = phase }
            if let highPass = record.highPass { states[channel].hpf = highPass }
            if let gain = record.gain {
                let value = Double(min(gain.value, gain.instrument ? 65 : 85))
                if gain.instrument {
                    states[channel].instrumentGain = value
                    if states[channel].inputType == AnalogInputLevel.instrument.rawValue { states[channel].gain = value }
                } else {
                    states[channel].micGain = value
                    if states[channel].inputType == AnalogInputLevel.mic.rawValue { states[channel].gain = value }
                }
            }
            if states[channel] != before { changed = true }
        }
        return changed
    }

    /// The store form, for one unit: A reads records 0..<8, B 8..<16. Saves
    /// the strips before acknowledging the stamps, and acknowledges stamps
    /// even when nothing changed, so an old edit cannot later undo a newer
    /// choice made in Maestro.
    ///
    /// A store with no acknowledged stamps yet applies what it finds: the
    /// first DAW edit after an update or on a new unit is a real edit. Records
    /// cannot belong to an earlier unit: the driver clears them when a unit is
    /// set up again, and its stamps start over with each driver instance.
    @discardableResult
    public static func apply(_ records: [MicPreEditRecord], to store: ChannelStateStore) -> Bool {
        guard records.count == 16, store.identity != nil, !store.isSimulating else { return false }
        let offset = store.unit == .b ? 8 : 0
        let unitRecords = records[offset..<offset + 8]
        var seen: [UInt64] = store.load(seenKey) ?? []
        let before = seen
        guard unitRecords.enumerated().contains(where: { index, record in
            record.stamp != 0 && (seen.count != 8 || record.stamp != seen[index])
        }) else { return false }
        var states = store.load(ChannelStateStore.inputKey, as: [InputChannelState].self) ?? []
        let changed = apply(unitRecords, seen: &seen, to: &states)
        if changed { store.save(states, for: ChannelStateStore.inputKey) }
        if seen != before { store.save(seen, for: seenKey) }
        return changed
    }
}
