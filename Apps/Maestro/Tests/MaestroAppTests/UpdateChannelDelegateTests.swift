import Foundation
import Testing
import MaestroCore
@testable import MaestroApp

/// The Sparkle delegate answers `allowedChannels` from the channel rule, and
/// the feed Sparkle loads is applied before Sparkle filters it.
@MainActor
@Suite("Update channel delegate")
struct UpdateChannelDelegateTests {
    private func makeStore() -> (ChannelStore, ScratchUserDefaults) {
        let name = "UpdateChannelDelegateTests.\(UUID().uuidString)"
        let defaults = ScratchUserDefaults(suiteName: name)!
        return (ChannelStore(defaults: defaults), defaults)
    }

    @Test("An update is refused while Apogee's kernel driver is loaded, and only then", arguments: [true, false])
    func refusesUpdateWithApogeeDriverLoaded(loaded: Bool) {
        let (store, defaults) = makeStore()
        defer { defaults.cleanup() }
        var asked = 0
        let delegate = UpdateChannelDelegate(store: store, installedVersion: "0.9.18",
                                             apogeeKernelDriverLoaded: { asked += 1; return loaded })
        let refusal = delegate.updateRefusal()
        #expect((refusal != nil) == loaded)
        #expect(asked == 1)
        if loaded {
            #expect(refusal?.localizedDescription == ApogeeDriverConflict.updateRefusal)
        }
        // Sparkle finds the hook by this selector.
        #expect(delegate.responds(to: NSSelectorFromString("updater:shouldProceedWithUpdate:updateCheck:error:")))
    }

    @Test func stableCopyAsksForNoChannels() {
        let (store, defaults) = makeStore()
        defer { defaults.cleanup() }
        let delegate = UpdateChannelDelegate(store: store, installedVersion: "0.8.40")
        #expect(delegate.currentAllowedChannels() == [])
        delegate.record(items: [FeedItem(version: "0.8.40"), FeedItem(version: "0.9.0", channel: "beta")])
        #expect(delegate.currentAllowedChannels() == [])
        #expect(store.preference == nil)
    }

    @Test func handInstalledBetaAsksForBetaInTheSameCheck() {
        let (store, defaults) = makeStore()
        defer { defaults.cleanup() }
        let delegate = UpdateChannelDelegate(store: store, installedVersion: "0.9.0")
        var changes = 0
        delegate.onChange = { changes += 1 }
        #expect(delegate.currentAllowedChannels() == [])
        delegate.record(items: [FeedItem(version: "0.8.40"), FeedItem(version: "0.9.0", channel: "beta")])
        #expect(delegate.currentAllowedChannels() == ["beta"])
        #expect(store.preference == .beta)
        #expect(changes == 1)
    }

    @Test func explicitChoiceDecides() {
        let (store, defaults) = makeStore()
        defer { defaults.cleanup() }
        let delegate = UpdateChannelDelegate(store: store, installedVersion: "0.8.40")
        store.preference = .beta
        #expect(delegate.currentAllowedChannels() == ["beta"])
        store.preference = .stable
        let betaCopy = UpdateChannelDelegate(store: store, installedVersion: "0.9.0")
        betaCopy.record(items: [FeedItem(version: "0.8.40"), FeedItem(version: "0.9.0", channel: "beta")])
        #expect(betaCopy.currentAllowedChannels() == [])
    }
}

/// Sparkle finds the delegate methods by selector; a Swift name that did not
/// map to them would leave Beta silently unused.
@MainActor
@Suite("Update channel delegate selectors")
struct UpdateChannelDelegateSelectorTests {
    @Test func respondsToSparkleSelectors() {
        let delegate = UpdateChannelDelegate(store: ChannelStore(defaults: ScratchUserDefaults(suiteName: "UpdateChannelDelegateSelectorTests")!), installedVersion: "0.8.40")
        #expect(delegate.responds(to: NSSelectorFromString("allowedChannelsForUpdater:")))
        #expect(delegate.responds(to: NSSelectorFromString("updater:didFinishLoadingAppcast:")))
        #expect(delegate.responds(to: NSSelectorFromString("updater:didFinishUpdateCycleForUpdateCheck:error:")))
    }
}
