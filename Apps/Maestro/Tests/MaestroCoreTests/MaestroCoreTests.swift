import Testing
@testable import MaestroCore

@Test func coreModuleLoads() {
    // Assert the shape, not the literal — MaestroCore.version is the release version and
    // is bumped by hand for every release. Pinning it here just breaks the suite on bump.
    let parts = MaestroCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { UInt($0) != nil })
}

@Test func buildInfoExists() {
    #expect(MaestroCore.buildNumber >= 0)
    #expect(!MaestroCore.gitHash.isEmpty)
}

@Test func buildInfoDevDefaults() {
    // In test builds (not deploy.sh), dev defaults are used
    if MaestroCore.buildNumber == 0 {
        #expect(MaestroCore.gitHash == "dev")
    } else {
        // deploy.sh-generated build: hash should be a short git hash (7+ chars)
        #expect(MaestroCore.gitHash.count >= 7)
    }
}
