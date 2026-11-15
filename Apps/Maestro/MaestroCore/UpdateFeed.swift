import CryptoKit
import Foundation

// Stable and Beta update channels.
//
// One Sparkle feed carries both channels: beta items have
// `<sparkle:channel>beta</sparkle:channel>`, stable items have no channel.
// Nothing in a package says beta; the channel a copy follows is decided at run
// time from the user's choice and from what the feed says about the installed
// version. Everything here is pure so it can be tested without Sparkle, the
// network or Installer.

/// The update channel a copy of Maestro follows.
public enum UpdateChannel: String, Sendable, Equatable, CaseIterable {
    case stable
    case beta

    /// The channel names Sparkle's `allowedChannels(for:)` should return. An
    /// empty set means stable items only; stable items are always included.
    public var sparkleAllowedChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: ["beta"]
        }
    }
}

/// The oldest stable version the go-back path will install. 0.8.40 is the
/// first release whose package installs over a newer app and that has the
/// channel feature. Raise it when a stable release fixes something that must
/// not be undone.
public enum UpdateFloor {
    public static let stable = "0.8.40"
}

/// Public links used by the update channel UI.
public enum UpdateLinks {
    public static let releasesPage = URL(string: "https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases")!
    public static let latestStablePackage = URL(string: "https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/latest/download/UnofficialSymphonyMaestro.pkg")!
}

extension UpdateLinks {
    /// Where the go-back path may download from: HTTPS anywhere, or plain
    /// HTTP to this Mac only (the rehearsal's local test feed).
    public static func isAllowedDownload(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host != nil
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }
}

// MARK: - Versions

