import AppKit
import MaestroCore
import SwiftUI

/// The dialogs of the update channel setting. Version numbers are filled in
/// at run time; no feature is named (the notes link comes from the feed).
enum UpdateChannelDialog: Identifiable, Equatable {
    case confirmBeta
    /// `offerSwitchOnly` is false when the copy is already on Stable (the
    /// "Install X…" button), so "Switch Without Installing" means nothing.
    case goBack(FeedItem, offerSwitchOnly: Bool)
    case feedUnreachable
    case refused(String)

    var id: String {
        switch self {
        case .confirmBeta: "beta"
        case .goBack(let item, _): "goBack-\(item.version)"
        case .feedUnreachable: "offline"
        case .refused(let reason): "refused-\(reason)"
        }
    }
}

/// Fixed wording, kept here so tests can read it.
enum UpdateChannelCopy {
    static let pickerHelp = "Stable is recommended. Beta versions are for testers: they arrive earlier and may have bugs."
    static let sessionBusy = "Finish or close the update first."
    static let automaticCheckHelp = "On by default. Turn this off to stop scheduled update checks; Maestro then only connects when you choose Check for Updates or change the update channel."
    static let betaTitle = "Switch to beta updates?"
    static let betaBody = "Beta versions are for testing. They arrive before they are finished, have had less testing, and may have bugs. A beta can replace the ThunderBridge driver."
    static let betaBack = "You can switch back to Stable at any time; Maestro then offers to reinstall the latest stable version."
    static let goBackTitle = "Go back to the stable version?"
    static let feedUnreachable = "Maestro couldn't read the update feed. The channel is now Stable. To reinstall the stable version, press Install stable in Preferences when you're online."
    static let verifyFailed = "Maestro couldn't verify the download, so nothing was installed."
    static let checking = "Checking the download…"

    static func testFeed(_ url: String) -> String { "Updates are being read from a test feed: \(url)" }
    static func runningBeta(_ installed: String, stable: String) -> String {
        "You're running beta \(installed). The latest stable version is \(stable)."
    }
    static func stillOnBeta(_ installed: String) -> String {
        "You're still running beta \(installed). You'll get the next stable version when it is newer than this one."
    }
    static func goBackBody(_ installed: String, stable: String) -> [String] {
        [
            runningBeta(installed, stable: stable),
            "Maestro will download \(stable), check it, and open the installer. Follow the installer; Maestro reopens when it has finished. Quit your audio apps first: audio is interrupted for a few seconds.",
            "If Maestro then shows a driver banner, unplug the ThunderBridge cable and plug it back in, or restart your Mac.",
        ]
    }
    static func downloading(_ version: String) -> String { "Downloading Maestro \(version)…" }
    static func installButton(_ version: String) -> String { "Install \(version)…" }
    static func switchAndInstall(_ version: String) -> String { "Switch and Install \(version)" }
}

/// The channel rows in Device Settings › Preferences.
struct UpdateChannelSettings: View {
    @EnvironmentObject private var updates: UpdateController
    @State private var dialog: UpdateChannelDialog?
    @State private var busy = false
    @State private var stillOnBetaNote = false

    private var pickerDisabled: Bool {
        updates.sessionInProgress || busy || updates.reinstaller.isBusy
    }

