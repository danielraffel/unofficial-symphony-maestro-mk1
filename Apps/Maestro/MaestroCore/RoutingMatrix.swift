/// Routing matrix domain model.
///
/// Represents the audio routing state for a device. The Symphony IO has a
/// flexible crosspoint matrix where any source can be routed to any destination.
/// The app exposes this as two grids: input routing (hardware→software) and
/// output routing (software→hardware).
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIORouting.h`
/// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp`
/// Evidence: `og_source/maestro2/App/Model/APAudioChannelModel.m` (maestroRoute)
/// Evidence: `og_source/maestro2/App/Controllers/APInputRoutingTabRowViewController.m`
/// Evidence: `og_source/maestro2/App/Controllers/APOutputRoutingTabRowViewController.m`

// MARK: - Routing Point

/// An endpoint in the routing matrix (source or destination).
///
/// At the domain level, a routing point is identified by a kind (what type
/// of endpoint) and a channel index within that kind.
public struct RoutingPoint: Sendable, Equatable, Hashable {
    /// The type of routing endpoint.
    public let kind: Kind
    /// Zero-based channel index within the kind.
    public let channel: Int

    public init(kind: Kind, channel: Int) {
        self.kind = kind
        self.channel = channel
    }

    /// Routing endpoint kinds.
    ///
    /// Maps to the source/destination groups in `SymphonyIORouting.h`.
    public enum Kind: String, Sendable, CaseIterable {
        /// Software playback/record channels (USB/P2P in hardware terms).
        case software
        /// Analog I/O board channels (IOBoard0/1 in hardware terms).
        case analog
        /// Digital I/O channels (optical/SPDIF, part of IOBoard in hardware).
        case digital
        /// Low-latency mixer output.
        case mixerOutput
        /// Headphone output.
        case headphone
        /// No signal (digital silence).
        case none
    }
}

// MARK: - Routing Assignment

/// A single routing connection: one destination channel receives audio from one source.
///
/// In the legacy code, this is represented by the `maestroRoute` struct
/// (`mObjectID` + `mElement`) stored as binary NSData on `APAudioChannelModel`.
public struct RoutingAssignment: Sendable, Equatable, Hashable {
    /// The destination channel receiving audio.
    public let destination: RoutingPoint
    /// The source channel providing audio.
    public let source: RoutingPoint

    public init(destination: RoutingPoint, source: RoutingPoint) {
        self.destination = destination
        self.source = source
    }
}

// MARK: - Routing Matrix

/// The complete routing state for a device.
///
/// Holds all active routing assignments. The matrix enforces two constraints
/// from the legacy UI:
/// - Input routing: each software record channel has exactly one hardware source.
///   Grid is row-constrained (one check per row).
/// - Output routing: each hardware output has exactly one software source.
///   Grid is column-constrained (one check per column).
///
/// Evidence: `og_source/maestro2/App/Views/APRoutingGridMatrix.m`
///   - Input grid: `constrainToRows:YES`
///   - Output grid: `constrainToRows:NO`
public struct RoutingMatrix: Sendable, Equatable {

    /// All active routing assignments.
    public private(set) var assignments: [RoutingAssignment]

    /// Whether this matrix is at its default (reset) state.
    public private(set) var isDefault: Bool

    public init(assignments: [RoutingAssignment] = [], isDefault: Bool = true) {
        self.assignments = assignments
        self.isDefault = isDefault
    }

    // MARK: - Queries

    /// Find the source routed to a specific destination, if any.
    public func source(for destination: RoutingPoint) -> RoutingPoint? {
        assignments.first { $0.destination == destination }?.source
    }

    /// Find all destinations receiving from a specific source.
    public func destinations(for source: RoutingPoint) -> [RoutingPoint] {
        assignments.filter { $0.source == source }.map(\.destination)
    }

    // MARK: - Mutations

    /// Set the source for a destination, replacing any existing assignment.
    public mutating func setRoute(source: RoutingPoint, destination: RoutingPoint) {
        assignments.removeAll { $0.destination == destination }
        assignments.append(RoutingAssignment(destination: destination, source: source))
        isDefault = false
    }

    /// Remove the routing assignment for a destination (routes to silence).
    public mutating func clearRoute(for destination: RoutingPoint) {
        assignments.removeAll { $0.destination == destination }
        isDefault = false
    }

    /// Reset all assignments and mark as default.
    public mutating func reset(to defaults: [RoutingAssignment]) {
        assignments = defaults
        isDefault = true
    }
}

// MARK: - Default Routing Factory

/// Creates default (1:1) routing assignments for Symphony IO USB.
///
/// Default input routing: hardware analog/digital inputs map 1:1 to
/// software record channels. Default output routing: software playback
/// channels map 1:1 to hardware analog/digital outputs.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp`
///   - `ResetInputRouting()` / `ResetOutputRouting()` set 1:1 mappings.
public enum RoutingDefaults: Sendable {

    /// Default input routing for a device with the given channel counts.
    /// Maps hardware input channel N to software record channel N.
    public static func inputRouting(analogChannels: Int, digitalChannels: Int) -> [RoutingAssignment] {
        var result: [RoutingAssignment] = []
        for ch in 0..<analogChannels {
            result.append(RoutingAssignment(
                destination: RoutingPoint(kind: .software, channel: ch),
                source: RoutingPoint(kind: .analog, channel: ch)
            ))
        }
        for ch in 0..<digitalChannels {
            result.append(RoutingAssignment(
                destination: RoutingPoint(kind: .software, channel: analogChannels + ch),
                source: RoutingPoint(kind: .digital, channel: ch)
            ))
        }
        return result
    }

    /// Default output routing for a device with the given channel counts.
    /// Maps software playback channel N to hardware output channel N.
    public static func outputRouting(analogChannels: Int, digitalChannels: Int) -> [RoutingAssignment] {
        var result: [RoutingAssignment] = []
        for ch in 0..<analogChannels {
            result.append(RoutingAssignment(
                destination: RoutingPoint(kind: .analog, channel: ch),
                source: RoutingPoint(kind: .software, channel: ch)
            ))
        }
        for ch in 0..<digitalChannels {
            result.append(RoutingAssignment(
                destination: RoutingPoint(kind: .digital, channel: ch),
                source: RoutingPoint(kind: .software, channel: analogChannels + ch)
            ))
        }
        return result
    }
}
