import Foundation
import Testing
@testable import MaestroCore

@Suite("VBus: entries, labels, persistence, driver gating")
struct VBusTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func defaults() -> UserDefaults {
        let name = "VBusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("the pop-up is the original's: None, then 2, 4, 8, 16, 32, 48 and 64 Channels, in that order")
    func entries() {
        #expect(VBusChannels.allCases.map(\.label) == [
            "None", "2 Channels", "4 Channels", "8 Channels", "16 Channels", "32 Channels", "48 Channels", "64 Channels",
        ])
        #expect(VBusChannels.allCases.map(\.rawValue) == [0, 2, 4, 8, 16, 32, 48, 64])
    }

    @Test("the sizes are the ones the driver accepts, and nothing else")
    func sizesMatchTheDriver() throws {
        let header = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "Drivers/Thunderbolt/Source/SymphonyThunderbridgeShared.h"), encoding: .utf8)
        let line = try #require(header.split(separator: "\n").first { $0.contains("return n == 0 ||") })
        let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { UInt32($0) }
        #expect(Set(numbers) == Set(VBusChannels.allCases.map(\.rawValue)))
        #expect(header.contains("#define kSelectorVBus           16"))
        #expect(header.contains("typedef struct { uint32_t magic, operation, channels; } SymphonyVBusInput;"))
        #expect(header.contains("typedef struct { uint32_t published, requested, firstChannel, flags; } SymphonyVBusStateOutput;"))
        #expect(VBusState.wordCount == 4)
    }

    @Test("the channel names are the ones the driver publishes")
    func names() throws {
        #expect(VBusChannels.outputName(1) == "VBout 1")
        #expect(VBusChannels.inputName(16) == "VBin 16")
        let driver = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "Drivers/Thunderbolt/Source/SymphonyThunderbridge.cpp"), encoding: .utf8)
        #expect(driver.contains(#"input ? "VBin %u" : "VBout %u""#))
    }

    @Test("None is the default, and a choice is saved for its card only")
    func persistence() {
        let d = defaults()
        #expect(VBusChannels.saved(in: d, deviceUID: "card-1") == .none)
        VBusChannels.eight.save(in: d, deviceUID: "card-1")
        #expect(VBusChannels.saved(in: d, deviceUID: "card-1") == .eight)
        #expect(VBusChannels.saved(in: d, deviceUID: "card-2") == .none)
        VBusChannels.sixtyFour.save(in: d, deviceUID: "card-2")
        #expect(VBusChannels.saved(in: d, deviceUID: "card-1") == .eight)
        VBusChannels.none.save(in: d, deviceUID: "card-1")
        #expect(VBusChannels.saved(in: d, deviceUID: "card-1") == .none)
        #expect(VBusChannels.saved(in: d, deviceUID: "card-2") == .sixtyFour)
    }

    @Test("a saved value that is no entry reads as None")
    func badSavedValue() {
        let d = defaults()
        for bad: Any in [3, 12, 128, -8, "8 Channels", 4_294_967_304 as Int64] {
            d.set(bad, forKey: VBusChannels.defaultsKey(deviceUID: "card"))
            #expect(VBusChannels.saved(in: d, deviceUID: "card") == .none, "\(bad)")
        }
    }

    @Test("only a driver from build 143 on is asked")
    func driverGate() {
        #expect(VBusChannels.requiredDriverBuild == 143)
        #expect(!VBusChannels.driverSupports(nil))
        #expect(!VBusChannels.driverSupports(.olderThanBuildReporting))
        #expect(!VBusChannels.driverSupports(.build(142)))
        #expect(!VBusChannels.driverSupports(.build(0)))
        #expect(VBusChannels.driverSupports(.build(143)))
        #expect(VBusChannels.driverSupports(.build(200)))
    }

    @Test("an older driver gives a reason; an unread or a current one gives none")
    func unavailableReason() throws {
        #expect(VBusChannels.unavailableReason(servingBuild: nil) == nil)
        #expect(VBusChannels.unavailableReason(servingBuild: .build(143)) == nil)
        for old: ServingDextBuild in [.build(142), .olderThanBuildReporting] {
            let reason = try #require(VBusChannels.unavailableReason(servingBuild: old))
            #expect(reason.contains("older") && reason.contains("Restart the Mac"))
        }
    }

    @Test("the page says to quit and reopen applications, then to restart the Mac, and never calls VBus experimental")
    func text() {
        let all = VBusChannels.explanationLines + VBusChannels.helpText
        #expect(VBusChannels.explanationLines.contains {
            $0.contains("quit and reopen your audio applications") && $0.contains("restart the Mac")
        })
        #expect(VBusChannels.helpText.contains {
            $0.contains("quit and reopen your audio applications") && $0.contains("restart the Mac")
        })
        for line in all { #expect(!line.lowercased().contains("experiment"), "\(line)") }
        #expect(VBusChannels.helpText.joined().contains("not over USB"))
        #expect(VBusChannels.helpText.joined().contains("VBout 1") && VBusChannels.helpText.joined().contains("VBin 1"))
    }

    @Test("the VBus channels are placed after the hardware channels")
    func placement() {
        #expect(VBusChannels.placementLine(channels: .none, hardwareChannels: 32) == nil)
        #expect(VBusChannels.placementLine(channels: .eight, hardwareChannels: 32)?.contains("33–40") == true)
        #expect(VBusChannels.placementLine(channels: .eight, hardwareChannels: 64)?.contains("65–72") == true)
        #expect(VBusChannels.placementLine(channels: .sixtyFour, hardwareChannels: 64)?.contains("65–128") == true)
    }

    @Test("per-channel values read from the device keep the hardware channels only")
    func hardwareOnly() {
        let forty = (0..<40).map { Float($0) }
        #expect(VBusChannels.hardwareOnly(forty, hardwareChannels: 32) == Array(forty.prefix(32)))
        #expect(VBusChannels.hardwareOnly(Array(forty.prefix(32)), hardwareChannels: 32).count == 32)
        #expect(VBusChannels.hardwareOnly(Array(forty.prefix(2)), hardwareChannels: 32).count == 2)
        let sixtyFour = (0..<64).map { Float($0) }   // the meter tap's limit: 32 hardware + 32 VBus, or 64 hardware
        #expect(VBusChannels.hardwareOnly(sixtyFour, hardwareChannels: 32).count == 32)
        #expect(VBusChannels.hardwareOnly(sixtyFour, hardwareChannels: 64) == sixtyFour)
        #expect(VBusChannels.hardwareOnly([Float](), hardwareChannels: 32).isEmpty)
    }

    @Test("the driver's state decodes from four words")
    func state() throws {
        let s = try #require(VBusState(words: [8, 16, 33, 0]))
        #expect(s.published == 8 && s.requested == 16 && s.firstChannel == 33 && !s.publishFailed)
        #expect(VBusState(words: [8, 16, 33]) == nil)
        #expect(VBusState(words: [0, 0, 0, 1])?.publishFailed == true)
        #expect(s.statusLine(chosen: .sixteen) == "Changing…")
        #expect(s.statusLine(chosen: .eight) == nil)
        #expect(VBusState(words: [0, 0, 0, 1])?.statusLine(chosen: .eight)?.contains("could not add") == true)
    }

    @Test("the diagnostics line carries the choice and what the driver reports")
    func reportLine() {
        let on = VBusState(published: 8, requested: 8, firstChannel: 65, flags: 0)
        #expect(VBusState.reportLine(chosen: .eight, state: on, driverSupports: true)
                == "VBus: 8 Channels (driver: 8 published, 8 requested, first channel 65)")
        #expect(VBusState.reportLine(chosen: VBusChannels.none, state: VBusState(published: 0, requested: 0, firstChannel: 0, flags: 0),
                                     driverSupports: true) == "VBus: None (driver: 0 published, 0 requested)")
        #expect(VBusState.reportLine(chosen: .eight, state: nil, driverSupports: true) == "VBus: 8 Channels (driver state not read)")
        #expect(VBusState.reportLine(chosen: .eight, state: nil, driverSupports: false).contains("older than build 143"))
        #expect(VBusState.reportLine(chosen: .two, state: VBusState(published: 0, requested: 0, firstChannel: 0, flags: 1),
                                     driverSupports: true).contains("flags 0x1"))
    }

    @Test("the report's device section includes the VBus line when there is one")
    func reportIncludesLine() {
        var report = DeviceInfoReport(deviceName: "Symphony I/O", connection: "ThunderBridge",
                                      board1: BoardTypeReading(card: .analogADDA16, source: .detected),
                                      board2: BoardTypeReading(card: .none, source: .detected))
        #expect(!report.clipboardText.contains("VBus"))
        report.vbusLine = "VBus: 8 Channels (driver: 8 published, 8 requested, first channel 33)"
        #expect(report.clipboardText.split(separator: "\n").last == "VBus: 8 Channels (driver: 8 published, 8 requested, first channel 33)")
    }

    @Test("the Core Audio list shows the hardware and VBus streams apart")
    func channelCountText() {
        #expect(VBusState.channelCountText(streams: [32]) == "32")
        #expect(VBusState.channelCountText(streams: [64]) == "64")
        #expect(VBusState.channelCountText(streams: [32, 8]) == "40 (streams 32+8)")
        #expect(VBusState.channelCountText(streams: [64, 64]) == "128 (streams 64+64)")
        #expect(VBusState.channelCountText(streams: []) == "0")
    }
}
