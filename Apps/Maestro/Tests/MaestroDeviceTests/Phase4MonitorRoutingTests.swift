import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

// MARK: - Speaker output mode

/// The speaker popup is Speaker Output **Mode** (`0x25`), not a source selector,
/// and its legal IDs are non-contiguous: 0, 2, 6, 8, 9, 10
/// (`SymphonyIOVendorSpecific.h:967-975`). Two separate failures are pinned here:
///
/// 1. The selector had **no case in either switch** of the mapper, so every write
///    was discarded as `.unsupportedProperty` before reaching the wire and every
///    read threw. The popup was inert no matter what it sent.
/// 2. Sending a popup row index instead of the ID silently picks a neighbour —
///    row 2 is "2 Speaker Sets" but the value 2 is Stereo.
@Suite("Speaker output mode wire encoding")
struct SpeakerOutputModeWireTests {

    @Test("Legal IDs are 0, 2, 6, 8, 9, 10 — nothing else")
    func legalIDs() {
        #expect(SymphonyIOSpeakerMode.allCases.map(\.rawValue) == [0, 2, 6, 8, 9, 10])
        for illegal: UInt8 in [1, 3, 4, 5, 7, 11, 12, 255] {
            #expect(SymphonyIOSpeakerMode(rawValue: illegal) == nil,
                    "\(illegal) is not a speaker mode")
        }
    }

    @Test("0 is Off, not Line")
    func zeroIsOff() {
        // eSymphonyIOSpeakerOutputMode_Off = 0 (SymphonyIOVendorSpecific.h:969),
        // cross-checked against eMainOutControls_None = 0x00 (mAEstro.h:542).
        #expect(SymphonyIOSpeakerMode(rawValue: 0) == .off)
    }

    @Test("Write sends the ID in pData[0] with wValue and wIndex zero")
    func writeWireFormat() throws {
        for mode in SymphonyIOSpeakerMode.allCases {
            let req = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .speakerOutputMode),
                value: .uint32(UInt32(mode.rawValue)))
            #expect(req.direction == .write)
            #expect(req.request == SymphonyIOCommand.speakerOutputMode.rawValue)
            #expect(req.request == 0x25)
            #expect(req.value == 0, "SendRequest(true, SpeakerOutputMode, 0, ...) — nValue is 0")
            #expect(req.index == 0)
            #expect(req.data == Data([mode.rawValue]),
                    "\(mode) must put its ID in pData[0], got \([UInt8](req.data))")
        }
    }

    @Test("A popup row index is rejected, not truncated onto a neighbouring mode")
    func rowIndexRejected() {
        // Row indices 1, 3, 4, 5 are not mode IDs. Before this change the value
        // reached the wire unchecked once a write case existed at all.
        for rowIndex: UInt32 in [1, 3, 4, 5, 7, 11] {
            #expect(throws: DeviceConnectionError.self) {
                _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: .speakerOutputMode),
                    value: .uint32(rowIndex))
            }
        }
    }

    @Test("Read uses the same opcode and asks for one byte")
    func readWireFormat() throws {
        let req = try SymphonyIOPropertyMapper.buildReadRequest(
            for: PropertyAddress(selector: .speakerOutputMode))
        #expect(req.direction == .read)
        #expect(req.request == 0x25)
        #expect(req.value == 0)
        #expect(req.index == 0)
        #expect(req.data.count == 1)
    }

    @Test("Read decodes the raw mode ID, not an index")
    func readDecodes() throws {
        let decoded = try SymphonyIOPropertyMapper.decodeResponse(
            USBControlResponse(data: Data([9]), bytesTransferred: 1),
            for: PropertyAddress(selector: .speakerOutputMode))
        #expect(decoded.asUInt32 == 9, "9 is 2 Speaker Sets, not row 9")
    }

    @Test("Speaker set count comes from the mode, not the row")
    func speakerSetCount() {
        #expect(SymphonyIOSpeakerMode.stereo.speakerSetCount == 1)
        #expect(SymphonyIOSpeakerMode.twoSpeakerSets.speakerSetCount == 2)
        #expect(SymphonyIOSpeakerMode.threeSpeakerSets.speakerSetCount == 3)
    }
}

// MARK: - Headphone source IDs and crosspoints

/// The headphone Output Source is a two-step operation:
/// `0x54` stores the choice ("opaque for the firmware",
/// `SymphonyIOVendorSpecific.h:274-276`) and a `0x31` crosspoint write to
/// destinations 224-227 makes it audible (`SymphonyIO_Stream.cpp:756-805`).
///
/// These tests pin the exact destinations — not just the opcode and payload
/// shape. The Dim/Sum regression passed its tests precisely because they checked
/// opcode and payload but never *which* destination the index addressed.
@Suite("Headphone source routing")
struct HeadphoneSourceRoutingTests {

