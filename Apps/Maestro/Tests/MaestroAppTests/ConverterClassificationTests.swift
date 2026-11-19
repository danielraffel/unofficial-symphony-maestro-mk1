import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

@Suite("Converter classification recovery")
struct ConverterClassificationTests {
    private func state(flags: UInt32) -> ConverterState {
        ConverterState(flags: flags,
                       unitCount: [1, 0],
                       units: [[0x0007_0030, 0, 0, 0], [0, 0, 0, 0]])
    }

    @Test("a zero Symphony probe clears stale port one converter state")
    func symphonyProbeWinsOverStaleConverterSnapshot() {
        let system = AppState.converterSystem(
            state: state(flags: ConverterState.flagPort1Converters), probeWord: 0)
        #expect(system == nil)
    }

    @Test("port two converters remain visible with a Symphony port one")
    func portTwoConverterStateIsRetained() {
        let system = AppState.converterSystem(
            state: ConverterState(flags: ConverterState.flagPort2Converters,
                                  unitCount: [0, 1],
                                  units: [[0, 0, 0, 0], [0x0007_0030, 0, 0, 0]]),
            probeWord: 0)
        #expect(system?.ports[0].isEmpty == true)
        #expect(system?.ports[1].isEmpty == false)
    }
}

@Suite("Converter discovery stability")
struct ConverterDiscoveryStabilityTests {
    @Test("A converter verdict invalidates identity once, not on every discovery pass")
    func invalidateOnlyOnVerdictChange() {
        let first = AppState.converterVerdictNeedsInvalidation(isConverter: true, unitA: .pending, unitB: .pending)
        let again = AppState.converterVerdictNeedsInvalidation(isConverter: true, unitA: .failed, unitB: .failed)
        let symphony = AppState.converterVerdictNeedsInvalidation(isConverter: false, unitA: .pending, unitB: .pending)
        #expect(first)
        #expect(!again)
        #expect(!symphony)
    }
}
