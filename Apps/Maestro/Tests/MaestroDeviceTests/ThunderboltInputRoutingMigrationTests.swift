import Testing
import Foundation
@testable import MaestroDevice

/// The one-time clear of Input Routing choices saved before 0.8.40, which were
/// made on a grid that showed the wrong default and were never re-sent.
@Suite("ThunderBridge input routing migration")
struct ThunderboltInputRoutingMigrationTests {
    private func freshDefaults() -> UserDefaults {
        let name = "ThunderboltInputRoutingMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let key = "routing_input_18_v2"

    @Test("Saved pre-0.8.40 choices are cleared once")
    func clearsOnce() {
        let defaults = freshDefaults()
        defaults.set(["0": 3, "4": 1], forKey: key)
        #expect(ThunderboltInputRoutingMigration.run(routingKey: key, defaults: defaults))
        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.bool(forKey: ThunderboltInputRoutingMigration.doneKey))

        // Choices made afterwards (on the 0.8.40 grid) are kept.
        defaults.set(["2": 5], forKey: key)
        #expect(!ThunderboltInputRoutingMigration.run(routingKey: key, defaults: defaults))
        #expect(defaults.dictionary(forKey: key) as? [String: Int] == ["2": 5])
    }

    @Test("Nothing saved: nothing removed, and it does not run again")
    func nothingSaved() {
        let defaults = freshDefaults()
        #expect(!ThunderboltInputRoutingMigration.run(routingKey: key, defaults: defaults))
        #expect(defaults.bool(forKey: ThunderboltInputRoutingMigration.doneKey))
        defaults.set(["1": 1], forKey: key)
        #expect(!ThunderboltInputRoutingMigration.run(routingKey: key, defaults: defaults))
        #expect(defaults.object(forKey: key) != nil)
    }

    @Test("Only the input routing entry is touched")
    func leavesOtherKeys() {
        let defaults = freshDefaults()
        defaults.set(["0": 3], forKey: key)
        defaults.set(["0": [1]], forKey: "routing_output_18_v2_multi")
        defaults.set(true, forKey: "thunderboltMainPairMixerMigration_v1")
        ThunderboltInputRoutingMigration.run(routingKey: key, defaults: defaults)
        #expect(defaults.object(forKey: "routing_output_18_v2_multi") != nil)
        #expect(defaults.bool(forKey: "thunderboltMainPairMixerMigration_v1"))
    }
}
