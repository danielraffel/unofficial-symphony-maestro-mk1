import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

// MARK: - USB Control Transfer Tests

@Suite("USBControlTransfer")
struct USBControlTransferTests {

    @Test func writeDirectionIs0x40() {
        #expect(USBTransferDirection.write.rawValue == 0x40)
    }

    @Test func readDirectionIs0xC0() {
        #expect(USBTransferDirection.read.rawValue == 0xC0)
    }

    @Test func requestBmRequestType() {
        let req = USBControlRequest(direction: .write, request: 0x03)
        #expect(req.bmRequestType == 0x40)
    }

    @Test func maxPayloadSizeIs64() {
        #expect(USBControlRequest.maxPayloadSize == 64)
    }

    @Test func valueSplit() {
        let (wValue, wIndex) = USBValueEncoding.split(0xAABBCCDD)
        #expect(wValue == 0xAABB)
        #expect(wIndex == 0xCCDD)
    }

    @Test func valueCombine() {
        let result = USBValueEncoding.combine(wValue: 0x1234, wIndex: 0x5678)
        #expect(result == 0x12345678)
    }

    @Test func valueSplitRoundTrip() {
        let original: UInt32 = 0xDEADBEEF
        let (wVal, wIdx) = USBValueEncoding.split(original)
        let reconstructed = USBValueEncoding.combine(wValue: wVal, wIndex: wIdx)
        #expect(reconstructed == original)
    }

    @Test func channelValueInput() {
        // Input channels have bit 31 SET (SYMPHONYIO_AUDIO_CHANNEL_INPUT_MASK)
        let value = USBValueEncoding.channelValue(channel: 5, isOutput: false)
        #expect(value & 0x8000_0000 != 0, "Input channels must have bit 31 set")
        #expect(value & 0x0000_FFFF == 5)
    }

    @Test func channelValueOutput() {
        // Output channels have bit 31 CLEAR
        let value = USBValueEncoding.channelValue(channel: 3, isOutput: true)
        #expect(value & 0x8000_0000 == 0, "Output channels must have bit 31 clear")
        #expect(value & 0x0000_FFFF == 3)
    }

    @Test func mixerValueEncoding() {
        let value = USBValueEncoding.mixerValue(mixerID: 2, channel: 15)
        #expect(value == (2 << 16) | 15)
    }
}

// MARK: - USB Transport Error Tests

@Suite("USBTransportError")
struct USBTransportErrorTests {

    @Test func transactionErrorExists() {
        let err = USBTransportError.transactionError
        #expect(err == .transactionError)
    }

    @Test func transactionErrorIsDistinct() {
        #expect(USBTransportError.transactionError != .timeout)
        #expect(USBTransportError.transactionError != .pipeStalled)
        #expect(USBTransportError.transactionError != .noDevice)
    }

