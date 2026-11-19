/// Authority comes from an explicit Maestro action, never from saving/migrating
/// an array or observing a hardware bit. Slot and channel are zero based.
/// Evidence: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:135-153,670-699.
public struct PhantomProvenance: Codable, Sendable, Equatable {
    public let unitID: UInt64
    public let boardSlot: Int
    public let channel: Int

    public init(unitID: UInt64, boardSlot: Int, channel: Int) {
        self.unitID = unitID
        self.boardSlot = boardSlot
        self.channel = channel
    }
}

public extension InputChannelState {
    func restoresPhantom(identity: UInt64?, boardSlot: Int, channel: Int) -> Bool {
        guard phantom, inputType == AnalogInputLevel.mic.rawValue,
              let identity, identity != 0, identity != UInt64.max else { return false }
        return phantomProvenance == PhantomProvenance(unitID: identity, boardSlot: boardSlot, channel: channel)
    }

    func recalled(identity: UInt64?, boardSlot: Int, channel: Int) -> Self {
        var state = self
        state.phantom = restoresPhantom(identity: identity, boardSlot: boardSlot, channel: channel)
        if !state.phantom { state.phantomProvenance = nil }
        return state
    }

    mutating func recordPhantomRequest(_ enabled: Bool, identity: UInt64?, boardSlot: Int, channel: Int) {
        phantom = enabled && inputType == AnalogInputLevel.mic.rawValue
        phantomProvenance = nil
        if phantom, let identity, identity != 0, identity != UInt64.max {
            phantomProvenance = PhantomProvenance(unitID: identity, boardSlot: boardSlot, channel: channel)
        }
    }

    /// Reject only the pending phantom fields; unrelated front-panel edits survive.
    mutating func rejectPhantomRequest(_ request: Self) {
        guard phantom == request.phantom, phantomProvenance == request.phantomProvenance else { return }
        phantom = false
        phantomProvenance = nil
    }

    /// Commit authority only after the transport accepts this explicit request.
    mutating func finishPhantomRequest(_ request: Self, accepted: Bool,
                                      identity: UInt64?, boardSlot: Int, channel: Int) {
        guard phantom == request.phantom, phantomProvenance == request.phantomProvenance else { return }
        if accepted {
            recordPhantomRequest(request.phantom, identity: identity, boardSlot: boardSlot, channel: channel)
        } else {
            rejectPhantomRequest(request)
        }
    }
}
