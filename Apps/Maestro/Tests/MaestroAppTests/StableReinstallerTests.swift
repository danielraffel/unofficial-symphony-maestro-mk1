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

    /// The progress sheet closes itself on idle, so start must leave idle at once.
    @Test func startIsBusyImmediatelyAndFinishes() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let reinstaller = StableReinstaller(publicKey: publicKey, environment: environment(root: root, recorder: recorder))
        reinstaller.start(item: try item())
        #expect(reinstaller.phase != .idle)
        #expect(reinstaller.isBusy)
        for _ in 0..<200 where reinstaller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reinstaller.phase == .handedOff(version: "0.8.40"))
        #expect(recorder.opened.count == 1)
    }

    @Test func cancelReturnsToIdleAndOpensNothing() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var env = environment(root: root, recorder: recorder)
        env.download = { _, _, _, _ in try await Task.sleep(for: .seconds(5)) }
        let reinstaller = StableReinstaller(publicKey: publicKey, environment: env)
        reinstaller.start(item: try item())
        try await Task.sleep(for: .milliseconds(50))
        reinstaller.cancel()
        #expect(reinstaller.phase == .idle)
        try await Task.sleep(for: .milliseconds(100))
        #expect(reinstaller.phase == .idle)
        #expect(recorder.opened.isEmpty)
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

    /// The newest notarized candidate package in the checkout, if one is at hand.
    nonisolated static let candidatePackage: URL? = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = (try? FileManager.default.contentsOfDirectory(at: repo.appendingPathComponent("Installer/release-candidates"),
                                                                       includingPropertiesForKeys: nil)) ?? []
        return candidates.filter { $0.pathExtension == "pkg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }()

    /// Control for the live assessment: the real `spctl` accepts a notarized
    /// Maestro package and the parser agrees. Reported as skipped, not passed,
    /// when no candidate is at hand.
    @Test(.enabled(if: StableReinstallerTests.candidatePackage != nil, "no package in Installer/release-candidates"))
    func liveAssessmentAcceptsANotarizedCandidate() async throws {
        let package = try #require(Self.candidatePackage)
        let result = await StableReinstaller.liveAssess(file: package)
        #expect(InstallerAssessment.check(exitStatus: result.status, output: result.output) == nil)
    }

    /// The real `spctl` refuses files that are not Maestro's notarized
    /// package, and the whole check sequence then opens nothing. Always runs.
    @Test func liveAssessmentRefusesOtherFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StableReinstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Not a package at all.
        let junk = directory.appendingPathComponent("junk.pkg")
        try Data("not a package".utf8).write(to: junk)
        let bad = await StableReinstaller.liveAssess(file: junk)
        #expect(InstallerAssessment.check(exitStatus: bad.status, output: bad.output) != nil)
        // A real but unsigned package, carrying a valid Sparkle signature:
        // the Sparkle key alone is not enough.
        let root = directory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("tmp/maestro-test-file"))
        let unsigned = directory.appendingPathComponent("unsigned.pkg")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/pkgbuild")
        build.arguments = ["--root", root.path, "--identifier", "com.example.maestro-test", "--version", "1", unsigned.path]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        try #require(build.terminationStatus == 0)
        let packageBytes = try Data(contentsOf: unsigned)
        let signature = try key.signature(for: packageBytes).base64EncodedString()
        let failure = await StableReinstaller.check(file: unsigned, length: packageBytes.count, signature: signature,
                                                    publicKey: publicKey, assess: StableReinstaller.liveAssess)
        guard case .notNotarized = failure else {
            Issue.record("an unsigned package with a valid Sparkle signature was not refused as unnotarized: \(String(describing: failure))")
            return
        }
    }
}
