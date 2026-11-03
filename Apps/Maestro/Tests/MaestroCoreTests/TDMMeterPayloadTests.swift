import Foundation
import Testing
@testable import MaestroCore

/// Pins the fingerprint that proved the output/mixer TDM payloads on the dev
/// unit are XMOS EP0 stack residue, and the software output-meter model that
/// replaces them. Byte values below are the ones captured on hardware on
/// 2026-09-10 (Docs/issue-1-research.md, "Metering").
@Suite("TDM meter payload validation")
struct TDMMeterPayloadTests {

    /// The exact 64-byte group-1 reply captured from the dev unit: 12 zero
    /// bytes, 20 bytes of frozen residue, then the request's own setup packet
    /// `C0 30 01 00 00 00 40 00`, a varying stack word, and zeros.
    static func capturedGroup1Reply(varying: UInt16 = 0xB6B3) -> Data {
        var b = [UInt8](repeating: 0, count: 64)
        let residue: [UInt8] = [0xd8, 0xfd, 0x01, 0x00, 0xb0, 0x4d, 0x01, 0x00,
                                0x13, 0x00, 0x00, 0x00, 0xd8, 0xfd, 0x01, 0x00,
                                0x66, 0x14, 0x01, 0x00]
        for (i, v) in residue.enumerated() { b[12 + i] = v }
        let setup: [UInt8] = [0xC0, 0x30, 0x01, 0x00, 0x00, 0x00, 0x40, 0x00]
        for (i, v) in setup.enumerated() { b[32 + i] = v }
        b[40] = UInt8(varying & 0xFF); b[41] = UInt8(varying >> 8)
        return Data(b)
    }

    @Test("Captured dev-unit output reply is recognised as an echoed request")
    func capturedReplyIsEcho() {
        let d = Self.capturedGroup1Reply()
        #expect(TDMMeterPayload.isSetupPacketEcho(d, group: 1, requestLength: 64))
        // The varying stack word after the setup packet must not matter.
        #expect(TDMMeterPayload.isSetupPacketEcho(Self.capturedGroup1Reply(varying: 0x67D4),
                                                  group: 1, requestLength: 64))
    }

    @Test("Fingerprint is tied to the request: wrong group or length does not match")
    func fingerprintIsRequestSpecific() {
        let d = Self.capturedGroup1Reply()
        #expect(!TDMMeterPayload.isSetupPacketEcho(d, group: 0, requestLength: 64))
        #expect(!TDMMeterPayload.isSetupPacketEcho(d, group: 3, requestLength: 64))
        #expect(!TDMMeterPayload.isSetupPacketEcho(d, group: 1, requestLength: 32))
    }

    @Test("A genuine 64-byte payload with real meter words is not an echo")
    func genuinePayloadIsNotEcho() {
        // 32 little-endian 14-bit levels, some with the over bit; nothing at
        // words 16-19 resembles {0x30C0, 0x0001, 0x0000, 0x0040}.
        var b = [UInt8](repeating: 0, count: 64)
        for w in 0..<32 {
            let v: UInt16 = UInt16(500 * w) & 0x3FFF | (w % 5 == 0 ? 0x8000 : 0)
            b[w * 2] = UInt8(v & 0xFF); b[w * 2 + 1] = UInt8(v >> 8)
        }
        #expect(!TDMMeterPayload.isSetupPacketEcho(Data(b), group: 1, requestLength: 64))
    }

    @Test("Zeroed buffer (first read after a routing change) is all-zero, not an echo")
    func zeroedBuffer() {
        let z = Data(repeating: 0, count: 64)
        #expect(TDMMeterPayload.isAllZero(z))
        #expect(!TDMMeterPayload.isSetupPacketEcho(z, group: 1, requestLength: 64))
        #expect(!TDMMeterPayload.isAllZero(Self.capturedGroup1Reply()))
    }

    @Test("A 32-byte mixer reply cannot carry the fingerprint and is reported as not-echo")
    func shortReplyIsNotEcho() {
        let d = Self.capturedGroup1Reply().prefix(32)
        #expect(!TDMMeterPayload.isSetupPacketEcho(Data(d), group: 2, requestLength: 32))
    }

    @Test("Detection honours a non-zero startIndex slice")
    func sliceSafe() {
        var padded = Data([0xEE, 0xEE, 0xEE, 0xEE])
        padded.append(Self.capturedGroup1Reply())
        let slice = padded[4...]
        #expect(slice.startIndex == 4)
        #expect(TDMMeterPayload.isSetupPacketEcho(slice, group: 1, requestLength: 64))
    }
}

@Suite("Software output meter map")
struct SoftwareOutputMeterMapTests {

    @Test("Output words map to contiguous IOBoard0/IOBoard1 destination bytes")
    func destinationBytes() {
        #expect(SoftwareOutputMeterMap.destinationByte(forWord: 0) == 32)
        #expect(SoftwareOutputMeterMap.destinationByte(forWord: 15) == 47)
        #expect(SoftwareOutputMeterMap.destinationByte(forWord: 16) == 48)
        #expect(SoftwareOutputMeterMap.destinationByte(forWord: 31) == 63)
        #expect(SoftwareOutputMeterMap.destinationByte(forWord: 32) == nil)
        #expect(SoftwareOutputMeterMap.destinationByte(forWord: -1) == nil)
    }

