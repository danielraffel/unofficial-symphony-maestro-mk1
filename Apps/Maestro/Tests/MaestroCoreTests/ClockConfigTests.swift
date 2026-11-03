import Testing
@testable import MaestroCore

/// Tests for the clock configuration domain model.
///
/// Evidence sources:
/// - `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// - `og_source/generic/ApogeeUSBProductID.h`

@Suite("ClockConfig")
struct ClockConfigTests {

    // MARK: - ClockSource

    @Test func clockSourceCaseIterable() {
        let sources = ClockSource.allCases
        #expect(sources.count == 5)
        #expect(sources.contains(.internal))
        #expect(sources.contains(.wordClock))
        #expect(sources.contains(.loopSync))
        #expect(sources.contains(.ioBoard1))
        #expect(sources.contains(.ioBoard2))
    }

    // MARK: - BoardClockSource

    @Test func boardClockSourceCaseIterable() {
        let sources = BoardClockSource.allCases
        #expect(sources.count == 7)
        #expect(sources.contains(.aes12))
        #expect(sources.contains(.spdifCoax))
        #expect(sources.contains(.optical0))
    }

    // MARK: - SampleRate

    @Test func sampleRateRawValues() {
        #expect(SampleRate.rate44100.rawValue == 44100.0)
        #expect(SampleRate.rate48000.rawValue == 48000.0)
        #expect(SampleRate.rate96000.rawValue == 96000.0)
        #expect(SampleRate.rate192000.rawValue == 192000.0)
    }

    @Test func sampleRateDisplayNames() {
        #expect(SampleRate.rate44100.displayName == "44.1 kHz")
        #expect(SampleRate.rate48000.displayName == "48 kHz")
        #expect(SampleRate.rate192000.displayName == "192 kHz")
    }

    @Test func sampleRateCategories() {
        #expect(SampleRate.rate44100.isDouble == false)
        #expect(SampleRate.rate44100.isQuad == false)
        #expect(SampleRate.rate88200.isDouble == true)
        #expect(SampleRate.rate88200.isQuad == false)
        #expect(SampleRate.rate96000.isDouble == true)
        #expect(SampleRate.rate176400.isDouble == false)
        #expect(SampleRate.rate176400.isQuad == true)
        #expect(SampleRate.rate192000.isQuad == true)
    }

    @Test func sampleRateComparable() {
        #expect(SampleRate.rate44100 < SampleRate.rate48000)
        #expect(SampleRate.rate96000 < SampleRate.rate192000)
    }

    @Test func sampleRateAllCases() {
        let all = SampleRate.allCases
        #expect(all.count == 6)
        // Verify sorted order
        #expect(all == all.sorted())
    }

    // MARK: - ClockConfig

    @Test func clockConfigDefaults() {
        let config = ClockConfig()
        #expect(config.source == .internal)
        #expect(config.boardSource == nil)
        #expect(config.sampleRate == .rate48000)
        #expect(config.isClockMaster == true)
        #expect(config.wordClockTermination == false)
        #expect(config.status == .locked)
    }

    @Test func clockConfigWithBoardSource() {
        let config = ClockConfig(
            source: .ioBoard1,
            boardSource: .aes12,
            sampleRate: .rate96000,
            isClockMaster: false
        )
        #expect(config.source == .ioBoard1)
        #expect(config.boardSource == .aes12)
        #expect(config.isClockMaster == false)
    }

    @Test func clockConfigEquatable() {
        let a = ClockConfig()
        let b = ClockConfig()
        let c = ClockConfig(source: .wordClock)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Sample Rate Availability

    /// PID 18 (0x12): 32ch mode — only base rates.
    @Test func mode32chRates() {
        let rates = SampleRateAvailability.mode32ch
        #expect(rates.count == 2)
        #expect(rates.contains(.rate44100))
        #expect(rates.contains(.rate48000))
        #expect(!rates.contains(.rate88200))
    }

    /// PID 16 (0x10): 16ch mode — base + double rates.
    @Test func mode16chRates() {
        let rates = SampleRateAvailability.mode16ch
        #expect(rates.count == 4)
        #expect(rates.contains(.rate44100))
        #expect(rates.contains(.rate96000))
        #expect(!rates.contains(.rate176400))
    }

    /// PID 17 (0x11): 8ch mode — all rates.
    @Test func mode8chRates() {
        let rates = SampleRateAvailability.mode8ch
        #expect(rates.count == 6)
        #expect(rates.contains(.rate192000))
    }
}
