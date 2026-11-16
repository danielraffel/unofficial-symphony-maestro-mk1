import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

/// What goes out on USB for the Software Return and Master strips, and what
/// ThunderBridge keeps receiving.
///
/// The unit's mixer numbers its strips 0-31 (inputs), 32 (Software Return) and
/// 33 (Master): `SymphonyIOVendorSpecific.h:1109-1112`
/// (`kSymphonyIOMixer_FaderIndexSoftwareReturn = 32`, `...MasterOut = 33`), and
/// the original daemon sends those. 1000 and 2000 are CoreAudio-level IDs.
@Suite("USB mixer strip addressing")
struct USBMixerWireTests {

    typealias Call = (bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data)

    private func makeConnection() -> (XPCDeviceConnection, MockXPCTransport) {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID, productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "usb-mixer-wire")!
        let transport = MockXPCTransport()
        return (XPCDeviceConnection(identifier: id, transport: transport), transport)
    }

    private let forbidden: Set<UInt16> = [1000, 2000, 0x1001, 0x1002, 0x2001, 0x2002]

    // MARK: Software Return and Master on the wire

    @Test("Software Return level, mute and solo go to strip 32 on both mixers")
    func softwareReturnWire() async throws {
        let table: [(AudioPropertySelector, PropertyValue, UInt8, [UInt8])] = [
            (.mixerChannelLevel, .float64(-12), 0xB0, [36]),
            (.mixerChannelMute, .bool(true), 0xB3, [1]),
            (.mixerChannelSolo, .bool(true), 0xB2, [1]),
            (.mixerChannelSolo, .bool(false), 0xB2, [0]),
        ]
        // The app's CoreAudio-level ID (1000) and the real strip (32) both land on 32.
        for channel: UInt32 in [1000, 32] {
            for mixerID: UInt32 in [1, 2] {
                for (selector, value, command, bytes) in table {
                    let (conn, transport) = makeConnection()
                    try await conn.setProperty(
                        PropertyAddress(selector: selector, element: (mixerID << 16) | channel),
                        value: value)
                    let call = try #require(transport.setPropertyCalls.first)
                    #expect(transport.setPropertyCalls.count == 1)
                    #expect(call.bRequest == command)
                    #expect(call.wValue == UInt16(mixerID))
                    #expect(call.wIndex == 32)
                    #expect(Array(call.data) == bytes)
                }
            }
        }
    }

    @Test("Master level goes to strip 33 on both mixers, dB + 48")
    func masterWire() async throws {
        for channel: UInt32 in [2000, 33] {
            for mixerID: UInt32 in [1, 2] {
                for (db, byte): (Double, UInt8) in [(0, 48), (-12, 36), (-48, 0), (6, 54)] {
                    let (conn, transport) = makeConnection()
                    try await conn.setProperty(
                        PropertyAddress(selector: .mixerChannelLevel, element: (mixerID << 16) | channel),
                        value: .float64(db))
                    let call = try #require(transport.setPropertyCalls.first)
                    #expect(call.bRequest == 0xB0)
                    #expect(call.wValue == UInt16(mixerID))
                    #expect(call.wIndex == 33)
                    #expect(Array(call.data) == [byte])
                }
            }
        }
    }

    @Test("input strips are untouched")
    func inputStripsUnchanged() async throws {
        for channel: UInt32 in [0, 5, 31] {
            let (conn, transport) = makeConnection()
            try await conn.setProperty(
                PropertyAddress(selector: .mixerChannelPan, element: (2 << 16) | channel),
                value: .float64(0))
            #expect(transport.setPropertyCalls.first?.wIndex == UInt16(channel))
            #expect(transport.setPropertyCalls.first?.bRequest == 0xB1)
        }
    }

    @Test("reads of Software Return and Master use 32 and 33")
    func readsUseRealStrips() async throws {
        let (conn, transport) = makeConnection()
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([36]))
        let sw = try await conn.getProperty(
            PropertyAddress(selector: .mixerChannelLevel, element: (1 << 16) | 1000))
        let master = try await conn.getProperty(
            PropertyAddress(selector: .mixerChannelLevel, element: (2 << 16) | 2000))
        #expect(sw == .float64(-12))
        #expect(master == .float64(-12))
        #expect(transport.getPropertyCalls.map { [$0.wValue, $0.wIndex] } == [[1, 32], [2, 33]])
    }

    // MARK: Nothing bogus reaches the wire

    @Test("no mixer level, mute, solo or pan write or read can carry a CoreAudio-level ID")
    func noBogusIndexOnUSB() async {
        let selectors: [AudioPropertySelector] = [
            .mixerChannelLevel, .mixerChannelMute, .mixerChannelSolo, .mixerChannelPan,
        ]
        let channels: [UInt32] = [
            0, 1, 31, 32, 33, 34, 1000, 2000, 0x1000, 0x1001, 0x1002, 0x2000, 0x2001, 0x2002,
        ]
        for selector in selectors {
            for mixerID: UInt32 in [1, 2] {
                for channel in channels {
                    let (conn, transport) = makeConnection()
                    transport.nextReply = XPCPropertyReply(status: 0, data: Data([1]))
                    let address = PropertyAddress(selector: selector, element: (mixerID << 16) | channel)
                    let value: PropertyValue =
                        selector == .mixerChannelMute || selector == .mixerChannelSolo
                        ? .bool(true) : .float64(0)
                    _ = try? await conn.setProperty(address, value: value)
                    _ = try? await conn.getProperty(address)
                    for call in transport.setPropertyCalls {
                        #expect(!forbidden.contains(call.wIndex), "write \(selector) ch \(channel) -> \(call.wIndex)")
                    }
                    for call in transport.getPropertyCalls {
                        #expect(!forbidden.contains(call.wIndex), "read \(selector) ch \(channel) -> \(call.wIndex)")
                    }
                }
            }
        }
    }

    @Test("the strips have no pan: nothing is sent for it")
    func noPanOnReturnOrMaster() async {
        for channel: UInt32 in [1000, 32, 2000, 33, 0x1001, 0x2002] {
            let (conn, transport) = makeConnection()
            await #expect(throws: DeviceConnectionError.self) {
                try await conn.setProperty(
                    PropertyAddress(selector: .mixerChannelPan, element: (1 << 16) | channel),
                    value: .float64(0.5))
            }
            #expect(transport.setPropertyCalls.isEmpty)
        }
    }

    @Test("the stereo side IDs are never sent")
    func sideIDsRefused() async {
        for channel: UInt32 in [0x1001, 0x1002, 0x2001, 0x2002] {
            let (conn, transport) = makeConnection()
            await #expect(throws: DeviceConnectionError.self) {
                try await conn.setProperty(
                    PropertyAddress(selector: .mixerChannelLevel, element: (1 << 16) | channel),
                    value: .float64(-3))
            }
            #expect(transport.setPropertyCalls.isEmpty)
        }
    }

    @Test("raw mixer commands are translated or dropped too")
    func rawMixerParam() {
        let (conn, transport) = makeConnection()
        conn.sendMixerParam(usbCmd: 0xB2, mixer: 1, channel: 1000, value: 1)
        conn.sendMixerParam(usbCmd: 0xB0, mixer: 2, channel: 2000, value: 40)
        conn.sendMixerParam(usbCmd: 0xB1, mixer: 1, channel: 1000, value: 64)
        conn.sendMixerParam(usbCmd: 0xB0, mixer: 1, channel: 0x1001, value: 40)
        #expect(transport.mixerParamCalls.map { [UInt16($0.usbCmd), $0.mixer, $0.channel, UInt16($0.value)] }
                == [[0xB2, 1, 32, 1], [0xB0, 2, 33, 40]])
    }

    // MARK: ThunderBridge keeps what it receives today

    /// The ThunderBridge driver translates 1000/2000 and the side IDs itself, so
    /// it must keep receiving them. It is sent the shared mapper's request with
    /// `nValue = (mixer << 16) | index` (`DextUserClient.sendFromUSBRequest`).
    @Test("ThunderBridge still receives 1000, 2000 and the stereo side IDs")
    func thunderBridgeUnchanged() throws {
        let cases: [(UInt32, UInt32)] = [
            (1000, 1000), (2000, 2000),
            (0x1001, 0x1001), (0x1002, 0x1002), (0x2001, 0x2001), (0x2002, 0x2002),
        ]
        for mixerID: UInt32 in [1, 2] {
            for (channel, expected) in cases {
                let request = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: .mixerChannelLevel, element: (mixerID << 16) | channel),
                    value: .float64(-12))
                #expect(request.request == 0xB0)
                #expect(DextUserClient.nValue(for: request) == (mixerID << 16) | expected)
                #expect(Array(request.data) == [36])
            }
            for selector in [AudioPropertySelector.mixerChannelMute, .mixerChannelSolo] {
                let request = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: selector, element: (mixerID << 16) | 1000),
                    value: .bool(true))
                #expect(DextUserClient.nValue(for: request) == (mixerID << 16) | 1000)
            }
            let pan = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .mixerChannelPan, element: (mixerID << 16) | 1000),
                value: .float64(0))
            #expect(DextUserClient.nValue(for: pan) == (mixerID << 16) | 1000)
        }
    }

    // MARK: Parity with the original

    /// `SymphonyIOMixer.cpp:287-452`: the daemon addresses Software Return as
    /// `kSymphonyIOMixer_FaderIndexSoftwareReturn` (32) and Master as
    /// `kSymphonyIOMixer_FaderIndexMasterOut` (33), with 0xB0 (fader, dB + 48,
    /// `kSymphonyIOMixer_ScaledFaderSettingZeroOffset`), 0xB3 (mute), 0xB2 (solo).
    @Test("Software Return and Master match the original's strip numbers and commands")
    func originalParity() async throws {
        let originalSoftwareReturn: UInt16 = 32
        let originalMaster: UInt16 = 33
        #expect(USBMixerStrip.softwareReturn == originalSoftwareReturn)
        #expect(USBMixerStrip.master == originalMaster)
        for mixerID: UInt16 in [1, 2] {
            let (conn, transport) = makeConnection()
            let element: (UInt16) -> UInt32 = { (UInt32(mixerID) << 16) | UInt32($0) }
            try await conn.setProperty(PropertyAddress(selector: .mixerChannelLevel, element: element(1000)), value: .float64(-6))
            try await conn.setProperty(PropertyAddress(selector: .mixerChannelMute, element: element(1000)), value: .bool(true))
            try await conn.setProperty(PropertyAddress(selector: .mixerChannelSolo, element: element(1000)), value: .bool(true))
            try await conn.setProperty(PropertyAddress(selector: .mixerChannelLevel, element: element(2000)), value: .float64(-6))
            let wire = transport.setPropertyCalls.map { [UInt16($0.bRequest), $0.wValue, $0.wIndex, UInt16($0.data[0])] }
            #expect(wire == [
                [0xB0, mixerID, originalSoftwareReturn, 42],
                [0xB3, mixerID, originalSoftwareReturn, 1],
                [0xB2, mixerID, originalSoftwareReturn, 1],
                [0xB0, mixerID, originalMaster, 42],
            ])
        }
    }
}

