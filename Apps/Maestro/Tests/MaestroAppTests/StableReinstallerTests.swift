import CryptoKit
import Foundation
import Testing
import MaestroCore
@testable import MaestroApp

/// The go-back download: every check must pass before Installer is opened.
@MainActor
@Suite("Stable reinstaller")
struct StableReinstallerTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    static let accepted = """
    /tmp/x.pkg: accepted
    source=Notarized Developer ID
    origin=Developer ID Installer: Daniel Raffel (95CX6P84C4)
    """

    final class Recorder: @unchecked Sendable {
        var opened: [URL] = []
        var assessed: [URL] = []
    }

    func item(length: Int? = nil, signature: String? = nil, url: String = "https://example.com/v0.8.40/UnofficialSymphonyMaestro.pkg") throws -> FeedItem {
        FeedItem(version: "0.8.40", channel: nil, enclosureURL: URL(string: url), length: length ?? bytes.count,
                 edSignature: try signature ?? key.signature(for: bytes).base64EncodedString(),
                 installationType: "package", minimumSystemVersion: "26.0")
    }

    func environment(root: URL, recorder: Recorder, payload: Data? = nil, assessStatus: Int32 = 0,
                     assessOutput: String = accepted, opens: Bool = true) -> StableReinstaller.Environment {
        let body = payload ?? bytes
        return StableReinstaller.Environment(
            download: { _, destination, _, progress in
                try body.write(to: destination)
                await progress(1)
            },
            assess: { file in
                recorder.assessed.append(file)
                return (assessStatus, assessOutput)
            },
            open: { file in
                recorder.opened.append(file)
                return opens
            },
            cacheRoot: root
        )
    }

    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StableReinstallerTests-\(UUID().uuidString)")
    }

    func mode(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    @Test func goodPackageIsHandedToInstaller() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let reinstaller = StableReinstaller(publicKey: publicKey, environment: environment(root: root, recorder: recorder))
        await reinstaller.run(item: try item())
        #expect(reinstaller.phase == .handedOff(version: "0.8.40"))
        let file = try #require(reinstaller.downloadedFile)
        #expect(recorder.opened == [file])
        #expect(recorder.assessed == [file])
        #expect(mode(file) == 0o444)
        #expect(mode(file.deletingLastPathComponent()) == 0o700)
        #expect(file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test func changedByteIsRefused() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var tampered = bytes
        tampered[1234] ^= 0xFF
        let reinstaller = StableReinstaller(publicKey: publicKey, environment: environment(root: root, recorder: recorder, payload: tampered))
        await reinstaller.run(item: try item())
        #expect(reinstaller.phase == .failed(PackageCheckFailure.badSignature.description))
        #expect(recorder.opened.isEmpty)
        #expect(recorder.assessed.isEmpty)
    }

    @Test func wrongSignatureIsRefused() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let other = try Curve25519.Signing.PrivateKey().signature(for: bytes).base64EncodedString()
        let reinstaller = StableReinstaller(publicKey: publicKey, environment: environment(root: root, recorder: recorder))
        await reinstaller.run(item: try item(signature: other))
        #expect(reinstaller.phase == .failed(PackageCheckFailure.badSignature.description))
        #expect(recorder.opened.isEmpty)
    }

    @Test func wrongLengthIsRefused() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let reinstaller = StableReinstaller(publicKey: publicKey, environment: environment(root: root, recorder: recorder))
        await reinstaller.run(item: try item(length: bytes.count + 1))
        #expect(reinstaller.phase == .failed(PackageCheckFailure.wrongLength(expected: bytes.count + 1, actual: bytes.count).description))
        #expect(recorder.opened.isEmpty)
    }

    @Test func packageSignedOnlyWithTheSparkleKeyIsRefused() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let reinstaller = StableReinstaller(publicKey: publicKey, environment: environment(
            root: root, recorder: recorder, assessStatus: 3, assessOutput: "/tmp/x.pkg: rejected\nsource=no usable signature"))
        await reinstaller.run(item: try item())
        guard case .failed = reinstaller.phase else { Issue.record("expected a refusal"); return }
        #expect(recorder.opened.isEmpty)
        #expect(recorder.assessed.count == 1)
    }

    @Test func plainHTTPToAnotherHostIsRefused() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let reinstaller = StableReinstaller(publicKey: publicKey, environment: environment(root: root, recorder: recorder))
        await reinstaller.run(item: try item(url: "http://example.com/0.8.40.pkg"))
        guard case .failed = reinstaller.phase else { Issue.record("expected a refusal"); return }
        #expect(recorder.opened.isEmpty)
    }

    /// Control for the live assessment: the real `spctl` accepts a notarized
    /// Maestro package and the parser agrees. Skipped when no candidate is at hand.
    @Test func liveAssessmentAcceptsANotarizedCandidate() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = (try? FileManager.default.contentsOfDirectory(at: repo.appendingPathComponent("Installer/release-candidates"),
                                                                       includingPropertiesForKeys: nil)) ?? []
        guard let package = candidates.first(where: { $0.pathExtension == "pkg" }) else { return }
        let result = await StableReinstaller.liveAssess(file: package)
        #expect(InstallerAssessment.check(exitStatus: result.status, output: result.output) == nil)
        // And a file that is not a package is refused.
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pkg")
        try Data("not a package".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let bad = await StableReinstaller.liveAssess(file: junk)
        #expect(InstallerAssessment.check(exitStatus: bad.status, output: bad.output) != nil)
    }
}