    @Test func localizedErrorDescriptions() {
        // All error cases should produce non-nil descriptions
        let errors: [USBTransportError] = [
            .noDevice, .disconnected, .pipeStalled, .timeout,
            .transactionError, .shortTransfer(expected: 4, actual: 1),
        ]
        for error in errors {
            #expect(error.errorDescription != nil, "Missing description for \(error)")
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test func transactionErrorDescription() {
        let desc = USBTransportError.transactionError.errorDescription ?? ""
        #expect(desc.contains("transaction") || desc.contains("Transaction") || desc.contains("USB"))
    }

    @Test func shortTransferIncludesCounts() {
        let desc = USBTransportError.shortTransfer(expected: 4, actual: 1).errorDescription ?? ""
        #expect(desc.contains("4") || desc.contains("short") || desc.contains("Short"))
    }
}

// MARK: - Symphony IO Command Tests

@Suite("SymphonyIOCommand")
struct SymphonyIOCommandTests {

    @Test func setSampleRateIs0x03() {
        #expect(SymphonyIOCommand.setSampleRate.rawValue == 0x03)
    }

    @Test func micGainIs0xC3() {
        #expect(SymphonyIOCommand.micGain.rawValue == 0xC3)
    }

    @Test func phantomPowerIs0xC6() {
        #expect(SymphonyIOCommand.phantomPower.rawValue == 0xC6)
    }

    @Test func audioRoutingIs0x31() {
        #expect(SymphonyIOCommand.audioRouting.rawValue == 0x31)
    }

    @Test func mixerFaderLevelIs0xB0() {
        #expect(SymphonyIOCommand.mixerFaderLevel.rawValue == 0xB0)
    }

    @Test func clockModeIs0x50() {
        #expect(SymphonyIOCommand.clockMode.rawValue == 0x50)
    }

    @Test func symphonyIOVersionIs0xA0() {
        #expect(SymphonyIOCommand.symphonyIOVersion.rawValue == 0xA0)
    }

    // New opcodes
    @Test func monitorOutputDimIs0xE7() {
        #expect(SymphonyIOCommand.monitorOutputDim.rawValue == 0xE7)
    }

    @Test func monitorSumToMonoIs0xE8() {
        #expect(SymphonyIOCommand.monitorSumToMono.rawValue == 0xE8)
    }

    @Test func activeSpeakerSetIs0xE9() {
        #expect(SymphonyIOCommand.activeSpeakerSet.rawValue == 0xE9)
    }

    @Test func headphoneAssignmentsIs0x54() {
        #expect(SymphonyIOCommand.headphoneAssignments.rawValue == 0x54)
    }
}

// MARK: - Clock Source Enum Tests (regression guard for the PR4 off-by-one fix)

@Suite("SymphonyIOClockSource")
struct SymphonyIOClockSourceTests {
    // eSymphonyIOClockSource: Unknown=0, Internal=1, WordClock=2, LoopSync=3, IOBoard1=4, IOBoard2=5
    // (og_source SymphonyIOVendorSpecific.h:857-865). The raw value is sent verbatim as ClockMode
    // pData[0] and used as the dext's 'clck' selector IDs — an off-by-one silently sends the wrong
    // clock source (that was the PR4 bug). This locks the numbering.
    @Test func rawValuesMatchLegacyEnum() {
        #expect(SymphonyIOClockSource.unknown.rawValue == 0)
        #expect(SymphonyIOClockSource.`internal`.rawValue == 1)
        #expect(SymphonyIOClockSource.wordClock.rawValue == 2)
        #expect(SymphonyIOClockSource.loopSync.rawValue == 3)
        #expect(SymphonyIOClockSource.ioBoard1.rawValue == 4)
        #expect(SymphonyIOClockSource.ioBoard2.rawValue == 5)
    }

    @Test func internalIsNotZero() {
        // 0 = Unknown, a firmware no-op. If Internal were 0, "select Internal" would do nothing.
        #expect(SymphonyIOClockSource.`internal`.rawValue != 0)
    }

    @Test func noInventedDigitalSources() {
        // The old enum invented aesEbu/spdif/adat/opticalSPDIF (board sub-sources, not clock
        // sources). The real set is exactly these five.
        #expect(SymphonyIOClockSource.allCases.count == 6) // incl. unknown
        let names = Set(SymphonyIOClockSource.allCases.map { "\($0)" })
        #expect(!names.contains("aesEbu"))
        #expect(!names.contains("adat"))
    }
}

// MARK: - Sample Rate Code Tests

@Suite("SymphonyIOSampleRateCode")
struct SampleRateCodeTests {

    @Test func allRates() {
        #expect(SymphonyIOSampleRateCode.rate48000.sampleRate == 48000)
        #expect(SymphonyIOSampleRateCode.rate44100.sampleRate == 44100)
        #expect(SymphonyIOSampleRateCode.rate96000.sampleRate == 96000)
        #expect(SymphonyIOSampleRateCode.rate88200.sampleRate == 88200)
        #expect(SymphonyIOSampleRateCode.rate192000.sampleRate == 192000)
        #expect(SymphonyIOSampleRateCode.rate176400.sampleRate == 176400)
    }

    @Test func fromSampleRate() {
        #expect(SymphonyIOSampleRateCode(sampleRate: 48000) == .rate48000)
        #expect(SymphonyIOSampleRateCode(sampleRate: 96000) == .rate96000)
        #expect(SymphonyIOSampleRateCode(sampleRate: 22050) == nil)
    }

    @Test func rawValues() {
        #expect(SymphonyIOSampleRateCode.rate48000.rawValue == 0x00)
        #expect(SymphonyIOSampleRateCode.rate96000.rawValue == 0x01)
        #expect(SymphonyIOSampleRateCode.rate192000.rawValue == 0x02)
        #expect(SymphonyIOSampleRateCode.rate44100.rawValue == 0x04)
    }
}

// MARK: - Constants Tests

@Suite("SymphonyIOConstants")
struct SymphonyIOConstantsTests {

    @Test func mixerConstants() {
        #expect(SymphonyIOConstants.numberOfMixers == 4)
        #expect(SymphonyIOConstants.mixerInputChannelCount == 33)
        #expect(SymphonyIOConstants.mixerFaderCount == 34)
        #expect(SymphonyIOConstants.panCenterValue == 64)
        #expect(SymphonyIOConstants.faderZeroOffset == 48)
    }

    @Test func gainConstants() {
        #expect(SymphonyIOConstants.micGainMaximum == 85)
        #expect(SymphonyIOConstants.instrumentGainMaximum == 65)
    }

    @Test func volumeConstants() {
        #expect(SymphonyIOConstants.headphoneVolumeMaximum == 64)
        #expect(SymphonyIOConstants.speakerVolumeMaximum == 64)
    }

    @Test func connectivityVerificationCode() {
        #expect(SymphonyIOConstants.connectivityVerificationCode == 0xDAE5_C4A1)
    }
}

// MARK: - Request Builder Tests

@Suite("SymphonyIORequestBuilder")
struct RequestBuilderTests {

    @Test func setSampleRateRequest() {
        let req = SymphonyIORequestBuilder.setSampleRate(.rate96000)
        #expect(req.direction == .write)
        #expect(req.request == 0x03)
        #expect(req.data == Data([0x01]))
    }

    @Test func getSampleRateRequest() {
        let req = SymphonyIORequestBuilder.getSampleRate()
        #expect(req.direction == .read)
        #expect(req.request == 0x03)
    }

    @Test func setClockModeRequest() {
        let req = SymphonyIORequestBuilder.setClockMode(source: .wordClock, isMaster: true)
        #expect(req.direction == .write)
        #expect(req.request == 0x50)
        #expect(req.data.count == 4)
        #expect(req.data[0] == 2) // wordClock = 2 (eSymphonyIOClockSource, SymphonyIOVendorSpecific.h:861)
        #expect(req.data[1] == 1) // isMaster
    }

    @Test func setMicGainRequest() {
        let req = SymphonyIORequestBuilder.setMicGain(channel: 3, gain: 42)
        #expect(req.direction == .write)
        #expect(req.request == 0xC3)
        #expect(req.value == 0, "Channel goes in wIndex, not wValue")
        #expect(req.index == 3, "Channel index in wIndex per legacy nValue convention")
        #expect(req.data == Data([42]))
    }

    @Test func setMicGainClampsToMax() {
        let req = SymphonyIORequestBuilder.setMicGain(channel: 0, gain: 200)
        #expect(req.data == Data([85])) // Clamped to max
    }

    @Test func setPhantomPowerRequest() {
        let req = SymphonyIORequestBuilder.setPhantomPower(channel: 5, enabled: true)
        #expect(req.direction == .write)
        #expect(req.request == 0xC6)
        #expect(req.value == 0, "Channel goes in wIndex per legacy nValue convention")
        #expect(req.index == 5)
        #expect(req.data == Data([1]))
    }

    @Test func setHeadphoneVolumeRequest() {
        let req = SymphonyIORequestBuilder.setHeadphoneVolume(channel: 0, attenuation: 64)
        #expect(req.direction == .write)
        #expect(req.request == 0x23)
        #expect(req.value == 0)
        #expect(req.index == 0, "HP channel in wIndex per legacy nValue convention")
        #expect(req.data == Data([64]))
    }

    @Test func getMeterDataRequest() {
        let req = SymphonyIORequestBuilder.getMeterData(group: .input)
        #expect(req.direction == .read)
        #expect(req.request == 0x30)
        #expect(req.value == 0)
        #expect(req.index == 0, "group 0 in wIndex")
        #expect(req.data.count == 64)
    }

    /// The mixer group is the case that distinguishes the two encodings: group 0
    /// looks identical either way, so only group 2 proves wIndex is being used.
    /// Sending it in wValue made the firmware reconstruct nValue = 0x00020000,
    /// which its ProcessTDMMeterRequest switch does not recognise — it returns the
    /// stale packet buffer and re-points the FPGA meter routes as if Output had
    /// been asked for.
    @Test func getMeterDataMixerGroupGoesInIndex() {
        let req = SymphonyIORequestBuilder.getMeterData(group: .mixer)
        #expect(req.request == 0x30)
        #expect(req.value == 0, "wValue is the high half of nValue and must be 0")
        #expect(req.index == 2, "mixer group 2 belongs in wIndex")
        #expect(req.data.count == 32)
    }

    @Test("Routing read destination occupies the low half of legacy nValue",
          arguments: [UInt16(32), 33, 48, 192, 193, 207])
    func getAudioRouteDestinationGoesInIndex(destination: UInt16) {
        let req = SymphonyIORequestBuilder.getAudioRoute(destination: destination)
        #expect(req.direction == .read)
        #expect(req.request == 0x31)
        // Reconstruct the firmware's nValue, independently of the builder.
        // The old wValue assignment addressed destination << 16 instead.
        #expect((UInt32(req.value) << 16 | UInt32(req.index)) == UInt32(destination))
        #expect(req.data.count == 1)
    }

    @Test func setAudioRoutesRequest() {
        let req = SymphonyIORequestBuilder.setAudioRoutes([
            (destination: 0, source: 2),
            (destination: 1, source: 3),
        ])
        #expect(req.direction == .write)
        #expect(req.request == 0x31)
        #expect(req.data == Data([0, 2, 1, 3]))
    }

    @Test func clearRouteUsesExplicitMuteSource() {
        let request = SymphonyIORequestBuilder.setAudioRoutes([
            (destination: 32, source: SymphonyIORoutingAddress.clearRoute),
            (destination: 33, source: SymphonyIORoutingAddress.clearRoute)
        ])
        #expect(request.request == SymphonyIOCommand.audioRouting.rawValue)
        #expect(request.data == Data([32, 0xFF, 33, 0xFF]))
    }

    @Test func getFirmwareVersionRequest() {
        let req = SymphonyIORequestBuilder.getFirmwareVersion(type: .mainBoard)
        #expect(req.direction == .read)
        #expect(req.request == 0xA0)
        #expect(req.value == 0)
        #expect(req.data.count == 3)
    }

    // MARK: - New request builder tests

    @Test func setAudioRouteSingleRequest() {
        let req = SymphonyIORequestBuilder.setAudioRoute(destination: 32, source: 192)
        #expect(req.direction == .write)
        #expect(req.request == 0x31)
        #expect(req.value == 0)
        #expect(req.data == Data([32, 192]))
    }

    // These previously asserted the vendor header's index convention
    // (speaker=0, HP1=1, HP2=2) and passed while the app dimmed the wrong
    // output, because they only checked opcode/value/data — never which
    // destination the index actually addresses. Firmware truth is
    // HP1=0, HP2=1, Speaker=2 (SymphonyIOEventProperties.h:380-385).

    @Test func setMonitorDimRequest() {
        let req = SymphonyIORequestBuilder.setMonitorDim(output: .speaker, enabled: true)
        #expect(req.direction == .write)
        #expect(req.request == 0xE7)
        #expect(req.value == 0)
        #expect(req.index == 2) // Speaker is 2 on the wire, not 0
        #expect(req.data == Data([1]))
    }

    @Test func getMonitorDimRequest() {
        let req = SymphonyIORequestBuilder.getMonitorDim(output: .headphone2)
        #expect(req.direction == .read)
        #expect(req.request == 0xE7)
        #expect(req.value == 0)
        #expect(req.index == 1) // HP2 is 1
        #expect(req.data.count == 1)
    }

    @Test func setMonitorSumToMonoRequest() {
        let req = SymphonyIORequestBuilder.setMonitorSumToMono(output: .headphone1, enabled: true)
        #expect(req.direction == .write)
        #expect(req.request == 0xE8)
        #expect(req.value == 0)
        #expect(req.index == 0) // HP1 is 0
        #expect(req.data == Data([1]))
    }

    @Test func getMonitorSumToMonoRequest() {
        let req = SymphonyIORequestBuilder.getMonitorSumToMono(output: .speaker)
        #expect(req.direction == .read)
        #expect(req.request == 0xE8)
        #expect(req.value == 0)
        #expect(req.index == 2) // Speaker is 2
    }

    @Test func getActiveSpeakerSetRequest() {
        let req = SymphonyIORequestBuilder.getActiveSpeakerSet()
        #expect(req.direction == .read)
        #expect(req.request == 0xE9)
        #expect(req.data.count == 1)
    }

    @Test func setActiveSpeakerSetRequest() {
        let req = SymphonyIORequestBuilder.setActiveSpeakerSet(mask: 1)
        #expect(req.direction == .write)
        #expect(req.request == 0xE9)
        #expect(req.data == Data([1]))
    }

    @Test func getHeadphoneAssignmentsRequest() {
        let req = SymphonyIORequestBuilder.getHeadphoneAssignments()
        #expect(req.direction == .read)
        #expect(req.request == 0x54)
        #expect(req.data.count == 1)
    }

    @Test func setHeadphoneAssignmentsRequest() {
        let req = SymphonyIORequestBuilder.setHeadphoneAssignments(hp1: 3, hp2: 5)
        #expect(req.direction == .write)
        #expect(req.request == 0x54)
        // hp2 in high nibble, hp1 in low nibble
        #expect(req.data == Data([(5 << 4) | 3]))
    }

    @Test func getDeviceModeRequest() {
        let req = SymphonyIORequestBuilder.getDeviceMode()
        #expect(req.direction == .read)
        #expect(req.request == SymphonyIOCommand.symphonyIOMode.rawValue)
        #expect(req.data.count == 1)
    }

    @Test(arguments: [UInt16(0), UInt16(1)])
    func getOpticalFormatRequest(board: UInt16) {
        let req = SymphonyIORequestBuilder.getOpticalFormat(board: board)
        #expect(req.direction == .read)
        #expect(req.request == 0x34)
        #expect(req.value == 0)
        #expect(req.index == board)
        #expect(req.data.count == 1)
    }

    @Test(arguments: [UInt16(0), UInt16(1)], [UInt8(0), UInt8(1)])
    func setOpticalFormatRequest(board: UInt16, format: UInt8) {
        let req = SymphonyIORequestBuilder.setOpticalFormat(board: board, format: format)
        #expect(req.direction == .write)
        #expect(req.request == 0x34)
        #expect(req.value == 0)
        #expect(req.index == board)
        #expect(req.data == Data([format]))
    }

    @Test func getSPDIFCoaxReplaceInputRequest() {
        let req = SymphonyIORequestBuilder.getSPDIFCoaxReplaceInput(board: 0)
        #expect(req.direction == .read)
        #expect(req.request == 0x35)
    }

    @Test func getSPDIFCoaxMirrorOutputRequest() {
        let req = SymphonyIORequestBuilder.getSPDIFCoaxMirrorOutput(board: 0)
        #expect(req.direction == .read)
        #expect(req.request == 0x36)
    }

    @Test func setDigitalReferenceLevelOutputRequest() {
        // Output channel 0: bit 31 clear → wValue=0, wIndex=0
        let req = SymphonyIORequestBuilder.setDigitalReferenceLevel(
            channel: 0, isOutput: true, level: 2
        )
        #expect(req.direction == .write)
        #expect(req.request == SymphonyIOCommand.digitalReferenceLevel.rawValue)
        #expect(req.value == 0, "Bit 31 clear for output")
        #expect(req.index == 0)
        #expect(req.data == Data([2]))
    }

    @Test func setDigitalReferenceLevelInputRequest() {
        // Input channel 5: bit 31 set → nValue=5|0x80000000 → wValue=0x8000, wIndex=5
        let req = SymphonyIORequestBuilder.setDigitalReferenceLevel(
            channel: 5, isOutput: false, level: 3
        )
        #expect(req.direction == .write)
        #expect(req.request == SymphonyIOCommand.digitalReferenceLevel.rawValue)
        #expect(req.value == 0x8000, "Bit 31 set for input → high word = 0x8000")
        #expect(req.index == 5, "Channel 5 in wIndex")
        #expect(req.data == Data([3]))
    }

    @Test func setFrontPanelMeterShowRequest() {
        // wIndex = physical LED bank, pData[0] = which channel octet.
        //
        // SymphonyIOVendorSpecific.h:47-49 documents this as
        // "nValue : 0 for Left Bank (1~8) and 1 for Right Bank(9~16)" -- nValue,
        // the PRE-SPLIT 32-bit value. SimpleControlProtocolUSB.cpp:56-57 splits it
        // wValue = nValue >> 16, wIndex = nValue & 0xFFFF, so the bank lands in
        // wIndex. This test previously asserted the opposite and cited that same
        // header line, which is how the wedge shipped.
        let req = SymphonyIORequestBuilder.setFrontPanelMeterShow(
            bank: .right, source: .analogOutput9to16)
        #expect(req.direction == .write)
        #expect(req.request == SymphonyIOCommand.frontPanelMeterShow.rawValue)
        #expect(req.value == 0, "wValue is the high half of nValue and must be 0")
        #expect(req.index == 1, "bank 1 (right) belongs in wIndex")
        #expect(req.data == Data([4]),
                "Analog Output 9-16 is payload 4; a hardcoded 0 makes 9-16 unreachable")
    }

    @Test func setSoftLimitRequest() {
        let req = SymphonyIORequestBuilder.setSoftLimit(channel: 2, mode: .softSaturate)
        #expect(req.direction == .write)
        #expect(req.request == SymphonyIOCommand.softLimit.rawValue)
        #expect(req.value == 0, "Channel goes in wIndex per legacy nValue convention")
        #expect(req.index == 2, "Channel 2 in wIndex")
        #expect(req.data == Data([SymphonyIOSoftLimitMode.softSaturate.rawValue]))
    }

    @Test func setAnalogReferenceLevelInputRequest() {
        // Input channel: bit 31 set (INPUT_MASK), channel in low bits
        let req = SymphonyIORequestBuilder.setAnalogReferenceLevel(
            channel: 3, isOutput: false, type: 2
        )
        #expect(req.direction == .write)
        #expect(req.request == SymphonyIOCommand.analogReferenceLevel.rawValue)
        // nValue = 3 | 0x80000000 → wValue=0x8000, wIndex=3
        #expect(req.value == 0x8000, "Bit 31 set for input → high word = 0x8000")
        #expect(req.index == 3, "Channel 3 in wIndex")
        #expect(req.data == Data([2, SymphonyIOConstants.doNotSetTrimValue]))
    }

    @Test func setAnalogReferenceLevelOutputRequest() {
        // Output channel: bit 31 clear, channel in low bits
        let req = SymphonyIORequestBuilder.setAnalogReferenceLevel(
            channel: 1, isOutput: true, type: 1
        )
        #expect(req.direction == .write)
        #expect(req.request == SymphonyIOCommand.analogReferenceLevel.rawValue)
        // nValue = 1 (no INPUT_MASK) → wValue=0, wIndex=1
        #expect(req.value == 0, "Bit 31 clear for output")
        #expect(req.index == 1, "Channel 1 in wIndex")
    }
}

// MARK: - Mock Transport Tests

@Suite("MockUSBTransport")
struct MockUSBTransportTests {

