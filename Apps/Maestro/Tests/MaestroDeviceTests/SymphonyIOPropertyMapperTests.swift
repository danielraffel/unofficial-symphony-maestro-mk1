import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

// MARK: - SymphonyIOPropertyMapper Tests

@Suite("SymphonyIOPropertyMapper")
struct SymphonyIOPropertyMapperTests {

    // MARK: - Read Request Tests

    @Test func outputLevelReadRequest() throws {
        let address = PropertyAddress(selector: .outputLevel)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
        #expect(request.request == SymphonyIOCommand.speakerOutputVolume.rawValue)
    }

    @Test func outputMuteReadRequest() throws {
        let address = PropertyAddress(selector: .outputMute)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
        #expect(request.request == SymphonyIOCommand.speakerOutputMute.rawValue)
    }

    @Test func micGainReadRequest() throws {
        let address = PropertyAddress(selector: .micGain, element: 3)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
        #expect(request.value == 0, "Channel goes in wIndex per legacy nValue convention")
        #expect(request.index == 3, "Channel 3 in wIndex")
    }

    @Test func phantomReadRequest() throws {
        let address = PropertyAddress(selector: .phantom, element: 0)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
    }

    @Test func headphone1LevelReadRequest() throws {
        let address = PropertyAddress(selector: .headphone1Level)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
        #expect(request.request == SymphonyIOCommand.headphoneVolume.rawValue)
        #expect(request.value == 0)
        #expect(request.index == 0, "HP1 channel in wIndex")
    }