@Suite("Mixer fader arithmetic")
struct MixerFaderMathTests {

    @Test("linked Software Return: one fader, helper at 0 dB")
    func linked() {
        let s = MixerFaderMath.softwareReturn(left: -3, right: -9, linked: true, linkedLevel: -12)
        #expect(s == SoftwareReturnFaderSplit(hardwareLevel: -12, leftTrim: 0, rightTrim: 0))
    }

    @Test("unlinked, left louder: fader takes left, right is attenuated by the difference")
    func leftLouder() {
        let s = MixerFaderMath.softwareReturn(left: -3, right: -9, linked: false, linkedLevel: 0)
        #expect(s == SoftwareReturnFaderSplit(hardwareLevel: -3, leftTrim: 0, rightTrim: -6))
    }

    @Test("unlinked, right louder")
    func rightLouder() {
        let s = MixerFaderMath.softwareReturn(left: -20, right: -2.5, linked: false, linkedLevel: 0)
        #expect(s == SoftwareReturnFaderSplit(hardwareLevel: -2.5, leftTrim: -17.5, rightTrim: 0))
    }

    @Test("unlinked, equal: no trim")
    func equal() {
        let s = MixerFaderMath.softwareReturn(left: -6, right: -6, linked: false, linkedLevel: 0)
        #expect(s == SoftwareReturnFaderSplit(hardwareLevel: -6, leftTrim: 0, rightTrim: 0))
    }