    @Test func startsConnected() {
        let transport = MockUSBTransport()
        #expect(transport.isConnected == true)
    }

    @Test func recordsRequests() async throws {
        let transport = MockUSBTransport()
        let req = SymphonyIORequestBuilder.getSampleRate()
        _ = try await transport.send(req)
        #expect(transport.sentRequests.count == 1)
        #expect(transport.sentRequests[0].request == 0x03)
    }

    @Test func cannedResponse() async throws {
        let transport = MockUSBTransport()
        transport.setResponse(for: .setSampleRate, data: Data([0x01]))
        let req = SymphonyIORequestBuilder.getSampleRate()
        let response = try await transport.send(req)
        #expect(response.data == Data([0x01]))
    }

    @Test func cannedError() async {
        let transport = MockUSBTransport()
        transport.setError(for: .setSampleRate, error: .timeout)
        let req = SymphonyIORequestBuilder.getSampleRate()
        do {
            _ = try await transport.send(req)
            #expect(Bool(false), "Should have thrown")
        } catch let error as USBTransportError {
            #expect(error == .timeout)
        } catch {
            #expect(Bool(false), "Wrong error type")
        }
    }

    @Test func disconnectedThrows() async {
        let transport = MockUSBTransport()
        transport.simulateDisconnect()
        #expect(transport.isConnected == false)
        let req = SymphonyIORequestBuilder.getSampleRate()
        do {
            _ = try await transport.send(req)
            #expect(Bool(false), "Should have thrown")
        } catch let error as USBTransportError {
            #expect(error == .noDevice)
        } catch {
            #expect(Bool(false), "Wrong error type")
        }
    }