    @Test("Source IDs are output-pair indices 0-15, board 0 then board 1")
    func sourceIDRange() {
        #expect(SymphonyIOHeadphoneRouting.pairsPerBoard == 8)
        #expect(SymphonyIOHeadphoneRouting.maximumSourceID == 15)
        for id: UInt32 in 0...15 {
            #expect(SymphonyIOHeadphoneRouting.isValidSourceID(id))
        }
        for id: UInt32 in [16, 17, 23, 37, 255] {
            #expect(!SymphonyIOHeadphoneRouting.isValidSourceID(id),
                    "\(id) cannot fit a 4-bit 0x54 nibble")
        }
    }

    @Test("Decomposition puts IDs 0-7 on board 0 and 8-15 on board 1")
    func decomposition() {
        let expected: [(UInt32, Int, Int)] = [
            (0, 0, 0), (3, 0, 3), (4, 0, 4), (7, 0, 7),
            (8, 1, 0), (11, 1, 3), (15, 1, 7)
        ]
        for (id, board, pair) in expected {
            let got = SymphonyIOHeadphoneRouting.decompose(sourceID: id)
            #expect(got?.board == board, "ID \(id) board")
            #expect(got?.pair == pair, "ID \(id) pair")
        }
        #expect(SymphonyIOHeadphoneRouting.decompose(sourceID: 16) == nil)
    }

    @Test("A source ID names the hardware output pair whose route is inherited")
    func outputPairDestinations() {
        // IOBoard0Ch0 = 32, IOBoard1Ch0 = 48 (SymphonyIORouting.h:187, :206).
        let expected: [(UInt32, UInt8, UInt8)] = [
            (0, 32, 33), (1, 34, 35), (3, 38, 39),
            (4, 40, 41), (7, 46, 47),
            (8, 48, 49), (11, 54, 55), (15, 62, 63)
        ]
        for (id, left, right) in expected {
            let got = SymphonyIOHeadphoneRouting.outputPairDestinations(sourceID: id)
            #expect(got?.left == left, "ID \(id) left destination")
            #expect(got?.right == right, "ID \(id) right destination")
        }
        #expect(SymphonyIOHeadphoneRouting.outputPairDestinations(sourceID: 16) == nil)
    }

    @Test("Headphone crosspoint destinations are 224/225 and 226/227")
    func headphoneDestinations() {
        let hp1 = SymphonyIOHeadphoneRouting.headphoneDestinations(.headphone1)
        let hp2 = SymphonyIOHeadphoneRouting.headphoneDestinations(.headphone2)
        #expect(hp1 == (224, 225))
        #expect(hp2 == (226, 227))
        // The regression shape to guard: addressing the wrong jack. HP2 must never
        // land on HP1's destinations.
        #expect(hp2.left != hp1.left)
        #expect(hp2.left != hp1.right)
    }

    @Test("Crosspoint write is one 0x31 transfer of [dest, src] pairs")
    func crosspointWireFormat() {
        let req = SymphonyIORequestBuilder.setHeadphoneCrosspoint(
            headphone: .headphone2, leftSource: 196, rightSource: 197)
        #expect(req.direction == .write)
        #expect(req.request == SymphonyIOCommand.audioRouting.rawValue)
        #expect(req.request == 0x31)
        #expect(req.value == 0, "0x31 write documents nValue as unused, set to zero")
        #expect(req.index == 0)
        #expect(req.data == Data([226, 196, 227, 197]),
                "payload is (dest, src) pairs: HP2 L/R from P2P ch4/ch5")
    }

    @Test("HP1 and HP2 crosspoints do not collide")
    func crosspointsDistinct() {
        let a = SymphonyIORequestBuilder.setHeadphoneCrosspoint(
            headphone: .headphone1, leftSource: 192, rightSource: 193)
        let b = SymphonyIORequestBuilder.setHeadphoneCrosspoint(
            headphone: .headphone2, leftSource: 192, rightSource: 193)
        #expect(a.data == Data([224, 192, 225, 193]))
        #expect(b.data == Data([226, 192, 227, 193]))
        #expect(a.data != b.data)
    }

    @Test("The 0x54 storage write rejects IDs that cannot fit a nibble")
    func storageRejectsOversizedIDs() {
        // The old Ensemble-style list offered 17, 23, 25 … 37. Masking turned 17
        // into 1 — "Optical 7-8" silently became "Line 1-2".
        for id: UInt32 in [16, 17, 23, 25, 37] {
            #expect(throws: DeviceConnectionError.self) {
                _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: .headphone1RoutingID), value: .uint32(id))
            }
            #expect(throws: DeviceConnectionError.self) {
                _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: .headphone2RoutingID), value: .uint32(id))
            }
        }
    }

    @Test("The 0x54 storage write packs HP1 low and HP2 high, preserving the sibling")
    func storagePacking() throws {
        let hp1 = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .headphone1RoutingID), value: .uint32(5))
        #expect(hp1.request == SymphonyIOCommand.headphoneAssignments.rawValue)
        #expect(hp1.request == 0x54)
        #expect(hp1.value == 0)
        #expect(hp1.index == 0)
        #expect(hp1.data.count == 1)
        #expect(hp1.data[0] & 0x0F == 5, "HP1 occupies the low nibble")

        let hp2 = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .headphone2RoutingID), value: .uint32(9))
        #expect(hp2.data[0] & 0x0F == 5, "HP1's nibble must survive an HP2 write")
        #expect((hp2.data[0] >> 4) & 0x0F == 9, "HP2 occupies the high nibble")
    }
}

// MARK: - Front panel meter bank

/// `wValue` picks the physical LED bank; `pData[0]` picks which channel octet
/// that bank shows. Conflating them is the trap — a builder that always sent
/// `pData[0] = 0` pinned both banks to Analog Out 1-8 and made channels 9-16
/// unreachable by construction.
///
/// Evidence: `SymphonyIOVendorSpecific.h:45-49`, `mAEstroTypes.h:17-39`.
@Suite("Front panel meter bank encoding")
struct FrontPanelMeterBankTests {

