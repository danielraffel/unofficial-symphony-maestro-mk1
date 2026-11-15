import CryptoKit
import Foundation
import Testing
@testable import MaestroCore

/// Stable and Beta update channels: feed signature, parsing, the channel rule,
/// and the choice of a stable version to go back to.
@Suite("Update channels")
struct UpdateChannelTests {

    // MARK: Fixtures

    /// Signed by Sparkle 2.10.0's own `sign_update` with a throwaway key whose
    /// private half was discarded. Proves Maestro's reader agrees with
    /// Sparkle's signer byte for byte.
    static let sparkleSignedFeedPublicKey = "hSHdSCT00Ew9EKoDFmaKIwJ+XumQifL1yND3VnNFqWQ="
    static let sparkleSignedFeed = """
<?xml version="1.0" encoding="utf-8" standalone="yes"?><!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires re-signing this file with generate_appcast or sign_update! The signed signature will be embedded at the end of this file.
--><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Maestro Updates</title>
    <item>
      <title>Maestro 0.9.0</title>
      <sparkle:version>0.9.0</sparkle:version>
      <sparkle:shortVersionString>0.9.0</sparkle:shortVersionString>
      <sparkle:channel>beta</sparkle:channel>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://example.com/v0.9.0</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
## Beta
      ]]></description>
      <enclosure url="https://example.com/v0.9.0/UnofficialSymphonyMaestro.pkg" sparkle:edSignature="AAAA" length="10" type="application/octet-stream" sparkle:installationType="package"></enclosure>
    </item>
    <item>
      <title>Maestro 0.8.40</title>
      <sparkle:version>0.8.40</sparkle:version>
      <sparkle:shortVersionString>0.8.40</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://example.com/v0.8.40</sparkle:fullReleaseNotesLink>
      <enclosure url="https://example.com/v0.8.40/UnofficialSymphonyMaestro.pkg" sparkle:edSignature="BBBB" length="11" type="application/octet-stream" sparkle:installationType="package"></enclosure>
    </item>
  </channel>
</rss><!-- sparkle-signatures:
edSignature: GwN7Tp2LA2mFkrLm3g/V8dKtgpDZeIj9E23PpPiwDrfOBgHXuOwmyTHUbwhPuuKUNJhmGS3ygn1AYeN862M+Bg==
length: 1661
-->
"""

    /// A fresh throwaway key per test.
    struct Signer {
        let key = Curve25519.Signing.PrivateKey()
        var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }

        /// Appends a block the way `sign_update` does.
        func sign(_ content: Data, length: Int? = nil) throws -> Data {
            let signature = try key.signature(for: content).base64EncodedString()
            var data = content
            data.append(Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(length ?? content.count)\n-->\n".utf8))
            return data
        }
    }

    static func item(_ version: String, beta: Bool = false, notes: String? = nil, type: String? = "package",
                     minimumSystem: String? = "26.0") -> FeedItem {
        FeedItem(version: version, channel: beta ? "beta" : nil,
                 notesURL: URL(string: notes ?? "https://example.com/v\(version)"),
                 enclosureURL: URL(string: "https://example.com/v\(version)/UnofficialSymphonyMaestro.pkg"),
                 length: 100, edSignature: "c2ln", installationType: type, minimumSystemVersion: minimumSystem)
    }

    static func feed(_ items: FeedItem...) -> FeedSnapshot { FeedSnapshot(items: items) }