/// A plain numeric `x.y.z` version (any number of components), compared
/// numerically with missing components treated as zero. Anything else is not
/// a version for the purposes of channels and is ignored.
public struct FeedVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            values.append(value)
        }
        components = values
        description = trimmed
    }

    public static func < (lhs: FeedVersion, rhs: FeedVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: FeedVersion, rhs: FeedVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

// MARK: - Signed feed

/// The Ed25519 signature block Sparkle's `sign_update` appends to a feed,
/// read the way `SPUExtractSignedFeed.m` reads it: the last
/// `<!-- sparkle-signatures:\n`, then `edSignature:` and `length:` lines up to
/// the next `-->`.
public struct SignedFeed: Sendable, Equatable {
    /// The bytes the signature covers: everything before the block.
    public let content: Data
    public let signature: Data
    public let length: Int

    private static let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    private static let suffix = Data("-->".utf8)

    /// Returns nil for a feed with no block, a malformed block, or a block
    /// whose `length` is not the content's byte count.
    public static func split(_ data: Data) -> SignedFeed? {
        guard let prefixRange = data.range(of: prefix, options: .backwards) else { return nil }
        let content = data.subdata(in: data.startIndex..<prefixRange.lowerBound)
        guard let suffixRange = data.range(of: suffix, in: prefixRange.upperBound..<data.endIndex) else { return nil }
        guard let block = String(data: data.subdata(in: prefixRange.upperBound..<suffixRange.lowerBound), encoding: .utf8) else { return nil }
        var signatureText: String?
        var length: Int?
        for line in block.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("edSignature:") {
                signatureText = line.dropFirst("edSignature:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("length:") {
                length = Int(line.dropFirst("length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let signatureText, let signature = Data(base64Encoded: signatureText), signature.count == 64,
              let length, length == content.count else { return nil }
        return SignedFeed(content: content, signature: signature, length: length)
    }

    public static func verify(content: Data, signature: Data, publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(signature, for: content)
    }

    /// Splits and verifies in one step; nil unless the feed is signed and the
    /// signature is valid for `publicKeyBase64`.
    public static func verifiedContent(_ data: Data, publicKeyBase64: String) -> Data? {
        guard let feed = split(data), verify(content: feed.content, signature: feed.signature, publicKeyBase64: publicKeyBase64) else { return nil }
        return feed.content
    }
}

/// Ed25519 check of a downloaded update package against the enclosure's
/// `sparkle:edSignature`, as Sparkle does. The file is memory-mapped rather
/// than streamed: Ed25519 (as used by Sparkle) signs the whole message, so
/// CryptoKit needs it in one piece.
public enum PackageSignature {
    public static func verify(file: URL, signatureBase64: String, publicKeyBase64: String) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64),
              let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return false }
        return SignedFeed.verify(content: data, signature: signature, publicKeyBase64: publicKeyBase64)
    }
}

// MARK: - Feed items

public struct FeedItem: Sendable, Equatable {
    public var version: String
    public var displayVersion: String
    /// nil for a stable item.
    public var channel: String?
    public var notesURL: URL?
    public var enclosureURL: URL?
    public var length: Int?
    public var edSignature: String?
    public var installationType: String?
    public var minimumSystemVersion: String?

    public init(version: String, displayVersion: String? = nil, channel: String? = nil, notesURL: URL? = nil,
                enclosureURL: URL? = nil, length: Int? = nil, edSignature: String? = nil,
                installationType: String? = nil, minimumSystemVersion: String? = nil) {
        self.version = version
        self.displayVersion = displayVersion ?? version
        self.channel = channel
        self.notesURL = notesURL
        self.enclosureURL = enclosureURL
        self.length = length
        self.edSignature = edSignature
        self.installationType = installationType
        self.minimumSystemVersion = minimumSystemVersion
    }

    public var parsedVersion: FeedVersion? { FeedVersion(version) }
    public var isStable: Bool { channel == nil }
    public var isBeta: Bool { channel == "beta" }
}

public enum FeedParseError: Error, Equatable, CustomStringConvertible {
    case notXML(String)

    public var description: String {
        switch self {
        case .notXML(let reason): "the update feed could not be read (\(reason))"
        }
    }
}

/// The items of one feed. Order in the file never matters: newest means the
/// highest version.
public struct FeedSnapshot: Sendable, Equatable {
    public let items: [FeedItem]

    public init(items: [FeedItem]) {
        self.items = items
    }

    public init(content: Data) throws {
        let parser = XMLParser(data: content)
        let reader = FeedXMLReader()
        parser.delegate = reader
        guard parser.parse() else {
            throw FeedParseError.notXML(parser.parserError?.localizedDescription ?? "unknown error")
        }
        items = reader.items
    }

    private static func newest(_ items: [FeedItem]) -> FeedItem? {
        items.filter { $0.parsedVersion != nil }.max { $0.parsedVersion! < $1.parsedVersion! }
    }

    public var newestStable: FeedItem? { Self.newest(items.filter(\.isStable)) }
    public var newestBeta: FeedItem? { Self.newest(items.filter(\.isBeta)) }

    public func item(version: String) -> FeedItem? {
        guard let wanted = FeedVersion(version) else { return nil }
        return items.first { $0.parsedVersion == wanted }
    }

    /// The release notes link for "What's in the current beta": the newest
    /// beta item's notes when that beta is above the newest stable, otherwise
    /// the releases page.
    public var currentBetaNotesURL: URL { currentBetaNotesItem?.notesURL ?? UpdateLinks.releasesPage }

    /// True when there is a beta above the newest stable (the link then names
    /// the current beta rather than the releases page).
    public var hasCurrentBeta: Bool { currentBetaNotesItem?.notesURL != nil }

    private var currentBetaNotesItem: FeedItem? {
        guard let beta = newestBeta, let betaVersion = beta.parsedVersion else { return nil }
        if let stable = newestStable?.parsedVersion, !(stable < betaVersion) { return nil }
        return beta
    }
}

/// `XMLParser` delegate collecting `<item>` elements. Names are matched with
/// their `sparkle:` prefix, as Sparkle's own feeds write them.
private final class FeedXMLReader: NSObject, XMLParserDelegate {
    var items: [FeedItem] = []
    private var current: [String: String]?
    private var enclosure: [String: String]?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "item" {
            current = [:]
            enclosure = nil
        } else if elementName == "enclosure", current != nil, enclosure == nil {
            enclosure = attributeDict
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard current != nil else { return }
        if elementName == "item" {
            finishItem()
            current = nil
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "sparkle:version", "sparkle:shortVersionString", "sparkle:channel",
             "sparkle:fullReleaseNotesLink", "sparkle:minimumSystemVersion":
            if current?[elementName] == nil { current?[elementName] = value }
        default:
            break
        }
        text = ""
    }

    private func finishItem() {
        guard let fields = current else { return }
        let enclosure = enclosure ?? [:]
        // Older feeds put the version on the enclosure.
        guard let version = fields["sparkle:version"] ?? enclosure["sparkle:version"], !version.isEmpty else { return }
        let display = fields["sparkle:shortVersionString"] ?? enclosure["sparkle:shortVersionString"]
        let channel = fields["sparkle:channel"].flatMap { $0.isEmpty ? nil : $0 }
        items.append(FeedItem(
            version: version,
            displayVersion: display.flatMap { $0.isEmpty ? nil : $0 },
            channel: channel,
            notesURL: fields["sparkle:fullReleaseNotesLink"].flatMap(URL.init(string:)),
            enclosureURL: enclosure["url"].flatMap(URL.init(string:)),
            length: enclosure["length"].flatMap(Int.init),
            edSignature: enclosure["sparkle:edSignature"],
            installationType: enclosure["sparkle:installationType"],
            minimumSystemVersion: fields["sparkle:minimumSystemVersion"]
        ))
    }
}

// MARK: - Which channel a copy is on

/// What the feed said about the installed version at the last read, stored in
/// the `maestroDerivedChannel` user default.
public struct DerivedChannel: Sendable, Equatable {
    /// The installed `CFBundleVersion` the derivation was made for.
    public var version: String
    /// The channel the rule derives from the feed alone, ignoring any choice
    /// the user made. Beta means this copy is a beta item above the newest
    /// stable.
    public var channel: UpdateChannel
    /// The newest stable version in that feed, for display only.
    public var newestStable: String?

    public init(version: String, channel: UpdateChannel, newestStable: String?) {
        self.version = version
        self.channel = channel
        self.newestStable = newestStable
    }

    public var dictionary: [String: String] {
        var result = ["version": version, "channel": channel.rawValue]
        if let newestStable { result["newestStable"] = newestStable }
        return result
    }

    public init?(dictionary: Any?) {
        guard let dictionary = dictionary as? [String: Any],
              let version = dictionary["version"] as? String,
              let channel = (dictionary["channel"] as? String).flatMap(UpdateChannel.init(rawValue:)) else { return nil }
        self.init(version: version, channel: channel, newestStable: dictionary["newestStable"] as? String)
    }

    /// True when this derivation was made for `installed`.
    public func applies(to installed: String) -> Bool {
        guard let mine = FeedVersion(version), let other = FeedVersion(installed) else { return version == installed }
        return mine == other
    }
}

public enum ChannelRule {
    /// The rule for a copy with no explicit choice: Beta if both hold, this
    /// copy's version is higher than the newest stable item **and** the feed
    /// has a beta item with exactly this version. Stable in every other case.
    public static func derive(installed: String, snapshot: FeedSnapshot) -> DerivedChannel {
        let newestStable = snapshot.newestStable
        var channel = UpdateChannel.stable
        if let mine = FeedVersion(installed) {
            let aboveStable = newestStable?.parsedVersion.map { $0 < mine } ?? true
            let isBetaItem = snapshot.items.contains { $0.isBeta && $0.parsedVersion == mine }
            if aboveStable && isBetaItem { channel = .beta }
        }
        return DerivedChannel(version: installed, channel: channel, newestStable: newestStable?.version)
    }

    /// The effective channel:
    /// 1. an explicit choice;
    /// 2. otherwise, with a feed read in this run, the rule on that feed;
    /// 3. otherwise the stored derivation if it was made for this version;
    /// 4. otherwise Stable.
    public static func effective(preference: UpdateChannel?, installed: String,
                                 snapshot: FeedSnapshot?, stored: DerivedChannel?) -> UpdateChannel {
        if let preference { return preference }
        if let snapshot { return derive(installed: installed, snapshot: snapshot).channel }
        if let stored, stored.applies(to: installed) { return stored.channel }
        return .stable
    }

    /// The explicit choice to save after a feed read (Daniel, 2026-11-15): a
    /// copy with no choice that the rule finds on Beta saves Beta, so it keeps
    /// getting betas after its version is promoted. Never writes Stable and
    /// never replaces a choice.
    public static func preferenceToSave(preference: UpdateChannel?, derived: DerivedChannel) -> UpdateChannel? {
        (preference == nil && derived.channel == .beta) ? .beta : nil
    }

    /// True when Preferences should say "You're running beta X. The latest
    /// stable version is Y." and offer to install Y: the copy follows Stable,
    /// yet the feed (at the last read) calls this version a beta above the
    /// newest stable.
    public static func isRunningBetaOnStable(effective: UpdateChannel, installed: String, stored: DerivedChannel?) -> Bool {
        guard effective == .stable, let stored, stored.applies(to: installed) else { return false }
        return stored.channel == .beta && stored.newestStable != nil
    }
}

/// The two user defaults behind the channel. Only the user writes
/// `maestroUpdateChannel`, through the picker and its dialogs, with one
/// exception: a feed read that finds this copy on Beta with no choice saved
/// saves Beta (`ChannelRule.preferenceToSave`).
public final class ChannelStore {
    public static let preferenceKey = "maestroUpdateChannel"
    public static let derivedKey = "maestroDerivedChannel"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var preference: UpdateChannel? {
        get { defaults.string(forKey: Self.preferenceKey).flatMap(UpdateChannel.init(rawValue:)) }
        set {
            if let newValue { defaults.set(newValue.rawValue, forKey: Self.preferenceKey) }
            else { defaults.removeObject(forKey: Self.preferenceKey) }
        }
    }

    public var derived: DerivedChannel? {
        get { DerivedChannel(dictionary: defaults.dictionary(forKey: Self.derivedKey)) }
        set {
            if let newValue { defaults.set(newValue.dictionary, forKey: Self.derivedKey) }
            else { defaults.removeObject(forKey: Self.derivedKey) }
        }
    }

    /// The single place a feed read is applied, whoever read it (Sparkle's
    /// delegate or Maestro's own fetch). Stores the derivation and, when the
    /// rule finds Beta and there is no choice, saves Beta. Returns the
    /// effective channel.
    @discardableResult
    public func record(snapshot: FeedSnapshot, installed: String) -> UpdateChannel {
        let derivation = ChannelRule.derive(installed: installed, snapshot: snapshot)
        derived = derivation
        if let save = ChannelRule.preferenceToSave(preference: preference, derived: derivation) {
            preference = save
        }
        return ChannelRule.effective(preference: preference, installed: installed, snapshot: snapshot, stored: derivation)
    }

    public func effective(installed: String, snapshot: FeedSnapshot?) -> UpdateChannel {
        ChannelRule.effective(preference: preference, installed: installed, snapshot: snapshot, stored: derived)
    }
}

// MARK: - Going back to stable

public enum StableRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case noStableItem
    case belowFloor(version: String, floor: String)
    case unsignedFeed

    public var description: String {
        switch self {
        case .noStableItem: "the update feed lists no stable package this Mac can install"
        case .belowFloor(let version, let floor): "the newest stable version in the feed, \(version), is older than \(floor), the oldest version Maestro can go back to"
        case .unsignedFeed: "the update feed is not signed with Maestro's key"
        }
    }
}

public enum StableTarget: Equatable, Sendable {
    /// The installed version is the newest stable (also a promoted beta).
    case upToDate
    /// The installed version is older; Sparkle offers this version.
    case sparkleWillOffer(String)
    /// The installed version is newer; going back installs this item.
    case goBack(FeedItem)
    case refused(StableRefusal)

    /// Chooses what "Stable" means for this copy from a feed whose signature
    /// has already been verified: the highest-version item with no channel,
    /// a package enclosure and a minimum system version this Mac meets.
    public static func choose(snapshot: FeedSnapshot, installed: String, floor: String = UpdateFloor.stable,
                              macOS: OperatingSystemVersion) -> StableTarget {
        let candidates = snapshot.items.filter { item in
            guard item.isStable, item.parsedVersion != nil, item.installationType == "package",
                  item.enclosureURL != nil, item.edSignature != nil, item.length != nil else { return false }
            guard let minimum = item.minimumSystemVersion, !minimum.isEmpty else { return true }
            return systemMeets(minimum, macOS)
        }
        guard let target = candidates.max(by: { $0.parsedVersion! < $1.parsedVersion! }),
              let targetVersion = target.parsedVersion else { return .refused(.noStableItem) }
        guard let mine = FeedVersion(installed) else { return .sparkleWillOffer(target.version) }
        if mine == targetVersion { return .upToDate }
        if mine < targetVersion { return .sparkleWillOffer(target.version) }
        if let floorVersion = FeedVersion(floor), targetVersion < floorVersion {
            return .refused(.belowFloor(version: target.version, floor: floor))
        }
        return .goBack(target)
    }

    private static func systemMeets(_ minimum: String, _ macOS: OperatingSystemVersion) -> Bool {
        guard let required = FeedVersion(minimum) else { return false }
        let running = FeedVersion("\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)")!
        return !(running < required)
    }
}

/// The checks on a downloaded go-back package, in order. Each failure names
/// the check for the "couldn't verify the download" message.
public enum PackageCheckFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case wrongLength(expected: Int, actual: Int)
    case badSignature
    case notNotarized(String)

    public var description: String {
        switch self {
        case .wrongLength(let expected, let actual): "the download is \(actual) bytes; the update feed says \(expected)"
        case .badSignature: "the download does not match the update feed's signature"
        case .notNotarized(let detail): "macOS did not accept the package as notarized by Maestro's developer (\(detail))"
        }
    }
}

/// Reads `spctl --assess --type install -vv <pkg>` (stdout and stderr
/// together). Accepts only exit 0, `source=Notarized Developer ID` and an
/// `origin=` line ending in the team ID.
public enum InstallerAssessment {
    public static let teamID = "95CX6P84C4"

    public static func check(exitStatus: Int32, output: String, teamID: String = teamID) -> PackageCheckFailure? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard exitStatus == 0 else { return .notNotarized("rejected, status \(exitStatus)") }
        guard lines.contains(where: { $0.hasSuffix(": accepted") || $0 == "accepted" }) else {
            return .notNotarized("not accepted")
        }
        guard lines.contains("source=Notarized Developer ID") else { return .notNotarized("not notarized") }
        guard lines.contains(where: { $0.hasPrefix("origin=Developer ID Installer: ") && $0.hasSuffix("(\(teamID))") }) else {
            return .notNotarized("signed by someone else")
        }
        return nil
    }
}
