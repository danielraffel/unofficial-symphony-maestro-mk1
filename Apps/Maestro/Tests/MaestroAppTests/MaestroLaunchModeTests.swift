import Testing
@testable import MaestroApp

struct MaestroLaunchModeTests {
    @Test func exactDeactivationCommandSelectsHeadlessMode() {
        #expect(MaestroLaunchMode(arguments: ["--deactivate-driver"]) == .deactivateDriver)
    }

    @Test(arguments: [
        [],
        ["-MaestroDiagnosticsSelfTest", "20"],
        ["--deactivate-driver", "extra"],
        ["--deactivate-driver=no"],
    ])
    func otherArgumentsKeepNormalLaunch(arguments: [String]) {
        #expect(MaestroLaunchMode(arguments: arguments) == .app)
    }
}