    @Test("Source values match eMaestroEnum_MetersShowValues exactly")
    func sourceValues() {
        #expect(SymphonyIOFrontPanelMeterSource.analogOutput1to8.rawValue == 0)
        #expect(SymphonyIOFrontPanelMeterSource.analogInput1to8.rawValue == 1)
        #expect(SymphonyIOFrontPanelMeterSource.digitalOutput1to8.rawValue == 2)
        #expect(SymphonyIOFrontPanelMeterSource.digitalInput1to8.rawValue == 3)
        #expect(SymphonyIOFrontPanelMeterSource.analogOutput9to16.rawValue == 4)
        #expect(SymphonyIOFrontPanelMeterSource.analogInput9to16.rawValue == 5)
        #expect(SymphonyIOFrontPanelMeterSource.digitalOutput25to32.rawValue == 14)
        #expect(SymphonyIOFrontPanelMeterSource.digitalInput25to32.rawValue == 15)
        #expect(SymphonyIOFrontPanelMeterSource.allCases.count == 16)
    }

    @Test("Analog Out 9-16 is payload 4 — the value a hardcoded 0 makes unreachable")
    func analogOut9to16IsFour() {
        #expect(SymphonyIOFrontPanelMeterSource.analogOutput9to16.rawValue == 4)
        #expect(SymphonyIOFrontPanelMeterSource.make(analog: true, input: false, octetIndex: 1)
                == .analogOutput9to16)
    }

    @Test("The three axes decompose consistently for every value")
    func axes() {
        for source in SymphonyIOFrontPanelMeterSource.allCases {
            let rebuilt = SymphonyIOFrontPanelMeterSource.make(
                analog: source.isAnalog, input: source.isInput, octetIndex: source.octetIndex)
            #expect(rebuilt == source, "\(source) failed to round-trip through its axes")
            #expect(source.firstChannel == source.octetIndex * 8 + 1)
        }
        #expect(SymphonyIOFrontPanelMeterSource.make(analog: true, input: true, octetIndex: 4) == nil)
    }

    @Test("Bank goes in wValue and the octet in pData[0] — independently")
    func bankAndSourceAreIndependent() {
        // Third tuple element is the expected wINDEX (not wValue): the bank is the
        // low half of legacy's nValue. See USBControlRequest.value for the split.
        let cases: [(SymphonyIOFrontPanelMeterBank, SymphonyIOFrontPanelMeterSource, UInt16, UInt8)] = [
            (.left,  .analogOutput1to8,  0, 0),
            (.left,  .analogOutput9to16, 0, 4),   // bank 1 CAN show the 9-16 octet
            (.right, .analogOutput1to8,  1, 0),   // bank 2 CAN show the 1-8 octet
            (.right, .analogOutput9to16, 1, 4),
            (.right, .analogInput1to8,   1, 1)
        ]
        for (bank, source, expectedIndex, expectedPayload) in cases {
            let req = SymphonyIORequestBuilder.setFrontPanelMeterShow(bank: bank, source: source)
            #expect(req.direction == .write)
            #expect(req.request == SymphonyIOCommand.frontPanelMeterShow.rawValue)
            #expect(req.request == 0x10)
            #expect(req.value == 0, "wValue is the high half of nValue and must be 0")
            #expect(req.index == expectedIndex, "wIndex is the LED bank")
            #expect(req.data == Data([expectedPayload]), "pData[0] is the channel octet")
        }
    }

    @Test("'AEmi' bank elements are 1-based and must not be double-decremented")
    func bankElementMapping() {
        // m_aMeterShow[nChan-1] — SymphonyIO.cpp:2574-2619.
        #expect(SymphonyIOFrontPanelMeterBank(propertyElement: 1) == .left)
        #expect(SymphonyIOFrontPanelMeterBank(propertyElement: 2) == .right)
        // Element 0 is tolerated as bank 1 for callers that already converted.
        #expect(SymphonyIOFrontPanelMeterBank(propertyElement: 0) == .left)
        #expect(SymphonyIOFrontPanelMeterBank(propertyElement: 3) == nil)
    }

    @Test("The 0x10 write reaches hardware by default, in the legacy shape")
    func writeIsSentByDefault() throws {
        // Hardware-confirmed 2026-09-11: the panel follows this request and EP0
        // keeps serving vendor reads afterwards. Unless the kill switch is set --
        // MAESTRO_ALLOW_FRONT_PANEL_METER_WRITE is unset (the default) -- the mapper must build it
        // rather than swallow it as cacheOnly, which is what made the Front Panel
        // pickers move without anything happening on the unit.
        guard SymphonyIOPropertyMapper.allowFrontPanelMeterWrites else {
            #expect(throws: DeviceConnectionError.cacheOnly(.metersShowInput)) {
                _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: .metersShowInput, element: 1), value: .uint32(4))
            }
            return
        }

        // Bank 2 (element 2 -> wValue 1) showing Analog Out 9-16 (payload 4).
        // Payload 4 is the case the old hardcoded pData[0] = 0 could never reach.
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .metersShowInput, element: 2), value: .uint32(4))
        #expect(request.direction == .write)
        #expect(request.request == SymphonyIOCommand.frontPanelMeterShow.rawValue)
        // wValue is the HIGH half of legacy's nValue and is always 0 for a
        // single-digit bank; the bank itself rides in wIndex. Sending it the other
        // way round is what wedged EP0 3-for-3 (fixed in 95668ac). This assertion
        // was wrong and went unnoticed because the gate above returned early.
        #expect(request.value == 0)
        #expect(request.index == SymphonyIOFrontPanelMeterBank.right.rawValue)
        #expect(request.data == Data([SymphonyIOFrontPanelMeterSource.analogOutput9to16.rawValue]))

        // Bank 1 is the transition that was watched on the panel: Analog In 1-8
        // (payload 1) to Analog Out 1-8 (payload 0), both on wValue 0.
        let bank1 = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .metersShowInput, element: 1), value: .uint32(0))
        #expect(bank1.value == SymphonyIOFrontPanelMeterBank.left.rawValue)
        #expect(bank1.data == Data([SymphonyIOFrontPanelMeterSource.analogOutput1to8.rawValue]))
    }

    @Test("An out-of-range bank or source is rejected before the cache-only check")
    func invalidInputsRejected() {
        #expect(throws: DeviceConnectionError.self) {
            _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .metersShowInput, element: 7), value: .uint32(4))
        }
        #expect(throws: DeviceConnectionError.self) {
            _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .metersShowInput, element: 1), value: .uint32(16))
        }
    }

    @Test("Readback goes through 0xDE, because the 0x10 read is disabled in firmware")
    func readbackUses0xDE() throws {
        let req = try SymphonyIOPropertyMapper.buildReadRequest(
            for: PropertyAddress(selector: .metersShowInput, element: 1))
        #expect(req.direction == .read)
        #expect(req.request == SymphonyIOCommand.getCurrentPreferenceSettings.rawValue)
        #expect(req.request == 0xDE)
        #expect(req.data.count == 4, "SymphonyIOSettings is 4 bytes")
    }

    @Test("0xDE bytes 0 and 1 are bank 1 and bank 2")
    func readbackDecoding() throws {
        // metersShow1 = Analog In 1-8 (1), metersShow2 = Analog Out 9-16 (4).
        let payload = Data([1, 4, 0, 2])
        let bank1 = try SymphonyIOPropertyMapper.decodeResponse(
            USBControlResponse(data: payload, bytesTransferred: 4),
            for: PropertyAddress(selector: .metersShowInput, element: 1))
        let bank2 = try SymphonyIOPropertyMapper.decodeResponse(
            USBControlResponse(data: payload, bytesTransferred: 4),
            for: PropertyAddress(selector: .metersShowInput, element: 2))
        #expect(bank1.asUInt32 == 1)
        #expect(bank2.asUInt32 == 4)

        let settings = SymphonyIOPreferenceSettings(data: payload)
        #expect(settings?.meterSourceBank1 == .analogInput1to8)
        #expect(settings?.meterSourceBank2 == .analogOutput9to16)
        #expect(settings?.oversHoldMode == 0)
        #expect(settings?.peakHoldMode == 2)
        #expect(SymphonyIOPreferenceSettings(data: Data([1, 2, 3])) == nil)
    }
}