    @Test("extreme values stay on the fader's range and never boost")
    func extremes() {
        let low = MixerFaderMath.softwareReturn(left: -48, right: 6, linked: false, linkedLevel: 0)
        #expect(low == SoftwareReturnFaderSplit(hardwareLevel: 6, leftTrim: -54, rightTrim: 0))
        let out = MixerFaderMath.softwareReturn(left: -500, right: 500, linked: false, linkedLevel: 0)
        #expect(out.hardwareLevel == 6)
        #expect(out.leftTrim == -54)
        #expect(MixerFaderMath.softwareReturn(left: 0, right: 0, linked: true, linkedLevel: 99).hardwareLevel == 6)
        #expect(MixerFaderMath.softwareReturn(left: 0, right: 0, linked: true, linkedLevel: -99).hardwareLevel == -48)
        for (l, r) in [(-48.0, -48.0), (6.0, 6.0), (-48.0, 6.0), (6.0, -48.0), (-10.0, -10.5)] {
            let s = MixerFaderMath.softwareReturn(left: l, right: r, linked: false, linkedLevel: 0)
            #expect(s.leftTrim <= 0 && s.rightTrim <= 0)
            #expect(s.leftTrim == 0 || s.rightTrim == 0)
            // Fader plus trim reproduces each side.
            #expect(s.hardwareLevel + s.leftTrim == l)
            #expect(s.hardwareLevel + s.rightTrim == r)
        }
    }

