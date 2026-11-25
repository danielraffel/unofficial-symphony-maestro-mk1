import AppKit
import MaestroCore
import SwiftUI

/// The dialogs of the update channel setting. Version numbers are filled in
/// at run time; no feature is named (the notes link comes from the feed).
enum UpdateChannelDialog: Identifiable, Equatable {
    case confirmBeta
    /// `offerSwitchOnly` is false when the copy is already on Stable (the
    /// "Install X" button), so "Switch Without Installing" means nothing.
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
    static let noBetaNow = "There's no beta available right now. You'll get the next one when it is released."
    /// Names no button label: "Install X" carries a version and is only
    /// shown once a feed has been read, which Check for Updates does.
    static let feedUnreachable = "Maestro couldn't read the update feed. The channel is now Stable. To reinstall the stable version when you're online, choose Check for Updates, then press the Install button under Update channel in Preferences."
    /// A package was downloaded and failed a check.
    static let verifyFailed = "Maestro couldn't verify the download, so nothing was installed."
    /// The feed itself was unusable; nothing was downloaded.
    static let feedRefused = "Maestro couldn't get the stable version from the update feed, so nothing was installed."
    static let checking = "Checking the download…"

    static func testFeed(_ url: String) -> String { "Updates are being read from a test feed: \(url)" }
    /// The dates are the feed's ("25 Nov"), each left out when unknown.
    static func runningBeta(_ installed: String, stable: String,
                            installedDate: String? = nil, stableDate: String? = nil) -> String {
        "You're running beta \(installed)\(dated(installedDate)). The latest stable version is \(stable)\(dated(stableDate))."
    }
    private static func dated(_ date: String?) -> String { date.map { " (\($0))" } ?? "" }
    static let seeWhatsNew = "See what's new"
    static let releaseNotes = "Release notes"
    static func stillOnBeta(_ installed: String) -> String {
        "You're still running beta \(installed). You'll get the next stable version when it is newer than this one."
    }
    static func goBackBody(_ installed: String, stable: String,
                           installedDate: String? = nil, stableDate: String? = nil) -> [String] {
        [
            runningBeta(installed, stable: stable, installedDate: installedDate, stableDate: stableDate),
            "Maestro will download \(stable), check it, and open the installer. Follow the installer; Maestro reopens when it has finished. Quit your audio apps first: audio is interrupted for a few seconds.",
            "If Maestro then shows a driver banner, unplug the ThunderBridge cable and plug it back in, or restart your Mac.",
        ]
    }
    static func downloading(_ version: String) -> String { "Downloading Maestro \(version)…" }
    /// No ellipsis: after a version number it read as a cut-off number.
    static func installButton(_ version: String) -> String { "Install \(version)" }
    static func switchAndInstall(_ version: String) -> String { "Switch and Install \(version)" }
}

/// The channel rows in App Settings › Updates.
struct UpdateChannelSettings: View {
    @EnvironmentObject private var updates: UpdateController
    @State private var dialog: UpdateChannelDialog?
    @State private var busy = false
    @State private var stillOnBetaNote = false

    private var pickerDisabled: Bool {
        updates.sessionInProgress || busy || updates.reinstaller.isBusy
    }

    var body: some View {
        LabeledContent {
            VStack(spacing: 4) {
                // SwiftUI's segmented picker keeps its natural width on
                // macOS; AppKit's control takes fixed segment widths, so each
                // channel's newest version sits centred under its half.
                ChannelSegmentedControl(selection: channelBinding)
                    .frame(width: ChannelReleasesRow.width)
                    .disabled(pickerDisabled)
                    .maestroHelp(UpdateChannelCopy.pickerHelp)
                // Nothing extra (no space, no spinner) until a feed was read
                // with scheduled checks on; then it fades in.
                if let releases = updates.channelReleases {
                    ChannelReleasesRow(releases: releases)
                        .transition(.opacity)
                }
            }
            .animation(.easeIn(duration: 0.25), value: updates.channelReleases)
        } label: {
            Text("Update channel")
        }
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
                Text(UpdateChannelCopy.runningBeta(updates.installedVersion, stable: stable,
                                                   installedDate: updates.releaseDateText(of: updates.installedVersion),
                                                   stableDate: updates.releaseDateText(of: stable)))
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

    /// "Install X": never trusts the stored number; reads and verifies the feed first.
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

/// The Stable | Beta segmented control, with two equal segments filling
/// `ChannelReleasesRow.width`.
struct ChannelSegmentedControl: NSViewRepresentable {
    @Binding var selection: UpdateChannel
    static let channels: [UpdateChannel] = [.stable, .beta]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Stable", "Beta"], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("Update channel")
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = Self.channels.firstIndex(of: selection) ?? 0
        control.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<UpdateChannel>
        init(selection: Binding<UpdateChannel>) { self.selection = selection }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard ChannelSegmentedControl.channels.indices.contains(sender.selectedSegment) else { return }
            let chosen = ChannelSegmentedControl.channels[sender.selectedSegment]
            selection.wrappedValue = chosen
            // A choice that opens a dialog first keeps the old channel
            // selected until it is confirmed.
            sender.selectedSegment = ChannelSegmentedControl.channels.firstIndex(of: selection.wrappedValue) ?? 0
        }
    }
}

/// The newest Stable and Beta versions, each centred under its half of the
/// channel picker: "0.9.28 · 25 Nov" and its release notes link.
struct ChannelReleasesRow: View {
    /// The picker's width; each half holds one channel's text.
    static let width: CGFloat = 280
    let releases: ChannelReleases

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(releases.stable)
            column(releases.beta)
        }
        .frame(width: Self.width)
    }

    @ViewBuilder private func column(_ release: ChannelRelease?) -> some View {
        VStack(spacing: 2) {
            if let release {
                // Version and date only: the dates show which is newer, and
                // a "Newer" pill raised "newer than what?" (owner, 2026-11-24).
                Text(release.summary())
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let notes = release.notesURL {
                    Link(UpdateChannelCopy.releaseNotes, destination: notes)
                        .font(.caption)
                }
            }
        }
        .lineLimit(1)
        .frame(width: Self.width / 2)
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
            // With no beta in the feed there are no notes to link to; the
            // general releases page would only show stable versions.
            if updates.feedHasNoCurrentBeta {
                Text(UpdateChannelCopy.noBetaNow)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !updates.feedHasNoCurrentBeta {
                    Button(updates.hasCurrentBeta ? "What's in the current beta" : "Release notes") {
                        NSWorkspace.shared.open(updates.currentBetaNotesURL)
                    }
                    .buttonStyle(.link)
                }
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
            ForEach(UpdateChannelCopy.goBackBody(updates.installedVersion, stable: item.displayVersion,
                                                 installedDate: updates.releaseDateText(of: updates.installedVersion),
                                                 stableDate: item.date.map { ChannelReleases.dateText($0) }), id: \.self) {
                Text($0).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let notes = item.notesURL {
                    Button(UpdateChannelCopy.seeWhatsNew) { NSWorkspace.shared.open(notes) }
                        .buttonStyle(.link)
                }
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
            FailureView(headline: UpdateChannelCopy.feedRefused, reason: reason, close: close)
        }
    }
}

private struct FailureView: View {
    var headline = UpdateChannelCopy.verifyFailed
    let reason: String
    let close: () -> Void

    var body: some View {
        Text(headline).fixedSize(horizontal: false, vertical: true)
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