    @Test func closeDisconnects() async {
        let transport = MockUSBTransport()
        await transport.close()
        #expect(transport.isConnected == false)
    }

    @Test func dynamicHandler() async throws {
        let transport = MockUSBTransport()
        transport.requestHandler = { request in
            .success(USBControlResponse(data: Data([42]), bytesTransferred: 1))
        }
        let req = SymphonyIORequestBuilder.getSampleRate()
        let response = try await transport.send(req)
        #expect(response.data == Data([42]))
    }
}

// MARK: - USB Device Connection Tests

@Suite("USBDeviceConnection")
struct USBDeviceConnectionTests {

    private func makeConnection() -> (USBDeviceConnection, MockUSBTransport) {
        let transport = MockUSBTransport()
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "test-usb"
        )!
        let conn = USBDeviceConnection(identifier: id, transport: transport)
        return (conn, transport)
    }

    // MARK: Connection State

    @Test func isConnectedReflectsTransport() {
        let (conn, transport) = makeConnection()
        #expect(conn.isConnected == true)
        transport.simulateDisconnect()
        #expect(conn.isConnected == false)
    }

    @Test func disconnectedGetThrows() async {
        let (conn, transport) = makeConnection()
        transport.simulateDisconnect()
        do {
            _ = try await conn.getProperty(PropertyAddress(selector: .sampleRate))
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .notConnected)
        } catch {
            #expect(Bool(false), "Wrong error type")
        }
    }

    @Test func disconnectedSetThrows() async {
        let (conn, transport) = makeConnection()
        transport.simulateDisconnect()
        do {
            try await conn.setProperty(
                PropertyAddress(selector: .sampleRate),
                value: .float64(48000)
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .notConnected)
        } catch {
            #expect(Bool(false), "Wrong error type")
        }
    }

    // MARK: Sample Rate

    @Test func readSampleRate() async throws {
        let (conn, transport) = makeConnection()
        // 0x00 = 48kHz
        transport.setResponse(for: .setSampleRate, data: Data([0x00]))
        let value = try await conn.getProperty(PropertyAddress(selector: .sampleRate))
        #expect(value == .float64(48000.0))
    }

    @Test func writeSampleRate() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .sampleRate),
            value: .float64(96000.0)
        )
        #expect(transport.sentRequests.count == 1)
        let req = transport.sentRequests[0]
        #expect(req.direction == .write)
        #expect(req.request == 0x03)
        #expect(req.data == Data([0x01])) // 96kHz code
    }

    // MARK: Mic Gain

    @Test func readMicGain() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .micGain, data: Data([42]))
        let value = try await conn.getProperty(
            PropertyAddress(selector: .micGain, scope: .input, element: 3)
        )
        #expect(value == .uint32(42))
    }

    @Test func writeMicGain() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .micGain, scope: .input, element: 3),
            value: .uint32(55)
        )
        let req = transport.sentRequests[0]
        #expect(req.request == 0xC3)
        #expect(req.value == 0, "Channel goes in wIndex per legacy nValue convention")
        #expect(req.index == 3, "Channel 3 in wIndex")
        #expect(req.data == Data([55]))
    }

    // MARK: Phantom Power

    @Test func readPhantomPower() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .phantomPower, data: Data([1]))
        let value = try await conn.getProperty(
            PropertyAddress(selector: .phantom, scope: .input, element: 0)
        )
        #expect(value == .bool(true))
    }

    @Test func writePhantomPower() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .phantom, scope: .input, element: 0),
            value: .bool(true)
        )
        let req = transport.sentRequests[0]
        #expect(req.request == 0xC6)
        #expect(req.data == Data([1]))
    }

    // MARK: Output Level

    @Test func readOutputLevel() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .speakerOutputVolume, data: Data([12]))
        let value = try await conn.getProperty(PropertyAddress(selector: .outputLevel))
        #expect(value == .float64(-12.0)) // 12 attenuation → -12 dB
    }

    @Test func writeOutputLevel() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .outputLevel),
            value: .float64(-20.0)
        )
        let req = transport.sentRequests[0]
        #expect(req.data == Data([20])) // -20 dB → 20 attenuation
    }

    // MARK: Output Mute

    @Test func readOutputMute() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .speakerOutputMute, data: Data([0]))
        let value = try await conn.getProperty(PropertyAddress(selector: .outputMute))
        #expect(value == .bool(false))
    }

    @Test func writeOutputMute() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .outputMute),
            value: .bool(true)
        )
        let req = transport.sentRequests[0]
        #expect(req.data == Data([1]))
    }

    // MARK: Mixer

    @Test func writeMixerFaderLevel() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .mixerChannelLevel, element: 5),
            value: .float64(0.0) // 0 dB → scaled 48
        )
        let req = transport.sentRequests[0]
        #expect(req.request == SymphonyIOCommand.mixerFaderLevel.rawValue)
        #expect(req.data == Data([48]))
    }

    @Test func writeMixerPan() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .mixerChannelPan, element: 0),
            value: .float64(0.0) // center → 64
        )
        let req = transport.sentRequests[0]
        #expect(req.request == SymphonyIOCommand.mixerInputPan.rawValue)
        #expect(req.data == Data([64]))
    }

    // MARK: Firmware Version

    @Test func readFirmwareVersion() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .symphonyIOVersion, data: Data([2, 1, 5]))
        let value = try await conn.getProperty(PropertyAddress(selector: .version))
        #expect(value == .string("2.1.5"))
    }

    // MARK: Read-Only Properties

    @Test func readOnlyPropertyThrows() async {
        let (conn, _) = makeConnection()
        do {
            try await conn.setProperty(
                PropertyAddress(selector: .version),
                value: .string("hacked")
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .readOnly(.version))
        } catch {
            #expect(Bool(false), "Wrong error type")
        }
    }

    @Test func clockStatusIsReadOnly() async {
        let (conn, _) = makeConnection()
        let settable = await conn.isPropertySettable(
            PropertyAddress(selector: .clockStatus)
        )
        #expect(settable == false)
    }

    @Test func deviceModeIsReadOnly() async {
        let (conn, _) = makeConnection()
        let settable = await conn.isPropertySettable(
            PropertyAddress(selector: .deviceMode)
        )
        #expect(settable == false)
    }

    // MARK: Unsupported Property

    @Test func unsupportedPropertyThrows() async {
        let (conn, _) = makeConnection()
        let bogus = AudioPropertySelector(rawValue: 0xDEADBEEF)
        do {
            _ = try await conn.getProperty(PropertyAddress(selector: bogus))
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .unsupportedProperty(bogus))
        } catch {
            #expect(Bool(false), "Wrong error type")
        }
    }

    // MARK: Has Property

    @Test func hasPropertyForSupported() async {
        let (conn, _) = makeConnection()
        let has = await conn.hasProperty(PropertyAddress(selector: .sampleRate))
        #expect(has == true)
    }

    @Test func hasPropertyForUnsupported() async {
        let (conn, _) = makeConnection()
        let has = await conn.hasProperty(
            PropertyAddress(selector: AudioPropertySelector(rawValue: 0xBEEF))
        )
        #expect(has == false)
    }

    @Test func hasPropertyForClockSource() async {
        let (conn, _) = makeConnection()
        let has = await conn.hasProperty(PropertyAddress(selector: .clockSource))
        #expect(has == true)
    }

    // MARK: Type Mismatch

    @Test func wrongTypeMicGainThrows() async {
        let (conn, _) = makeConnection()
        do {
            try await conn.setProperty(
                PropertyAddress(selector: .micGain, scope: .input, element: 0),
                value: .string("not a number")
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            if case .typeMismatch = error {
                // Expected
            } else {
                #expect(Bool(false), "Wrong error variant: \(error)")
            }
        } catch {
            #expect(Bool(false), "Wrong error type")
        }
    }

    // MARK: Listeners

    @Test func listenerReceivesChange() async throws {
        let (conn, _) = makeConnection()
        let observer = PropertyObserver()
        let address = PropertyAddress(selector: .outputMute)
        await conn.addListener(observer, for: address)

        try await conn.setProperty(address, value: .bool(true))

        var received: PropertyChange?
        for await change in observer.stream {
            received = change
            break
        }
        #expect(received?.address == address)
        #expect(received?.value == .bool(true))
    }

    // MARK: - Clock Source Caching

    @Test func clockSourceReturnsCachedDefault() async throws {
        let (conn, _) = makeConnection()
        // Clock source should return cached value (default 0 = internal)
        // without hitting USB at all
        let value = try await conn.getProperty(PropertyAddress(selector: .clockSource))
        #expect(value == .uint32(0))
    }

    @Test func clockSourceUpdatesCache() async throws {
        let (conn, transport) = makeConnection()
        // Write a new clock source
        try await conn.setProperty(
            PropertyAddress(selector: .clockSource),
            value: .uint32(1) // word clock
        )
        // Read should return the cached value we just wrote
        let value = try await conn.getProperty(PropertyAddress(selector: .clockSource))
        #expect(value == .uint32(1))
        // The write should have sent a USB command
        #expect(transport.sentRequests.count == 1)
        #expect(transport.sentRequests[0].request == 0x50)
    }

    // MARK: - New property reads: Output Dim

    @Test func readOutputDim() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .monitorOutputDim, data: Data([1]))
        let value = try await conn.getProperty(PropertyAddress(selector: .outputDim))
        #expect(value == .bool(true))
    }

    @Test func writeOutputDim() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .outputDim),
            value: .bool(true)
        )
        let req = transport.sentRequests[0]
        #expect(req.request == 0xE7)
        #expect(req.value == 0) // speaker output
        #expect(req.data == Data([1]))
    }

    // MARK: - Output Sum-to-Mono

    @Test func writeOutputSumToMono() async throws {
        let (conn, transport) = makeConnection()
        try await conn.setProperty(
            PropertyAddress(selector: .outputSumToMono),
            value: .bool(true)
        )
        let req = transport.sentRequests[0]
        #expect(req.request == 0xE8)
        #expect(req.value == 0) // speaker
        #expect(req.data == Data([1]))
    }

    // MARK: - Headphone Levels

    @Test func readHeadphone1Level() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .headphoneVolume, data: Data([30]))
        let value = try await conn.getProperty(PropertyAddress(selector: .headphone1Level))
        #expect(value == .float64(-30.0))
    }

    @Test func readHeadphone2Level() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .headphoneVolume, data: Data([15]))
        let value = try await conn.getProperty(PropertyAddress(selector: .headphone2Level))
        #expect(value == .float64(-15.0))
    }

    // MARK: - Headphone Mute

    @Test func readHeadphone1Mute() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .headphoneMute, data: Data([1]))
        let value = try await conn.getProperty(PropertyAddress(selector: .headphone1Mute))
        #expect(value == .bool(true))
    }

    @Test func readHeadphone2Mute() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .headphoneMute, data: Data([0]))
        let value = try await conn.getProperty(PropertyAddress(selector: .headphone2Mute))
        #expect(value == .bool(false))
    }

    // MARK: - Headphone Dim / Sum-to-Mono

    @Test func readHeadphone1Dim() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .monitorOutputDim, data: Data([1]))
        let value = try await conn.getProperty(PropertyAddress(selector: .headphone1Dim))
        #expect(value == .bool(true))
    }

    @Test func readHeadphone1SumToMono() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .monitorSumToMono, data: Data([0]))
        let value = try await conn.getProperty(PropertyAddress(selector: .headphone1SumToMono))
        #expect(value == .bool(false))
    }

    // MARK: - Active Speaker Set

    @Test func readActiveSpeakerSet() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .activeSpeakerSet, data: Data([1]))
        let value = try await conn.getProperty(PropertyAddress(selector: .activeSpeakerSet))
        #expect(value == .uint32(1))
    }

    // MARK: - Digital I/O

    @Test func readOpticalInFormat() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .opticalFormat, data: Data([0]))
        let value = try await conn.getProperty(PropertyAddress(selector: .opticalInFormat))
        #expect(value == .uint32(0)) // 0 = ADAT
    }

    @Test func readSpdifReplace() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .spdifCoaxReplaceInput, data: Data([0]))
        let value = try await conn.getProperty(PropertyAddress(selector: .spdifReplaceID))
        #expect(value == .uint32(0))
    }

    @Test func readSpdifMirror() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .spdifCoaxMirrorOutput, data: Data([1]))
        let value = try await conn.getProperty(PropertyAddress(selector: .spdifMirrorID))
        #expect(value == .uint32(1))
    }

    // MARK: - Device Mode

    @Test func readDeviceMode() async throws {
        let (conn, transport) = makeConnection()
        transport.setResponse(for: .symphonyIOMode, data: Data([4]))
        let value = try await conn.getProperty(PropertyAddress(selector: .deviceMode))
        #expect(value == .uint32(4))
    }

    // MARK: - Word Clock

    @Test func wordClockDivideIsUnsupported() async throws {
        // 'AEwd' word-clock divide has no vendor EP0 opcode on Symphony IO MKI (it was an
        // Ensemble-only HAL property, mAEstro.h:1036-1039). It must NOT map to proToolsStarSync
        // (0x53, an unrelated register); it now throws .unsupportedProperty.
        let (conn, _) = makeConnection()
        await #expect(throws: DeviceConnectionError.self) {
            _ = try await conn.getProperty(PropertyAddress(selector: .wordClockDivide))
        }
    }
}

