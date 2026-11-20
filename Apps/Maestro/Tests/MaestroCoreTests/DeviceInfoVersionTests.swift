import Foundation
import Testing
@testable import MaestroCore

/// Device Settings › Info over ThunderBridge: the 0xA0 version replies, the
/// Hardware ID, the identity rows, Port 2 folding and the copied order.
@Suite("Device Info versions and layout")
struct DeviceInfoVersionTests {

    // MARK: - 0xA0 replies (SymphonyIOControl.cpp:1120-1142; SymphonyIO.cpp:1436-1445)

    @Test func replyIsExactlyThreeBytes() {
        let two = SymphonyVersionReply(data: Data([1, 2]))
        let four = SymphonyVersionReply(data: Data([1, 2, 3, 4]))
        let empty = SymphonyVersionReply(data: Data())
        let zero = SymphonyVersionReply(data: Data([0, 0, 0]))
        #expect(two == nil)
        #expect(four == nil)
        #expect(empty == nil)
        #expect(zero == SymphonyVersionReply(major: 0, minor: 0, build: 0))
    }

    @Test func overallIsBCDPerField() {
        let reply = SymphonyVersionReply(major: 0x01, minor: 0x06, build: 0x72)
        let text = SymphonyVersionComponent.overall.displayText(reply)
        #expect(text == "1.6.72")
        let tens = SymphonyVersionReply(major: 0x12, minor: 0x34, build: 0x09)
        let tensText = SymphonyVersionComponent.overall.displayText(tens)
        #expect(tensText == "12.34.9")
    }

    @Test func fpgaIsMajorInHex() {
        let reply = SymphonyVersionReply(major: 0x73, minor: 9, build: 9)
        for component: SymphonyVersionComponent in [.mainFPGA, .primaryFPGA, .secondaryFPGA] {
            let text = component.displayText(reply)
            #expect(text == "v73")
        }
        let hexReply = SymphonyVersionReply(major: 0x3B, minor: 0, build: 0)
        let hexText = SymphonyVersionComponent.primaryFPGA.displayText(hexReply)
        #expect(hexText == "v3B")
    }

    @Test func hardwareIsMajorOnly() {
        let reply = SymphonyVersionReply(major: 2, minor: 0, build: 0)
        for component: SymphonyVersionComponent in [.mainBoardHardware, .primaryBoardHardware, .secondaryBoardHardware] {
            let text = component.displayText(reply)
            #expect(text == "2")
        }
    }

    @Test func componentNumberingMatchesTheOriginal() {
        let raw = SymphonyVersionComponent.allCases.map(\.rawValue)
        let expected: [UInt32] = [0, 1, 2, 3, 4, 5, 6]
        #expect(raw == expected)
        #expect(SymphonyVersionComponent.fpga(slot: 1) == .secondaryFPGA)
        #expect(SymphonyVersionComponent.hardware(slot: 0) == .primaryBoardHardware)
    }

    @Test func boardFPGAOnlyForInstalledNonMicPreBoards() {
        let both = SymphonyVersions.componentsToRead(slot1: .analogADDA16, slot2: .optical)
        let bothExpected: [SymphonyVersionComponent] = [.overall, .mainFPGA, .primaryFPGA, .secondaryFPGA]
        #expect(both == bothExpected)
        let micPre = SymphonyVersions.componentsToRead(slot1: .micPre8, slot2: .analogAES)
        let micPreExpected: [SymphonyVersionComponent] = [.overall, .mainFPGA, .secondaryFPGA]
        #expect(micPre == micPreExpected)
        let empty = SymphonyVersions.componentsToRead(slot1: IOCardType.none, slot2: nil)
        let emptyExpected: [SymphonyVersionComponent] = [.overall, .mainFPGA]
        #expect(empty == emptyExpected)
    }