// MARK: - Reset

/// Reset must not reach for `0xC2`. On a USB Symphony the daemon computes the
/// default table in software and writes ordinary `0x31` pairs; only the PCIe
/// controller issues the firmware reset, whose flat 1:1 map is not board-aware
/// and would re-point optical destinations.
@Suite("Routing reset")
struct RoutingResetTests {

    @Test("'AEt2' is not wired to opcode 0xC2")
    func resetRoutingIsNotMappedToC2() {
        #expect(throws: DeviceConnectionError.self) {
            _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .resetRouting), value: .uint32(1))
        }
    }

    @Test("Monitor defaults match SymphonyIO::ResetToDefaults")
    func monitorDefaults() {
        #expect(SymphonyIOMonitorDefaults.levelAttenuationDB == 20)
        #expect(SymphonyIOMonitorDefaults.muted == false)
        #expect(SymphonyIOMonitorDefaults.dimmed == false)
        #expect(SymphonyIOMonitorDefaults.summedToMono == false)
        #expect(SymphonyIOMonitorDefaults.peakHoldMode == 0)
        #expect(SymphonyIOMonitorDefaults.oversHoldMode == 0)
        // Stereo iff the unit has at least two analog outputs (SymphonyIO.cpp:1588-1595).
        #expect(SymphonyIOMonitorDefaults.speakerMode(analogOutputChannels: 16) == .stereo)
        #expect(SymphonyIOMonitorDefaults.speakerMode(analogOutputChannels: 2) == .stereo)
        #expect(SymphonyIOMonitorDefaults.speakerMode(analogOutputChannels: 0) == .off)
    }

    @Test("Front-panel bank defaults are asymmetric — input on 1, output on 2")
    func frontPanelDefaults() {
        // ResetMeterSourceToDefault, SymphonyIO.cpp:1702-1724.
        #expect(SymphonyIOMonitorDefaults.meterSourceBank1(hasAnalogInputs: true) == .analogInput1to8)
        #expect(SymphonyIOMonitorDefaults.meterSourceBank1(hasAnalogInputs: false) == .digitalInput1to8)
        #expect(SymphonyIOMonitorDefaults.meterSourceBank2(hasAnalogOutputs: true) == .analogOutput1to8)
        #expect(SymphonyIOMonitorDefaults.meterSourceBank2(hasAnalogOutputs: false) == .digitalOutput1to8)

        // The wire values the Device Settings pickers seed themselves with before
        // the 0xDE read lands. They are written as bare numbers there because a
        // SwiftUI @State initializer cannot reach MaestroDevice; pinning them here
        // is what keeps those numbers honest. A seed of 0 on bank 1 would show
        // analog OUTPUT on the left column -- the daemon's initializer does not.
        // Evidence: og_source/maestrolink/Software/SymphonyIO.cpp:181-182.
        #expect(SymphonyIOFrontPanelMeterSource.analogInput1to8.rawValue == 1)
        #expect(SymphonyIOFrontPanelMeterSource.analogOutput1to8.rawValue == 0)
    }

    @Test("Trims are calibration data and survive the default scope")
    func resetScopes() {
        #expect(SymphonyIOResetScope.allButCalibration.resetsTrims == false)
        #expect(SymphonyIOResetScope.all.resetsTrims == true)
    }
}

