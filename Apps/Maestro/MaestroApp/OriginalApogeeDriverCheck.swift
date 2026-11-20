// OriginalApogeeDriverCheck.swift — the app's side of OriginalApogeeDrivers:
// the real file and loaded-kext lookups, and the Device Settings warning.

import SwiftUI
import IOKit.kext
import MaestroCore

extension AppState {

    /// Look for Apogee's original Symphony I/O MkI drivers, off the main thread.
    ///
    /// Read-only: a few file checks and one loaded-kext query for the exact
    /// bundle identifiers. Run at launch and when Device Settings opens, not on
    /// a timer, so removing them shows up the next time the page is opened.
    @MainActor
    func refreshOriginalApogeeDrivers() {
        guard !originalApogeeDriverCheckInFlight else { return }
        originalApogeeDriverCheckInFlight = true
        Task { @MainActor [weak self] in
            let finding = await Task.detached(priority: .utility) {
                Self.previewOriginalApogeeDrivers() ?? OriginalApogeeDrivers.detect(
                    fileExists: { FileManager.default.fileExists(atPath: $0) },
                    loadedBundleIDs: Self.loadedOriginalApogeeKextIDs())
            }.value
            guard let self else { return }
            self.originalApogeeDriverCheckInFlight = false
            if self.originalApogeeDrivers != finding {
                self.originalApogeeDrivers = finding
                if !finding.isEmpty {
                    print("[Maestro] Original Apogee Symphony I/O drivers found: \(finding.lines.joined(separator: "; "))")
                }
            }
        }
    }

    /// The launch argument that previews the warning for a screenshot without
    /// installing Apogee's drivers:
    ///
    ///   .build/debug/MaestroApp -MaestroPreviewOriginalApogeeDrivers installed
    ///   .build/debug/MaestroApp -MaestroPreviewOriginalApogeeDrivers restart
    ///
    /// `installed` shows a typical finding (the issue 31 kext, loaded, and the
    /// Symphony Systems plug-ins); `restart` shows the kext still loaded after
    /// Uninstall. DEBUG builds only: the read is compiled out of release builds
    /// (the installer builds with `-c release`), so a stray defaults key can
    /// never make a shipped Maestro claim Apogee's drivers are installed.
    nonisolated static let originalApogeeDriversPreviewKey = "MaestroPreviewOriginalApogeeDrivers"

    nonisolated static func previewOriginalApogeeDrivers() -> OriginalApogeeDriverFinding? {
        #if DEBUG
        let thunderBridge = "com.apogeedigital.driver.Symphony64ThunderBridge"
        switch UserDefaults.standard.string(forKey: originalApogeeDriversPreviewKey) {
        case "installed":
            let hal = OriginalApogeeDrivers.symphonySystemsDirectory
            let files: Set<String> = [
                "/Library/Extensions/Symphony64Thunderbridge.kext/Contents/Info.plist",
                "\(hal)/SymphonyPlugin.bundle/Contents/Info.plist",
                "\(hal)/SymphonyIOUSBPlugIn.bundle/Contents/Info.plist",
                "/Library/LaunchDaemons/com.SymphonyDaemon.plist",
            ]
            return OriginalApogeeDrivers.detect(fileExists: files.contains, loadedBundleIDs: [thunderBridge])
        case "restart":
            return OriginalApogeeDrivers.detect(fileExists: { _ in false }, loadedBundleIDs: [thunderBridge])
        default:
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Which of Apogee's MkI kext identifiers are loaded in the kernel. Asks for
    /// exactly those identifiers, so nothing else is enumerated.
    nonisolated static func loadedOriginalApogeeKextIDs() -> Set<String> {
        let ids = OriginalApogeeDrivers.kernelExtensionBundleIDs as CFArray
        guard let info = KextManagerCopyLoadedKextInfo(ids, nil)?.takeRetainedValue() as? [String: Any] else {
            return []
        }
        return Set(info.keys)
    }
}

/// The red section at the top of Device Settings while Apogee's original
/// Symphony I/O drivers are installed. Gone once they are; no dismiss button.
struct OriginalApogeeDriversWarning: View {
    let finding: OriginalApogeeDriverFinding

    static let headline = "Apogee's original Symphony I/O drivers are installed"
    static let message = "Maestro doesn't support running alongside them. The two can interfere with each other and cause problems, including crashes."

    @State private var showFound = false

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.headline)
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(Self.message)
                    if finding.isAwaitingRestartOnly {
                        Text(OriginalApogeeDrivers.restartAdvice)
                            .fontWeight(.semibold)
                    } else {
                        Text(.init(OriginalApogeeDrivers.removalAdvice))
                        Link(destination: OriginalApogeeDrivers.releaseDMGURL) {
                            Label("Download Apogee's Symphony I/O Release 5.5", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                    }
                    if finding.hasStagedCopy {
                        Text(OriginalApogeeDrivers.stagedAdvice)
                    }
                    DisclosureGroup("What was found", isExpanded: $showFound) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(finding.lines, id: \.self) { line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    ApogeeStillThereSteps()
                    if !finding.isAwaitingRestartOnly { ManualApogeeRemovalSteps() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A tint and a border, not a fill: .red adapts to light and dark,
            // and the text stays the primary colour on it in both. (A grouped
            // Form on macOS ignores listRowBackground.)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.45), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// Collapsed by default, under the uninstaller advice: what someone can try
/// themselves when the warning survives Apogee's Uninstall and a restart.
struct ApogeeStillThereSteps: View {
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(OriginalApogeeDrivers.stillThereTitle, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OriginalApogeeDrivers.stillThereIntro)
                Text(OriginalApogeeDrivers.clearStagingCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                ForEach(Array(OriginalApogeeDrivers.stillThereSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                        Text(LocalizedStringKey(step))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(OriginalApogeeDrivers.stillThereCaveat)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .font(.callout)
    }
}

/// The last resort, collapsed by default, under the uninstaller advice in the
/// Device Settings warning and in Help: what has to be removed if Apogee's
/// uninstaller won't run. Never the primary instruction.
struct ManualApogeeRemovalSteps: View {
    static let title = "If you can't run Apogee's uninstaller"
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(Self.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OriginalApogeeDrivers.manualRemovalIntro)
                ForEach(OriginalApogeeDrivers.manualRemovalParts, id: \.self) { part in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(LocalizedStringKey(part))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .font(.callout)
    }
}
