import Testing
@testable import MaestroApp

/// The channel wording is the approved copy of the release-channels plan (§6)
/// and names no feature: the notes link comes from the feed.
@Suite("Update channel copy")
struct UpdateChannelCopyTests {
    @Test func betaConfirmationNamesNoFeature() {
        let text = [UpdateChannelCopy.betaTitle, UpdateChannelCopy.betaBody, UpdateChannelCopy.betaBack].joined(separator: " ")
        for word in ["64", "two-port", "Two-port", "second unit", "0.9"] {
            #expect(!text.contains(word))
        }
        #expect(UpdateChannelCopy.betaBody.contains("may have bugs"))
        #expect(UpdateChannelCopy.betaBody.contains("can replace the ThunderBridge driver"))
    }

    @Test func versionsAreFilledIn() {
        #expect(UpdateChannelCopy.runningBeta("0.9.0", stable: "0.8.40") == "You're running beta 0.9.0. The latest stable version is 0.8.40.")
        #expect(UpdateChannelCopy.installButton("0.8.40") == "Install 0.8.40")
        #expect(UpdateChannelCopy.switchAndInstall("0.8.40") == "Switch and Install 0.8.40")
        #expect(UpdateChannelCopy.downloading("0.8.40") == "Downloading Maestro 0.8.40…")
        #expect(UpdateChannelCopy.stillOnBeta("0.9.0") == "You're still running beta 0.9.0. You'll get the next stable version when it is newer than this one.")
        #expect(UpdateChannelCopy.goBackBody("0.9.0", stable: "0.8.40").first == UpdateChannelCopy.runningBeta("0.9.0", stable: "0.8.40"))
        #expect(UpdateChannelCopy.runningBeta("0.9.28", stable: "0.8.40", installedDate: "25 Nov", stableDate: "16 Nov")
                == "You're running beta 0.9.28 (25 Nov). The latest stable version is 0.8.40 (16 Nov).")
        #expect(UpdateChannelCopy.runningBeta("0.9.28", stable: "0.8.40", stableDate: "16 Nov")
                == "You're running beta 0.9.28. The latest stable version is 0.8.40 (16 Nov).")
        #expect(UpdateChannelCopy.goBackBody("0.9.28", stable: "0.8.40", installedDate: "25 Nov", stableDate: "16 Nov").first
                == "You're running beta 0.9.28 (25 Nov). The latest stable version is 0.8.40 (16 Nov).")
        #expect(UpdateChannelCopy.testFeed("http://127.0.0.1:8765/appcast.xml") == "Updates are being read from a test feed: http://127.0.0.1:8765/appcast.xml")
    }

    /// Rehearsal 2026-11-15: the offline message named a button ("Install
    /// stable") that does not exist, and a feed refused before any download
    /// was reported as a download that could not be verified.
    @Test func failureWordingMatchesWhatHappened() {
        #expect(!UpdateChannelCopy.feedUnreachable.contains("Install stable"))
        #expect(UpdateChannelCopy.feedUnreachable.contains("choose Check for Updates, then press the Install button under Update channel"))
        #expect(UpdateChannelCopy.feedRefused == "Maestro couldn't get the stable version from the update feed, so nothing was installed.")
        #expect(!UpdateChannelCopy.feedRefused.contains("download"))
        #expect(UpdateChannelCopy.verifyFailed == "Maestro couldn't verify the download, so nothing was installed.")
        #expect(UpdateChannelCopy.noBetaNow == "There's no beta available right now. You'll get the next one when it is released.")
    }

    /// Preferences promises no connection without a user action when
    /// scheduled checks are off; changing channel is such an action.
    @Test func automaticCheckHelpMentionsTheChannel() {
        #expect(UpdateChannelCopy.automaticCheckHelp.hasSuffix("only connects when you choose Check for Updates or change the update channel."))
    }
}
