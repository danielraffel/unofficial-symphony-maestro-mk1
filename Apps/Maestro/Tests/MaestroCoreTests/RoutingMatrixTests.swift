import Testing
@testable import MaestroCore

/// Tests for the routing matrix domain model.
///
/// Evidence sources:
/// - `og_source/maestrolink/Software/SymphonyIO/SymphonyIORouting.h`
/// - `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp`
/// - `og_source/maestro2/App/Views/APRoutingGridMatrix.m`

@Suite("RoutingMatrix")
struct RoutingMatrixTests {

    // MARK: - RoutingPoint

    @Test func routingPointEquality() {
        let a = RoutingPoint(kind: .analog, channel: 0)
        let b = RoutingPoint(kind: .analog, channel: 0)
        let c = RoutingPoint(kind: .analog, channel: 1)
        let d = RoutingPoint(kind: .digital, channel: 0)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test func routingPointKindCaseIterable() {
        // Verify all expected kinds exist
        let kinds = RoutingPoint.Kind.allCases
        #expect(kinds.contains(.software))
        #expect(kinds.contains(.analog))
        #expect(kinds.contains(.digital))
        #expect(kinds.contains(.mixerOutput))
        #expect(kinds.contains(.headphone))
        #expect(kinds.contains(.none))
        #expect(kinds.count == 6)
    }

    // MARK: - Empty matrix

    @Test func emptyMatrixIsDefault() {
        let matrix = RoutingMatrix()
        #expect(matrix.assignments.isEmpty)
        #expect(matrix.isDefault == true)
    }

    // MARK: - Set and query routes

    @Test func setRouteThenQuery() {
        var matrix = RoutingMatrix()
        let src = RoutingPoint(kind: .analog, channel: 0)
        let dst = RoutingPoint(kind: .software, channel: 0)

        matrix.setRoute(source: src, destination: dst)

        #expect(matrix.source(for: dst) == src)
        #expect(matrix.isDefault == false)
    }

    @Test func setRouteReplacesExisting() {
        var matrix = RoutingMatrix()
        let dst = RoutingPoint(kind: .software, channel: 0)
        let src1 = RoutingPoint(kind: .analog, channel: 0)
        let src2 = RoutingPoint(kind: .analog, channel: 1)

        matrix.setRoute(source: src1, destination: dst)
        matrix.setRoute(source: src2, destination: dst)

        #expect(matrix.source(for: dst) == src2)
        #expect(matrix.assignments.count == 1)
    }

    @Test func clearRoute() {
        var matrix = RoutingMatrix()
        let src = RoutingPoint(kind: .analog, channel: 0)
        let dst = RoutingPoint(kind: .software, channel: 0)

        matrix.setRoute(source: src, destination: dst)
        matrix.clearRoute(for: dst)

        #expect(matrix.source(for: dst) == nil)
        #expect(matrix.assignments.isEmpty)
    }

    @Test func destinationsForSource() {
        var matrix = RoutingMatrix()
        let src = RoutingPoint(kind: .software, channel: 0)
        let dst1 = RoutingPoint(kind: .analog, channel: 0)
        let dst2 = RoutingPoint(kind: .analog, channel: 1)

        matrix.setRoute(source: src, destination: dst1)
        matrix.setRoute(source: src, destination: dst2)

        let dests = matrix.destinations(for: src)
        #expect(dests.count == 2)
        #expect(dests.contains(dst1))
        #expect(dests.contains(dst2))
    }

    // MARK: - Reset

    @Test func resetRestoresDefaultFlag() {
        var matrix = RoutingMatrix()
        let src = RoutingPoint(kind: .analog, channel: 0)
        let dst = RoutingPoint(kind: .software, channel: 0)

        matrix.setRoute(source: src, destination: dst)
        #expect(matrix.isDefault == false)

        let defaults = RoutingDefaults.inputRouting(analogChannels: 8, digitalChannels: 0)
        matrix.reset(to: defaults)
        #expect(matrix.isDefault == true)
        #expect(matrix.assignments.count == 8)
    }

    // MARK: - Default routing factory

    /// Symphony IO USB has 8 analog + 8 digital I/O channels (at 44.1/48k).
    /// Default input routing is 1:1: analog in 0→sw 0, ..., digital in 0→sw 8, ...
    @Test func defaultInputRouting8Analog8Digital() {
        let defaults = RoutingDefaults.inputRouting(analogChannels: 8, digitalChannels: 8)
        #expect(defaults.count == 16)

        // First analog channel
        #expect(defaults[0].source == RoutingPoint(kind: .analog, channel: 0))
        #expect(defaults[0].destination == RoutingPoint(kind: .software, channel: 0))

        // Last analog channel
        #expect(defaults[7].source == RoutingPoint(kind: .analog, channel: 7))
        #expect(defaults[7].destination == RoutingPoint(kind: .software, channel: 7))

        // First digital channel
        #expect(defaults[8].source == RoutingPoint(kind: .digital, channel: 0))
        #expect(defaults[8].destination == RoutingPoint(kind: .software, channel: 8))

        // Last digital channel
        #expect(defaults[15].source == RoutingPoint(kind: .digital, channel: 7))
        #expect(defaults[15].destination == RoutingPoint(kind: .software, channel: 15))
    }

    @Test func defaultOutputRouting8Analog8Digital() {
        let defaults = RoutingDefaults.outputRouting(analogChannels: 8, digitalChannels: 8)
        #expect(defaults.count == 16)

        // First analog output
        #expect(defaults[0].destination == RoutingPoint(kind: .analog, channel: 0))
        #expect(defaults[0].source == RoutingPoint(kind: .software, channel: 0))

        // First digital output
        #expect(defaults[8].destination == RoutingPoint(kind: .digital, channel: 0))
        #expect(defaults[8].source == RoutingPoint(kind: .software, channel: 8))
    }

    /// Symphony IO at higher sample rates may have fewer channels (e.g. 8ch mode).
    @Test func defaultRoutingWithFewerChannels() {
        let defaults = RoutingDefaults.inputRouting(analogChannels: 8, digitalChannels: 0)
        #expect(defaults.count == 8)
    }

    // MARK: - RoutingAssignment

    @Test func assignmentEquality() {
        let a = RoutingAssignment(
            destination: RoutingPoint(kind: .software, channel: 0),
            source: RoutingPoint(kind: .analog, channel: 0)
        )
        let b = RoutingAssignment(
            destination: RoutingPoint(kind: .software, channel: 0),
            source: RoutingPoint(kind: .analog, channel: 0)
        )
        #expect(a == b)
    }

    @Test func assignmentHashable() {
        let a = RoutingAssignment(
            destination: RoutingPoint(kind: .software, channel: 0),
            source: RoutingPoint(kind: .analog, channel: 0)
        )
        let set: Set<RoutingAssignment> = [a, a]
        #expect(set.count == 1)
    }

    // MARK: - Dual routing (one source → two destinations)

    /// Dual routing: single software source feeds both analog and digital outputs.
    /// This models the Symphony IO MKI pattern where USB ch0 drives both IOBoard0 ch0
    /// and IOBoard1 ch0 simultaneously (FPGA crosspoint allows multiple destinations per source).
    @Test func dualRoutingSameSourceTwoDestinations() {
        var matrix = RoutingMatrix()
        let src = RoutingPoint(kind: .software, channel: 0)
        let board0Out = RoutingPoint(kind: .analog, channel: 0)
        let board1Out = RoutingPoint(kind: .digital, channel: 0)

        matrix.setRoute(source: src, destination: board0Out)
        matrix.setRoute(source: src, destination: board1Out)

        // Source should map to 2 destinations
        let dests = matrix.destinations(for: src)
        #expect(dests.count == 2)
        #expect(dests.contains(board0Out))
        #expect(dests.contains(board1Out))

        // Each destination should map back to the same source
        #expect(matrix.source(for: board0Out) == src)
        #expect(matrix.source(for: board1Out) == src)
    }

    /// Full dual routing: all 8 software pairs route to both IOBoard0 and IOBoard1.
    @Test func fullDualRouting8Pairs() {
        var matrix = RoutingMatrix()
        for ch in 0..<8 {
            let src = RoutingPoint(kind: .software, channel: ch)
            let primary = RoutingPoint(kind: .analog, channel: ch)
            let secondary = RoutingPoint(kind: .digital, channel: ch)
            matrix.setRoute(source: src, destination: primary)
            matrix.setRoute(source: src, destination: secondary)
        }
        // 16 total assignments (8 pairs × 2 destinations each)
        #expect(matrix.assignments.count == 16)

        // Each source has exactly 2 destinations
        for ch in 0..<8 {
            let src = RoutingPoint(kind: .software, channel: ch)
            #expect(matrix.destinations(for: src).count == 2)
        }
    }

    /// Clearing one destination of a dual route preserves the other.
    @Test func clearOneDualRoutePreservesOther() {
        var matrix = RoutingMatrix()
        let src = RoutingPoint(kind: .software, channel: 0)
        let board0Out = RoutingPoint(kind: .analog, channel: 0)
        let board1Out = RoutingPoint(kind: .digital, channel: 0)

        matrix.setRoute(source: src, destination: board0Out)
        matrix.setRoute(source: src, destination: board1Out)
        #expect(matrix.destinations(for: src).count == 2)

        // Clear only the secondary route
        matrix.clearRoute(for: board1Out)
        #expect(matrix.destinations(for: src).count == 1)
        #expect(matrix.source(for: board0Out) == src)
        #expect(matrix.source(for: board1Out) == nil)
    }
}
