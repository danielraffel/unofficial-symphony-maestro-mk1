import Foundation
import Testing
@testable import MaestroApp
@testable import MaestroDevice
@testable import MaestroCore

@Suite("Unit B in the app")
struct UnitBAppTests {
    @Test("Sparse replay output cache keeps untouched defaults")
    func sparseReplayOutputOverlay() {
        let destinations: [UInt8] = [32, 33, 48, 49]
        let defaults: [UInt8: UInt8] = [32: 128, 33: 129, 48: 16, 49: 17]
        let saved: [UInt8: UInt8] = [32: 8, 33: 9]
        let merged = AppState.replayOutputSources(defaults: defaults, saved: saved,
                                                   complete: false, destinations: destinations)
        #expect(merged == [32: 8, 33: 9, 48: 16, 49: 17])
        let complete = AppState.replayOutputSources(defaults: defaults, saved: saved,
                                                     complete: true, destinations: destinations)
        #expect(complete == [32: 8, 33: 9, 48: SymphonyIORoutingAddress.none,
                             49: SymphonyIORoutingAddress.none])
    }

    @Test("Replay requested during recall is deferred until stores commit")
    func replayDeferral() {
        var state = ReplayDeferral()
        state.beginRecall()
        state.request()
        #expect(state.isInFlight())
        let released = state.finishRecall()
        #expect(released)
        #expect(!state.isInFlight())
        let releasedAgain = state.finishRecall()
        #expect(!releasedAgain)
    }

    @Test("Monitor writes keep their captured unit and Core Audio stays with A")
    func monitorUnitBoundaries() throws {
        let output = try source("OutputViews.swift")
        #expect(output.contains("monitorTarget = appState.unitWriteTarget"))
        #expect(output.contains("guard appState.isCurrent(monitorTarget), let device = monitorTarget.device"))
        #expect(output.contains("if monitorTarget.unit == .a { appState.writeASPVolume(level) }"))
        #expect(output.contains("if monitorTarget.unit == .a { appState.writeASPMute(speakerMuted) }"))
        #expect(!output.contains("if !channels.isEmpty && appState.activeUnit == .a"))
        let units = try source("AppState+UnitB.swift")
        #expect(units.contains("let devices = [device, unitBDevice].compactMap { $0 }"))
        #expect(units.contains("unitBMonitor = monitor"))
        #expect(units.contains("await monitor.refresh(from: connection)"))
        for file in ["MonitorViews.swift", "MaestroApp.swift"] {
            #expect(try source(file).contains("appState.clearMeters()"))
        }
    }

    @Test("Unit B output pairs route on XLink TX 32-63")
    func unitBRoutePairs() throws {
        let board0 = SymphonyIORoutingAddress.ioBoard0Base
        let board1 = SymphonyIORoutingAddress.ioBoard1Base
        // DAW 33-34 (grid row 16) to unit B's first pair.
        let daw = try #require(AppState.unitBRoutePair(destLeft: board0, gridRow: 16))
        #expect(daw.map(\.payload) == [Data([32, 96, 1]), Data([33, 97, 1])])
        // DAW 1-2 crosses to unit B's first output pair without a source offset.
        #expect(AppState.unitBRoutePair(destLeft: board0, gridRow: 0)?.map(\.payload)
                == [Data([32, 64, 1]), Data([33, 65, 1])])
        // DAW 1-2 to unit B's slot 2 output 3-4.
        let first = try #require(AppState.unitBRoutePair(destLeft: board1 + 2, gridRow: 0))
        #expect(first.map(\.payload) == [Data([50, 64, 1]), Data([51, 65, 1])])
        // Mixer 1 and Mixer 2 (grid rows 32, 33).
        #expect(AppState.unitBRoutePair(destLeft: board0, gridRow: 32)?.map(\.payload)
                == [Data([32, 128, 1]), Data([33, 129, 1])])
        #expect(AppState.unitBRoutePair(destLeft: board0 + 14, gridRow: 33)?.map(\.payload)
                == [Data([46, 130, 1]), Data([47, 131, 1])])
        // Clearing disables the channels on their own PCI_OUT slots.
        #expect(AppState.unitBRoutePair(destLeft: board0, gridRow: nil)?.map(\.payload)
                == [Data([32, 96, 0]), Data([33, 97, 0])])
        // A row past the mixers, or a destination that is not an output, is refused.
        #expect(AppState.unitBRoutePair(destLeft: board0, gridRow: 34) == nil)
        #expect(AppState.unitBRoutePair(destLeft: 0, gridRow: 0) == nil)
    }

    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroApp/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Input and Output pages read the chosen unit, never unit A's members directly")
    func perUnitPagesUseUnitMembers() throws {
        for file in ["InputViews.swift", "OutputViews.swift"] {
            let text = try source(file)
            for member in ["appState.device", "appState.channelStateStore", "appState.channelNaming",
                           "appState.inputMeterLevels", "appState.outputMeterLevels",
                           "appState.primaryBoardType", "appState.rememberDigitalSetting("] {
                #expect(!text.contains(member + " ") && !text.contains(member + ".")
                        && !text.contains(member + "?") && !text.contains(member + ")"),
                        "\(file) reads \(member)")
            }
            #expect(!text.contains("appState.cardLayout.") && !text.contains("appState.cardLayout }"),
                    "\(file) reads appState.cardLayout")
        }
    }

    @Test("The picker sits above the per-unit pages only, and rebuilds them on a change")
    func pickerPlacement() throws {
        let shell = try source("AppShell.swift")
        #expect(shell.contains("if isPerUnit && appState.unitPickerVisible {"))
        #expect(shell.contains("page.id(appState.activeUnit)"))
    }

    @Test("A write that awaits keeps to the unit it was made for")
    func writesKeepTheirUnit() throws {
        let input = try source("InputViews.swift")
        let output = try source("OutputViews.swift")
        for text in [input, output] {
            // Unit B's values never re-read the chosen unit after the await.
            #expect(!text.contains("appState.rememberUnitDigitalSetting("))
            #expect(!text.contains("appState.unitChannelNaming.spdifReplace["))
            #expect(text.contains("let target = appState.unitWriteTarget"))
            // Both pages retain the captured unit across suspension.
        }
        // Input type changes execute one immutable sequence and do not restore
        // an old phantom-ON snapshot after a partial hardware failure.
        #expect(input.contains("let sequence = writes"))
        #expect(input.contains("MicPreSettingsReplay.apply(sequence, layout: layout, device: device)"))
        #expect(output.contains("channels[index] == after"))
        #expect(input.contains("target.channelStore.save(saved, for: ChannelStateStore.inputKey)"))
        #expect(output.contains("target.channelStore.save(channels, for: ChannelStateStore.outputKey)"))
    }

    @Test("Digital settings are saved under the key they were taken with")
    func digitalSettingsKeyPerUnit() throws {
        let defaults = try #require(UserDefaults(suiteName: "UnitBAppTests.digital"))
        defaults.removePersistentDomain(forName: "UnitBAppTests.digital")
        SlotDigitalSettings.remember(.spdifReplaceID, slot: 0, value: 3,
                                     key: "slotDigitalSettings.unitB.x", defaults: defaults)
        #expect(SlotDigitalSettings.load(key: "slotDigitalSettings.unitB.x", defaults: defaults).spdifReplace[0] == 3)
        #expect(SlotDigitalSettings.load(key: "slotDigitalSettings.x", defaults: defaults).spdifReplace[0] == nil)
        defaults.removePersistentDomain(forName: "UnitBAppTests.digital")
    }

    @Test("Unit B's output routes are kept per unit B card pair")
    func unitBRoutingCacheScope() {
        #expect(AppState.unitBOutputRoutingDirection(cardScope: nil, simulating: false) == nil)
        #expect(AppState.unitBOutputRoutingDirection(cardScope: "optical+none", simulating: false)
                == "output.unitB.optical+none")
        #expect(AppState.unitBOutputRoutingDirection(cardScope: "optical+none", simulating: true)
                == "output.unitB.sim:optical+none")
    }

    @Test("Unit B's connection says Loop Sync")
    func unitBConnectionComment() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroDevice/ThunderboltUnitBConnection.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("a Word Clock slave of unit A"))
        #expect(text.contains("a Loop Sync slave of unit A"))
    }

    @Test("Converters: simulation keeps its own routes, presets spare converters, connect resets first")
    func converterApp() throws {
        #expect(AppState.converterRoutingStoreSignature("p1u1r03", simulated: true) == "sim:p1u1r03")
        #expect(AppState.converterRoutingStoreSignature("p1u1r03", simulated: false) == "p1u1r03")
        #expect(AppState.presetWritesSymphonySettings(connectedUnit: nil))
        #expect(!AppState.presetWritesSymphonySettings(connectedUnit: .ad16x))
        let state = try source("AppState.swift")
        #expect(state.contains("await replayConverterRouting(resetFirst: true)\n            return"))
        #expect(state.contains("system.driverSupportsConverterControls else { return nil }"))
        #expect(state.contains("isSimulatingCards: cardSimulation != nil || connectionMode == .simulated"))
    }

    @Test("Software Return 1-2 is saved only when the driver says unit B is gone")
    func softwareReturnResetNeedsAnAnswer() throws {
        let text = try source("AppState+UnitB.swift")
        #expect(text.contains("if confirmedAbsent { resetSoftwareReturnSourcesBeyondOneUnit() }"))
        #expect(text.contains("confirmedAbsent: state?.present == false"))
        let mixer = try source("MixerViews.swift")
        #expect(mixer.contains("let held = TwoUnitMixer.isHeld("))
    }
}