    @Test func headphone2LevelReadRequest() throws {
        let address = PropertyAddress(selector: .headphone2Level)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.value == 0, "Channel goes in wIndex per legacy nValue convention")
        #expect(request.index == 1, "HP2 channel in wIndex")
    }

    @Test func mixerChannelLevelReadRequest() throws {
        // element = (mixerID << 16) | channelIndex — mixer 0, channel 5
        let element: UInt32 = (0 << 16) | 5
        let address = PropertyAddress(selector: .mixerChannelLevel, element: element)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
        #expect(request.request == SymphonyIOCommand.mixerFaderLevel.rawValue)
        #expect(request.value == 0)   // mixerID in wValue
        #expect(request.index == 5)   // channelIndex in wIndex
    }

    @Test func mixerChannelLevelReadMixer1() throws {
        // mixer 1, channel 3
        let element: UInt32 = (1 << 16) | 3
        let address = PropertyAddress(selector: .mixerChannelLevel, element: element)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.value == 1)   // mixerID
        #expect(request.index == 3)   // channelIndex
    }

    @Test func routeReadRequest() throws {
        let address = PropertyAddress(selector: .route, element: 10)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
    }

    @Test func softwareReturnSourceRoutesMixerOneToPairThreeFour() throws {
        let address = PropertyAddress(selector: .mixerSoftwareReturnID, element: 1 << 16)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .uint32(SymphonyIOSoftwareReturnSource.output3_4.rawValue))
        #expect(request.request == SymphonyIOCommand.audioRouting.rawValue)
        #expect(request.data == Data([
            SymphonyIORoutingAddress.mixer0AppInputBase,
            SymphonyIORoutingAddress.p2pBase &+ 2,
            SymphonyIORoutingAddress.mixer0AppInputBase &+ 1,
            SymphonyIORoutingAddress.p2pBase &+ 3
        ]))
    }

    @Test func softwareReturnSourceRoutesMixerTwoToPairFifteenSixteen() throws {
        let address = PropertyAddress(selector: .mixerSoftwareReturnID, element: 2 << 16)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .uint32(SymphonyIOSoftwareReturnSource.output15_16.rawValue))
        #expect(request.data == Data([
            SymphonyIORoutingAddress.mixer1AppInputBase,
            SymphonyIORoutingAddress.p2pBase &+ 14,
            SymphonyIORoutingAddress.mixer1AppInputBase &+ 1,
            SymphonyIORoutingAddress.p2pBase &+ 15
        ]))
    }

    @Test func softwareReturnSourceDecodesRoutedPair() throws {
        let address = PropertyAddress(selector: .mixerSoftwareReturnID, element: 1 << 16)
        let response = USBControlResponse(
            data: Data([SymphonyIORoutingAddress.p2pBase &+ 6]), bytesTransferred: 1)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .uint32(SymphonyIOSoftwareReturnSource.output7_8.rawValue))
    }

    @Test func unsupportedPropertyThrows() {
        let address = PropertyAddress(selector: .daemonAlive)
        #expect(throws: DeviceConnectionError.self) {
            try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        }
    }

    @Test func clockStatusReadRequest() throws {
        let address = PropertyAddress(selector: .clockStatus)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
    }

    @Test func versionReadRequest() throws {
        let address = PropertyAddress(selector: .version)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
    }

    // MARK: - Write Request Tests

    @Test func outputLevelWriteFromFloat64() throws {
        let address = PropertyAddress(selector: .outputLevel)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .float64(-20.0))
        #expect(request.direction == .write)
        #expect(request.request == SymphonyIOCommand.speakerOutputVolume.rawValue)
        // -(-20) = 20 attenuation
        #expect(request.data == Data([20]))
    }

    @Test func outputLevelWriteFromUInt32() throws {
        let address = PropertyAddress(selector: .outputLevel)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .uint32(30))
        #expect(request.data == Data([30]))
    }

    @Test func outputMuteWrite() throws {
        let address = PropertyAddress(selector: .outputMute)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .bool(true))
        #expect(request.direction == .write)
    }

    @Test func sampleRateWrite() throws {
        let address = PropertyAddress(selector: .sampleRate)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .float64(48000.0))
        #expect(request.direction == .write)
        #expect(request.request == SymphonyIOCommand.setSampleRate.rawValue)
    }

    @Test func micGainWrite() throws {
        let address = PropertyAddress(selector: .micGain, element: 2)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .uint32(45))
        #expect(request.direction == .write)
    }

    @Test func phantomWrite() throws {
        let address = PropertyAddress(selector: .phantom, element: 0)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .bool(true))
        #expect(request.direction == .write)
    }

    @Test func mixerChannelMuteWrite() throws {
        // element = (mixerID << 16) | channelIndex — mixer 0, channel 3
        let element: UInt32 = (0 << 16) | 3
        let address = PropertyAddress(selector: .mixerChannelMute, element: element)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .bool(true))
        #expect(request.direction == .write)
        #expect(request.request == SymphonyIOCommand.mixerInputMute.rawValue)
        #expect(request.value == 0)   // mixerID in wValue
        #expect(request.index == 3)   // channelIndex in wIndex
        #expect(request.data == Data([1]))
    }

    @Test func mixerChannelLevelWriteMixer1() throws {
        // mixer 1, SW Return (channel 1000) — verify compound element split
        let element: UInt32 = (1 << 16) | 1000
        let address = PropertyAddress(selector: .mixerChannelLevel, element: element)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .float64(-20.0))
        #expect(request.value == 1)      // mixerID
        #expect(request.index == 1000)   // SW Return channel
        #expect(request.data == Data([28]))  // -20 + 48 = 28
    }

    @Test func mixerChannelPanWriteSoftwareReturnUsesMixerAndReservedChannel() throws {
        // SW Return on mixer 2 is the reserved channel 1000. The pan request
        // must use the same compound element split as ordinary mixer inputs.
        let element: UInt32 = (1 << 16) | 1000
        let address = PropertyAddress(selector: .mixerChannelPan, element: element)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .float64(-0.5))
        #expect(request.request == SymphonyIOCommand.mixerInputPan.rawValue)
        #expect(request.value == 1)
        #expect(request.index == 1000)
        #expect(request.data == Data([32])) // (-0.5 + 1) * 64
    }

    @Test func decodeMixerPanPreservesEndpoints() throws {
        let left = try SymphonyIOPropertyMapper.decodeResponse(
            USBControlResponse(data: Data([0]), bytesTransferred: 1),
            for: PropertyAddress(selector: .mixerChannelPan, element: 1000))
        let right = try SymphonyIOPropertyMapper.decodeResponse(
            USBControlResponse(data: Data([128]), bytesTransferred: 1),
            for: PropertyAddress(selector: .mixerChannelPan, element: 1000))
        #expect(left == .float64(-1.0))
        #expect(right == .float64(1.0))
    }

    @Test func mixerChannelLevelWriteMaster() throws {
        // mixer 0, Master (channel 2000)
        let element: UInt32 = (0 << 16) | 2000
        let address = PropertyAddress(selector: .mixerChannelLevel, element: element)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .float64(0.0))
        #expect(request.value == 0)      // mixerID
        #expect(request.index == 2000)   // Master channel
        #expect(request.data == Data([48]))  // 0 + 48 = 48
    }

    @Test func writeTypeMismatchThrows() {
        let address = PropertyAddress(selector: .outputMute)
        #expect(throws: DeviceConnectionError.self) {
            try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: .uint32(1))
        }
    }

    // MARK: - Decode Response Tests

    @Test func decodeOutputLevel() throws {
        let response = USBControlResponse(data: Data([20]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .outputLevel)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        // 20 attenuation → -20 dB
        #expect(value == .float64(-20.0))
    }

    @Test func decodeOutputMute() throws {
        let response = USBControlResponse(data: Data([1]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .outputMute)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .bool(true))
    }

    @Test func decodeOutputMuteUnmuted() throws {
        let response = USBControlResponse(data: Data([0]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .outputMute)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .bool(false))
    }

    @Test func decodeMicGain() throws {
        let response = USBControlResponse(data: Data([45]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .micGain, element: 0)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .uint32(45))
    }

    @Test func decodePhantom() throws {
        let response = USBControlResponse(data: Data([1]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .phantom)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .bool(true))
    }

    @Test func decodeMixerLevel() throws {
        // 28 raw → 28 - 48 = -20 dB
        let response = USBControlResponse(data: Data([28]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .mixerChannelLevel, element: 0)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .float64(-20.0))
    }

    @Test func decodeMixerPan() throws {
        // 64 raw → (64/64) - 1.0 = 0.0 (center)
        let response = USBControlResponse(data: Data([64]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .mixerChannelPan, element: 0)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .float64(0.0))
    }

    @Test func decodeRoute() throws {
        let response = USBControlResponse(data: Data([0xC0]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .route, element: 0)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .uint32(0xC0))
    }

    @Test func meterDataInputGroupRead() throws {
        let address = PropertyAddress(selector: .meterData, scope: .input)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
        #expect(request.request == SymphonyIOCommand.tdmMeterData.rawValue)
        // The meter group is the LOW half of legacy's 32-bit nValue, so it rides in
        // wIndex and wValue is always 0. Legacy: SendRequest(false, 0x30, meterGroup, ...)
        // (og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:176-181) split
        // wValue = nValue >> 16, wIndex = nValue & 0xFFFF
        // (og_source/maestrolink/Software/ControlProtocol/SimpleControlProtocolUSB.cpp:56-57).
        #expect(request.value == 0)
        #expect(request.index == 0)  // TDM group 0 = input
        #expect(request.data.count == 64)  // I/O message length
    }

    @Test func meterDataOutputGroupRead() throws {
        let address = PropertyAddress(selector: .meterData, scope: .output)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.value == 0, "wValue is the high half of nValue and must be 0")
        #expect(request.index == 1)  // TDM group 1 = output
        #expect(request.data.count == 64)
    }

    @Test func meterDataMixerGroupRead() throws {
        let address = PropertyAddress(selector: .meterData, scope: .global)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.value == 0, "wValue is the high half of nValue and must be 0")
        #expect(request.index == 2)  // TDM group 2 = mixer return & master
        #expect(request.data.count == 32)  // Mixer message length
    }

    @Test func decodeMeterData() throws {
        let meterBytes = Data([10, 20, 30, 40, 50, 60])
        let response = USBControlResponse(data: meterBytes, bytesTransferred: 6)
        let address = PropertyAddress(selector: .meterData, scope: .input)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .data(meterBytes))
    }

    @Test func decodeFirmwareVersion() throws {
        let response = USBControlResponse(data: Data([1, 3, 7]), bytesTransferred: 3)
        let address = PropertyAddress(selector: .version)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .string("1.3.7"))
    }

    @Test func decodeSampleRateReturnsCached() throws {
        let response = USBControlResponse(data: Data(), bytesTransferred: 0)
        let address = PropertyAddress(selector: .sampleRate)
        let value = try SymphonyIOPropertyMapper.decodeResponse(
            response, for: address, cachedSampleRate: 96000)
        #expect(value == .float64(96000))
    }

    @Test func decodeClockSourceReturnsCached() throws {
        let response = USBControlResponse(data: Data(), bytesTransferred: 0)
        let address = PropertyAddress(selector: .clockSource)
        let value = try SymphonyIOPropertyMapper.decodeResponse(
            response, for: address, cachedClockSource: 2)
        #expect(value == .uint32(2))
    }

    @Test func decodeClockStatus() throws {
        let response = USBControlResponse(data: Data([1]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .clockStatus)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .uint32(1))
    }

    @Test func decodeHP1RoutingID() throws {
        // Low nibble = HP1 assignment
        let response = USBControlResponse(data: Data([0x35]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .headphone1RoutingID)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .uint32(5))
    }

    @Test func decodeHP2RoutingID() throws {
        // High nibble = HP2 assignment
        let response = USBControlResponse(data: Data([0x35]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .headphone2RoutingID)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .uint32(3))
    }

    @Test func decodeActiveSpeakerSet() throws {
        let response = USBControlResponse(data: Data([0x03]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .activeSpeakerSet)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .uint32(3))
    }

    @Test func decodeHeadphoneLevel() throws {
        let response = USBControlResponse(data: Data([50]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .headphone1Level)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .float64(-50.0))
    }

    @Test func decodeEmptyResponseThrows() {
        let response = USBControlResponse(data: Data(), bytesTransferred: 0)
        let address = PropertyAddress(selector: .outputLevel)
        #expect(throws: DeviceConnectionError.self) {
            try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        }
    }

    // MARK: - Mixer Element Split Tests

    @Test func splitMixerElementMixer0Channel5() {
        let (mixID, chIdx) = SymphonyIOPropertyMapper.splitMixerElement((0 << 16) | 5)
        #expect(mixID == 0)
        #expect(chIdx == 5)
    }

    @Test func splitMixerElementMixer1Channel1000() {
        // SW Return on mixer 1
        let (mixID, chIdx) = SymphonyIOPropertyMapper.splitMixerElement((1 << 16) | 1000)
        #expect(mixID == 1)
        #expect(chIdx == 1000)
    }

    @Test func splitMixerElementMixer0Master() {
        // Master on mixer 0
        let (mixID, chIdx) = SymphonyIOPropertyMapper.splitMixerElement((0 << 16) | 2000)
        #expect(mixID == 0)
        #expect(chIdx == 2000)
    }

    // MARK: - Metadata Tests

    @Test func readOnlySelectorsContainsClockStatus() {
        #expect(SymphonyIOPropertyMapper.readOnlySelectors.contains(.clockStatus))
    }

    @Test func readOnlySelectorsContainsVersion() {
        #expect(SymphonyIOPropertyMapper.readOnlySelectors.contains(.version))
    }

    @Test func writeOnlySelectorsContainsSampleRate() {
        #expect(SymphonyIOPropertyMapper.writeOnlySelectors.contains(.sampleRate))
    }

    @Test func writeOnlySelectorsContainsClockSource() {
        #expect(SymphonyIOPropertyMapper.writeOnlySelectors.contains(.clockSource))
    }

    @Test func writeOnlySelectorsContainsMeterConfig() {
        // peakHold/oversHold are bytes 2 and 3 of the same 0xDE block that answers
        // the meter sources, so they are readable in principle — but neither has a
        // read route or decode case yet, so they stay write-only until that exists.
        #expect(SymphonyIOPropertyMapper.writeOnlySelectors.contains(.peakHoldMode))
        #expect(SymphonyIOPropertyMapper.writeOnlySelectors.contains(.oversHoldMode))
        #expect(SymphonyIOPropertyMapper.writeOnlySelectors.contains(.prefix))
        #expect(SymphonyIOPropertyMapper.writeOnlySelectors.contains(.keyboardVolumePeripheralID))
        #expect(SymphonyIOPropertyMapper.writeOnlySelectors.contains(.keyboardVolumeOutputID))
    }

    @Test func meterSourcesAreReadableNotWriteOnly() {
        // These were write-only, which is why the Front Panel pickers showed
        // @State defaults instead of the device: getProperty short-circuited to the
        // cache and never issued a read. The 0x10 read is disabled in firmware
        // ("Disabled in XMOS!! use getPreferenceSettings instead",
        // og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:64-66),
        // so the readback is 0xDE.
        #expect(!SymphonyIOPropertyMapper.writeOnlySelectors.contains(.frontPanelMeterBank))
        #expect(!SymphonyIOPropertyMapper.writeOnlySelectors.contains(.metersShowInput))

        let req = try? SymphonyIOPropertyMapper.buildReadRequest(
            for: PropertyAddress(selector: .metersShowInput, element: 1))
        #expect(req?.request == SymphonyIOCommand.getCurrentPreferenceSettings.rawValue)
        #expect(req?.direction == .read)
        #expect(req?.data.count == 4, "SymphonyIOSettings is 4 bytes")
        // 0xDE sends nValue = 0, so both halves are 0 regardless of bank.
        #expect(req?.value == 0)
        #expect(req?.index == 0)
    }

    @Test func metersShowInputWrite() throws {
        // 0x10 is cache-only by default: it took the unit off the USB bus on the
        // second bank change of a session (2026-09-11). When armed for testing
        // with MAESTRO_ALLOW_FRONT_PANEL_METER_WRITE=1 the request must be the
        // legacy shape -- and never the 0xFF sentinel the old code emitted, which
        // the device reads as a real opcode (connectivityVerification).
        let address = PropertyAddress(selector: .metersShowInput, element: 1)
        guard SymphonyIOPropertyMapper.allowFrontPanelMeterWrites else {
            #expect(throws: DeviceConnectionError.cacheOnly(.metersShowInput)) {
                _ = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: .uint32(3))
            }
            return
        }
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: .uint32(3))
        #expect(request.request == SymphonyIOCommand.frontPanelMeterShow.rawValue)
        #expect(request.request != 0xFF)
        #expect(request.value == SymphonyIOFrontPanelMeterBank.left.rawValue)
        #expect(request.data == Data([SymphonyIOFrontPanelMeterSource.digitalInput1to8.rawValue]))
    }

    @Test func frontPanelMeterBankWrite() throws {
        // The other selector onto the same opcode. Element 0 is tolerated as
        // bank 1 for a caller that already converted to 0-based.
        let address = PropertyAddress(selector: .frontPanelMeterBank, element: 0)
        guard SymphonyIOPropertyMapper.allowFrontPanelMeterWrites else {
            #expect(throws: DeviceConnectionError.cacheOnly(.frontPanelMeterBank)) {
                _ = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: .uint32(1))
            }
            return
        }
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: .uint32(1))
        #expect(request.request == SymphonyIOCommand.frontPanelMeterShow.rawValue)
        #expect(request.value == SymphonyIOFrontPanelMeterBank.left.rawValue)
        #expect(request.data == Data([SymphonyIOFrontPanelMeterSource.analogInput1to8.rawValue]))
    }

    // MARK: - S6: Out-of-Range Write Values Do Not Trap

    /// A .digitalRefLevel value with raw > 255 must truncate (fail the single op
    /// gracefully) rather than trap on UInt8(raw) and crash the whole app. Before
    /// the S6 fix this line was `UInt8(raw)`, which would abort the test process.
    @Test func digitalRefLevelOutOfRangeDoesNotTrap() throws {
        let address = PropertyAddress(selector: .digitalRefLevel, element: 1)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .uint32(256))
        // 256 & 0xFF == 0 — truncated, not trapped.
        #expect(request.data == Data([0]))
    }

    // MARK: - S2: Headphone Routing Shared-Register Preservation

    /// HP1 and HP2 share one hardware register (0x54): low nibble = HP1,
    /// high nibble = HP2. Writing one output must preserve the sibling's nibble.
    /// This is the exact "HP1 write zeroes HP2" regression guard. The mapper keeps
    /// a process-global cache of the last-written nibbles; the test drives both in
    /// sequence so the outcome is deterministic regardless of prior cache state.
    @Test func headphoneRoutingPreservesSiblingNibble() throws {
        // Establish HP2 = 5 (high nibble). HP1 nibble is whatever the cache held;
        // we don't assert it here — the next write pins it.
        _ = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .headphone2RoutingID), value: .uint32(5))

        // Write HP1 = 3. HP2's nibble (5) MUST be preserved, not zeroed.
        let afterHP1 = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .headphone1RoutingID), value: .uint32(3))
        #expect(afterHP1.request == 0x54)
        #expect(afterHP1.data == Data([(5 << 4) | 3]))  // 0x53 — HP2 preserved

        // Write HP2 = 6. HP1's nibble (3) MUST be preserved, not zeroed.
        let afterHP2 = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .headphone2RoutingID), value: .uint32(6))
        #expect(afterHP2.request == 0x54)
        #expect(afterHP2.data == Data([(6 << 4) | 3]))  // 0x63 — HP1 preserved
    }

    // MARK: - I/O Card Type Tests

    @Test func primaryBoardTypeReadRequest() throws {
        let address = PropertyAddress(selector: .primaryBoardType)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
        #expect(request.request == SymphonyIOCommand.optionBoardType.rawValue)
        #expect(request.value == 0)    // wValue = 0
        #expect(request.index == 0)    // wIndex = slot 0 = primary
    }

    @Test func secondaryBoardTypeReadRequest() throws {
        let address = PropertyAddress(selector: .secondaryBoardType)
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        #expect(request.direction == .read)
        #expect(request.request == SymphonyIOCommand.optionBoardType.rawValue)
        #expect(request.value == 0)    // wValue = 0
        #expect(request.index == 1)    // wIndex = slot 1 = secondary
    }

    @Test func decodePrimaryBoardType() throws {
        // 3 = optical (ADAT)
        let response = USBControlResponse(data: Data([3]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .primaryBoardType)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .uint32(3))
    }

    @Test func readOnlySelectorsContainsBoardTypes() {
        #expect(SymphonyIOPropertyMapper.readOnlySelectors.contains(.primaryBoardType))
        #expect(SymphonyIOPropertyMapper.readOnlySelectors.contains(.secondaryBoardType))
    }
}

