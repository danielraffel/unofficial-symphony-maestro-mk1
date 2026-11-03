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

    @Test("Headphone inherit uses the dext boot table on ThunderBridge: XLink n feeds every output n")
    func thunderboltBootTable() {
        // SymphonyThunderbridge.cpp steps 19b-1 / 19b-1b route XLink RX 0-15 to
        // IOBoard0 ch0-15 and IOBoard1 ch0-15 directly, DAC L/R included.
        for destination in UInt8(32)...UInt8(47) {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination, transport: .thunderbolt)
                    == destination - 32)
        }
        for destination in UInt8(48)...UInt8(63) {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination, transport: .thunderbolt)
                    == destination - 48)
        }
        for destination: UInt8 in [0, 31, 64, 96, 192, 224, 236] {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination, transport: .thunderbolt) == nil)
        }
        // With no cached route, HP "follows Out 1/2" on ThunderBridge inherits XLink 0/1,
        // not Mixer0 (USB) and not P2P (silence in Symphony mode).
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 32, cachedRoutes: [:], transport: .thunderbolt) == 0)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 33, cachedRoutes: [:], transport: .thunderbolt) == 1)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 50, cachedRoutes: [:], transport: .thunderbolt) == 2)
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
}