    @Test func readStopsAtFirstFailureShortReplyOrRefusal() {
        let all: [SymphonyVersionComponent] = [.overall, .mainFPGA, .primaryFPGA, .secondaryFPGA]
        var asked: [SymphonyVersionComponent] = []
        let full = SymphonyVersions.read(all, allowed: { true }) { component in
            asked.append(component)
            return Data([UInt8(component.rawValue), 0, 0])
        }
        #expect(asked == all)
        #expect(full.text(.mainFPGA) == "v1")
        #expect(full.text(.overall) == "0.0.0")

        asked = []
        let failing = SymphonyVersions.read(all, allowed: { true }) { component in
            asked.append(component)
            if component == .primaryFPGA { throw CancellationError() }
            return Data([1, 2, 3])
        }
        #expect(asked.count == 3)
        #expect(failing.replies.count == 2)
        #expect(failing.text(.primaryFPGA) == nil)

        asked = []
        let short = SymphonyVersions.read(all, allowed: { true }) { component in
            asked.append(component)
            return component == .overall ? Data([1, 2]) : Data([1, 2, 3])
        }
        #expect(asked.count == 1)
        #expect(short.replies.isEmpty)

        var allowedCalls = 0
        let refused = SymphonyVersions.read(all, allowed: {
            allowedCalls += 1
            return allowedCalls < 2
        }) { _ in Data([1, 2, 3]) }
        #expect(refused.replies.count == 1)
        #expect(allowedCalls == 2)
    }

    // MARK: - Hardware ID (SymphonyIOControl.cpp:1203-1207; SymphonyIO.cpp:1434)

    @Test func hardwareIDMasksTheTopByteUppercaseHex() {
        let id: UInt64 = 0xFF01_0203_0405_06AB
        let text = SymphonyHardwareID.text(id)
        #expect(text == "10203040506AB")
        #expect(SymphonyHardwareID.text(0x1234) == "1234")
    }

    // MARK: - Identity rows without repeats

    @Test func usbNameAlreadySaysModeAndChannels() {
        let report = DeviceInfoReport(deviceName: "Symphony I/O (16-Channel (up to 96 kHz))",
                                      connection: "USB Hardware", deviceModel: "Symphony I/O",
                                      mode: "16-Channel (up to 96 kHz)", channelCount: 16)
        let labels = report.identityRows.map(\.label)
        #expect(labels == ["Device Name", "Connection"])
        let text = report.clipboardText
        #expect(!text.contains("Device Model"))
        #expect(!text.contains("Mode:"))
        #expect(!text.contains("Channel Count"))
    }

    @Test func thunderboltShowsChannelCountOnce() {
        let report = DeviceInfoReport(deviceName: "Symphony I/O", connection: "Thunderbolt (ThunderBridge)",
                                      deviceModel: "Symphony I/O (32-Channel (44.1/48 kHz))", channelCount: 64)
        let rows = report.identityRows.map { "\($0.label): \($0.value)" }
        let expected = ["Device Name: Symphony I/O", "Connection: Thunderbolt (ThunderBridge)", "Channel Count: 64"]
        #expect(rows == expected)
    }

    @Test func modeShownWhenNameDoesNotSayIt() {
        let report = DeviceInfoReport(deviceName: "Symphony I/O", connection: "USB Hardware",
                                      mode: "32-Channel (44.1/48 kHz)", channelCount: 32)
        let labels = report.identityRows.map(\.label)
        let expected = ["Device Name", "Connection", "Mode"]
        #expect(labels == expected)
    }

    // MARK: - ThunderBridge report

    private func thunderboltReport() -> DeviceInfoReport {
        var report = DeviceInfoReport(
            deviceName: "Symphony I/O", connection: "Thunderbolt (ThunderBridge)",
            firmwareVersion: "1.6.72", fpgaVersion: "v73", hardwareID: "1020304050607",
            board1: BoardTypeReading(card: .analogADDA16, source: .detected, hardwareMajor: 2),
            board1Version: "v33",
            board2: .detected(.micPre8),
            channelCount: 32)
        report.showsXMOS = false
        report.board1HardwareVersion = "2"
        return report
    }

    @Test func thunderboltCopyHasNoXMOSAndCarriesCardVersions() {
        let text = thunderboltReport().clipboardText
        #expect(!text.contains("XMOS"))
        #expect(text.contains("Hardware Version: 2"))
        #expect(text.contains("Version: v33"))
        #expect(text.contains("Firmware: 1.6.72"))
        #expect(text.contains("Hardware ID: 1020304050607"))
    }

