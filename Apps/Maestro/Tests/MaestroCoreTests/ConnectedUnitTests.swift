import Testing
@testable import MaestroCore

/// Reply codes are from Apogee's original source (XLinkRegisters.h:279-295).
@Suite("ConnectedUnit")
struct ConnectedUnitTests {
    private let ran: UInt32 = 0x8000_0000, answered: UInt32 = 0x4000_0000

    @Test("no probe means a Symphony I/O, or an older driver")
    func notProbed() {
        #expect(ConnectedUnit(probeWord: 0) == nil)
        #expect(ConnectedUnit(probeWord: 0x0000_00C3) == nil)
    }

    @Test("each converter is recognised by its channel banks")
    func converters() {
        #expect(ConnectedUnit(probeWord: ran | answered | 0x3A) == .ad16x)
        #expect(ConnectedUnit(probeWord: ran | answered | 0xC1) == .da16x)
        #expect(ConnectedUnit(probeWord: ran | answered | 0xF0) == .dd16x)
        #expect(ConnectedUnit(probeWord: ran | answered | 0x52) == .rosetta800)
        // The extended reply in bits 8-15 does not change the type.
        #expect(ConnectedUnit(probeWord: ran | answered | 0x2000_0000 | 0xAB00 | 0xC1) == .da16x)
    }

    @Test("an unknown or missing answer is reported as such, with no layout")
    func unknowns() {
        #expect(ConnectedUnit(probeWord: ran | answered | 0x21) == .unrecognised(reply: 0x21))
        #expect(ConnectedUnit(probeWord: ran) == .silent)
        #expect(ConnectedUnit.silent.channels == nil)
        #expect(ConnectedUnit.unrecognised(reply: 0x21).channels == nil)
    }

    @Test("a DA-16X shows 16 outputs and no inputs; an unidentified unit keeps the generic layout")
    func layout() {
        let da = CardLayout(isKnown: false, fallbackChannelCount: 32, converter: .da16x)
        #expect(da.analogOutputStripCount == 16)
        #expect(da.analogInputStripCount == 0)
        let ad = CardLayout(isKnown: false, fallbackChannelCount: 32, converter: .ad16x)
        #expect(ad.analogInputStripCount == 16)
        #expect(ad.analogOutputStripCount == 0)
        let silent = CardLayout(isKnown: false, fallbackChannelCount: 32, converter: .silent)
        #expect(silent.analogOutputStripCount == 32)
        #expect(silent.analogInputStripCount == 32)
        // A Symphony I/O with cards is never overridden.
        let symphony = CardLayout(slot1: .analogADDA16, isKnown: true, converter: .da16x)
        #expect(symphony.analogOutputStripCount == symphony.slot1.analogOutputChannels)
    }

    /// A converter has no option cards, so the copied details must not say its
    /// cards were "not detected".
    @Test("copied device details describe a converter without card errors")
    func report() {
        let report = DeviceInfoReport(deviceName: ConnectedUnit.da16x.modelName ?? "",
                                      connection: "Thunderbolt (ThunderBridge)",
                                      connectedUnit: ConnectedUnit.da16x.displayName)
        let text = report.clipboardText
        #expect(text.contains("Device Name: Apogee DA-16X"))
        #expect(text.contains("Connected Unit: DA-16X (16 outputs)"))
        #expect(text.contains("IOBoard1: Not applicable (not a Symphony I/O)"))
        #expect(!text.lowercased().contains("not detected"))
        // A Symphony I/O report is unchanged.
        let symphony = DeviceInfoReport(connection: "USB Hardware").clipboardText
        #expect(!symphony.contains("Connected Unit"))
        #expect(!symphony.contains("Not applicable"))
    }

    @Test("the connection row names the PCIe card when that is what is attached")
    func connectionLabel() {
        #expect(ConnectionLabel.text(isThunderbolt: false, pciIdentifier: nil) == "USB Hardware")
        #expect(ConnectionLabel.text(isThunderbolt: true, pciIdentifier: "pci19c2,2200") == "Thunderbolt (ThunderBridge)")
        #expect(ConnectionLabel.text(isThunderbolt: true, pciIdentifier: nil) == "Thunderbolt (ThunderBridge)")
        #expect(ConnectionLabel.text(isThunderbolt: true, pciIdentifier: "pci19c2,2100")
                == "Thunderbolt (Symphony 64 PCIe card, experimental)")
    }

    /// The usual rig: an AD-16X and a DA-16X on one cable. Unit 1 in the low
    /// byte, units 2-4 as bank nibbles in bits 16-27.
    @Test("chained converters are listed nearest first and their channels add up")
    func chain() {
        let adThenDa = ConnectedUnit(probeWord: ran | answered | 0x30 | (0xC << 16))
        #expect(adThenDa == .chain([.ad16x, .da16x]))
        #expect(adThenDa?.channels?.inputs == 16)
        #expect(adThenDa?.channels?.outputs == 16)
        #expect(adThenDa?.modelName == "Apogee AD-16X + Apogee DA-16X")

        // Three DA-16X: 48 outputs, but the link carries 32.
        let threeDa = ConnectedUnit(probeWord: ran | answered | 0xC0 | (0xC << 16) | (0xC << 20))
        #expect(threeDa == .chain([.da16x, .da16x, .da16x]))
        #expect(threeDa?.channels?.outputs == 32)
        #expect(threeDa?.channels?.inputs == 0)

        // A gap ends the chain: unit 4 without unit 3 is ignored.
        #expect(ConnectedUnit(probeWord: ran | answered | 0x30 | (0xC << 24)) == .ad16x)

        // One unknown unit makes the total unknown: generic layout.
        let withUnknown = ConnectedUnit(probeWord: ran | answered | 0x30 | (0x2 << 16))
        #expect(withUnknown == .chain([.ad16x, .unrecognised(reply: 0x20)]))
        #expect(withUnknown?.channels == nil)
        let layout = CardLayout(isKnown: false, fallbackChannelCount: 32, converter: withUnknown)
        #expect(layout.analogOutputStripCount == 32)
    }
}