// MARK: - Routing address constants

@Suite("Routing address constants")
struct RoutingAddressTests {

    @Test("Destination bases match SymphonyIORouting.h")
    func destinationBases() {
        #expect(SymphonyIORoutingAddress.ioBoard0Base == 32)
        #expect(SymphonyIORoutingAddress.ioBoard1Base == 48)
        #expect(SymphonyIORoutingAddress.mixer0Base == 64)
        #expect(SymphonyIORoutingAddress.mixer1Base == 96)
        #expect(SymphonyIORoutingAddress.p2pBase == 192)
        #expect(SymphonyIORoutingAddress.headphone1Base == 224)
        #expect(SymphonyIORoutingAddress.headphone2Base == 226)
        #expect(SymphonyIORoutingAddress.mixer0AppInputBase == 228)
        #expect(SymphonyIORoutingAddress.mixer1AppInputBase == 230)
        #expect(SymphonyIORoutingAddress.channelsPerIOBoard == 16)
    }

    @Test("Silence (236) and clear-route (0xFF) are different things")
    func silenceVersusClear() {
        // eSymphonyIORoutingSource_None = 236 is what ResetOutputRouting pre-fills;
        // 0xFF is the opcode-0x31 payload sentinel that mutes a destination.
        #expect(SymphonyIORoutingAddress.none == 236)
        #expect(SymphonyIORoutingAddress.clearRoute == 0xFF)
        #expect(SymphonyIORoutingAddress.none != SymphonyIORoutingAddress.clearRoute)
    }
}

// MARK: - Default routing tables

/// `ResetOutputRouting` / `ResetInputRouting`
/// (`SymphonyIOUSBAudioRoutingController.cpp:623-712`, `:714-812`) walk **all
/// analog channels across both boards first, then all digital channels**,
/// assigning one running USB channel counter. Two things this pins:
///
/// - it is not a diagonal, and it is certainly not the dual map (every DAW pair
///   driving both boards) the app used to write on Reset Routing;
/// - destinations with no channel behind them stay at silence (236), not clamped
///   onto a neighbour.
///
/// The analog-before-digital order is what keeps an Analog+Optical unit's ADAT
/// destinations on the USB channels the user expects.
@Suite("Default routing tables")
struct DefaultRoutingTableTests {

    private func source(_ routes: [SymphonyIODefaultRouting.Route], destination: UInt8) -> UInt8? {
        routes.first { $0.destination == destination }?.source
    }

