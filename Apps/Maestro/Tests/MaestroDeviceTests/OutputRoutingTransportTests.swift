/// Output routing must address host playback the way the Symphony sees it on
/// each transport: P2P (192+) in the USB modes, XLink RX (0+) in Symphony
/// (ThunderBridge) mode. Evidence: dext Start step 19b-1 routes
/// `kSIOSrc_XLinkCh0 + n` and that path is what plays; Jeff's 0.8.19 report
/// "output routing does not work in ThunderBridge mode" was P2P sources.

import Testing
import MaestroCore
@testable import MaestroDevice

@Suite("Output routing playback source per transport")
struct OutputRoutingTransportTests {

    @Test("USB keeps the P2P base; ThunderBridge uses XLink RX")
    func bases() {
        #expect(SymphonyIORoutingAddress.hostPlaybackBase(for: .usb) == 192)
        #expect(SymphonyIORoutingAddress.hostPlaybackBase(for: .thunderbolt) == 0)
    }

    @Test("XLink sources are plausible output sources")
    func plausible() {
        #expect(SymphonyIOHeadphoneRouting.isPlausibleOutputSource(0))
        #expect(SymphonyIOHeadphoneRouting.isPlausibleOutputSource(31))
        #expect(!SymphonyIOHeadphoneRouting.isPlausibleOutputSource(32))   // IOBoard byte
        #expect(SymphonyIOHeadphoneRouting.isPlausibleOutputSource(192))
    }

    @Test("default output table follows the playback base")
    func defaultTable() {
        let boards = SymphonyIODefaultRouting.BoardChannels(analog: 8, digital: 8)
        let usb = SymphonyIODefaultRouting.outputRoutes(board0: boards, board1: .init(analog: 0, digital: 0), usbChannelCount: 16)
        let tb = SymphonyIODefaultRouting.outputRoutes(board0: boards, board1: .init(analog: 0, digital: 0), usbChannelCount: 16,
                                                       playbackBase: SymphonyIORoutingAddress.xlinkPlaybackBase)
        #expect(usb.count == tb.count)
        for (u, t) in zip(usb, tb) {
            #expect(u.destination == t.destination)
            if u.source == SymphonyIORoutingAddress.none {
                #expect(t.source == SymphonyIORoutingAddress.none)
            } else {
                #expect(u.source &- 192 == t.source)
            }
        }
        // Analog 1 ← playback 1 on both transports, just addressed differently.
        #expect(usb.first?.source == 192)
        #expect(tb.first?.source == 0)
    }