// MARK: - Meter Group Tests

@Suite("SymphonyIOMeterGroup")
struct MeterGroupTests {

    @Test func inputGroupLength() {
        #expect(SymphonyIOMeterGroup.input.messageLengthBytes == 64)
    }

    @Test func outputGroupLength() {
        #expect(SymphonyIOMeterGroup.output.messageLengthBytes == 64)
    }

    @Test func mixerGroupLength() {
        #expect(SymphonyIOMeterGroup.mixer.messageLengthBytes == 32)
    }
}

// MARK: - P3F-34: Soft Limiter Mode Tests

@Suite("SymphonyIOSoftLimitMode")
struct SoftLimitModeTests {
    @Test func softLimitModeRawValues() {
        #expect(SymphonyIOSoftLimitMode.off.rawValue == 0)
        #expect(SymphonyIOSoftLimitMode.limit2dBfs.rawValue == 1)
        #expect(SymphonyIOSoftLimitMode.limit4dBfs.rawValue == 2)
        #expect(SymphonyIOSoftLimitMode.softSaturate.rawValue == 3)
        #expect(SymphonyIOSoftLimitMode.softCrunch.rawValue == 4)
    }

    @Test func softLimitModeFromRawValue() {
        for raw: UInt8 in 0...4 {
            let mode = SymphonyIOSoftLimitMode(rawValue: raw)
            #expect(mode != nil, "Raw value \(raw) should produce a valid mode")
        }
        #expect(SymphonyIOSoftLimitMode(rawValue: 5) == nil)
    }

    @Test func setSoftLimitRequestForChannel3() {
        let req = SymphonyIORequestBuilder.setSoftLimit(channel: 3, mode: .softSaturate)
        #expect(req.direction == .write)
        #expect(req.request == SymphonyIOCommand.softLimit.rawValue)
        #expect(req.value == 0, "Channel goes in wIndex per legacy nValue convention")
        #expect(req.index == 3, "Channel 3 in wIndex")
        #expect(req.data == Data([SymphonyIOSoftLimitMode.softSaturate.rawValue]))
    }
}
