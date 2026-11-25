import Testing
@testable import MaestroCore

struct SymphonyExtendedSelectorsTests {
    @Test func servingBuildNotBundledBuildControlsCapability() {
        #expect(!SymphonyExtendedSelectors.supported(by: nil))
        #expect(!SymphonyExtendedSelectors.supported(by: .build(131)))
        #expect(SymphonyExtendedSelectors.supported(by: .build(132)))
        #expect(SymphonyExtendedSelectors.supported(by: .build(133)))
    }
}
