// ThunderBridge card-side output routing — the stage the legacy PCIe routing
// controller programmed for host playback (SymphonyPCIeRoutingController.cpp
// routeSymphonyHW → Sym64Routing::SetOutputSource).

import Testing
import MaestroCore
@testable import MaestroDevice

@Suite("ThunderBridge card output routing")
struct ThunderboltCardRoutingTests {

    @Test("Symphony output destinations map onto the port's 32 XLink TX channels")
    func destinationToChannel() {
        for destination in UInt8(32)...UInt8(47) {
            #expect(ThunderboltCardRouting.channel(forDestination: destination) == destination - 32)
        }
        for destination in UInt8(48)...UInt8(63) {
            #expect(ThunderboltCardRouting.channel(forDestination: destination) == 16 + (destination - 48))
        }
        for destination: UInt8 in [0, 31, 64, 96, 128, 192, 236, 255] {
            #expect(ThunderboltCardRouting.channel(forDestination: destination) == nil)
        }
    }

    @Test("DAW playback n is PCI_OUT n; mixer buses are MIXER0_OUT + 2m + side")
    func sourceToSlot() {
        // Sym64RoutingRegisters.h:94 SYMPHONY64_PCI_OUT0 = 64, :159 SYMPHONY64_MIXER0_OUT = 128.
        for n in UInt8(0)...UInt8(31) {
            #expect(ThunderboltCardRouting.slot(forSource: n) == 64 + n)
        }
        #expect(ThunderboltCardRouting.slot(forSource: SymphonyIORoutingAddress.mixer0Base) == 128)
        #expect(ThunderboltCardRouting.slot(forSource: SymphonyIORoutingAddress.mixer0Base + 1) == 129)
        #expect(ThunderboltCardRouting.slot(forSource: SymphonyIORoutingAddress.mixer1Base) == 130)
        #expect(ThunderboltCardRouting.slot(forSource: SymphonyIORoutingAddress.mixer1Base + 1) == 131)
        // Hardware inputs and P2P are not matrix output sources on ThunderBridge.
        for source: UInt8 in [32, 63, 66, 98, 192, 236, 255] {
            #expect(ThunderboltCardRouting.slot(forSource: source) == nil)
        }
    }

    @Test("Jeff's case: DAW 1-2 onto Line 3/4 programs XLink TX 2/3 ← PCI_OUT 0/1")
    func crossRoute() {
        #expect(ThunderboltCardRouting.route(destination: 34, source: 0)
                == .init(channel: 2, slot: 64, enabled: true))
        #expect(ThunderboltCardRouting.route(destination: 35, source: 1)
                == .init(channel: 3, slot: 65, enabled: true))
        // DAW 3-4 onto Line 1/2 bypasses the card mixer: direct PCI_OUT 2/3.
        #expect(ThunderboltCardRouting.route(destination: 32, source: 2)
                == .init(channel: 0, slot: 66, enabled: true))
        // DAW 17-18 onto board 1 output 1/2 (XLink TX 16/17).
        #expect(ThunderboltCardRouting.route(destination: 48, source: 16)
                == .init(channel: 16, slot: 80, enabled: true))
    }

    @Test("DAW 1-2 onto the main pair goes through card mixer 0, the driver default")
    func mainPairViaMixer() {
        #expect(ThunderboltCardRouting.route(destination: 32, source: 0)
                == .init(channel: 0, slot: 128, enabled: true))
        #expect(ThunderboltCardRouting.route(destination: 33, source: 1)
                == .init(channel: 1, slot: 129, enabled: true))
    }

    @Test("Clearing a route disables the channel and keeps its straight slot")
    func clear() {
        #expect(ThunderboltCardRouting.route(destination: 34, source: SymphonyIORoutingAddress.clearRoute)
                == .init(channel: 2, slot: 66, enabled: false))
        #expect(ThunderboltCardRouting.route(destination: 50, source: SymphonyIORoutingAddress.none)
                == .init(channel: 18, slot: 82, enabled: false))
        #expect(ThunderboltCardRouting.route(destination: 200, source: 0) == nil)
        #expect(ThunderboltCardRouting.route(destination: 34, source: 40) == nil)
    }

    @Test("The payload is [channel, slot, enabled]")
    func payload() {
        let route = ThunderboltCardRouting.Route(channel: 2, slot: 64, enabled: true)
        #expect(Array(route.payload) == [2, 64, 1])
        #expect(Array(ThunderboltCardRouting.Route(channel: 5, slot: 69, enabled: false).payload) == [5, 69, 0])
    }

    @Test("The 32-channel default table for an 8x8 optical card maps every entry to a card route")
    func defaultTableMaps() {
        let routes = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 0, digital: 0),
            usbChannelCount: Int(ThunderboltCardRouting.channelCount),
            playbackBase: SymphonyIORoutingAddress.xlinkPlaybackBase)
        #expect(!routes.isEmpty)
        for route in routes {
            let card = ThunderboltCardRouting.route(destination: route.destination, source: route.source)
            #expect(card != nil, "no card route for \(route)")
            guard let card else { continue }
            if route.source == SymphonyIORoutingAddress.none {
                #expect(!card.enabled)
            } else if card.channel < 2 {
                #expect(card.slot == 128 + card.channel)
            } else {
                #expect(card.slot == 64 + route.source)
            }
        }
    }

    @Test("Headphone inherit on ThunderBridge ignores the cache: the Symphony side is fixed")
    func headphoneInheritIgnoresCache() {
        let cached: [UInt8: UInt8] = [34: 0, 35: 1]
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 34, cachedRoutes: cached, transport: .thunderbolt) == 2)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 34, cachedRoutes: cached, transport: .usb) == 0)
    }
}
