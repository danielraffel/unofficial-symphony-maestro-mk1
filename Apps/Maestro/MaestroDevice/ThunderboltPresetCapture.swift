import Foundation
import MaestroCore

extension ThunderboltPreset {
    /// Caller owns the unit serial lock; all reads must be fresh hardware reads.
    static func capture(_ seed: ThunderboltPreset, layout: CardLayout, hostChannels: Int,
                        peripheralB: Bool = false,
                        readProperty: (PropertyAddress) throws -> PropertyValue,
                        readRaw: (UInt8, UInt32, Int) throws -> Data) throws -> ThunderboltPreset {
        var preset = seed
        for selector in ThunderboltPreset.monitorOrder + [.headphone1RoutingID, .headphone2RoutingID] {
            let value = try readProperty(PropertyAddress(selector: selector))
            guard let raw = value.asUInt32 ?? value.asBool.map({ $0 ? UInt32(1) : 0 }) else {
                throw ThunderboltPreset.RecallError.unsupported("unreadable monitor setting \(selector).")
            }
            preset.globals[selector.rawValue] = raw
        }
        func monitor(_ selector: AudioPropertySelector) -> UInt32 { preset.globals[selector.rawValue]! }
        preset.metadata.outputLevel = -Double(monitor(.outputLevel))
        preset.metadata.outputMuted = monitor(.outputMute) != 0
        preset.metadata.outputDimmed = monitor(.outputDim) != 0
        preset.metadata.outputSumToMono = monitor(.outputSumToMono) != 0
        preset.metadata.hp1Level = -Double(monitor(.headphone1Level))
        preset.metadata.hp1Muted = monitor(.headphone1Mute) != 0
        preset.metadata.hp1RoutingID = monitor(.headphone1RoutingID)
        preset.metadata.hp2Level = -Double(monitor(.headphone2Level))
        preset.metadata.hp2Muted = monitor(.headphone2Mute) != 0
        preset.metadata.hp2RoutingID = monitor(.headphone2RoutingID)
        if !peripheralB { preset.globals[AudioPropertySelector.clockSource.rawValue] = try readProperty(PropertyAddress(selector: .clockSource)).asUInt32 }
        func read(_ selector: AudioPropertySelector, element: UInt32 = 0) throws -> UInt32 {
            guard let value = try readProperty(PropertyAddress(selector: selector, element: element)).asUInt32 else {
                throw ThunderboltPreset.RecallError.unsupported("unreadable setting \(selector).")
            }
            return value
        }
        preset.metadata.meterBank1Source = try read(.metersShowInput, element: 1)
        preset.metadata.meterBank2Source = try read(.metersShowInput, element: 2)
        preset.metadata.peakHoldMode = try read(.peakHoldMode)
        preset.metadata.overHoldMode = try read(.oversHoldMode)
        for slot in 0..<2 {
            let card = layout.card(atSlot: slot)
            if card.hasOpticalPorts {
                let value = try read(card.opticalFormatUsesInput ? .opticalInFormat : .opticalOutFormat, element: UInt32(slot))
                if slot == 0 { preset.metadata.opticalInFormat = value } else { preset.metadata.slot2OpticalFormat = value }
            }
            if card.hasSPDIFCoax {
                let replace = try read(.spdifReplaceID, element: UInt32(slot))
                let mirror = try read(.spdifMirrorID, element: UInt32(slot))
                if slot == 0 {
                    preset.metadata.spdifReplaceID = replace
                    preset.metadata.spdifMirrorID = mirror
                } else {
                    preset.metadata.slot2SPDIFReplaceID = replace
                    preset.metadata.slot2SPDIFMirrorID = mirror
                }
            }
        }
        preset.inputRoutes = try (0..<32).map {
            UInt8(try read(.routing, element: UInt32(SymphonyIORoutingAddress.p2pBase) + UInt32($0)))
        }
        let selection = try readRaw(0x2A, 0, 1)
        guard selection.count == 1 else { throw DeviceConnectionError.transportError("Short front panel selection read") }
        preset.frontPanelSelection = selection[0]
        if layout.slot2 == .micPre8 {
            let identity = try readRaw(0xC0, 0, 8)
            guard identity.count == 8, identity.contains(where: { $0 != 0 }), identity.contains(where: { $0 != 0xFF }) else {
                throw RecallError.unsupported("the unit identity could not be read.")
            }
            preset.unitID = identity
        }
        _ = try preset.writes(layout: layout, currentUnitID: preset.unitID, hostChannels: hostChannels, peripheralB: peripheralB)
        return preset
    }

}
