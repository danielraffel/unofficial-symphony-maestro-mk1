import Foundation
import MaestroCore

extension ThunderboltPreset {
    /// Reset each card layer, then each peripheral in the same direction.
    /// og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:849-953;
    /// og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:838-856.
    ///
    /// `order`: the unit's channel order as the serving driver programs it
    /// (`ThunderboltUnitChannelOrder`). The input reset writes the capture
    /// table the driver programs in that order (analog first from driver
    /// 150, card by card before), and each headphone follows its output
    /// pair's XLink channel in that order. Nil: the analog-first walk, and
    /// headphones by position (the reset as it was before the order was
    /// known).
    public static func peripheralReset(layout: CardLayout, input: Bool,
                                       order: ThunderboltUnitChannelOrder? = nil,
                                       headphoneSource: (AudioPropertySelector) throws -> UInt32?) throws -> [Write] {
        guard layout.isKnown, layout.converter == nil, layout.converterLayout == nil else {
            throw RecallError.unsupported("unknown Symphony I/O boards.")
        }
        if input {
            let routes = order.map {
                SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: $0.slot1, slot2: $0.slot2, order: $0.order)
            } ?? SymphonyIODefaultRouting.inputRoutes(
                board0: .init(analog: layout.slot1.analogInputChannels, digital: layout.slot1.digitalInputChannels),
                board1: .init(analog: layout.slot2.analogInputChannels, digital: layout.slot2.digitalInputChannels),
                usbChannelCount: 32)
            return routes.map {
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
            // The XLink channels the unit's playback table plays on the pair
            // the headphone follows.
            let pair = SymphonyIOHeadphoneRouting.outputPairDestinations(sourceID: source)!
            let left = SymphonyIOHeadphoneRouting.thunderboltBootTableSource(forDestination: pair.left, order: order)
                ?? SymphonyIORoutingAddress.none
            let right = SymphonyIOHeadphoneRouting.thunderboltBootTableSource(forDestination: pair.right, order: order)
                ?? SymphonyIORoutingAddress.none
            writes += [
                .property(PropertyAddress(selector: .routing, scope: .output, element: UInt32(destinations.left)), .uint32(UInt32(left))),
                .property(PropertyAddress(selector: .routing, scope: .output, element: UInt32(destinations.right)), .uint32(UInt32(right))),
            ]
        }
        return writes
    }

    /// `orders`: each unit's channel order (index 0 unit A, 1 unit B; a
    /// missing or nil entry is card by card). The output reset writes all 32
    /// XLink channels of each unit, straight from `PCI_OUT n`, and enables
    /// XLink n when the unit's playback table plays it on one of its real
    /// outputs: card by card when n is one of the fitted outputs by position,
    /// analog first when n is below the unit's output count.
    public static func cardReset(input: Bool, layouts: [CardLayout],
                                 orders: [ThunderboltUnitChannelOrder?] = []) -> [Write] {
        if input {
            let routing = SymphonyCardInputRouting(model: .init(topology: .symphonyOnly, hostChannels: 64, unitBConfigured: true))
            return (0..<64).compactMap { routing.command(host: $0, source: $0).map(Write.cardInput) }
        }
        return layouts.prefix(2).enumerated().flatMap { unit, layout -> [Write] in
            let order = unit < orders.count ? orders[unit] : nil
            let enabled: Set<UInt8>
            if let order, order.order == .analogFirst {
                let routes = SymphonyIODefaultRouting.thunderboltOutputRoutes(slot1: order.slot1, slot2: order.slot2,
                                                                             order: order.order)
                enabled = Set(routes.compactMap { route in
                    guard route.source != SymphonyIORoutingAddress.none else { return nil }
                    return ThunderboltCardRouting.channel(forDestination: route.destination, slot1: order.slot1,
                                                          slot2: order.slot2, order: order.order)
                })
            } else {
                enabled = Set(SymphonyIODefaultRouting.thunderboltOutputRoutes(
                    board0Outputs: layout.slot1.totalOutputChannels, board1Outputs: layout.slot2.totalOutputChannels)
                    .filter { $0.source != SymphonyIORoutingAddress.none }.map { $0.destination - 32 })
            }
            return (0..<UInt8(32)).map { n in
                let channel = UInt8(unit * 32) + n
                return .output(.init(channel: channel, slot: 64 + channel, enabled: enabled.contains(n)))
            }
        }
    }
}
