import Foundation
import MaestroCore

// MARK: - Per-slot digital settings

/// Each slot's optical format, S/PDIF Coax Replaces and Mirrors: what a
/// preset carries and what the Mac remembers for the unit.
///
/// Apogee's daemon kept these per board in its settings (on disk) and applied
/// them to the hardware when the unit connected in the USB and Symphony modes
/// (`og_source/maestrolink/Software/SymphonyIO_IOBoard.cpp:327-340, 493-566`,
/// `OpticalIn_SymphonyIO_Stream.cpp:387-437`; `SymphonyIO.cpp:1396-1412` says
/// the computer, not the unit, holds them in those modes). The firmware starts
/// at ADAT/SMUX, Replaces Off, Mirrors Analog 1-2 (`SymphonyIOStateData.cpp:
/// 127-151`), so without a replay every power cycle or driver restart lost them.
public struct SlotDigitalSettings: Codable, Equatable, Sendable {
    /// Per slot: 0 = ADAT/SMUX, 1 = S/PDIF.
    public var opticalFormat: [UInt32?] = [nil, nil]
    /// Per slot: Replaces wire value, 0 Off, 1-8.
    public var spdifReplace: [UInt32?] = [nil, nil]
    /// Per slot: Mirrors wire value, 1-8.
    public var spdifMirror: [UInt32?] = [nil, nil]

    public init() {}

    /// The settings saved under `key`, or none.
    public static func load(key: String, defaults: UserDefaults = .standard) -> SlotDigitalSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? PropertyListDecoder().decode(SlotDigitalSettings.self, from: data)
        else { return SlotDigitalSettings() }
        return settings
    }

    /// Record one value under `key` (a unit's own key, taken before the write
    /// that confirmed it).
    public static func remember(_ selector: AudioPropertySelector, slot: Int, value: UInt32,
                                key: String, defaults: UserDefaults = .standard) {
        var settings = load(key: key, defaults: defaults)
        settings.record(selector, slot: slot, value: value)
        if let data = try? PropertyListEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }

    /// Record a value the app wrote (or read back) for one slot.
    public mutating func record(_ selector: AudioPropertySelector, slot: Int, value: UInt32) {
        guard slot >= 0, slot < 2 else { return }
        switch selector {
        case .opticalInFormat, .opticalOutFormat: if value <= 1 { opticalFormat[slot] = value }
        case .spdifReplaceID: if value <= 8 { spdifReplace[slot] = value }
        case .spdifMirrorID: if (1...8).contains(value) { spdifMirror[slot] = value }
        default: break
        }
    }

    /// The writes that put these settings on the cards fitted now.
    ///
    /// Only to a card that has the feature: the optical format to a card with
    /// optical ports, through the direction it has; Replaces and Mirrors to a
    /// card with coax jacks. Mirrors is never written as Off (0): the original's
    /// menu has no Off (`SymphonyIO_IOBoard.cpp:1195-1220`). Unknown values are
    /// not written.
    public func writes(layout: CardLayout) -> [PresetDigitalWrites.Write] {
        var writes: [PresetDigitalWrites.Write] = []
        for slot in 0..<2 {
            let card = layout.card(atSlot: slot)
            let element = UInt32(slot)
            if card.hasOpticalPorts, let format = opticalFormat[slot], format <= 1 {
                let selector: AudioPropertySelector = card.opticalFormatUsesInput ? .opticalInFormat : .opticalOutFormat
                writes.append(.init(address: PropertyAddress(selector: selector, element: element), value: format))
            }
            if card.hasSPDIFCoax {
                if let replace = spdifReplace[slot], replace <= 8 {
                    writes.append(.init(address: PropertyAddress(selector: .spdifReplaceID, scope: .input,
                                                                 element: element), value: replace))
                }
                if let mirror = spdifMirror[slot], (1...8).contains(mirror) {
                    writes.append(.init(address: PropertyAddress(selector: .spdifMirrorID, scope: .output,
                                                                 element: element), value: mirror))
                }
            }
        }
        return writes
    }
}

/// The writes a preset makes for the per-slot digital settings.
public enum PresetDigitalWrites {
    public struct Write: Equatable, Sendable {
        public let address: PropertyAddress
        public let value: UInt32
    }

    public static func settings(of preset: MaestroPreset) -> SlotDigitalSettings {
        var settings = SlotDigitalSettings()
        settings.opticalFormat = [preset.opticalInFormat, preset.slot2OpticalFormat]
        settings.spdifReplace = [preset.spdifReplaceID, preset.slot2SPDIFReplaceID]
        settings.spdifMirror = [preset.spdifMirrorID, preset.slot2SPDIFMirrorID]
        return settings
    }

    public static func writes(for preset: MaestroPreset, layout: CardLayout) -> [Write] {
        settings(of: preset).writes(layout: layout)
    }
}