    @Test("Output: Analog+Optical in slot 0, nothing in slot 1")
    func outputAnalogOpticalOnly() {
        // Board 0 = 8 analog out + 8 optical out. Board destinations 32-39 are the
        // analog channels, 40-47 the optical ones (analog first within a board).
        let routes = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 0, digital: 0),
            usbChannelCount: 16)

        #expect(routes.count == 32, "both boards' 16 destinations are always written")
        for channel in 0..<8 {
            #expect(source(routes, destination: 32 + UInt8(channel)) == 192 + UInt8(channel),
                    "analog out \(channel) ← P2P ch\(channel)")
        }
        for channel in 0..<8 {
            #expect(source(routes, destination: 40 + UInt8(channel)) == 200 + UInt8(channel),
                    "optical out \(channel) ← P2P ch\(channel + 8)")
        }
        for destination in UInt8(48)...UInt8(63) {
            #expect(source(routes, destination: destination) == SymphonyIORoutingAddress.none,
                    "empty slot 1 destination \(destination) stays silent")
        }
    }

    @Test("Output: analog on BOTH boards is consumed before any digital")
    func outputAnalogBeforeDigitalAcrossBoards() {
        // Board 0 = Analog+Optical (8/8), board 1 = AnalogDA16 (16 analog out).
        // Legacy assigns board0 analog 0-7, then board1 analog 8-15 (wrapping the
        // 16-channel USB counter), and only then board0's optical.
        let routes = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 16, digital: 0),
            usbChannelCount: 16)

        #expect(source(routes, destination: 32) == 192, "board0 analog ch0 ← P2P ch0")
        #expect(source(routes, destination: 39) == 199, "board0 analog ch7 ← P2P ch7")
        #expect(source(routes, destination: 48) == 200, "board1 analog ch0 ← P2P ch8")
        #expect(source(routes, destination: 55) == 207, "board1 analog ch7 ← P2P ch15")
        // Counter wraps modulo the USB channel count, exactly as legacy does.
        #expect(source(routes, destination: 56) == 192, "board1 analog ch8 wraps to P2P ch0")
        // Digital comes last, after every analog channel on both boards.
        #expect(source(routes, destination: 40) == 200,
                "board0 optical ch0 is assigned after ALL analog, wrapping to P2P ch8")
    }

    @Test("Output: it is NOT the dual map we used to write")
    func outputIsNotDual() {
        let routes = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 0, digital: 0),
            usbChannelCount: 16)
        // The old reset drove board 0 ch0 and board 1 ch0 from the same DAW pair.
        let board0 = source(routes, destination: 32)
        let board1 = source(routes, destination: 48)
        #expect(board0 != board1 || board1 == SymphonyIORoutingAddress.none,
                "each hardware output gets its own USB channel")
    }

    @Test("Input: P2P destinations, analog first, unmapped channels silent")
    func inputRouting() {
        // Board 0 = Analog+Optical (8 analog in, 8 optical in), slot 1 empty.
        let routes = SymphonyIODefaultRouting.inputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 0, digital: 0),
            usbChannelCount: 16)

        #expect(routes.count == 16)
        for channel in 0..<8 {
            #expect(source(routes, destination: 192 + UInt8(channel)) == 32 + UInt8(channel),
                    "USB record ch\(channel) ← board0 analog in \(channel)")
        }
        for channel in 0..<8 {
            #expect(source(routes, destination: 200 + UInt8(channel)) == 40 + UInt8(channel),
                    "USB record ch\(channel + 8) ← board0 optical in \(channel)")
        }
        // Every destination is a P2P byte — input reset can never touch a hardware
        // output, ADAT included.
        for route in routes {
            #expect(route.destination >= SymphonyIORoutingAddress.p2pBase)
        }
    }

    @Test("Input: software channels with no hardware behind them are silent, not clamped")
    func inputLeavesSurplusSilent() {
        // A 16-channel USB mode on a unit with only 8 analog inputs.
        let routes = SymphonyIODefaultRouting.inputRoutes(
            board0: .init(analog: 8, digital: 0),
            board1: .init(analog: 0, digital: 0),
            usbChannelCount: 16)
        for channel in 8..<16 {
            #expect(source(routes, destination: 192 + UInt8(channel)) == SymphonyIORoutingAddress.none,
                    "USB record ch\(channel) has no hardware source — stays at 236")
        }
    }

    /// The grid a 2x16 unit draws with no user edits, checked against the real
    /// thing. Columns on the dev unit: 24 analog line inputs then ADAT 1-8, so
    /// board 0 is 16 analog and board 1 is 8 analog + 8 digital.
    ///
    /// Only 8 software pairs get a source because `usbChannelCount` is 16 and
    /// always 16 — the FPGA's P2P block is bytes 192-207. Rows 17-32 staying
    /// empty is the correct answer, not a missing one.
    @Test("Input default on a 32-in unit is the diagonal, first 16 channels only")
    func inputDefaultIsDiagonalOnDevUnit() {
        let routes = SymphonyIODefaultRouting.inputRoutes(
            board0: .init(analog: 16, digital: 0),
            board1: .init(analog: 8, digital: 8),
            usbChannelCount: SymphonyIODefaultRouting.usbChannelCount)
        for channel in 0..<16 {
            #expect(source(routes, destination: 192 + UInt8(channel)) == 32 + UInt8(channel),
                    "software in \(channel + 1) <- Line \(channel + 1)")
        }
        #expect(routes.count == 16, "no destination past P2P 207 is ever written")
    }

    /// The output twin, same unit: 8 analog outs + ADAT 1-8 on board 0, ADAT
    /// 9-24 on board 1. Board 1 is 16 wide but the source counter wraps at 16,
    /// so ADAT 9-24 repeat software 1-16 — the dual routing the grid draws as a
    /// second X on every row.
    @Test("Output default on a 2x16 unit: analog first, then board 1 repeats")
    func outputDefaultDualRoutesOnDevUnit() {
        let routes = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 0, digital: 16),
            usbChannelCount: SymphonyIODefaultRouting.usbChannelCount)
        for channel in 0..<16 {
            #expect(source(routes, destination: 32 + UInt8(channel)) == 192 + UInt8(channel),
                    "board0 out \(channel) <- software \(channel + 1)")
            #expect(source(routes, destination: 48 + UInt8(channel)) == 192 + UInt8(channel),
                    "board1 out \(channel) <- software \(channel + 1), the second X")
        }
    }

    @Test("Output reset never writes a headphone, mixer or metering destination")
    func outputResetStaysOnBoardDestinations() {
        let routes = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 16, digital: 0),
            board1: .init(analog: 8, digital: 8),
            usbChannelCount: 32)
        for route in routes {
            #expect(route.destination >= SymphonyIORoutingAddress.ioBoard0Base)
            #expect(route.destination < SymphonyIORoutingAddress.ioBoard1Base + 16)
        }
    }
}

// MARK: - Headphone crosspoint source resolution (never from the wire)

/// The old incorrectly encoded `0x31` read returned `0x20`
/// for all 80 destinations 32-191, including DAC L/R which are demonstrably
/// mixer-fed (`Docs/issue-1-research.md`). Byte 32 in SOURCE space is IOBoard0
/// input ch0 — analog input 1. Inheriting it would swap a headphone from the DAW
/// mix to a mono analog input, i.e. silence with nothing plugged in.
/// Correctly placing destination in wIndex now reads distinct routes; these
/// tests retain the independent cache-validation contract for headphone routing.
///
/// Legacy never reads hardware for this either: `RouteHeadphones`
/// (`SymphonyIO_Stream.cpp:756-805`) asks `GetRoutedToHWSource`, which returns
/// the daemon's OWN in-memory table
/// (`SymphonyIOUSBAudioRoutingController.cpp:382-396`).
@Suite("Headphone crosspoint source resolution")
struct HeadphoneCrosspointSourceTests {

