import Testing
@testable import MaestroCore

/// Device Info panel / Copy button tests.
///
/// The panel's text is a pure function of (device name, connection, firmware,
/// board 1 reading, board 2 reading), so the exact clipboard output is testable
/// exhaustively without hardware — all 8 card values in slot 1 crossed with all
/// 8 in slot 2, in every provenance state.
///
/// The point of the provenance is honesty: card detection (`0xA1`, a `0xC0`
/// vendor EP0 read) currently FAILS on USB, and the panel used to present the
/// stale `UserDefaults` value as fact.
@Suite("Device Info report")
struct DeviceInfoReportTests {

    // MARK: - Provenance wording

    @Test func detectedReadingNamesTheProductAndSaysDetected() {
        let r = BoardTypeReading.detected(.optical)
        #expect(r.displayText == "8x8 OPT (detected)")
        #expect(r.source.isTrustworthy)
    }

    @Test func cachedReadingSaysItWasNotDetectedThisSession() {
        let r = BoardTypeReading.cached(.analogAD16)
        #expect(r.displayText == "16 Analog In / 16 Digital Out (cached — not detected this session)")
        #expect(r.source.isTrustworthy == false)
    }

    @Test func unknownReadingNamesNoCard() {
        let r = BoardTypeReading.unknown
        #expect(r.displayText == "Unknown (not detected)")
        #expect(r.source.isTrustworthy == false)
        // Crucially it must NOT claim "None" — an empty slot and a failed read
        // are different claims.
        #expect(!r.displayText.contains("None"))
    }

    @Test func simulatedReadingSaysItIsNotRealHardware() {
        let r = BoardTypeReading(card: .micPre8, source: .simulated)
        #expect(r.displayText == "8MicPre (simulated — not real hardware)")
        #expect(r.source.isTrustworthy == false)
    }

    @Test func detectedEmptySlotStillSaysNoneNotUnknown() {
        #expect(BoardTypeReading.detected(.none).displayText == "None (detected)")
    }

