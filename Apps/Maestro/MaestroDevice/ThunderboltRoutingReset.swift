import Foundation
import MaestroCore

extension ThunderboltPreset {
    /// Reset each card layer, then each peripheral in the same direction.
    /// og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:849-953;
    /// og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:838-856.
    public static func peripheralReset(layout: CardLayout, input: Bool,
                                       headphoneSource: (AudioPropertySelector) throws -> UInt32?) throws -> [Write] {
        guard layout.isKnown, layout.converter == nil, layout.converterLayout == nil else {
            throw RecallError.unsupported("unknown Symphony I/O boards.")
        }
        if input {
            return SymphonyIODefaultRouting.inputRoutes(
                board0: .init(analog: layout.slot1.analogInputChannels, digital: layout.slot1.digitalInputChannels),
                board1: .init(analog: layout.slot2.analogInputChannels, digital: layout.slot2.digitalInputChannels),
                usbChannelCount: 32).map {
                    .property(PropertyAddress(selector: .routing, scope: .input, element: UInt32($0.destination)), .uint32(UInt32($0.source)))
                }
        }
        // The ThunderBridge's board output table is fixed. Replay headphone
        // crosspoints after card outputs, even if the Outputs page was closed.
        // og_source/maestrolink/Software/SymphonyIO.cpp:2716-2737.
        var writes: [Write] = []
        for (index, selector) in [AudioPropertySelector.headphone1RoutingID, .headphone2RoutingID].enumerated() {
            guard let source = try headphoneSource(selector), source < 16 else {
                throw RecallError.unsupported("headphone sources could not be read.")
            }
            let destinations = SymphonyIOHeadphoneRouting.Headphone(rawValue: index)!.destinations
            writes += [
                .property(PropertyAddress(selector: .routing, scope: .output, element: UInt32(destinations.left)), .uint32(source * 2)),
                .property(PropertyAddress(selector: .routing, scope: .output, element: UInt32(destinations.right)), .uint32(source * 2 + 1)),
            ]
        }
        return writes
    }

    public static func cardReset(input: Bool, layouts: [CardLayout]) -> [Write] {
        if input {
            let routing = SymphonyCardInputRouting(model: .init(topology: .symphonyOnly, hostChannels: 64, unitBConfigured: true))
            return (0..<64).compactMap { routing.command(host: $0, source: $0).map(Write.cardInput) }
        }
        return layouts.prefix(2).enumerated().flatMap { unit, layout in
            SymphonyIODefaultRouting.thunderboltOutputRoutes(
                board0Outputs: layout.slot1.totalOutputChannels, board1Outputs: layout.slot2.totalOutputChannels,
                mainPairOnMixer: false).map { route in
                    let channel = UInt8(unit * 32) + route.destination - 32
                    return .output(.init(channel: channel, slot: 64 + channel, enabled: route.source != SymphonyIORoutingAddress.none))
                }
        }
    }
}
