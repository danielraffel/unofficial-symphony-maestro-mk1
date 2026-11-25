import Foundation
import Testing
@testable import MaestroApp
@testable import MaestroDevice
@testable import MaestroCore

@Suite("Device Info in the app", .serialized)
@MainActor
struct DeviceInfoAppTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func swiftSources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var result: [(String, String)] = []
        for folder in ["MaestroApp", "MaestroDevice", "MaestroCore"] {
            let dir = root.appendingPathComponent(folder)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
            for name in names {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                result.append(("\(folder)/\(name)", text))
            }
        }
        return result
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The 0xA0 version reads have one trigger: Device Settings' properties load.
    @Test func versionReadsOnlyFromTheDeviceSettingsLoad() throws {
        var readCallers: [String] = []
        var loadCallers: [String] = []
        for file in try swiftSources() {
            let reads = occurrences(of: ".readSymphonyVersions(", in: file.text)
            if reads > 0 { readCallers.append("\(file.name)×\(reads)") }
            let loads = occurrences(of: ".loadThunderboltVersions(", in: file.text)
            if loads > 0 { loadCallers.append("\(file.name)×\(loads)") }
        }
        #expect(readCallers == ["MaestroApp/AppState+DeviceVersions.swift×1"])
        #expect(loadCallers == ["MaestroApp/SettingsViews.swift×1"])

        let settings = try source("MaestroApp/SettingsViews.swift")
        let load = try #require(settings.range(of: "private func loadProperties() async {"))
        let call = try #require(settings.range(of: ".loadThunderboltVersions("))
        let after = settings[load.upperBound...]
        let nextFunction = after.range(of: "\n    private func ")?.lowerBound ?? settings.endIndex
        #expect(call.lowerBound > load.upperBound)
        #expect(call.lowerBound < nextFunction)
        // Its only trigger is the page's `.task(id: appState.viewReloadToken)`.
        let triggers = occurrences(of: "await loadProperties()", in: settings)
        #expect(triggers == 1)

        // Nothing on the connect, recovery or timer paths names it.
        let appState = try source("MaestroApp/AppState.swift")
        #expect(!appState.contains("loadThunderboltVersions"))
        #expect(!appState.contains("readSymphonyVersions"))
    }

    /// Device Info's Copy button copies the same Device-then-Software text
    /// as the About box, from this page's report.
    @Test func deviceInfoCopyIsTheAboutBoxText() throws {
        let settings = try source("MaestroApp/SettingsViews.swift")
        #expect(settings.contains("appState.deviceInfoSnapshot = currentDeviceReport()\n"
            + "                        NSPasteboard.general.clearContents()\n"
            + "                        NSPasteboard.general.setString(appState.diagnosticsText, forType: .string)"))
        #expect(!settings.contains("setString(currentDeviceReport().clipboardText"))
    }

    /// A simulated connection is never a ThunderBridge, whatever the transport says.
    @Test func noReadsWithoutAThunderBridgeConnection() {
        let state = AppState()
        state.device = SimulatedDevice.symphonyIO32ch()
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        #expect(!state.thunderboltVersionReadsAllowed)
        state.transportType = .usb
        #expect(!state.thunderboltVersionReadsAllowed)
    }

    /// The gate opens for a ThunderBridge Symphony I/O with known cards, and
    /// closes for a converter on the cable or while two units sleep.
    @Test func gateOpensOnlyForAnAwakeThunderBridgeSymphony() {
        let state = AppState()
        state.device = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                                   audioDeviceID: 0, settingsStore: DeviceSettingsStore())
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.primaryBoardType = .analogADDA16
        state.secondaryBoardType = .optical
        let open = state.thunderboltVersionReadsAllowed
        #expect(open)
        state.hardwareSleepState = .sleeping
        let asleep = state.thunderboltVersionReadsAllowed
        #expect(!asleep)
        state.hardwareSleepState = .awake
        state.connectedUnit = .da16x
        let converter = state.thunderboltVersionReadsAllowed
        #expect(!converter)
    }

    /// The About box's copy: Device then Software, with the hardware ID even
    /// before Device Settings has been opened, and no XMOS line over ThunderBridge.
    @Test func aboutCopyOrderAndFallbackHardwareID() {
        let state = AppState()
        state.device = SimulatedDevice.symphonyIO32ch()
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.unitAIdentity = 0xFF01_0203_0405_06AB
        let text = state.diagnosticsText
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let order = ["Device Name:", "Connection:", "Channel Count:", "Hardware ID: 10203040506AB",
                     "Firmware:", "FPGA version:", "IOBoard1:", "IOBoard2:",
                     "Maestro:", "macOS:", "Audio path:", "Driver extension:", "App path:"]
        let found = order.map { prefix in lines.firstIndex { $0.hasPrefix(prefix) } ?? -1 }
        #expect(!found.contains(-1), "\(text)")
        #expect(found == found.sorted(), "\(text)")
        #expect(!text.contains("XMOS"))
        #expect(!text.contains("Device Model"))
        #expect(!text.contains("Mode:"))
    }

    @Test func snapshotGetsTheIdentityToo() {
        let state = AppState()
        state.device = SimulatedDevice.symphonyIO32ch()
        state.connectionMode = .hardware
        state.transportType = .usb
        state.deviceInfoSnapshot = DeviceInfoReport(connection: "USB Hardware")
        state.unitAIdentity = 0xABC
        let report = state.deviceInfoReportForDiagnostics
        #expect(report?.hardwareID == "ABC")
        #expect(report?.showsXMOS == true)
    }
}