    @Test("Proxy boot routing: slot 0 and slot 1 both mirror USB channel n")
    func defaultRouting() {
        #expect(SoftwareOutputMeterMap.source(forWord: 6, routes: [:]) == .usbChannel(6))
        #expect(SoftwareOutputMeterMap.source(forWord: 22, routes: [:]) == .usbChannel(6))
        #expect(SoftwareOutputMeterMap.source(forWord: 0, routes: [:]) == .usbChannel(0))
        #expect(SoftwareOutputMeterMap.source(forWord: 31, routes: [:]) == .usbChannel(15))
    }

    @Test("Cached P2P route: Line 7/8 fed from USB 5/6 meters USB 4/5")
    func customUSBRoute() {
        // syncOutputRoutingToHardware writes dest 38/39 <- p2pBase + row*2 (+1).
        let routes: [UInt8: UInt8] = [38: 196, 39: 197]
        #expect(SoftwareOutputMeterMap.source(forWord: 6, routes: routes) == .usbChannel(4))
        #expect(SoftwareOutputMeterMap.source(forWord: 7, routes: routes) == .usbChannel(5))
        // Untouched destinations keep the default.
        #expect(SoftwareOutputMeterMap.source(forWord: 8, routes: routes) == .usbChannel(8))
    }

    @Test("Mixer sources resolve to the mixer's L/R; hardware inputs are unknown")
    func mixerAndUnknownRoutes() {
        let routes: [UInt8: UInt8] = [32: 64, 33: 65, 34: 96, 35: 97, 36: 40]
        #expect(SoftwareOutputMeterMap.source(forWord: 0, routes: routes) == .mixerOut(mixer: 0, channel: 0))
        #expect(SoftwareOutputMeterMap.source(forWord: 1, routes: routes) == .mixerOut(mixer: 0, channel: 1))
        #expect(SoftwareOutputMeterMap.source(forWord: 2, routes: routes) == .mixerOut(mixer: 1, channel: 0))
        #expect(SoftwareOutputMeterMap.source(forWord: 4, routes: routes) == .unknown)   // IOBoard0 input 8
        #expect(SoftwareOutputMeterMap.source(forWord: 40, routes: routes) == .unknown)  // out of range
    }

    @Test("Levels: USB peaks convert to dBFS and mixer outputs follow selected return pairs")
    func levels() {
        var peaks = [Float](repeating: 0, count: 16)
        peaks[0] = 1.0; peaks[1] = 0.5; peaks[6] = 0.1
        #expect(SoftwareOutputMeterMap.level(for: .usbChannel(0), usbPeaks: peaks) == 0.0)
        #expect(abs(SoftwareOutputMeterMap.level(for: .usbChannel(1), usbPeaks: peaks) - (-6.0206)) < 0.01)
        #expect(abs(SoftwareOutputMeterMap.level(for: .usbChannel(6), usbPeaks: peaks) - (-20.0)) < 0.01)
        #expect(SoftwareOutputMeterMap.level(for: .usbChannel(7), usbPeaks: peaks) == -60.0)
        #expect(SoftwareOutputMeterMap.level(for: .usbChannel(99), usbPeaks: peaks) == -60.0)
        #expect(SoftwareOutputMeterMap.level(for: .mixerOut(mixer: 0, channel: 1), usbPeaks: peaks)
                == SoftwareOutputMeterMap.level(for: .usbChannel(1), usbPeaks: peaks))
        #expect(SoftwareOutputMeterMap.level(
            for: .mixerOut(mixer: 1, channel: 0),
            usbPeaks: peaks,
            mixerSoftwareReturnSources: [0, 3])
                == SoftwareOutputMeterMap.level(for: .usbChannel(6), usbPeaks: peaks))
        #expect(SoftwareOutputMeterMap.level(
            for: .mixerOut(mixer: 0, channel: 1),
            usbPeaks: peaks,
            mixerSoftwareReturnSources: [7, 0])
                == SoftwareOutputMeterMap.level(for: .usbChannel(15), usbPeaks: peaks))
        #expect(SoftwareOutputMeterMap.level(for: .mixerOut(mixer: 1, channel: 5), usbPeaks: peaks) == -60.0)
        #expect(SoftwareOutputMeterMap.level(for: .unknown, usbPeaks: peaks) == -60.0)
        // Two-channel fallback from an older proxy: channels beyond the array are silent.
        #expect(SoftwareOutputMeterMap.level(for: .usbChannel(2), usbPeaks: [1.0, 1.0]) == -60.0)
        #expect(SoftwareOutputMeterMap.dBFS(linearPeak: 0) == -60.0)
        #expect(SoftwareOutputMeterMap.dBFS(linearPeak: 0.0001) == -60.0)
    }
}