    @Test("Master: linked uses the linked level, unlinked uses the quieter side")
    func master() {
        #expect(MixerFaderMath.master(left: -3, right: -9, linked: true, linkedLevel: -5) == -5)
        #expect(MixerFaderMath.master(left: -3, right: -9, linked: false, linkedLevel: 0) == -9)
        #expect(MixerFaderMath.master(left: -9, right: -3, linked: false, linkedLevel: 0) == -9)
        #expect(MixerFaderMath.master(left: -6, right: -6, linked: false, linkedLevel: 0) == -6)
        #expect(MixerFaderMath.master(left: -60, right: 6, linked: false, linkedLevel: 0) == -48)
        #expect(MixerFaderMath.master(left: 12, right: 9, linked: false, linkedLevel: 0) == 6)
    }
}

@Suite("USB connect-time mixer restore")
struct USBMixerRestoreTests {

    private func defaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func save(_ d: UserDefaults, swReturn: MixerChannelState) {
        d.set(try! JSONEncoder().encode(swReturn), forKey: "mixerState_swReturn")
    }

    @Test("saved Master and Software Return reach strips 33 and 32 on both mixers, helper neutral")
    func restoreWritesBothMixers() async throws {
        let d = defaults("USBMixerRestoreTests.both")
        save(d, swReturn: MixerChannelState(level: -4, pan: 0.5, isMuted: true, isSoloed: true))
        d.set(-12.0, forKey: "mixerMasterLevel_0")
        d.set(-6.0, forKey: "mixerMasterLevel_1")
        d.set(-12.0, forKey: "mixerMasterLeftLevel_0"); d.set(-12.0, forKey: "mixerMasterRightLevel_0")
        d.set(-6.0, forKey: "mixerMasterLeftLevel_1"); d.set(-6.0, forKey: "mixerMasterRightLevel_1")
        d.set(true, forKey: "mixerMasterFadersLinked")
        d.set(-4.0, forKey: "mixerSWReturnLeftLevel_0"); d.set(-4.0, forKey: "mixerSWReturnRightLevel_0")
        d.set(-20.0, forKey: "mixerSWReturnLeftLevel_1"); d.set(-20.0, forKey: "mixerSWReturnRightLevel_1")
        d.set(true, forKey: "mixerSWReturnFadersLinked")
        d.set(0, forKey: "mixerSoftwareReturnSource_0")
        d.set(2, forKey: "mixerSoftwareReturnSource_1")

        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(
            identifier: USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
                productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "restore")!,
            transport: transport)
        await conn.restoreReturnAndMaster(helperMixer: 0, defaults: d)

