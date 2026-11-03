// Diagnostics.swift — the one report a bug report needs, assembled in one place.
//
// Two panels show this material: Device Info ("what hardware is this") and Software Info
// ("what code is running"). Telling someone to press two Copy buttons on a settings page
// loses half the report half the time, so the About box copies both at once and Help
// points at that single button.

import Foundation
import MaestroCore

extension AppState {

    /// Re-read which driver extensions are registered.
    ///
    /// Cheap — a 3 KB plist — so the panels that show it refresh on appear rather than
    /// trusting a launch-time snapshot taken before an activation had finished.
    func refreshInstalledDexts() {
        installedDexts = SystemExtensionInstaller.shared.installedDexts()
    }

    /// Everything the Software Info panel shows, assembled from what the process can see
    /// about itself plus the dext properties `sysextd` handed back.
    var softwareInfoReport: SoftwareInfoReport {
        // "Version 26.0 (Build 25A123)" reads better without the redundant prefix.
        let os = ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "")

        let audioPath: String
        switch connectionMode {
        case .hardware:
            audioPath = transportType == .thunderbolt
                ? "Thunderbolt (ThunderBridge driver extension)"
                : "USB (audio plug-in and helper)"
        case .simulated:
            audioPath = cardSimulation != nil ? "Card simulation — no hardware" : "Not connected"
        default:
            audioPath = "Not connected"
        }

        // Prefer the enabled copy. During a half-applied upgrade both the outgoing and
        // incoming versions come back, and the enabled one is the one that will win.
        let dexts = installedDexts ?? []
        let primary = dexts.first(where: { $0.isEnabled }) ?? dexts.first

        return SoftwareInfoReport(
            appVersion: MaestroCore.version,
            buildNumber: MaestroCore.buildNumber,
            gitHash: MaestroCore.gitHash,
            appPath: Bundle.main.bundlePath,
            osVersion: os,
            audioPath: audioPath,
            installedDextVersion: primary?.displayVersion,
            registeredDextCount: dexts.count,
            bundledDextBuild: SystemExtensionInstaller.shared.bundledDextBuildVersion,
            installedDextBuild: primary?.bundleVersion,
            dextLookupFailed: installedDexts == nil,
            dextEnabled: primary?.isEnabled ?? false,
            dextAwaitingApproval: primary?.isAwaitingUserApproval ?? false,
            dextAwaitingReboot: primary?.isAwaitingReboot ?? false,
            thunderBridgePresent: SystemExtensionInstaller.shared.isThunderBridgePresent(),
            pciDeviceIdentifier: SystemExtensionInstaller.shared.presentThunderBridgePCIIdentifier()
        )
    }

    /// The hardware half of the report.
    ///
    /// System Setup publishes the real thing into ``deviceInfoSnapshot`` when it loads,
    /// because that page resolves board provenance against the firmware XML and knows
    /// the firmware, FPGA and XMOS versions. Before that page has been opened, fall back
    /// to what this object knows first-hand — identity, transport and the two board
    /// readings — rather than reporting nothing.
    var deviceInfoReportForDiagnostics: DeviceInfoReport? {
        guard connectionMode == .hardware else { return nil }
        if let deviceInfoSnapshot { return deviceInfoSnapshot }
        guard let device else { return nil }
        return DeviceInfoReport(
            deviceName: device.identifier.displayName,
            connection: transportType == .thunderbolt ? "Thunderbolt (ThunderBridge)" : "USB Hardware",
            board1: primaryBoardReading,
            board2: secondaryBoardReading,
            deviceModel: device.identifier.displayName,
            mode: device.identifier.mode.displayName,
            channelCount: device.identifier.mode.channelCount
        )
    }

    /// Hardware then software, in the shape someone can paste into a bug report.
    var diagnosticsText: String {
        var blocks: [String] = []
        if let hardware = deviceInfoReportForDiagnostics {
            blocks.append(hardware.clipboardText)
        } else if connectionMode == .simulated, cardSimulation != nil {
            blocks.append("Device: card simulation — no hardware connected")
        } else {
            blocks.append("Device: not connected")
        }
        blocks.append(softwareInfoReport.clipboardText)
        return blocks.joined(separator: "\n\n")
    }
}
