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
                OriginalApogeeDrivers.detect(
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
                    Text(.init(OriginalApogeeDrivers.removalAdvice))
                    Link(destination: OriginalApogeeDrivers.releaseDMGURL) {
                        Label("Download Apogee's Symphony I/O Release 5.5", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
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
                    ManualApogeeRemovalSteps()
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