        let wire = transport.setPropertyCalls.map { [UInt16($0.bRequest), $0.wValue, $0.wIndex, UInt16($0.data[0])] }
        #expect(wire == [
            // mixer ID 1: Master -12 dB, Software Return -4 dB, muted, soloed
            [0xB0, 1, 33, 36], [0xB0, 1, 32, 44], [0xB3, 1, 32, 1], [0xB2, 1, 32, 1],
            // mixer ID 2: Master -6 dB, Software Return -20 dB (a non-default source too)
            [0xB0, 2, 33, 42], [0xB0, 2, 32, 28], [0xB3, 2, 32, 1], [0xB2, 2, 32, 1],
        ])
        // The helper's level and mute are neutral; pan is as saved.
        #expect(transport.swReturnLevelCalls == [0])
        #expect(transport.swReturnMuteCalls == [false])
        #expect(transport.swReturnPanCalls == [0.5])
        for call in transport.setPropertyCalls {
            #expect(![1000, 2000, 0x1001, 0x1002, 0x2001, 0x2002].contains(call.wIndex))
        }
    }

    @Test("unlinked faders: louder side to the unit, difference to the helper; Master takes the quieter")
    func unlinkedPlan() {
        let d = defaults("USBMixerRestoreTests.unlinked")
        save(d, swReturn: MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false))
        d.set(false, forKey: "mixerSWReturnFadersLinked")
        d.set(false, forKey: "mixerMasterFadersLinked")
        for m in 0..<2 {
            d.set(-3.0, forKey: "mixerSWReturnLeftLevel_\(m)"); d.set(-9.0, forKey: "mixerSWReturnRightLevel_\(m)")
            d.set(-2.0, forKey: "mixerMasterLeftLevel_\(m)"); d.set(-5.0, forKey: "mixerMasterRightLevel_\(m)")
            d.set(0.0, forKey: "mixerMasterLevel_\(m)")
        }
        let steps = USBMixerRestorePlan.steps(for: .load(defaults: d), helperMixer: 1)
        // Only per-side gains: a level message first would let the quieter
        // side play at 0 dB until the second message arrived.
        #expect(steps.first == .helperGain(.sides(left: 0, right: -6)))
        #expect(steps.contains(.helperMute(false)))
        for m: UInt32 in [1, 2] {
            #expect(steps.contains(.hardware(
                PropertyAddress(selector: .mixerChannelLevel, element: (m << 16) | 33), .float64(-5))))
            #expect(steps.contains(.hardware(
                PropertyAddress(selector: .mixerChannelLevel, element: (m << 16) | 32), .float64(-3))))
        }
    }

    @Test("unlinked restore sends only per-side gains to the helper, never a level that resets both")
    func unlinkedHelperMessages() async {
        let d = defaults("USBMixerRestoreTests.helperMessages")
        save(d, swReturn: MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false))
        d.set(false, forKey: "mixerSWReturnFadersLinked")
        d.set(0, forKey: "mixerSoftwareReturnSource_0")
        d.set(-3.0, forKey: "mixerSWReturnLeftLevel_0"); d.set(-9.0, forKey: "mixerSWReturnRightLevel_0")
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(
            identifier: USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
                productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "restore2")!,
            transport: transport)
        await conn.restoreReturnAndMaster(helperMixer: 0, defaults: d)
        #expect(transport.swReturnLevelCalls.isEmpty)
        #expect(transport.swReturnChannelLevelCalls.map { [Double($0.channel), $0.dB] } == [[0, 0], [1, -6]])
        // The unit's Software Return fader gets the louder side (-3 dB).
        #expect(transport.setPropertyCalls.contains { $0.wValue == 1 && $0.wIndex == 32 && $0.bRequest == 0xB0 && $0.data == Data([45]) })
    }

    @Test("a split with differing sides yields only side gains; equal sides yield neutral")
    func helperGainDecision() {
        #expect(MixerFaderMath.softwareReturn(left: -3, right: -9, linked: false, linkedLevel: 0).helperGain
                == .sides(left: 0, right: -6))
        #expect(MixerFaderMath.softwareReturn(left: -3, right: -3, linked: false, linkedLevel: 0).helperGain == .neutral)
        #expect(MixerFaderMath.softwareReturn(left: -3, right: -9, linked: true, linkedLevel: -3).helperGain == .neutral)
    }

    @Test("neutral defaults when nothing is saved")
    func nothingSaved() {
        let d = defaults("USBMixerRestoreTests.empty")
        let steps = USBMixerRestorePlan.steps(for: .load(defaults: d), helperMixer: 0)
        #expect(steps.first == .helperGain(.neutral))
        #expect(steps.contains(.helperMute(false)))
        #expect(steps.contains(.helperPan(0)))
        let hardware = steps.compactMap { step -> (UInt32, PropertyValue)? in
            if case .hardware(let a, let v) = step { return (a.element, v) } else { return nil }
        }
        #expect(hardware.count == 8)
        #expect(hardware.allSatisfy { [32, 33].contains($0.0 & 0xFFFF) })
    }
}
