import Combine
import CryptoKit
import Foundation
import Testing
import MaestroCore
@testable import MaestroApp

/// Preferences disables the channel picker while the go-back download is
/// busy, and reads that through `UpdateController`. SwiftUI redraws only for
/// the object a view holds, so the controller must announce the reinstaller's
/// changes as its own.
///
/// Rehearsal row B11(b), 2026-11-15: after a refused go-back closed with OK,
/// the picker and "Install 0.8.40" stayed disabled until Check for Updates
/// happened to redraw the page.
@MainActor
@Suite("Update controller refresh")
struct UpdateControllerRefreshTests {
    @Test func aFinishedGoBackRedrawsPreferences() async throws {
        let name = "UpdateControllerRefreshTests.\(UUID().uuidString)"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }

        // A package whose signature does not match: the check refuses it.
        let key = Curve25519.Signing.PrivateKey()
        let bytes = Data(repeating: 7, count: 4096)
        let reinstaller = StableReinstaller(
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            environment: StableReinstaller.Environment(
                download: { _, destination, _, progress in
                    try bytes.write(to: destination)
                    await progress(1)
                },
                assess: { _ in (0, "") },
                open: { _ in true },
                cacheRoot: root))
        let controller = UpdateController(store: ChannelStore(defaults: defaults), reinstaller: reinstaller, startsUpdater: false)

        // objectWillChange fires before the value changes, so each entry is
        // the state a change started from.
        var busyBeforeChange: [Bool] = []
        let subscription = controller.objectWillChange.sink { _ in
            busyBeforeChange.append(controller.reinstaller.isBusy)
        }
        defer { subscription.cancel() }

        let item = FeedItem(version: "0.8.40", channel: nil,
                            enclosureURL: URL(string: "https://example.com/v0.8.40/UnofficialSymphonyMaestro.pkg"),
                            length: bytes.count,
                            edSignature: try key.signature(for: Data("other".utf8)).base64EncodedString(),
                            installationType: "package", minimumSystemVersion: "26.0")
        await reinstaller.run(item: item)

        guard case .failed = reinstaller.phase else {
            Issue.record("expected a refused package, got \(reinstaller.phase)")
            return
        }
        // The last change is "checking" to "failed": the controller must
        // announce it, or the picker stays disabled.
        #expect(busyBeforeChange.last == true, "the controller announces the go-back finishing")
        #expect(!controller.reinstaller.isBusy)
    }
}

/// App Settings › Updates shows the newest Stable and Beta versions only
/// after a feed was read in this run, with scheduled checks on.
@MainActor
@Suite("Update controller channel releases")
struct UpdateControllerChannelReleasesTests {
    @Test func shownOnlyAfterAFeedRead() throws {
        let name = "UpdateControllerChannelReleasesTests.\(UUID().uuidString)"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let controller = UpdateController(store: ChannelStore(defaults: defaults), startsUpdater: false)
        // The test process has no app bundle, so Sparkle may report checks
        // off; set the switch for the test and put it back afterwards.
        let original = controller.automaticallyChecksForUpdates
        defer { controller.automaticallyChecksForUpdates = original }
        controller.automaticallyChecksForUpdates = true

        // No read yet, or the read failed: nothing extra is shown.
        #expect(controller.channelReleases == nil)

        let date = Date(timeIntervalSince1970: 1_795_574_573)  // 25 Nov 2026 02:42:53 GMT
        controller.setSnapshotForTesting(FeedSnapshot(items: [
            FeedItem(version: "0.8.40", notesURL: URL(string: "https://example.com/v0.8.40")),
            FeedItem(version: "0.9.28", channel: "beta", date: date),
        ]))
        let releases = try #require(controller.channelReleases)
        #expect(releases.stable?.version == "0.8.40")
        #expect(releases.beta?.isNewer == true)
        #expect(controller.releaseDate(of: "0.9.28") == date)
        #expect(controller.releaseDate(of: "0.8.40") == nil)

        // Automatically check for updates off: hidden, whatever was read.
        controller.automaticallyChecksForUpdates = false
        #expect(controller.channelReleases == nil)
        controller.automaticallyChecksForUpdates = true
        #expect(controller.channelReleases != nil)

        controller.setSnapshotForTesting(nil)
        #expect(controller.channelReleases == nil)
    }
}