    @Test("Headphone inherit uses the dext boot table on ThunderBridge: slot 1 from XLink 0-15, slot 2 from XLink 16-31")
    func thunderboltBootTable() {
        // SymphonyThunderbridge.cpp step 19b-1 routes XLink RX 0-15 to IOBoard0
        // ch0-15 (DAC L/R included) and step 19b-1b routes XLink RX 16-31 to
        // IOBoard1 ch0-15. The legacy daemon agrees (SymphonyIOPTHDRoutingController
        // GetRoutedToHWSource: board 1 → XLinkCh16 + n).
        for destination in UInt8(32)...UInt8(47) {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination, transport: .thunderbolt)
                    == destination - 32)
        }
        for destination in UInt8(48)...UInt8(63) {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination, transport: .thunderbolt)
                    == 16 + (destination - 48))
        }
        for destination: UInt8 in [0, 31, 64, 96, 192, 224, 236] {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination, transport: .thunderbolt) == nil)
        }
        // With no cached route, HP "follows Out 1/2" on ThunderBridge inherits XLink 0/1,
        // not Mixer0 (USB) and not P2P (silence in Symphony mode).
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 32, cachedRoutes: [:], transport: .thunderbolt) == 0)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 33, cachedRoutes: [:], transport: .thunderbolt) == 1)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 50, cachedRoutes: [:], transport: .thunderbolt) == 18)
        // Slot 2 output 1 (dest 48) is XLink 16, the same channel the card-side
        // output routing uses for it and the dext's output-name table names
        // "slot 2 output 1".
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 48, cachedRoutes: [:], transport: .thunderbolt) == 16)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 48, cachedRoutes: [:], transport: .thunderbolt)
                == ThunderboltCardRouting.channel(forDestination: 48))
        for destination in UInt8(32)...UInt8(63) {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination, transport: .thunderbolt)
                    == ThunderboltCardRouting.channel(forDestination: destination))
        }
        // The USB table is unchanged.
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 32, cachedRoutes: [:], transport: .usb) == 64)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 50, cachedRoutes: [:], transport: .usb) == 194)
    }

    @Test("Clearing a stereo route clears both channels instead of overflowing 0xFF + 1")
    func clearRouteRightChannel() {
        #expect(SymphonyIORoutingAddress.rightChannelSource(of: SymphonyIORoutingAddress.clearRoute)
                == SymphonyIORoutingAddress.clearRoute)
        #expect(SymphonyIORoutingAddress.rightChannelSource(of: SymphonyIORoutingAddress.none)
                == SymphonyIORoutingAddress.none)
        #expect(SymphonyIORoutingAddress.rightChannelSource(of: 0) == 1)
        #expect(SymphonyIORoutingAddress.rightChannelSource(of: 192) == 193)
        #expect(SymphonyIORoutingAddress.rightChannelSource(of: 64) == 65)
    }

    @Test("ThunderBridge default output table is the driver's: Mac n on slot 1 output n, 17-32 on slot 2")
    func thunderboltPositionTable() {
        // Two 8x8s: the USB table would put slot 2's Line outputs on playback 9-16.
        let routes = SymphonyIODefaultRouting.thunderboltOutputRoutes(board0Outputs: 16, board1Outputs: 16)
        #expect(routes.count == 32)
        var byDestination: [UInt8: UInt8] = [:]
        for route in routes { byDestination[route.destination] = route.source }
        // Main pair on Mixer 1, as the driver programs it.
        #expect(byDestination[32] == SymphonyIORoutingAddress.mixer0Base)
        #expect(byDestination[33] == SymphonyIORoutingAddress.mixer0Base + 1)
        for channel in UInt8(2)...UInt8(15) { #expect(byDestination[32 + channel] == channel) }
        for channel in UInt8(0)...UInt8(15) { #expect(byDestination[48 + channel] == 16 + channel) }
        // Every route reaches the card output the driver's fixed table gives it.
        for route in routes where route.source < 32 {
            #expect(ThunderboltCardRouting.channel(forDestination: route.destination) == route.source)
        }

        // Empty slot 1: slot 2 stays on 17-32; slot 1's destinations are silent.
        let empty = SymphonyIODefaultRouting.thunderboltOutputRoutes(board0Outputs: 0, board1Outputs: 16)
        #expect(empty.first { $0.destination == 34 }?.source == SymphonyIORoutingAddress.none)
        #expect(empty.first { $0.destination == 48 }?.source == 16)
    }

    @Test("The ThunderBridge reset confirmation describes the position table")
    func thunderboltPlanLines() {
        let text = RoutingResetGuard.outputPlanLines(board1: .optical, board2: .optical, transport: .thunderbolt)
            .joined(separator: "\n")
        #expect(text.contains("Slot 1 (8x8 OPT) analog out 1-8 ← Mixer 1, DAW 3-8"), "\(text)")
        #expect(text.contains("Slot 1 (8x8 OPT) ADAT out 1-8 ← DAW 9-16"), "\(text)")
        #expect(text.contains("Slot 2 (8x8 OPT) analog out 1-8 ← DAW 17-24"), "\(text)")
        #expect(text.contains("Slot 2 (8x8 OPT) ADAT out 1-8 ← DAW 25-32"), "\(text)")
    }
}
