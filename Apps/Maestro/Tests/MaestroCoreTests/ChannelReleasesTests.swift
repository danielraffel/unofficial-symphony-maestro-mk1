import Foundation
import Testing
@testable import MaestroCore

/// App Settings › Updates: the newest Stable and Beta versions under the
/// channel picker, read from the feed Sparkle uses.
@Suite("Channel releases")
struct ChannelReleasesTests {

    /// Items of the real appcast.xml (2026-11-25), descriptions trimmed. The
    /// beta items come first, as `generate_appcast` writes them.
    static let realFeed = """
<?xml version="1.0" encoding="utf-8" standalone="yes"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>Maestro Updates</title>
    <link>https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases</link>
    <description>Updates for Unofficial Symphony Maestro</description>
    <language>en</language>
    <item>
      <title>Maestro 0.9.28</title>
      <pubDate>Wed, 25 Nov 2026 02:42:53 GMT</pubDate>
      <sparkle:version>0.9.28</sparkle:version>
      <sparkle:shortVersionString>0.9.28</sparkle:shortVersionString>
      <sparkle:channel>beta</sparkle:channel>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/tag/v0.9.28</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
This beta makes ThunderBridge connect faster after a replug.
      ]]></description>
      <enclosure url="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download/v0.9.28/UnofficialSymphonyMaestro.pkg" sparkle:edSignature="nvcm" length="6374150" type="application/octet-stream" sparkle:installationType="package"></enclosure>
    </item>
    <item>
      <title>Maestro 0.9.26</title>
      <pubDate>Tue, 24 Nov 2026 20:25:14 GMT</pubDate>
      <sparkle:version>0.9.26</sparkle:version>
      <sparkle:shortVersionString>0.9.26</sparkle:shortVersionString>
      <sparkle:channel>beta</sparkle:channel>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/tag/v0.9.26</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download/v0.9.26/UnofficialSymphonyMaestro.pkg" sparkle:edSignature="AAAA" length="10" type="application/octet-stream" sparkle:installationType="package"></enclosure>
    </item>
    <item>
      <title>Maestro 0.8.40</title>
      <pubDate>Mon, 16 Nov 2026 05:12:14 GMT</pubDate>
      <sparkle:version>0.8.40</sparkle:version>
      <sparkle:shortVersionString>0.8.40</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/tag/v0.8.40</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
Every option card now behaves the way it did in Apogee's original Maestro.
      ]]></description>
      <enclosure url="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download/v0.8.40/UnofficialSymphonyMaestro.pkg" sparkle:edSignature="BBBB" length="11" type="application/octet-stream" sparkle:installationType="package"></enclosure>
    </item>
    <item>
      <title>Maestro 0.8.39</title>
      <pubDate>Sat, 14 Nov 2026 01:00:00 GMT</pubDate>
      <sparkle:version>0.8.39</sparkle:version>
      <sparkle:shortVersionString>0.8.39</sparkle:shortVersionString>
      <sparkle:fullReleaseNotesLink>https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/tag/v0.8.39</sparkle:fullReleaseNotesLink>
    </item>
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: pkuu
length: 1
-->
"""

    static func feed(_ items: String) -> Data {
        Data("""
<?xml version="1.0" encoding="utf-8"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Maestro Updates</title>
\(items)
</channel></rss>
""".utf8)
    }

    static func item(_ version: String, beta: Bool = false, date: String? = "Mon, 16 Nov 2026 05:12:14 GMT",
                     notes: Bool = true) -> String {
        """
<item><title>Maestro \(version)</title>\(date.map { "<pubDate>\($0)</pubDate>" } ?? "")<sparkle:version>\(version)</sparkle:version>\
\(beta ? "<sparkle:channel>beta</sparkle:channel>" : "")\
\(notes ? "<sparkle:fullReleaseNotesLink>https://example.com/v\(version)</sparkle:fullReleaseNotesLink>" : "")</item>
"""
    }

    static let gb = Locale(identifier: "en_GB")
    static let us = Locale(identifier: "en_US")

    // MARK: Parsing and selection

    @Test func realFeedGivesNewestStableAndBeta() throws {
        let releases = try #require(ChannelReleases.make(content: Data(Self.realFeed.utf8), automaticChecks: true))
        let stable = try #require(releases.stable)
        let beta = try #require(releases.beta)
        #expect(stable.version == "0.8.40")
        #expect(beta.version == "0.9.28")
        #expect(stable.summary(locale: Self.gb) == "0.8.40 · 16 Nov")
        #expect(beta.summary(locale: Self.gb) == "0.9.28 · 25 Nov")
        #expect(stable.notesURL == URL(string: "https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/tag/v0.8.40"))
        #expect(beta.notesURL == URL(string: "https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/tag/v0.9.28"))
        #expect(beta.isNewer)
        #expect(!stable.isNewer)
    }

