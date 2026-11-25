import Testing
@testable import MaestroCore

struct SymphonyCardInputTransitionPolicyTests {
    @Test func leaving64RestoresOnlyLowerHalfUnitBRoutes() {
        let routes = [0: 32, 1: 7, 2: 63, 31: 12, 32: 40]
        let restored = SymphonyCardInputTransitionPolicy.restoreSingleUnitRoutes(routes)
        #expect(restored[0] == 0)
        #expect(restored[1] == 7)
        #expect(restored[2] == 2)
        #expect(restored[31] == 12)
        #expect(restored[32] == 40)
    }
}