    @Test func usbCopyKeepsXMOS() {
        let report = DeviceInfoReport(connection: "USB Hardware", xmosVersion: "1.6.72")
        let text = report.clipboardText
        #expect(text.contains("XMOS Version: 1.6.72"))
    }

    @Test func boardLineAddsHardwareOnlyWhenRead() {
        let line = DeviceInfoReport.boardLine(.detected(.optical), version: "v33", hardwareVersion: "4")
        #expect(line == "8x8 OPT (detected), Version: v33, Hardware Version: 4")
        let without = DeviceInfoReport.boardLine(.detected(.optical), version: nil)
        #expect(without == "8x8 OPT (detected), Version: Unknown")
    }

    // MARK: - Port 2

    @Test func port2FoldsAtThirtyTwoChannelsWithNothingOnIt() {
        let idle = SecondPortState(portCount: 2, flags: 0x0F)
        #expect(idle.reportLines.count >= 5)
        let folded = idle.reportLines(sixtyFourSelected: false)
        #expect(folded == ["Port 1: in use (channels 1–32)", "Port 2: not in use"])
        let detailed = idle.reportLines(sixtyFourSelected: true)
        #expect(detailed == ["Port 1: in use (channels 1–32)"] + idle.reportLines)
    }

    @Test func port2DetailsWhenSomethingIsOnIt() {
        let unit = SecondPortState(portCount: 2, flags: 0x0F, units: [0x0005_0030])
        #expect(!unit.isNotInUse(sixtyFourSelected: false))
        let running = SecondPortState(portCount: 2, audio: SecondPortState.audioActiveFlag)
        #expect(!running.isNotInUse(sixtyFourSelected: false))
        #expect(running.reportLines(sixtyFourSelected: true).prefix(2)
                == ["Port 1: in use (channels 1–32)", "Port 2: in use (channels 33–64)"])
        let off = SecondPortState(portCount: 1)
        #expect(!off.isNotInUse(sixtyFourSelected: false))
        #expect(off.reportLines(sixtyFourSelected: false).isEmpty)
    }

    @Test func sixtyFourSelectedCountsAPendingSwitch() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: PortSelection.port1.rawValue, state: nil)
        let atThirtyTwo = model.sixtyFourSelected
        #expect(!atThirtyTwo)
        _ = model.userChose(.ports1And2)
        let pending = model.sixtyFourSelected
        #expect(pending)
    }

    // MARK: - Copy order

    @Test func copyOrderIsIdentityIDFirmwareFPGACardsUnitBPort2() {
        var report = thunderboltReport()
        report.unitBLines = ["Unit B Firmware: 1.6.72"]
        report.port2Lines = [SecondPortState.port1Line, SecondPortState.notInUseLine]
        let lines = report.clipboardText.split(separator: "\n").map(String.init)
        let prefixes = ["Device Name", "Connection", "Channel Count", "Hardware ID", "Firmware", "FPGA version",
                        "IOBoard1", "IOBoard2", "Unit B", "Port 1", "Port 2"]
        let found = prefixes.map { prefix in lines.firstIndex { $0.hasPrefix(prefix) } ?? -1 }
        #expect(!found.contains(-1))
        #expect(found == found.sorted())
        #expect(lines.count == prefixes.count)
    }
}

@Suite("Device Info hardware versions")
struct DeviceInfoHardwareVersionTests {
    @Test func onlyAnInstalledBoardHasAHardwareVersion() {
        let installed = BoardTypeReading(card: .optical, source: .detected, hardwareMajor: 3)
        let empty = BoardTypeReading(card: .none, source: .detected, hardwareMajor: 0)
        let unknown = BoardTypeReading(card: .none, source: .unknown, hardwareMajor: 0)
        let unread = BoardTypeReading(card: .optical, source: .detected, hardwareMajor: nil)
        #expect(DeviceInfoReport.hardwareVersionText(installed) == "3")
        #expect(DeviceInfoReport.hardwareVersionText(empty) == nil)
        #expect(DeviceInfoReport.hardwareVersionText(unknown) == nil)
        #expect(DeviceInfoReport.hardwareVersionText(unread) == nil)
    }
}