    @Test("The readback residue 0x20 is refused, not written")
    func residueRefused() {
        #expect(SymphonyIOHeadphoneRouting.routeReadbackResidue == 32)
        #expect(!SymphonyIOHeadphoneRouting.isPlausibleOutputSource(32),
                "byte 32 is IOBoard0 ch0 — an INPUT, never an output-route source")
        // A cache poisoned with the residue must not be believed: the boot table
        // answers instead, and the boot table never yields 32.
        let poisoned: [UInt8: UInt8] = [40: 32, 41: 32]
        let left = SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 40, cachedRoutes: poisoned)
        let right = SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 41, cachedRoutes: poisoned)
        #expect(left != 32)
        #expect(right != 32)
        #expect(left == 200, "dest 40 falls back to the boot table: 192 + (40 - 32)")
        #expect(right == 201)
    }

    @Test("Every IOBoard byte is refused as an output-route source")
    func ioBoardBytesRefused() {
        for byte in UInt8(32)...UInt8(63) {
            #expect(!SymphonyIOHeadphoneRouting.isPlausibleOutputSource(byte),
                    "\(byte) is a hardware I/O channel, not a playback source")
        }
        #expect(!SymphonyIOHeadphoneRouting.isPlausibleOutputSource(SymphonyIORoutingAddress.none))
        #expect(!SymphonyIOHeadphoneRouting.isPlausibleOutputSource(SymphonyIORoutingAddress.clearRoute))
    }

    @Test("P2P and mixer bytes are the only plausible sources")
    func plausibleSources() {
        for byte in UInt8(192)...UInt8(223) {
            #expect(SymphonyIOHeadphoneRouting.isPlausibleOutputSource(byte))
        }
        for byte: UInt8 in [64, 65, 96, 97] {
            #expect(SymphonyIOHeadphoneRouting.isPlausibleOutputSource(byte))
        }
        for byte: UInt8 in [66, 98, 191, 224, 226, 228] {
            #expect(!SymphonyIOHeadphoneRouting.isPlausibleOutputSource(byte))
        }
    }

    @Test("An uncached destination falls back to the proxy boot table")
    func uncachedFallsBackToBootTable() {
        // Evidence: Drivers/VolumeProxy/MaestroVolumeProxy.c:1233-1276.
        // DAC L/R are mixer-fed.
        #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: 32) == 64)
        #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: 33) == 65)
        // IOBoard0 ch2-15 take USB ch2-15.
        for destination in UInt8(34)...UInt8(47) {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination)
                    == 192 + (destination - 32))
        }
        // IOBoard1 ch0-15 take USB ch0-15.
        for destination in UInt8(48)...UInt8(63) {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination)
                    == 192 + (destination - 48))
        }
        // Nothing outside the hardware output destinations has a boot entry.
        for destination: UInt8 in [0, 31, 64, 96, 192, 224, 236] {
            #expect(SymphonyIOHeadphoneRouting.bootTableSource(forDestination: destination) == nil)
        }
        // And resolution with an empty cache uses exactly that table — no read.
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 32, cachedRoutes: [:]) == 64)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 48, cachedRoutes: [:]) == 192)
    }

    @Test("A cached route wins over the boot table")
    func cacheWins() {
        let cached: [UInt8: UInt8] = [32: 194, 33: 195]
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 32, cachedRoutes: cached) == 194)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: 33, cachedRoutes: cached) == 195)
    }

    @Test("A destination with no cache entry and no boot entry resolves to nothing")
    func nothingKnownWritesNothing() {
        // Headphone and mixer app-input destinations are not hardware outputs; a
        // source ID can never name them, but the resolver must still refuse
        // rather than invent a byte.
        for destination: UInt8 in [224, 225, 228, 230, 100, 191] {
            #expect(SymphonyIOHeadphoneRouting.inheritedSource(
                forDestination: destination, cachedRoutes: [:]) == nil)
        }
    }
}

// MARK: - Reset Routing guard (H2/H3)

/// The default routing table is derived ENTIRELY from the two card types, so a
/// wrong card re-points real outputs. `AppState.readCardTypes()` keeps the
/// previous (cached) value when a live `0xA1` read fails, so the failure mode is
/// a WRONG card — never `.none`, which is all the old guard checked.
@Suite("Routing reset guard")
struct RoutingResetGuardTests {