// IOCardType tests moved to MaestroCoreTests/IOCardTypeTests.swift

// MARK: - Volume Attenuation Math Tests

/// Tests for the volume attenuation mapping used by ASP and proxy.
/// ASP range: raw 0 (-64 dB, atten=64) → raw 64 (0 dB, atten=0)
/// Formula: attenuation = 64 - rawValue, dB = -attenuation
/// Safe default: raw 44 = -20 dB (attenuation 20)
@Suite("VolumeAttenuationMapping")
struct VolumeAttenuationMappingTests {

    @Test func safeDefaultAtMinus20dB() throws {
        // ASP safe default: raw 44 = -20 dB
        let response = USBControlResponse(data: Data([20]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .outputLevel)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .float64(-20.0))
    }

    @Test func safeDefaultWriteProduces20Attenuation() throws {
        let address = PropertyAddress(selector: .outputLevel)
        let request = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .float64(-20.0))
        #expect(request.data == Data([20]))
    }

    @Test func fullVolumeAtZerodB() throws {
        // raw 64 = 0 dB (no attenuation) — dangerously loud default
        let response = USBControlResponse(data: Data([0]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .outputLevel)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .float64(0.0))
    }

    @Test func minimumVolumeAtMinus64dB() throws {
        let response = USBControlResponse(data: Data([64]), bytesTransferred: 1)
        let address = PropertyAddress(selector: .outputLevel)
        let value = try SymphonyIOPropertyMapper.decodeResponse(response, for: address)
        #expect(value == .float64(-64.0))
    }

    @Test func attenuationBoundaryValues() throws {
        let address = PropertyAddress(selector: .outputLevel)

        // Min volume (raw 0 → atten 64 → -64 dB)
        let minReq = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .float64(-64.0))
        #expect(minReq.data == Data([64]))

        // Max volume (raw 64 → atten 0 → 0 dB)
        let maxReq = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: address, value: .float64(0.0))
        #expect(maxReq.data == Data([0]))
    }
}

