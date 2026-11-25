import Foundation
import MaestroCore

extension ThunderboltPreset {
    /// Caller owns the unit serial lock; all reads must be fresh hardware reads.
    static func capture(_ seed: ThunderboltPreset, layout: CardLayout, hostChannels: Int,
                        peripheralB: Bool = false,
                        readProperty: (PropertyAddress) throws -> PropertyValue,
                        readRaw: (UInt8, UInt32, Int) throws -> Data,
                        onSkipped: @Sendable (String) -> Void = { _ in }) throws -> ThunderboltPreset {
        var preset = seed
        for selector in ThunderboltPreset.monitorOrder + [.headphone1RoutingID, .headphone2RoutingID] {
            do {
                let value = try readProperty(PropertyAddress(selector: selector))
                guard let raw = value.asUInt32 ?? value.asBool.map({ $0 ? UInt32(1) : 0 }) else {
                    onSkipped("monitor setting \(selector)"); continue
                }
                preset.globals[selector.rawValue] = raw
            } catch { onSkipped("monitor setting \(selector)") }
        }
        func monitor(_ selector: AudioPropertySelector) -> UInt32? { preset.globals[selector.rawValue] }
        if let v = monitor(.outputLevel) { preset.metadata.outputLevel = -Double(v) }
        if let v = monitor(.outputMute) { preset.metadata.outputMuted = v != 0 }
        if let v = monitor(.outputDim) { preset.metadata.outputDimmed = v != 0 }
        if let v = monitor(.outputSumToMono) { preset.metadata.outputSumToMono = v != 0 }
        if let v = monitor(.headphone1Level) { preset.metadata.hp1Level = -Double(v) }
        if let v = monitor(.headphone1Mute) { preset.metadata.hp1Muted = v != 0 }
        if let v = monitor(.headphone1RoutingID) { preset.metadata.hp1RoutingID = v }
        if let v = monitor(.headphone2Level) { preset.metadata.hp2Level = -Double(v) }
        if let v = monitor(.headphone2Mute) { preset.metadata.hp2Muted = v != 0 }
        if let v = monitor(.headphone2RoutingID) { preset.metadata.hp2RoutingID = v }
        if !peripheralB { if let v = try? readProperty(PropertyAddress(selector: .clockSource)).asUInt32 { preset.globals[AudioPropertySelector.clockSource.rawValue] = v } else { onSkipped("clock source") } }
        func read(_ selector: AudioPropertySelector, element: UInt32 = 0) -> UInt32 {
            do {
                guard let value = try readProperty(PropertyAddress(selector: selector, element: element)).asUInt32 else {
                    onSkipped("setting \(selector)"); return 0
                }
                return value
            } catch {
                onSkipped("setting \(selector)"); return 0
            }
        }
        preset.metadata.meterBank1Source = read(.metersShowInput, element: 1)
        preset.metadata.meterBank2Source = read(.metersShowInput, element: 2)
        preset.metadata.peakHoldMode = read(.peakHoldMode)
        preset.metadata.overHoldMode = read(.oversHoldMode)
        for slot in 0..<2 {
            let card = layout.card(atSlot: slot)
            if card.hasOpticalPorts {
                let value = read(card.opticalFormatUsesInput ? .opticalInFormat : .opticalOutFormat, element: UInt32(slot))
                if slot == 0 { preset.metadata.opticalInFormat = value } else { preset.metadata.slot2OpticalFormat = value }
            }
            if card.hasSPDIFCoax {
                let replace = read(.spdifReplaceID, element: UInt32(slot))
                let mirror = read(.spdifMirrorID, element: UInt32(slot))
                if slot == 0 {
                    preset.metadata.spdifReplaceID = replace
                    preset.metadata.spdifMirrorID = mirror
                } else {
                    preset.metadata.slot2SPDIFReplaceID = replace
                    preset.metadata.slot2SPDIFMirrorID = mirror
                }
            }
        }
        var routeMask = Array(repeating: true, count: 32)
        preset.inputRoutes = (0..<32).map { index in
            do {
                guard let value = try readProperty(PropertyAddress(selector: .routing,
                        scope: .input, element: UInt32(SymphonyIORoutingAddress.p2pBase) + UInt32(index))).asUInt32,
                      value <= 255 else { routeMask[index] = false; return SymphonyIORoutingAddress.none }
                return UInt8(value)
            } catch {
                routeMask[index] = false
                onSkipped("input route \(index)")
                return SymphonyIORoutingAddress.none
            }
        }
        preset.inputRouteMask = routeMask.allSatisfy { $0 } ? nil : routeMask
        if let selection = try? readRaw(0x2A, 0, 1), selection.count == 1 {
            preset.frontPanelSelection = selection[0]
        } else { onSkipped("front panel selection") }
        if layout.slot2 == .micPre8 {
            if let identity = try? readRaw(0xC0, 0, 8), identity.count == 8,
               identity.contains(where: { $0 != 0 }), identity.contains(where: { $0 != 0xFF }) {
                // Reading the unit ID never creates per-channel authority.
                // Only an explicit Maestro phantom action can do that; preserve
                // verified channels as-is and report unverified ON bits.
                let unit = SymphonyIdentityReader.decode(identity)
                if preset.metadata.inputChannelStates.enumerated().contains(where: { index, state in
                    state.phantom && !state.restoresPhantom(identity: unit, boardSlot: 1, channel: index)
                }) {
                    onSkipped("phantom power provenance (phantom will not be restored)")
                } else {
                    preset.unitID = identity
                }
            } else {
                onSkipped("unit identity")
            }
        }
        return preset
    }

}
