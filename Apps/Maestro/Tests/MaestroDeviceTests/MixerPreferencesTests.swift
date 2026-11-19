import Foundation
import Testing
import MaestroCore
import MaestroDevice

@Suite("Physical mixer preferences")
struct MixerPreferencesTests {
    let layout = CardLayout(slot1: .optical, slot2: .analogAD16)

    @Test func unidentifiedUsesReceiptForReadsAndWrites() throws {
        let name = "IdentityFallback.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-12.0, forKey: "mixerMasterLevel_0")
        let known = ChannelStateStore(defaults: defaults, layout: layout,
            isSimulatingCards: false, identity: 42)
        let scoped = known.mixerPreferences
        scoped.set(-31.0, forKey: "mixerMasterLevel_0")
        let failed = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false)
        let fallback = failed.mixerPreferences
        #expect(fallback.storageKey == scoped.storageKey)
        #expect(fallback.object(forKey: "mixerMasterLevel_0") as? Double == -31)
        fallback.set(-27.0, forKey: "mixerMasterLevel_0")
        #expect(scoped.object(forKey: "mixerMasterLevel_0") as? Double == -27)
        #expect(defaults.double(forKey: "mixerMasterLevel_0") == -12)
    }

    @Test func unidentifiedBeforeMigrationUsesLegacy() throws {
        let name = "IdentityLegacy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-19.0, forKey: "mixerMasterLevel_0")
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false)
        let preferences = store.mixerPreferences
        #expect(preferences.object(forKey: "mixerMasterLevel_0") as? Double == -19)
        preferences.set(-25.0, forKey: "mixerMasterLevel_0")
        #expect(defaults.double(forKey: "mixerMasterLevel_0") == -25)
    }

    @Test func upgradePreservesEveryLegacyValueAndFreezesTheSource() throws {
        let name = "MixerPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let strip = MixerChannelState(level: -13, pan: 0.25, isMuted: true, isSoloed: true)
        for key in MixerPreferences.legacyKeys { defaults.set(-7.0, forKey: key) }
        defaults.set(try JSONEncoder().encode(strip), forKey: "mixerState_swReturn")
        defaults.set(false, forKey: "mixerMasterFadersLinked")
        defaults.set(true, forKey: "mixerSWReturnFadersLinked")
        defaults.set(1, forKey: "routingMode")
        defaults.set(3, forKey: "mixerSoftwareReturnSource_0")
        let before = USBMixerSavedState.load(defaults: defaults)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        let preferences = store.mixerPreferences
        let after = USBMixerSavedState.load(preferences: preferences)
        #expect(before == after)
        #expect(preferences.integer(forKey: "routingMode") == 1)
        for key in MixerPreferences.legacyKeys {
            let old = try #require(defaults.object(forKey: key) as? NSObject)
            let migrated = preferences.object(forKey: key) as? NSObject
            #expect(old == migrated)
            defaults.set(99, forKey: key)
        }
        let reloaded = USBMixerSavedState.load(preferences: store.mixerPreferences)
        #expect(reloaded == before)
        #expect(defaults.string(forKey: "mixerWideState.migratedTo") == store.scope)
        #expect(defaults.dictionary(forKey: "mixerWideState.migrationReceipt") != nil)
    }

    @Test func unitBReplacementLayoutSimulationAndPendingStaySeparate() throws {
        let name = "MixerPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-12.0, forKey: "mixerMasterLevel_0")
        let a = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        let b = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, unit: .b, identity: 84)
        let bPrefs = b.mixerPreferences
        #expect(bPrefs.object(forKey: "mixerMasterLevel_0") == nil)
        let aPrefs = a.mixerPreferences
        #expect(aPrefs.object(forKey: "mixerMasterLevel_0") as? Double == -12)
        bPrefs.set(-22.0, forKey: "mixerMasterLevel_0")
        #expect(aPrefs.object(forKey: "mixerMasterLevel_0") as? Double == -12)
        let movedB = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 84)
        #expect(movedB.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == -22)
        let changedLayout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        let converter = CardLayout(isKnown: false, converter: ConnectedUnit(probeWord: 0x8000_0000))
        let others = [
            ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 99),
            ChannelStateStore(defaults: defaults, layout: changedLayout, isSimulatingCards: false, identity: 42),
            ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: true, identity: 42),
            ChannelStateStore(defaults: defaults, layout: converter, isSimulatingCards: false),
            ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, awaitingIdentity: true)
        ]
        for other in others {
            let preferences = other.mixerPreferences
            #expect(preferences.object(forKey: "mixerMasterLevel_0") == nil)
            preferences.set(-33.0, forKey: "mixerMasterLevel_0")
        }
        #expect(aPrefs.object(forKey: "mixerMasterLevel_0") as? Double == -12)
        #expect(bPrefs.object(forKey: "mixerMasterLevel_0") as? Double == -22)
    }

    @Test func missingLegacyFieldsNeverAppearLaterAndReceiptResumes() throws {
        let name = "MixerPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        let first = store.mixerPreferences
        defaults.set(1, forKey: "routingMode")
        let key = try #require(first.storageKey)
        defaults.removeObject(forKey: key) // interruption before destination materialization
        let resumed = store.mixerPreferences
        #expect(resumed.integer(forKey: "routingMode") == 0)
        #expect(defaults.dictionary(forKey: key)?.isEmpty == true)
    }
}