    @Test func detailedTextFoldsInTheTechnicalDescriptor() {
        let r = BoardTypeReading.detected(.optical)
        #expect(r.detailedText
                == "8x8 OPT (8 analog I/O + 8 ADAT optical I/O + 2 S/PDIF) (detected)")
        #expect(BoardTypeReading.unknown.detailedText == "Unknown (not detected)")
    }

    // MARK: - resolve()

    @Test func resolvePrefersALiveRead() {
        let r = BoardTypeReading.resolve(live: .optical, cached: .analogAES)
        #expect(r == .detected(.optical))
    }

    @Test func resolveFallsBackToCacheAndSaysSo() {
        let r = BoardTypeReading.resolve(live: nil, cached: .analogAD16)
        #expect(r.source == .cached)
        #expect(r.card == .analogAD16)
    }

    @Test func resolveWithNothingIsUnknown() {
        #expect(BoardTypeReading.resolve(live: nil, cached: nil) == .unknown)
    }

    /// A cached `.none` is a cached value, not an unknown one — the caller
    /// distinguishes "no cache entry" (nil) from "cache says empty" (.none).
    @Test func resolveTreatsCachedNoneAsCached() {
        let r = BoardTypeReading.resolve(live: nil, cached: IOCardType.none)
        #expect(r.source == .cached)
        #expect(r.card == IOCardType.none)
    }

    @Test func resolveMarksSimulationEvenWhenItLooksLive() {
        let r = BoardTypeReading.resolve(live: .micPre8, cached: nil, isSimulated: true)
        #expect(r.source == .simulated)
        #expect(r.card == .micPre8)
    }

    // MARK: - Board line

    @Test func boardLineAppendsVersionWhenKnown() {
        #expect(DeviceInfoReport.boardLine(.detected(.optical), version: "v33")
                == "8x8 OPT (detected), Version: v33")
        #expect(DeviceInfoReport.boardLine(.detected(.optical), version: nil)
                == "8x8 OPT (detected)")
        #expect(DeviceInfoReport.boardLine(.detected(.optical), version: "")
                == "8x8 OPT (detected)")
    }

    /// An unknown slot must not carry a version — a version we cannot attribute
    /// to a known board is worse than no version.
    @Test func boardLineDropsVersionForUnknownSlot() {
        #expect(DeviceInfoReport.boardLine(.unknown, version: "v33") == "Unknown (not detected)")
    }

    // MARK: - The user's actual hardware

    /// The dev unit reports Optical (3) + AnalogAD16 (4). Whatever else changes,
    /// this pairing must render with the right Apogee names.
    @Test func devUnitRendersCorrectly() {
        let report = DeviceInfoReport(
            connection: "USB Hardware",
            firmwareVersion: "1.6.72",
            board1: .detected(.optical),
            board2: .detected(.analogAD16)
        )
        let text = report.clipboardText
        #expect(text.contains("IOBoard1: 8x8 OPT (detected)"))
        #expect(text.contains("IOBoard2: 16 Analog In / 16 Digital Out (detected)"))
        #expect(report.hasUnverifiedBoardTypes == false)
    }

    /// The same unit as it actually behaves today: detection fails, values come
    /// from cache, and the panel must admit it.
    @Test func devUnitFromCacheIsLabelledAsCached() {
        let report = DeviceInfoReport(
            connection: "USB Hardware",
            firmwareVersion: "1.6.72",
            board1: .cached(.optical),
            board2: .cached(.analogAD16)
        )
        let text = report.clipboardText
        #expect(text.contains("IOBoard1: 8x8 OPT (cached — not detected this session)"))
        #expect(text.contains("IOBoard2: 16 Analog In / 16 Digital Out (cached — not detected this session)"))
        #expect(report.hasUnverifiedBoardTypes)
    }

    // MARK: - Full clipboard shape

    @Test func clipboardTextFullShape() {
        let report = DeviceInfoReport(
            deviceName: "Symphony I/O (16-Channel (up to 96 kHz))",
            connection: "USB Hardware",
            firmwareVersion: "1.6.72",
            fpgaVersion: "v73",
            hardwareID: "ABC123",
            xmosVersion: "5.4c",
            board1: .detected(.optical),
            board1Version: "v33",
            board2: .detected(.analogAD16),
            board2Version: "v12",
            deviceModel: "Symphony I/O",
            mode: "16-Channel (up to 96 kHz)",
            channelCount: 16
        )
        let expected = """
        Device Name: Symphony I/O (16-Channel (up to 96 kHz))
        Connection: USB Hardware
        Firmware: 1.6.72
        FPGA version: v73
        Hardware ID: ABC123
        IOBoard1: 8x8 OPT (detected), Version: v33
        IOBoard2: 16 Analog In / 16 Digital Out (detected), Version: v12
        XMOS Version: 5.4c
        Device Model: Symphony I/O
        Mode: 16-Channel (up to 96 kHz)
        Channel Count: 16
        """
        #expect(report.clipboardText == expected)
    }

    @Test func clipboardTextOmitsMissingFieldsButNeverTheBoards() {
        let report = DeviceInfoReport(connection: "Thunderbolt (ThunderBridge)")
        let lines = report.clipboardText.split(separator: "\n").map(String.init)
        #expect(lines == [
            "Device Name: Symphony I/O",
            "Connection: Thunderbolt (ThunderBridge)",
            "IOBoard1: Unknown (not detected)",
            "IOBoard2: Unknown (not detected)",
        ])
    }

    // MARK: - Exhaustive: all 8 x 8 card combinations

    /// Every slot-1 value crossed with every slot-2 value, detected.
    /// Each line must carry the Apogee product name and the provenance.
    @Test func allSixtyFourCombinationsRenderProductNamesAndProvenance() {
        var seen = 0
        for c1 in IOCardType.allCases {
            for c2 in IOCardType.allCases {
                let report = DeviceInfoReport(
                    connection: "USB Hardware",
                    board1: .detected(c1),
                    board2: .detected(c2)
                )
                let text = report.clipboardText
                #expect(text.contains("IOBoard1: \(c1.productName) (detected)"),
                        "slot1 \(c1) rendered as: \(text)")
                #expect(text.contains("IOBoard2: \(c2.productName) (detected)"),
                        "slot2 \(c2) rendered as: \(text)")
                #expect(report.hasUnverifiedBoardTypes == false)
                seen += 1
            }
        }
        #expect(seen == 64)
    }

    /// The same 64 combinations, cached — every one must be labelled as such.
    @Test func allSixtyFourCombinationsCachedAreLabelledUnverified() {
        for c1 in IOCardType.allCases {
            for c2 in IOCardType.allCases {
                let report = DeviceInfoReport(
                    connection: "USB Hardware",
                    board1: .cached(c1),
                    board2: .cached(c2)
                )
                let text = report.clipboardText
                #expect(text.contains("IOBoard1: \(c1.productName) (cached — not detected this session)"))
                #expect(text.contains("IOBoard2: \(c2.productName) (cached — not detected this session)"))
                #expect(report.hasUnverifiedBoardTypes)
            }
        }
    }

    /// Mixed provenance: a detected slot 1 with a cached slot 2 still flags.
    @Test func mixedProvenanceStillFlagsUnverified() {
        for c1 in IOCardType.allCases {
            for c2 in IOCardType.allCases {
                let report = DeviceInfoReport(
                    connection: "USB Hardware",
                    board1: .detected(c1),
                    board2: .cached(c2)
                )
                #expect(report.hasUnverifiedBoardTypes,
                        "\(c1)/\(c2): a cached slot must flag the report")
            }
        }
    }

    /// No two card values may render to the same slot line — that ambiguity is
    /// exactly the bug this rename fixes.
    @Test func allEightCardsRenderDistinctSlotLines() {
        let lines = IOCardType.allCases.map { DeviceInfoReport.boardLine(.detected($0), version: nil) }
        #expect(Set(lines).count == 8)
    }
}