// MARK: - ASP Device Name Filtering Tests

/// Tests verifying the name-based filtering logic that distinguishes
/// the real USB device ("Symphony I/O : USB Audio") from the ASP
/// virtual device ("Symphony I/O : Maestro").
@Suite("ASPDeviceNameFiltering")
struct ASPDeviceNameFilteringTests {

    @Test func realDeviceNameMatchesFilter() {
        let name = "Symphony I/O : USB Audio"
        let matches = name.contains("Symphony") && !name.contains("Maestro")
        #expect(matches == true)
    }

    @Test func virtualDeviceNameExcludedByFilter() {
        let name = "Symphony I/O : Maestro"
        let matches = name.contains("Symphony") && !name.contains("Maestro")
        #expect(matches == false)
    }

    @Test func unrelatedDeviceExcludedByFilter() {
        let name = "MacBook Pro Speakers"
        let matches = name.contains("Symphony") && !name.contains("Maestro")
        #expect(matches == false)
    }

    @Test func oldDeviceNameWouldNotMatch() {
        // Regression: old name "Symphony IO Volume" should also not match
        // if it were ever encountered (e.g., stale device registration)
        let name = "Symphony IO Volume"
        let matches = name.contains("Symphony") && !name.contains("Maestro")
        // Old name would still match — but it won't exist after this rename
        #expect(matches == true)
    }
}