    var body: some View {
        Picker("Update channel", selection: channelBinding) {
            Text("Stable").tag(UpdateChannel.stable)
            Text("Beta").tag(UpdateChannel.beta)
        }
        .pickerStyle(.segmented)
        .disabled(pickerDisabled)
        .help(UpdateChannelCopy.pickerHelp)
        .unredacted()
        .onAppear { updates.refreshForPreferencesIfAllowed() }
        .sheet(item: $dialog) { dialog in
            UpdateChannelSheet(dialog: dialog, stillOnBetaNote: $stillOnBetaNote) { self.dialog = nil }
                .environmentObject(updates)
        }
        Text(updates.sessionInProgress ? UpdateChannelCopy.sessionBusy : UpdateChannelCopy.pickerHelp)
            .font(.caption)
            .foregroundStyle(.secondary)

        if stillOnBetaNote, updates.effectiveChannel == .stable {
            Text(UpdateChannelCopy.stillOnBeta(updates.installedVersion))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if updates.isRunningBetaOnStable, let stable = updates.newestStableForDisplay {
            HStack {
                Text(UpdateChannelCopy.runningBeta(updates.installedVersion, stable: stable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(UpdateChannelCopy.installButton(stable)) { installStable() }
                    .disabled(pickerDisabled)
            }
        }
        if let feed = updates.feedOverride {
            Text(UpdateChannelCopy.testFeed(feed))
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private var channelBinding: Binding<UpdateChannel> {
        Binding(
            get: { updates.effectiveChannel },
            set: { newValue in
                guard newValue != updates.effectiveChannel, !pickerDisabled else { return }
                switch newValue {
                case .beta: openBetaConfirmation()
                case .stable: chooseStable()
                }
            }
        )
    }

    private func openBetaConfirmation() {
        busy = true
        Task {
            // Refresh the notes link from the verified feed; without it the
            // link falls back to the releases page.
            _ = try? await updates.loadFeed()
            busy = false
            dialog = .confirmBeta
        }
    }

    private func chooseStable() {
        busy = true
        Task {
            let outcome = await updates.chooseStable()
            busy = false
            switch outcome {
            case .saveStable, .saveStableAndCheck: break
            case .askToGoBack(let item): dialog = .goBack(item, offerSwitchOnly: true)
            case .saveStableOffline: dialog = .feedUnreachable
            case .saveStableRefused(let reason): dialog = .refused(reason)
            }
        }
    }

    /// "Install X…": never trusts the stored number; reads and verifies the feed first.
    private func installStable() {
        guard !updates.isSessionInProgress else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                switch try await updates.stableTargetForInstall() {
                case .goBack(let item): dialog = .goBack(item, offerSwitchOnly: false)
                case .upToDate: break
                case .sparkleWillOffer: updates.checkForUpdates()
                case .refused(let reason): dialog = .refused(reason.description)
                }
            } catch let error as FeedReadError {
                dialog = error.isUnreachable ? .feedUnreachable : .refused(error.description)
            } catch {
                dialog = .feedUnreachable
            }
        }
    }
}

/// One sheet for every channel dialog, so the notes link can open without
/// closing it and the go-back download can show its progress in place.
struct UpdateChannelSheet: View {
    let dialog: UpdateChannelDialog
    @Binding var stillOnBetaNote: Bool
    let close: () -> Void
    @EnvironmentObject private var updates: UpdateController
    @State private var installing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if installing {
                ReinstallProgressView(reinstaller: updates.reinstaller, close: close)
            } else {
                content
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch dialog {
        case .confirmBeta:
            Text(UpdateChannelCopy.betaTitle).font(.headline)
            Text(UpdateChannelCopy.betaBody).fixedSize(horizontal: false, vertical: true)
            Text(UpdateChannelCopy.betaBack).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(updates.hasCurrentBeta ? "What's in the current beta" : "Release notes") {
                    NSWorkspace.shared.open(updates.currentBetaNotesURL)
                }
                .buttonStyle(.link)
                Spacer()
                // Cancel is the default button: Return and Escape both cancel.
                Button("Cancel", action: close)
                    .keyboardShortcut(.defaultAction)
                Button("Switch to Beta") {
                    updates.chooseBeta()
                    close()
                }
            }
        case .goBack(let item, let offerSwitchOnly):
            Text(UpdateChannelCopy.goBackTitle).font(.headline)
            ForEach(UpdateChannelCopy.goBackBody(updates.installedVersion, stable: item.displayVersion), id: \.self) {
                Text($0).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                if offerSwitchOnly {
                    Button("Switch Without Installing") {
                        updates.setPreference(.stable)
                        stillOnBetaNote = true
                        close()
                    }
                }
                Button(UpdateChannelCopy.switchAndInstall(item.displayVersion)) {
                    guard !updates.isSessionInProgress else { return }
                    updates.setPreference(.stable)
                    installing = true
                    updates.reinstaller.start(item: item)
                }
                .keyboardShortcut(.defaultAction)
            }
        case .feedUnreachable:
            Text(UpdateChannelCopy.feedUnreachable).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK", action: close).keyboardShortcut(.defaultAction)
            }
        case .refused(let reason):
            FailureView(reason: reason, close: close)
        }
    }
}

private struct FailureView: View {
    let reason: String
    let close: () -> Void

    var body: some View {
        Text(UpdateChannelCopy.verifyFailed).fixedSize(horizontal: false, vertical: true)
        Text("(\(reason))")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Download manually") {
                NSWorkspace.shared.open(UpdateLinks.latestStablePackage)
            }
            Button("OK", action: close).keyboardShortcut(.defaultAction)
        }
    }
}

private struct ReinstallProgressView: View {
    @ObservedObject var reinstaller: StableReinstaller
    let close: () -> Void

    var body: some View {
        switch reinstaller.phase {
        case .idle:
            // Cancelled.
            Color.clear.frame(height: 1).onAppear(perform: close)
        case .downloading(let version, let fraction):
            Text(UpdateChannelCopy.downloading(version))
            if let fraction { ProgressView(value: fraction) } else { ProgressView() }
            HStack {
                Spacer()
                Button("Cancel") { reinstaller.cancel() }.keyboardShortcut(.cancelAction)
            }
        case .checking(let version):
            Text(UpdateChannelCopy.downloading(version))
            Text(UpdateChannelCopy.checking).foregroundStyle(.secondary)
            ProgressView()
        case .handedOff:
            // Installer is open; nothing more to click in Maestro.
            Color.clear.frame(height: 1).onAppear {
                reinstaller.reset()
                close()
            }
        case .failed(let reason):
            FailureView(reason: reason) {
                reinstaller.reset()
                close()
            }
        }
    }
}
