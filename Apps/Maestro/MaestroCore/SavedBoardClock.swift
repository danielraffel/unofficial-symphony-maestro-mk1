import Foundation

/// A card's digital input chosen as the clock source (SPDIF, AES, ADAT/SMUX),
/// remembered for one physical Symphony I/O.
///
/// Internal and Word Clock live in the driver's clock control and come back
/// with it. A card input is sent to the unit beside that control, so after a
/// restart the driver put the unit back on whatever the control held and the
/// choice was lost. The original saved the source and sent it at every
/// connect (og_source/maestrolink/Software/SymphonyIO.cpp, ApplySettingsToHardware).
public struct SavedBoardClock: Codable, Equatable, Sendable {
    /// The Clock Source menu key (`ClockSourceMenu.key`).
    public var key: UInt32
    /// What the driver's clock control read when the choice was made; nil if
    /// it could not be read.
    public var control: UInt32?

    public init(key: UInt32, control: UInt32?) {
        self.key = key
        self.control = control
    }

    public static func defaultsKey(identity: UInt64) -> String {
        "thunderboltBoardClock.\(String(identity, radix: 16))"
    }

    public enum Decision: Equatable, Sendable {
        /// Send this key to the unit.
        case send(UInt32)
        /// Leave the unit alone and keep the saved choice (the control cannot
        /// be read yet, or the card that has this input is not there now).
        case wait
        /// The clock control was changed elsewhere since (Audio MIDI Setup, a
        /// DAW): that newer choice stands and the saved one is dropped.
        case forget
    }

    /// What to do with a saved choice at connect. `offered` is the keys the
    /// Clock Source menu lists for the cards present.
    public static func decide(saved: SavedBoardClock?, controlNow: UInt32?,
                              offered: [UInt32]) -> Decision? {
        guard let saved else { return nil }
        guard let controlNow else { return .wait }
        if let control = saved.control, control != controlNow { return .forget }
        return offered.contains(saved.key) ? .send(saved.key) : .wait
    }

    public static func load(identity: UInt64, defaults: UserDefaults = .standard) -> SavedBoardClock? {
        guard let data = defaults.data(forKey: defaultsKey(identity: identity)) else { return nil }
        return try? JSONDecoder().decode(SavedBoardClock.self, from: data)
    }

    public static func store(_ value: SavedBoardClock?, identity: UInt64,
                             defaults: UserDefaults = .standard) {
        let key = defaultsKey(identity: identity)
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
