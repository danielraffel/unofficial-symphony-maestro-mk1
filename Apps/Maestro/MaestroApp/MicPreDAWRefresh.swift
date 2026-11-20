import Foundation

/// One coalesced link-state read for a burst of HAL notifications. A task that
/// was cancelled (listeners stopped, device replaced) must not clear the slot
/// of a newer task, or two reads would run at once.
struct MicPreDAWRefreshGate: Equatable {
    private(set) var generation = 0
    private(set) var inFlight: Int?

    /// A token for a new read, or nil while one is already pending.
    mutating func begin() -> Int? {
        guard inFlight == nil else { return nil }
        generation += 1
        inFlight = generation
        return generation
    }

    /// True when `token` is still the pending read (not cancelled or replaced).
    func isCurrent(_ token: Int) -> Bool { inFlight == token }

    mutating func finish(_ token: Int) {
        if inFlight == token { inFlight = nil }
    }

    mutating func cancel() {
        inFlight = nil
        generation += 1
    }
}

/// The Inputs page reloads its strips when a DAW edit lands, except while the
/// user drags a gain knob: that reload waits for the drag to end, as the
/// front-panel gain path drops readings during a drag.
struct MicPreDAWDeferredReload: Equatable {
    private(set) var pending = false

    /// True when the page should reload now.
    mutating func request(dragging: Bool) -> Bool {
        if dragging { pending = true; return false }
        pending = false
        return true
    }

    /// True when a reload was held back by the drag that just ended.
    mutating func dragEnded() -> Bool {
        defer { pending = false }
        return pending
    }
}
