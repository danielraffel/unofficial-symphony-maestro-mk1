import MaestroCore

// MARK: - Per-slot digital settings

/// The optical format, S/PDIF Coax Replaces and Mirrors writes a preset makes,
/// per slot, for the cards fitted now.
///
/// Only to a card that has the feature: the optical format to a card with
/// optical ports, through the direction it has; Replaces and Mirrors to a card
/// with coax jacks. Mirrors is never written as Off (0): the original's menu
/// has no Off (`SymphonyIO_IOBoard.cpp:1195-1220`). A slot-2 value the preset
/// did not save is not written.
public enum PresetDigitalWrites {
    public struct Write: Equatable, Sendable {
        public let address: PropertyAddress
        public let value: UInt32
    }

    public static func writes(for preset: MaestroPreset, layout: CardLayout) -> [Write] {
        var writes: [Write] = []
        for slot in 0..<2 {
            let card = layout.card(atSlot: slot)
            let element = UInt32(slot)
            let format = slot == 0 ? preset.opticalInFormat : preset.slot2OpticalFormat
            let replace = slot == 0 ? preset.spdifReplaceID : preset.slot2SPDIFReplaceID
            let mirror = slot == 0 ? preset.spdifMirrorID : preset.slot2SPDIFMirrorID
            if card.hasOpticalPorts, let format, format <= 1 {
                let selector: AudioPropertySelector = card.opticalFormatUsesInput ? .opticalInFormat : .opticalOutFormat
                writes.append(Write(address: PropertyAddress(selector: selector, element: element), value: format))
            }
            if card.hasSPDIFCoax {
                if let replace, replace <= 8 {
                    writes.append(Write(address: PropertyAddress(selector: .spdifReplaceID, scope: .input,
                                                                 element: element), value: replace))
                }
                if let mirror, (1...8).contains(mirror) {
                    writes.append(Write(address: PropertyAddress(selector: .spdifMirrorID, scope: .output,
                                                                 element: element), value: mirror))
                }
            }
        }
        return writes
    }
}