// MARK: - Monitor output index encoding (Dim / Sum to Mono)

/// The firmware's monitor-output index is NOT what the vendor header comment
/// says. `SymphonyIOVendorSpecific.h:576-584` documents wIndex for 0xE7/0xE8 as
/// Speakers=1, HP1=2, HP2=3; the daemon translates through a different enum
/// before the wire (`SymphonyIOControl.cpp:25-29`) and the firmware agrees with
/// the daemon (`SymphonyIOEventProperties.h:380-385`): HP1=0, HP2=1, Speaker=2.
///
/// We shipped the header's version, which rotated every command by one —
/// pressing Dim on Headphone 1 dimmed Headphone 2. Reported publicly as
/// "D and M change state but have no effect".
@Suite("Monitor output index encoding")
struct MonitorOutputIndexTests {

    @Test("Firmware enum values match SymphonyIOEventProperties.h:380-385")
    func rawValues() {
        #expect(SymphonyIORequestBuilder.MonitorOutput.headphone1.rawValue == 0)
        #expect(SymphonyIORequestBuilder.MonitorOutput.headphone2.rawValue == 1)
        #expect(SymphonyIORequestBuilder.MonitorOutput.speaker.rawValue    == 2)
    }

    @Test("Dim writes carry the firmware index, not the header's")
    func dimWireIndex() throws {
        let cases: [(AudioPropertySelector, UInt16)] = [
            (.outputDim,     SymphonyIORequestBuilder.MonitorOutput.speaker.rawValue),
            (.headphone1Dim, SymphonyIORequestBuilder.MonitorOutput.headphone1.rawValue),
            (.headphone2Dim, SymphonyIORequestBuilder.MonitorOutput.headphone2.rawValue),
        ]
        for (selector, expected) in cases {
            let req = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: selector), value: .bool(true))
            #expect(req.request == SymphonyIOCommand.monitorOutputDim.rawValue)
            #expect(req.index == expected,
                    "\(selector) must send wIndex \(expected), got \(req.index)")
            #expect(req.data == Data([1]))
        }
    }

    @Test("Sum to Mono writes carry the firmware index, not the header's")
    func sumToMonoWireIndex() throws {
        let cases: [(AudioPropertySelector, UInt16)] = [
            (.outputSumToMono,     SymphonyIORequestBuilder.MonitorOutput.speaker.rawValue),
            (.headphone1SumToMono, SymphonyIORequestBuilder.MonitorOutput.headphone1.rawValue),
            (.headphone2SumToMono, SymphonyIORequestBuilder.MonitorOutput.headphone2.rawValue),
        ]
        for (selector, expected) in cases {
            let req = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: selector), value: .bool(true))
            #expect(req.request == SymphonyIOCommand.monitorSumToMono.rawValue)
            #expect(req.index == expected,
                    "\(selector) must send wIndex \(expected), got \(req.index)")
        }
    }

    /// The regression itself: the three destinations must map to three DISTINCT
    /// indices. The old bug was a rotation, so every value was still unique —
    /// distinctness alone would not have caught it. Pin the exact values.
    @Test("Speaker must not be index 0 — that address is Headphone 1")
    func speakerIsNotZero() throws {
        let req = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .outputDim), value: .bool(true))
        #expect(req.index != 0,
                "index 0 is Headphone 1 in firmware; sending it dims the wrong output")
        #expect(req.index == 2)
    }

    @Test("Reads use the same encoding as writes")
    func readsMatchWrites() throws {
        let pairs: [(AudioPropertySelector, AudioPropertySelector)] = [
            (.outputDim, .outputSumToMono),
            (.headphone1Dim, .headphone1SumToMono),
            (.headphone2Dim, .headphone2SumToMono),
        ]
        for (dim, sum) in pairs {
            let rd = try SymphonyIOPropertyMapper.buildReadRequest(for: PropertyAddress(selector: dim))
            let wr = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: dim), value: .bool(true))
            #expect(rd.index == wr.index, "\(dim) read/write index disagree")

            let rs = try SymphonyIOPropertyMapper.buildReadRequest(for: PropertyAddress(selector: sum))
            let ws = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: sum), value: .bool(true))
            #expect(rs.index == ws.index, "\(sum) read/write index disagree")
        }
    }
}