    /// The feed's own day (UTC), in the user's order: 0.9.28 was published
    /// 25 Nov 02:42 GMT, still 24 Nov in California.
    @Test func dateIsTheFeedsDayInTheUsersOrder() throws {
        let snapshot = try FeedSnapshot(content: Data(Self.realFeed.utf8))
        let date = try #require(snapshot.newestBeta?.date)
        #expect(ChannelReleases.dateText(date, locale: Self.gb) == "25 Nov")
        #expect(ChannelReleases.dateText(date, locale: Self.us) == "Nov 25")
    }

    @Test func orderInTheFileDoesNotMatter() throws {
        let data = Self.feed(Self.item("0.8.39") + Self.item("0.9.1", beta: true) + Self.item("0.8.40") + Self.item("0.9.0", beta: true))
        let releases = try #require(ChannelReleases.make(content: data, automaticChecks: true))
        #expect(releases.stable?.version == "0.8.40")
        #expect(releases.beta?.version == "0.9.1")
    }

    @Test func versionsCompareByNumberNotText() throws {
        let data = Self.feed(Self.item("0.10.0") + Self.item("0.9.28", beta: true))
        let releases = try #require(ChannelReleases.make(content: data, automaticChecks: true))
        #expect(releases.stable?.version == "0.10.0")
        #expect(releases.stable?.isNewer == true)
        #expect(releases.beta?.isNewer == false)
    }

    @Test func equalVersionsMarkNeitherNewer() throws {
        let data = Self.feed(Self.item("0.9.28") + Self.item("0.9.28", beta: true))
        let releases = try #require(ChannelReleases.make(content: data, automaticChecks: true))
        #expect(releases.stable?.isNewer == false)
        #expect(releases.beta?.isNewer == false)
    }

    @Test func oneChannelAloneIsNeverNewer() throws {
        let releases = try #require(ChannelReleases.make(content: Self.feed(Self.item("0.8.40")), automaticChecks: true))
        #expect(releases.stable?.version == "0.8.40")
        #expect(releases.stable?.isNewer == false)
        #expect(releases.beta == nil)
    }

    @Test func missingDateOrLinkLeavesOutJustThatPiece() throws {
        let data = Self.feed(Self.item("0.8.40", date: nil) + Self.item("0.9.28", beta: true, notes: false))
        let releases = try #require(ChannelReleases.make(content: data, automaticChecks: true))
        let stable = try #require(releases.stable)
        let beta = try #require(releases.beta)
        #expect(stable.date == nil)
        #expect(stable.summary(locale: Self.gb) == "0.8.40")
        #expect(stable.notesURL == URL(string: "https://example.com/v0.8.40"))
        #expect(beta.notesURL == nil)
        #expect(beta.summary(locale: Self.gb) == "0.9.28 · 16 Nov")
    }

    @Test func unreadableDateIsDroppedNotTheItem() throws {
        let data = Self.feed(Self.item("0.8.40", date: "sometime last week"))
        let releases = try #require(ChannelReleases.make(content: data, automaticChecks: true))
        #expect(releases.stable?.version == "0.8.40")
        #expect(releases.stable?.date == nil)
    }

    @Test func itemsWithoutAVersionAreIgnored() {
        let data = Self.feed("<item><title>Maestro</title><pubDate>Mon, 16 Nov 2026 05:12:14 GMT</pubDate></item>")
        #expect(ChannelReleases.make(content: data, automaticChecks: true) == nil)
    }

    @Test func malformedFeedGivesNothing() {
        #expect(ChannelReleases.make(content: Data("<rss><channel><item>".utf8), automaticChecks: true) == nil)
        #expect(ChannelReleases.make(content: Data("Not Found".utf8), automaticChecks: true) == nil)
        #expect(ChannelReleases.make(content: Data(), automaticChecks: true) == nil)
    }

    // MARK: When to show

    @Test func hiddenWithScheduledChecksOff() throws {
        let snapshot = try FeedSnapshot(content: Data(Self.realFeed.utf8))
        #expect(ChannelReleases.make(snapshot: snapshot, automaticChecks: false) == nil)
        #expect(ChannelReleases.make(content: Data(Self.realFeed.utf8), automaticChecks: false) == nil)
    }

    /// A failed read leaves no snapshot.
    @Test func hiddenWithoutAFeedRead() {
        #expect(ChannelReleases.make(snapshot: nil, automaticChecks: true) == nil)
    }

    @Test func sameWhicheverChannelThisCopyFollows() throws {
        // Nothing about the installed copy or its channel goes in.
        let snapshot = try FeedSnapshot(content: Data(Self.realFeed.utf8))
        let releases = ChannelReleases.make(snapshot: snapshot, automaticChecks: true)
        #expect(releases?.beta?.isNewer == true)
    }
}