    @Test("The owner's pair — Optical in slot 0, AD16 in slot 1 — keeps ADAT on DAW 9-16")
    func ownerCardPairPreservesADAT() {
        // Slot 0 = 8x8 OPT: 8 analog out + 8 ADAT out.
        // Slot 1 = 16 Analog In / 16 Digital Out: 0 analog out + 16 ADAT out.
        #expect(IOCardType.optical.analogOutputChannels == 8)
        #expect(IOCardType.optical.digitalOutputChannels == 8)
        #expect(IOCardType.analogAD16.analogOutputChannels == 0)
        #expect(IOCardType.analogAD16.digitalOutputChannels == 16)

        let routes = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: IOCardType.optical.analogOutputChannels,
                          digital: IOCardType.optical.digitalOutputChannels),
            board1: .init(analog: IOCardType.analogAD16.analogOutputChannels,
                          digital: IOCardType.analogAD16.digitalOutputChannels),
            usbChannelCount: SymphonyIODefaultRouting.usbChannelCount)
        var map: [UInt8: UInt8] = [:]
        for route in routes { map[route.destination] = route.source }

        // Analog out 1-8 (dest 32-39) ← DAW 1-8 (192-199).
        for channel in 0..<8 {
            #expect(map[32 + UInt8(channel)] == 192 + UInt8(channel))
        }
        // THE regression: slot 0 ADAT 1-8 (dest 40-47) ← DAW 9-16 (200-207).
        for channel in 0..<8 {
            #expect(map[40 + UInt8(channel)] == 200 + UInt8(channel),
                    "ADAT out \(channel + 1) must carry DAW \(channel + 9), not DAW \(channel + 1)")
        }
    }

    @Test("Misdetecting slot 1 as a second Optical card is what moves ADAT onto DAW 1-8")
    func misdetectionMovesADAT() {
        let wrong = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 8, digital: 8),   // slot 1 misread as another OPT
            usbChannelCount: SymphonyIODefaultRouting.usbChannelCount)
        var map: [UInt8: UInt8] = [:]
        for route in wrong { map[route.destination] = route.source }
        // Slot 0 ADAT now takes DAW 1-8 — exactly the harm the guard prevents.
        #expect(map[40] == 192)
        #expect(map[47] == 199)
    }

    @Test("The USB channel modulo is 16, not the device mode's channel count")
    func usbChannelModuloIsSixteen() {
        #expect(SymphonyIODefaultRouting.usbChannelCount == 16)

        // 8-channel mode used to wrap ADAT 1-8 back onto DAW 1-8.
        let eight = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 0, digital: 0),
            usbChannelCount: 8)
        #expect(eight.first { $0.destination == 40 }?.source == 192,
                "the bug being fixed: modulo 8 puts ADAT on DAW 1")

        // 32-channel mode used to assign P2P bytes past 207, which nothing renders.
        let thirtyTwo = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 8, digital: 8),
            usbChannelCount: 32)
        #expect(thirtyTwo.contains { $0.source > 207 && $0.source != SymphonyIORoutingAddress.none },
                "the other bug: sources above P2P ch15 are never rendered")

        // With 16, every assigned source stays inside the P2P block 192-207.
        let correct = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: 8, digital: 8),
            board1: .init(analog: 8, digital: 8),
            usbChannelCount: SymphonyIODefaultRouting.usbChannelCount)
        for route in correct where route.source != SymphonyIORoutingAddress.none {
            #expect(route.source >= 192 && route.source <= 207)
        }
    }

    @Test("A cached or unknown slot refuses the reset — .none was never the failure mode")
    func refusesOnUntrustedProvenance() {
        // Both detected: allowed.
        #expect(RoutingResetGuard.refusalReason(
            board1: .detected(.optical), board2: .detected(.analogAD16)) == nil)
        // Even a detected .none is allowed — it was measured.
        #expect(RoutingResetGuard.refusalReason(
            board1: .detected(.optical), board2: .detected(.none)) == nil)

        // One stale slot is enough to refuse, and this is the real-world case:
        // a WRONG card carried over from UserDefaults.
        let staleSlot2 = RoutingResetGuard.refusalReason(
            board1: .detected(.optical), board2: .cached(.optical))
        #expect(staleSlot2 != nil)
        #expect(staleSlot2?.contains("Slot 2") == true)
        #expect(staleSlot2?.contains("ADAT") == true, "the refusal must name the consequence")

        #expect(RoutingResetGuard.refusalReason(
            board1: .cached(.optical), board2: .detected(.analogAD16)) != nil)
        #expect(RoutingResetGuard.refusalReason(board1: .unknown, board2: .unknown) != nil)
        #expect(RoutingResetGuard.refusalReason(
            board1: BoardTypeReading(card: .optical, source: .simulated),
            board2: .detected(.analogAD16)) != nil,
                "a simulated card is not a measurement either")
    }

    @Test("The output confirmation names the cards and the concrete ADAT consequence")
    func outputConfirmationNamesADAT() {
        let lines = RoutingResetGuard.outputPlanLines(board1: .optical, board2: .analogAD16)
        let text = lines.joined(separator: "\n")
        #expect(text.contains("8x8 OPT"))
        #expect(text.contains("16 Analog In / 16 Digital Out"))
        #expect(text.contains("ADAT out 1-8 ← DAW 9-16"),
                "the ADAT consequence must be spelled out, got:\n\(text)")
        #expect(text.contains("analog out 1-8 ← DAW 1-8"))
        // Slot 1's 16 ADAT outputs wrap back to DAW 1-16.
        #expect(text.contains("ADAT out 1-16 ← DAW 1-16"))
    }

    @Test("The input confirmation states plainly that no hardware output is touched")
    func inputConfirmationStatesScope() {
        let lines = RoutingResetGuard.inputPlanLines(
            board1: .optical, board2: .analogAD16, usbChannelCount: 16)
        let text = lines.joined(separator: "\n")
        #expect(text.contains("No hardware output is touched"))
        #expect(text.contains("ADAT outputs are unaffected"))
        // Optical slot 0 gives 8 analog + 8 ADAT inputs; AD16 slot 1 gives 16
        // analog inputs. Analog is consumed across both boards before digital, so
        // the 16 USB record channels run out before any ADAT input is reached.
        #expect(text.contains("DAW in 1-8 ← Slot 1 Analog in 1-8"))
        #expect(text.contains("DAW in 9-16 ← Slot 2 Analog in 1-8"))
        // "…and what will NOT reach the DAW" — stated, not left to be discovered.
        #expect(text.contains("Slot 1 ADAT in 1-8: NOT routed to the DAW."))
        #expect(text.contains("Slot 2 Analog in 9-16: NOT routed to the DAW."))
    }

    @Test("An empty slot is described, not silently skipped")
    func emptySlotDescribed() {
        let lines = RoutingResetGuard.outputPlanLines(board1: .optical, board2: .none)
        #expect(lines.contains { $0.contains("Slot 2") && $0.contains("no card") })
    }
}
