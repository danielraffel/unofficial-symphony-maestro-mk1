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
        defer { defaults.removePersistentDomain(forName: name) }
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