    static let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)

    // MARK: Feed signature

    @Test func sparkleSignedFeedVerifiesAndParses() throws {
        let data = Data(Self.sparkleSignedFeed.utf8)
        let content = try #require(SignedFeed.verifiedContent(data, publicKeyBase64: Self.sparkleSignedFeedPublicKey))
        let snapshot = try FeedSnapshot(content: content)
        #expect(snapshot.items.map(\.version) == ["0.9.0", "0.8.40"])
        #expect(snapshot.newestBeta?.version == "0.9.0")
        #expect(snapshot.newestStable?.version == "0.8.40")
        let stable = try #require(snapshot.newestStable)
        #expect(stable.enclosureURL?.absoluteString == "https://example.com/v0.8.40/UnofficialSymphonyMaestro.pkg")
        #expect(stable.length == 11)
        #expect(stable.edSignature == "BBBB")
        #expect(stable.installationType == "package")
        #expect(stable.minimumSystemVersion == "26.0")
        #expect(snapshot.newestBeta?.notesURL?.absoluteString == "https://example.com/v0.9.0")
    }

    /// The tracked production feed verifies with the key in the app's
    /// Info.plist and has no tagged item that is not `beta`.
    @Test func trackedFeedVerifiesWithTheAppKey() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let feed = try Data(contentsOf: repo.appendingPathComponent("appcast.xml"))
        let info = try Data(contentsOf: repo.appendingPathComponent("Apps/Maestro/MaestroApp/Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])
        let key = try #require(plist["SUPublicEDKey"] as? String)
        let content = try #require(SignedFeed.verifiedContent(feed, publicKeyBase64: key))
        let snapshot = try FeedSnapshot(content: content)
        #expect(snapshot.newestStable != nil)
        #expect(snapshot.items.allSatisfy { $0.channel == nil || $0.channel == "beta" })
    }

    @Test func sparkleSignedFeedFailsWithAnotherKey() {
        let data = Data(Self.sparkleSignedFeed.utf8)
        #expect(SignedFeed.verifiedContent(data, publicKeyBase64: Signer().publicKeyBase64) == nil)
    }

    @Test func signedFeedSplitsAndVerifies() throws {
        let signer = Signer()
        let content = Data("<rss><channel></channel></rss>".utf8)
        let feed = try #require(SignedFeed.split(try signer.sign(content)))
        #expect(feed.content == content)
        #expect(feed.length == content.count)
        #expect(SignedFeed.verify(content: feed.content, signature: feed.signature, publicKeyBase64: signer.publicKeyBase64))
    }

    @Test func unsignedFeedIsRefused() {
        let data = Data("<rss><channel></channel></rss>".utf8)
        #expect(SignedFeed.split(data) == nil)
        #expect(SignedFeed.verifiedContent(data, publicKeyBase64: Signer().publicKeyBase64) == nil)
    }

    @Test func wrongLengthIsRefused() throws {
        let signer = Signer()
        let content = Data("<rss><channel></channel></rss>".utf8)
        #expect(SignedFeed.split(try signer.sign(content, length: content.count - 1)) == nil)
    }

    @Test func editedContentFailsVerification() throws {
        let signer = Signer()
        var data = try signer.sign(Data("<rss><channel>a</channel></rss>".utf8))
        data[data.startIndex + 14] = UInt8(ascii: "b")
        #expect(SignedFeed.verifiedContent(data, publicKeyBase64: signer.publicKeyBase64) == nil)
    }

    @Test func lastSignatureBlockWins() throws {
        let signer = Signer()
        let first = try signer.sign(Data("<rss>one</rss>".utf8))
        // A second block signed over everything before it, including the first block.
        let both = try signer.sign(first)
        let feed = try #require(SignedFeed.split(both))
        #expect(feed.content == first)
        #expect(SignedFeed.verify(content: feed.content, signature: feed.signature, publicKeyBase64: signer.publicKeyBase64))
        // A forged trailing block does not verify, even though an earlier one would.
        var forged = first
        forged.append(Data("<!-- sparkle-signatures:\nedSignature: \(Data(repeating: 1, count: 64).base64EncodedString())\nlength: \(first.count)\n-->\n".utf8))
        #expect(SignedFeed.verifiedContent(forged, publicKeyBase64: signer.publicKeyBase64) == nil)
    }

    @Test func packageSignatureChecksTheFile() throws {
        let signer = Signer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("p.pkg")
        let bytes = Data((0..<5000).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        let signature = try signer.key.signature(for: bytes).base64EncodedString()
        #expect(PackageSignature.verify(file: file, signatureBase64: signature, publicKeyBase64: signer.publicKeyBase64))
        #expect(!PackageSignature.verify(file: file, signatureBase64: signature, publicKeyBase64: Signer().publicKeyBase64))
        var changed = bytes
        changed[100] ^= 1
        try changed.write(to: file)
        #expect(!PackageSignature.verify(file: file, signatureBase64: signature, publicKeyBase64: signer.publicKeyBase64))
    }

    // MARK: Versions and newest items

    @Test func versionsCompareNumerically() {
        #expect(FeedVersion("0.8.40")! > FeedVersion("0.8.9")!)
        #expect(FeedVersion("0.10.0")! > FeedVersion("0.9.5")!)
        #expect(FeedVersion("0.9")! == FeedVersion("0.9.0")!)
        #expect(FeedVersion("0.9.0b1") == nil)
        #expect(FeedVersion("") == nil)
    }

    @Test func newestItemsAreChosenByVersionNotPosition() {
        let snapshot = Self.feed(Self.item("0.8.9"), Self.item("0.9.0", beta: true), Self.item("0.8.40"),
                                 Self.item("0.10.0", beta: true), Self.item("0.8.39"), Self.item("0.9.1", beta: true))
        #expect(snapshot.newestStable?.version == "0.8.40")
        #expect(snapshot.newestBeta?.version == "0.10.0")
        #expect(snapshot.item(version: "0.9.1")?.isBeta == true)
    }

    @Test func notesLinkIsTheCurrentBeta() {
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true, notes: "https://example.com/beta"))
        #expect(snapshot.hasCurrentBeta)
        #expect(snapshot.currentBetaNotesURL.absoluteString == "https://example.com/beta")
    }

    @Test func notesLinkFallsBackWithNoBetaAboveStable() {
        // The beta was promoted (a stable item at the same version) or an old tag remains below stable.
        let promoted = Self.feed(Self.item("0.9.0"), Self.item("0.8.40"), Self.item("0.8.99", beta: true))
        #expect(!promoted.hasCurrentBeta)
        #expect(promoted.currentBetaNotesURL == UpdateLinks.releasesPage)
        #expect(Self.feed(Self.item("0.8.40")).currentBetaNotesURL == UpdateLinks.releasesPage)
        #expect(UpdateLinks.releasesPage.absoluteString == "https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases")
    }

    // MARK: The channel rule (plan §2.1)

    @Test func allowedChannels() {
        #expect(UpdateChannel.stable.sparkleAllowedChannels == [])
        #expect(UpdateChannel.beta.sparkleAllowedChannels == ["beta"])
    }

    /// 0.9.0 installed by hand, 0.9.0 is a beta item: Beta.
    @Test func handInstalledBetaIsBeta() {
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true))
        #expect(ChannelRule.derive(installed: "0.9.0", snapshot: snapshot).channel == .beta)
        #expect(ChannelRule.effective(preference: nil, installed: "0.9.0", snapshot: snapshot, stored: nil) == .beta)
    }

    /// Only the first condition: above the newest stable but not in the feed
    /// (a stable package before its item is live, or a candidate).
    @Test func aboveStableAloneIsStable() {
        let snapshot = Self.feed(Self.item("0.8.39"), Self.item("0.9.0", beta: true))
        #expect(ChannelRule.derive(installed: "0.8.40", snapshot: snapshot).channel == .stable)
    }

    /// Only the second condition: still tagged, but a later beta was promoted.
    @Test func betaItemBelowStableIsStable() {
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true), Self.item("0.9.1"))
        #expect(ChannelRule.derive(installed: "0.9.0", snapshot: snapshot).channel == .stable)
    }

    /// The same copy after 0.9.0 itself is promoted: Stable by the rule.
    @Test func promotedVersionIsStable() {
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.9.0"))
        let derived = ChannelRule.derive(installed: "0.9.0", snapshot: snapshot)
        #expect(derived.channel == .stable)
        #expect(derived.newestStable == "0.9.0")
    }

    @Test func stableReleaseFromFeedIsStable() {
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true))
        #expect(ChannelRule.derive(installed: "0.8.40", snapshot: snapshot).channel == .stable)
    }

    @Test func explicitChoiceIsNeverOverridden() {
        let betaFeed = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true))
        let promoted = Self.feed(Self.item("0.8.40"), Self.item("0.9.0"))
        let storedBeta = DerivedChannel(version: "0.9.0", channel: .beta, newestStable: "0.8.40")
        #expect(ChannelRule.effective(preference: .stable, installed: "0.9.0", snapshot: betaFeed, stored: storedBeta) == .stable)
        #expect(ChannelRule.effective(preference: .beta, installed: "0.9.0", snapshot: promoted, stored: nil) == .beta)
        #expect(ChannelRule.effective(preference: .beta, installed: "0.8.40", snapshot: promoted, stored: nil) == .beta)
    }

    /// Beta copy, feed unreachable since install: Stable. Read once, now offline: the stored Beta.
    @Test func withoutAFeedTheStoredDerivationCountsForThisVersionOnly() {
        #expect(ChannelRule.effective(preference: nil, installed: "0.9.0", snapshot: nil, stored: nil) == .stable)
        let stored = DerivedChannel(version: "0.9.0", channel: .beta, newestStable: "0.8.40")
        #expect(ChannelRule.effective(preference: nil, installed: "0.9.0", snapshot: nil, stored: stored) == .beta)
        #expect(ChannelRule.effective(preference: nil, installed: "0.9.1", snapshot: nil, stored: stored) == .stable)
    }

    /// The tester's 9006 build (app 0.8.40) replaced by the 0.9.0 package.
    @Test func testerBuildReplacedByFirstBeta() {
        let snapshot = Self.feed(Self.item("0.8.39"), Self.item("0.8.40"), Self.item("0.9.0", beta: true))
        let stored = DerivedChannel(version: "0.8.40", channel: .stable, newestStable: "0.8.40")
        #expect(ChannelRule.effective(preference: nil, installed: "0.9.0", snapshot: nil, stored: stored) == .stable)
        #expect(ChannelRule.effective(preference: nil, installed: "0.9.0", snapshot: snapshot, stored: stored) == .beta)
    }

    @Test func derivedChannelRoundTripsThroughDefaults() {
        let value = DerivedChannel(version: "0.9.0", channel: .beta, newestStable: "0.8.40")
        #expect(DerivedChannel(dictionary: value.dictionary) == value)
        #expect(DerivedChannel(dictionary: ["version": "0.9.0", "channel": "nightly"]) == nil)
        #expect(DerivedChannel(dictionary: nil) == nil)
    }

    // MARK: Saving Beta the first time it is derived (Daniel, 2026-11-15)

    private static func freshDefaults() -> (UserDefaults, String) {
        let name = "UpdateChannelTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func derivedBetaIsSavedAsTheChoice() {
        let (defaults, name) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChannelStore(defaults: defaults)
        let beta = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true))
        #expect(store.record(snapshot: beta, installed: "0.9.0") == .beta)
        #expect(store.preference == .beta)
        #expect(defaults.string(forKey: "maestroUpdateChannel") == "beta")
        #expect(store.derived == DerivedChannel(version: "0.9.0", channel: .beta, newestStable: "0.8.40"))
        // After promotion the copy stays on Beta.
        let promoted = Self.feed(Self.item("0.8.40"), Self.item("0.9.0"))
        #expect(store.record(snapshot: promoted, installed: "0.9.0") == .beta)
        #expect(store.derived?.channel == .stable)
        // And after a later beta is promoted.
        let later = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true), Self.item("0.9.1"))
        #expect(store.record(snapshot: later, installed: "0.9.0") == .beta)
    }

    @Test func derivedStableIsNeverSaved() {
        let (defaults, name) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChannelStore(defaults: defaults)
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true))
        #expect(store.record(snapshot: snapshot, installed: "0.8.40") == .stable)
        #expect(store.preference == nil)
        #expect(defaults.object(forKey: "maestroUpdateChannel") == nil)
        // So the same Mac still derives Beta after a beta is installed by hand.
        #expect(store.record(snapshot: snapshot, installed: "0.9.0") == .beta)
        #expect(store.preference == .beta)
    }

    @Test func explicitStableIsNotReplacedByADerivedBeta() {
        let (defaults, name) = Self.freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChannelStore(defaults: defaults)
        store.preference = .stable
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true), Self.item("0.9.1", beta: true))
        #expect(store.record(snapshot: snapshot, installed: "0.9.0") == .stable)
        #expect(store.preference == .stable)
        #expect(store.derived?.channel == .beta)
        #expect(ChannelRule.isRunningBetaOnStable(effective: .stable, installed: "0.9.0", stored: store.derived))
    }

    @Test func preferenceToSave() {
        let beta = DerivedChannel(version: "0.9.0", channel: .beta, newestStable: "0.8.40")
        let stable = DerivedChannel(version: "0.9.0", channel: .stable, newestStable: "0.9.0")
        #expect(ChannelRule.preferenceToSave(preference: nil, derived: beta) == .beta)
        #expect(ChannelRule.preferenceToSave(preference: nil, derived: stable) == nil)
        #expect(ChannelRule.preferenceToSave(preference: .stable, derived: beta) == nil)
        #expect(ChannelRule.preferenceToSave(preference: .beta, derived: stable) == nil)
    }

    @Test func betaBuildLineNeedsAStoredBetaDerivationForThisVersion() {
        let beta = DerivedChannel(version: "0.9.0", channel: .beta, newestStable: "0.8.40")
        #expect(ChannelRule.isRunningBetaOnStable(effective: .stable, installed: "0.9.0", stored: beta))
        #expect(!ChannelRule.isRunningBetaOnStable(effective: .beta, installed: "0.9.0", stored: beta))
        #expect(!ChannelRule.isRunningBetaOnStable(effective: .stable, installed: "0.9.1", stored: beta))
        // A candidate above stable that the feed does not list is not called a beta.
        let candidate = DerivedChannel(version: "0.8.41", channel: .stable, newestStable: "0.8.40")
        #expect(!ChannelRule.isRunningBetaOnStable(effective: .stable, installed: "0.8.41", stored: candidate))
    }

    // MARK: Going back to stable (plan §5)

    @Test func goBackChoosesTheHighestUntaggedPackage() {
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.8.41"), Self.item("0.9.0", beta: true),
                                 Self.item("0.9.1", beta: true))
        #expect(StableTarget.choose(snapshot: snapshot, installed: "0.9.1", macOS: Self.tahoe) == .goBack(Self.item("0.8.41")))
    }

    @Test func goBackComparesWithTheInstalledVersion() {
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.9.0", beta: true))
        #expect(StableTarget.choose(snapshot: snapshot, installed: "0.8.40", macOS: Self.tahoe) == .upToDate)
        #expect(StableTarget.choose(snapshot: snapshot, installed: "0.8.39", macOS: Self.tahoe) == .sparkleWillOffer("0.8.40"))
        #expect(StableTarget.choose(snapshot: snapshot, installed: "0.9.0", macOS: Self.tahoe) == .goBack(Self.item("0.8.40")))
        // A promoted beta is up to date.
        let promoted = Self.feed(Self.item("0.8.40"), Self.item("0.9.0"))
        #expect(StableTarget.choose(snapshot: promoted, installed: "0.9.0", macOS: Self.tahoe) == .upToDate)
    }

    @Test func goBackRefusesBelowTheFloor() {
        let snapshot = Self.feed(Self.item("0.8.39"), Self.item("0.9.0", beta: true))
        #expect(StableTarget.choose(snapshot: snapshot, installed: "0.9.0", macOS: Self.tahoe)
                == .refused(.belowFloor(version: "0.8.39", floor: "0.8.40")))
        #expect(UpdateFloor.stable == "0.8.40")
    }

    @Test func goBackIgnoresNonPackageEnclosuresAndUnmetSystems() {
        let snapshot = Self.feed(Self.item("0.8.40"), Self.item("0.8.42", type: "application"),
                                 Self.item("0.8.43", minimumSystem: "27.0"), Self.item("0.9.0", beta: true))
        #expect(StableTarget.choose(snapshot: snapshot, installed: "0.9.0", macOS: Self.tahoe) == .goBack(Self.item("0.8.40")))
        let onlyApp = Self.feed(Self.item("0.8.41", type: nil), Self.item("0.9.0", beta: true))
        #expect(StableTarget.choose(snapshot: onlyApp, installed: "0.9.0", macOS: Self.tahoe) == .refused(.noStableItem))
    }

    @Test func goBackRefusesAFeedWithOnlyBetas() {
        let snapshot = Self.feed(Self.item("0.9.0", beta: true))
        #expect(StableTarget.choose(snapshot: snapshot, installed: "0.9.0", macOS: Self.tahoe) == .refused(.noStableItem))
    }

    @Test func goBackNeedsASignedFeed() throws {
        // The verified-content gate is the only way into StableTarget from the app.
        let signer = Signer()
        let content = Data(Self.sparkleSignedFeed.utf8)
        #expect(SignedFeed.verifiedContent(content, publicKeyBase64: signer.publicKeyBase64) == nil)
        let unsigned = try #require(SignedFeed.split(content)).content
        #expect(SignedFeed.verifiedContent(unsigned, publicKeyBase64: Self.sparkleSignedFeedPublicKey) == nil)
    }

    @Test func goBackDownloadsOnlyOverHTTPSOrFromThisMac() {
        #expect(UpdateLinks.isAllowedDownload(URL(string: "https://github.com/a/b.pkg")!))
        #expect(UpdateLinks.isAllowedDownload(URL(string: "http://127.0.0.1:8765/0.8.40.pkg")!))
        #expect(UpdateLinks.isAllowedDownload(URL(string: "http://localhost:8765/0.8.40.pkg")!))
        #expect(!UpdateLinks.isAllowedDownload(URL(string: "http://example.com/0.8.40.pkg")!))
        #expect(!UpdateLinks.isAllowedDownload(URL(string: "file:///tmp/0.8.40.pkg")!))
    }

    // MARK: Installer assessment

    @Test func spctlAcceptsOnlyNotarizedPackagesFromTheTeam() {
        let good = """
        /tmp/x.pkg: accepted
        source=Notarized Developer ID
        origin=Developer ID Installer: Daniel Raffel (95CX6P84C4)
        """
        #expect(InstallerAssessment.check(exitStatus: 0, output: good) == nil)
        #expect(InstallerAssessment.check(exitStatus: 3, output: good) != nil)
        #expect(InstallerAssessment.check(exitStatus: 0, output: good.replacingOccurrences(of: "Notarized Developer ID", with: "Developer ID")) != nil)
        #expect(InstallerAssessment.check(exitStatus: 0, output: good.replacingOccurrences(of: "95CX6P84C4", with: "ABCDE12345")) != nil)
        #expect(InstallerAssessment.check(exitStatus: 0, output: good.replacingOccurrences(of: "Developer ID Installer", with: "Developer ID Application")) != nil)
        #expect(InstallerAssessment.check(exitStatus: 0, output: good.replacingOccurrences(of: ": accepted", with: ": rejected")) != nil)
    }
}