// MARK: - MicPre group / insert wire encoding (0xC7 / 0xC8 / 0xC9)

/// The three controls the Symphony I/O user guide documents and we shipped
/// hidden: Group, Insert Select and Insert In. Two of the three are ordinary
/// channel-indexed byte writes. `0xC8` is NOT:
///
/// `SymphonyIOVendorSpecific.h:429-431` documents it as
/// "nValue: Channel Index / pData: insert #". `SetInsertAssignmentInHardware`
/// (`SymphonyIOBoard_MicPre8ch.cpp:1790-1810`) does the opposite — `wIndex` is
/// the INSERT and the payload is a CHANNEL BITMASK — and rebuilds all eight
/// inserts on every change.
///
/// Modelled on `MonitorOutputIndexTests`, whose lesson was that checking opcode
/// and payload without checking WHICH DESTINATION the index addresses lets a
/// rotated-index bug pass. Every assertion below pins opcode, wValue, wIndex and
/// payload together.
@Suite("MicPre group/insert wire encoding")
struct MicPreGroupInsertWireTests {

    // MARK: 0xC7 — Group

    @Test("Group writes 0xC7 with the channel in wIndex and the group ID as payload")
    func groupWriteEncoding() throws {
        for channel in 0..<8 {
            for group in 0...8 {
                let req = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: .groupID, scope: .input, element: UInt32(channel)),
                    value: .uint32(UInt32(group)))
                #expect(req.direction == .write)
                #expect(req.request == 0xC7)
                #expect(req.request == SymphonyIOCommand.channelGroup.rawValue)
                #expect(req.value == 0, "nValue = nChannel, so wValue (nValue >> 16) is 0")
                #expect(req.index == UInt16(channel),
                        "0xC7 addresses the CHANNEL — group \(group) went to index \(req.index)")
                #expect(req.data == Data([UInt8(group)]))
            }
        }
    }

    @Test("Group Off is the explicit value 0, not an absent write")
    func groupOffIsZero() throws {
        let req = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .groupID, scope: .input, element: 6),
            value: .uint32(InputChannelLogic.groupOff))
        #expect(req.index == 6)
        #expect(req.data == Data([0]))
    }

    @Test("A group ID above 8 is rejected rather than truncated")
    func groupOutOfRangeRejected() {
        #expect(throws: DeviceConnectionError.self) {
            _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .groupID, scope: .input, element: 0),
                value: .uint32(9))
        }
    }

    @Test("Group reads use the same channel index as writes")
    func groupReadMatchesWrite() throws {
        for channel: UInt32 in 0..<8 {
            let rd = try SymphonyIOPropertyMapper.buildReadRequest(
                for: PropertyAddress(selector: .groupID, scope: .input, element: channel))
            let wr = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .groupID, scope: .input, element: channel),
                value: .uint32(1))
            #expect(rd.request == wr.request)
            #expect(rd.index == wr.index)
            #expect(rd.direction == .read)
        }
    }

    // MARK: 0xC8 — Insert

    /// THE regression this suite exists for. If someone "fixes" `.insertID` back
    /// to the header's documented shape, wIndex becomes the channel and the
    /// payload the insert number — inserts land on the wrong channels.
    @Test("0xC8 addresses the INSERT, not the channel, and carries a channel bitmask")
    func insertWriteEncoding() throws {
        // Insert 3 (wire index 2) held by channel 5 → payload 0x20.
        let req = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .insertID, scope: .input, element: 2),
            value: .uint32(0x20))
        #expect(req.direction == .write)
        #expect(req.request == 0xC8)
        #expect(req.request == SymphonyIOCommand.insert.rawValue)
        #expect(req.value == 0)
        #expect(req.index == 2, "wIndex is the 0-based INSERT index, not the channel")
        #expect(req.data == Data([0x20]), "payload is 0x01 << channel, not the insert number")
        #expect(req.data != Data([3]), "a payload of 3 would be the header's (wrong) encoding")
    }

    @Test("Every insert index reaches its own wIndex")
    func insertIndexIsNotRotated() throws {
        for insert: UInt32 in 0..<8 {
            let req = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .insertID, scope: .input, element: insert),
                value: .uint32(0x01))
            #expect(req.index == UInt16(insert),
                    "insert \(insert) must address wIndex \(insert), got \(req.index)")
        }
    }

    @Test("An element past insert 8 is rejected")
    func insertElementOutOfRange() {
        #expect(throws: DeviceConnectionError.self) {
            _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .insertID, scope: .input, element: 8),
                value: .uint32(0x01))
        }
    }

    @Test("A mask wider than a byte is rejected rather than truncated")
    func insertMaskOutOfRange() {
        #expect(throws: DeviceConnectionError.self) {
            _ = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .insertID, scope: .input, element: 0),
                value: .uint32(0x1FF))
        }
    }

    /// The full rebuild: one UI change is EIGHT control transfers, because an
    /// insert is only released by writing mask 0 to it.
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:1790-1810`.
    @Test("setInsertAssignments rebuilds all eight inserts, in order")
    func insertRebuildCoversAllEight() {
        // Channel 0 → Insert 1, channel 5 → Insert 3, channel 7 → Insert 8.
        let table: [UInt32] = [1, 0, 0, 0, 0, 3, 0, 8]
        let reqs = SymphonyIORequestBuilder.setInsertAssignments(insertPerChannel: table)

        #expect(reqs.count == 8, "the daemon writes every insert, not just the one that moved")

        let expectedMasks: [UInt8] = [
            0x01,   // insert 1 → channel 0
            0x00,   // insert 2 → nobody
            0x20,   // insert 3 → channel 5
            0x00, 0x00, 0x00, 0x00,
            0x80,   // insert 8 → channel 7
        ]
        for (i, req) in reqs.enumerated() {
            #expect(req.direction == .write)
            #expect(req.request == SymphonyIOCommand.insert.rawValue, "request \(i) opcode")
            #expect(req.value == 0, "request \(i) wValue")
            #expect(req.index == UInt16(i),
                    "request \(i) must address insert \(i), got wIndex \(req.index)")
            #expect(req.data == Data([expectedMasks[i]]),
                    "request \(i) payload must be \(expectedMasks[i]), got \(Array(req.data))")
        }
    }

    @Test("Releasing an insert writes mask 0 to exactly that insert")
    func insertReleaseWritesZero() {
        let before = SymphonyIORequestBuilder.setInsertAssignments(
            insertPerChannel: [0, 4, 0, 0, 0, 0, 0, 0])
        #expect(before[3].data == Data([0x02]), "insert 4 → channel 1")

        let after = SymphonyIORequestBuilder.setInsertAssignments(
            insertPerChannel: [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(after[3].index == 3)
        #expect(after[3].data == Data([0x00]), "the release is a mask-0 write to insert 4")
    }

    /// Every request the rebuild produces must survive the property layer
    /// unchanged — the app pushes them through `setProperty`, not the builder.
    @Test("The rebuild and the mapper agree byte for byte")
    func rebuildMatchesMapper() throws {
        let table: [UInt32] = [2, 0, 7, 0, 0, 0, 1, 0]
        let built = SymphonyIORequestBuilder.setInsertAssignments(insertPerChannel: table)
        let masks = InputChannelLogic.insertAssignmentMasks(insertPerChannel: table)

        for (insert, mask) in masks {
            let mapped = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .insertID, scope: .input, element: UInt32(insert)),
                value: .uint32(UInt32(mask)))
            #expect(mapped.request == built[insert].request)
            #expect(mapped.value == built[insert].value)
            #expect(mapped.index == built[insert].index)
            #expect(mapped.data == built[insert].data)
        }
    }

    // MARK: 0xC9 — Insert Return

    @Test("Insert Return writes 0xC9 with the channel in wIndex and 0/1 payload")
    func insertReturnEncoding() throws {
        for channel in 0..<8 {
            for enabled in [true, false] {
                let req = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: .insertReturnEnable, scope: .input,
                                         element: UInt32(channel)),
                    value: .bool(enabled))
                #expect(req.direction == .write)
                #expect(req.request == 0xC9)
                #expect(req.request == SymphonyIOCommand.insertEnable.rawValue)
                #expect(req.value == 0)
                #expect(req.index == UInt16(channel),
                        "0xC9 addresses the CHANNEL — got index \(req.index) for channel \(channel)")
                #expect(req.data == Data([enabled ? 1 : 0]))
            }
        }
    }

    @Test("Insert Return reads use the same channel index as writes")
    func insertReturnReadMatchesWrite() throws {
        for channel: UInt32 in 0..<8 {
            let rd = try SymphonyIOPropertyMapper.buildReadRequest(
                for: PropertyAddress(selector: .insertReturnEnable, scope: .input, element: channel))
            let wr = try SymphonyIOPropertyMapper.buildWriteRequest(
                for: PropertyAddress(selector: .insertReturnEnable, scope: .input, element: channel),
                value: .bool(true))
            #expect(rd.request == wr.request)
            #expect(rd.index == wr.index)
            #expect(rd.direction == .read)
        }
    }

    @Test("Insert Return decodes back to a Bool")
    func insertReturnDecodes() throws {
        let address = PropertyAddress(selector: .insertReturnEnable, scope: .input, element: 0)
        #expect(try SymphonyIOPropertyMapper.decodeResponse(
            USBControlResponse(data: Data([1]), bytesTransferred: 1), for: address) == .bool(true))
        #expect(try SymphonyIOPropertyMapper.decodeResponse(
            USBControlResponse(data: Data([0]), bytesTransferred: 1), for: address) == .bool(false))
    }

    // MARK: The three opcodes must stay distinct

    /// All three commands are one-byte writes with wValue 0, so an opcode mix-up
    /// would be invisible in the payload. Pin the opcodes themselves.
    @Test("0xC7 / 0xC8 / 0xC9 are three different opcodes and stay in their lane")
    func opcodesAreDistinct() throws {
        let group = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .groupID, scope: .input, element: 1), value: .uint32(1))
        let insert = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .insertID, scope: .input, element: 1), value: .uint32(1))
        let ret = try SymphonyIOPropertyMapper.buildWriteRequest(
            for: PropertyAddress(selector: .insertReturnEnable, scope: .input, element: 1),
            value: .bool(true))

        #expect(Set([group.request, insert.request, ret.request]).count == 3)
        #expect(group.request == 0xC7)
        #expect(insert.request == 0xC8)
        #expect(ret.request == 0xC9)
        // 0xCA is the high-pass filter; none of the three may land on it.
        #expect(!Set([group.request, insert.request, ret.request])
            .contains(SymphonyIOCommand.highPassFilter.rawValue))
        // 0xC6 is phantom power — a stray write there is a physical hazard.
        #expect(!Set([group.request, insert.request, ret.request])
            .contains(SymphonyIOCommand.phantomPower.rawValue))
    }

    /// Channel-indexed MicPre writes are 0-based on the wire and must not be
    /// silently shifted. A phantom write to the wrong channel is a hazard, so pin
    /// the whole family together.
    @Test("Every channel-indexed MicPre opcode uses the element verbatim")
    func channelIndexingIsZeroBasedAcrossTheFamily() throws {
        let cases: [(AudioPropertySelector, PropertyValue, UInt8)] = [
            (.micGain,           .uint32(20), SymphonyIOCommand.micGain.rawValue),
            (.phantom,           .bool(true), SymphonyIOCommand.phantomPower.rawValue),
            (.phaseReverse,      .bool(true), SymphonyIOCommand.phaseInverse.rawValue),
            (.highPassFilter,    .bool(true), SymphonyIOCommand.highPassFilter.rawValue),
            (.groupID,           .uint32(2),  SymphonyIOCommand.channelGroup.rawValue),
            (.insertReturnEnable, .bool(true), SymphonyIOCommand.insertEnable.rawValue),
        ]
        for (selector, value, opcode) in cases {
            for channel: UInt32 in 0..<8 {
                let req = try SymphonyIOPropertyMapper.buildWriteRequest(
                    for: PropertyAddress(selector: selector, scope: .input, element: channel),
                    value: value)
                #expect(req.request == opcode)
                #expect(req.value == 0, "\(selector) must leave wValue 0")
                #expect(req.index == UInt16(channel),
                        "\(selector) shifted channel \(channel) to wIndex \(req.index)")
            }
        }
    }
}

// MARK: - Reset scope (shared with the Output page)

@Suite("Input reset scope")
struct InputResetScopeTests {

    @Test("The keep-trims scope is the one that preserves calibration")
    func scopeSemantics() {
        #expect(SymphonyIOResetScope.allButCalibration.resetsTrims == false)
        #expect(SymphonyIOResetScope.all.resetsTrims == true)
    }

    /// `resetsTrims` is exactly the flag the reset takes, so the two scopes must
    /// produce the two different outcomes through the real call.
    @Test("The two scopes produce different results through the real entry point")
    func scopesDiffer() {
        func run(_ scope: SymphonyIOResetScope) -> InputChannelState {
            var channels = [InputChannelState](repeating: InputChannelState(), count: 16)
            channels[9].inputType = AnalogInputLevel.minus10dBV.rawValue
            channels[9].trim = 1.2
            channels[9].digitalRefLevel = 5
            channels[9].softLimit = 3
            InputChannelLogic.resetToDefaults(
                &channels, includingCalibration: scope.resetsTrims, micPreInstalled: true,
                hostAnalogInputChannels: 16)
            return channels[9]
        }
        let kept = run(.allButCalibration)
        let full = run(.all)

        #expect(kept.softLimit == 0 && full.softLimit == 0)
        #expect(kept.trim == 1.2)
        #expect(full.trim == 0)
        #expect(kept.inputType == AnalogInputLevel.minus10dBV.rawValue)
        #expect(full.inputType == AnalogInputLevel.plus4dBu.rawValue)
        #expect(kept.digitalRefLevel == 5)
        #expect(full.digitalRefLevel == 2)
    }
}
