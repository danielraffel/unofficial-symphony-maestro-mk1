import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


// MARK: - Preset Library (P3F-32)

/// Manages the user presets directory and surfaces a list of saved .mst2 files.
///
/// Presets are stored at:
///   ~/Library/Application Support/Maestro/Presets/
///
/// Evidence: og_source/maestro2/App/APDocument.m — user preset folder pattern;
///           og_source/maestro2/App/APPresetManagerWindowController.m — preset list UI
@MainActor
@Observable
final class PresetLibrary {
    static let shared = PresetLibrary()

    private(set) var names: [String] = []

    private var directory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Maestro/Presets", isDirectory: true)
    }

    private init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        names = items
            .filter { $0.pathExtension == "mst2" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted(by: { $0.localizedCompare($1) == .orderedAscending })
    }

    func url(for name: String) -> URL {
        directory.appendingPathComponent("\(name).mst2")
    }

    func save(preset: MaestroPreset, named name: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try preset.save(to: url(for: name))
        refresh()
    }

    func delete(named name: String) throws {
        try FileManager.default.removeItem(at: url(for: name))
        refresh()
    }

    func openInFinder() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}

// MARK: - Routing State Cache

/// Persists routing state to UserDefaults so tab navigation doesn't lose user changes.
///
/// Keyed by direction ("input"/"output") and USB product ID so each card model stores
/// its routing independently. Supports future multi-device scenarios (Symphony IO MKI
/// 16ch, 8ch, 32ch, Ensemble, etc.) with zero code changes — each gets its own key.
///
/// ## What this may and may not hold
///
/// **Only crosspoints a person actually chose.** Never a grid the app derived for
/// display. Neither transport can read the input crosspoint back — the USB mapper
/// has no read opcode for `.routing` and the dext has no read dispatch for it — so
/// the grid on screen is usually `SymphonyIODefaultRouting`'s table, which is a
/// reasonable guess and not a measurement. Persisting a guess makes it
/// indistinguishable from a choice on the next launch, and since the cache outranks
/// the derived default, a wrong guess then sticks forever with nothing able to
/// correct it.
///
/// That is not hypothetical: builds before `v2` stored the whole displayed grid.
/// When the card layout had not been read yet the old fallback
/// (`min(i, columns.count - 1)`, `columns.count == 1`) collapsed every row onto
/// column 0, and the first tap afterwards saved all eight rows pointing at
/// Line 1/2. That entry then survived every relaunch and every card change, and is
/// why USB input routing drew a single stacked column while Thunderbolt — same
/// hardware, same table, no stale entry — drew the correct diagonal.
///
/// Hence the `_v2` suffix: it abandons every pre-existing entry exactly once
/// rather than trying to tell a poisoned grid from a deliberate one, which cannot
/// be done after the fact.
///
/// Pattern:
///   1. Save on a user action (tap, preset load) — and only the rows they touched
///   2. In view .task: derive the default grid, then overlay these saved edits
///   3. A hardware read, where one ever becomes possible, outranks both
struct RoutingStateCache {
    let key: String

    /// - Parameters:
    ///   - direction: "input" or "output" — stored separately for independent state.
    ///   - productID: USB product ID differentiates card models
    ///     (e.g. 0x0010 = Symphony IO MKI 16-ch, 0x0011 = 8-ch, 0x0012 = 32-ch).
    init(direction: String, productID: UInt16) {
        self.key = "routing_\(direction)_\(productID)_v2"
        Self.discardPreV2(direction: direction, productID: productID)
    }

    /// Drop the unversioned entries once. See the note above: a `v1` entry could be
    /// a derived guess promoted to truth, and nothing distinguishes it from a real
    /// choice, so none of them are worth keeping.
    private static func discardPreV2(direction: String, productID: UInt16) {
        let stale = "routing_\(direction)_\(productID)"
        for key in [stale, stale + "_multi"]
        where UserDefaults.standard.object(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Persist the current routing state optimistically.
    /// Call immediately on user action so tab navigation restores the intended state
    /// even if hardware writes haven't completed yet.
    /// Supports both single-route [Int: Int] (input) and multi-route [Int: Set<Int>] (output).
    func save(_ routes: [Int: Int]) {
        let dict = Dictionary(uniqueKeysWithValues: routes.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(dict, forKey: key)
    }

    func save(_ routes: [Int: Set<Int>]) {
        // Serialize as [String: [Int]] — each row maps to array of column indices
        let dict = Dictionary(uniqueKeysWithValues: routes.map { (String($0.key), Array($0.value.sorted())) })
        UserDefaults.standard.set(dict, forKey: key + "_multi")
    }

    /// Load the last persisted routing state (single-route, for input routing).
    /// Returns nil if no state exists for this device/direction yet.
    func load() -> [Int: Int]? {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Int],
              !raw.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v -> (Int, Int)? in
            guard let i = Int(k) else { return nil }
            return (i, v)
        })
    }

    /// Load the last persisted routing state (multi-route, for output dual routing).
    /// Falls back to single-route cache and converts to Set if multi cache is empty.
    func loadMulti() -> [Int: Set<Int>]? {
        // Try multi-route cache first
        if let raw = UserDefaults.standard.dictionary(forKey: key + "_multi") as? [String: [Int]],
           !raw.isEmpty {
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v -> (Int, Set<Int>)? in
                guard let i = Int(k) else { return nil }
                return (i, Set(v))
            })
        }
        // Fall back to legacy single-route cache and convert
        if let single = load() {
            return Dictionary(uniqueKeysWithValues: single.map { ($0.key, Set([$0.value])) })
        }
        return nil
    }
}

// MARK: - Routing & Mixer Presets (P3C-05, P3C-06)

/// Simple preset system for routing configurations and mixer states.
/// Stores presets in UserDefaults as JSON.
///
/// Evidence: `og_source/maestro2/App/Controllers/APPresetManager.h`
enum PresetManager {
    /// Save a routing preset (input or output routes).
    static func saveRoutingPreset(name: String, routes: [Int: Int], key: String) {
        var presets = loadRoutingPresets(key: key)
        presets[name] = routes
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Load all routing presets for a given key.
    static func loadRoutingPresets(key: String) -> [String: [Int: Int]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let presets = try? JSONDecoder().decode([String: [Int: Int]].self, from: data) else {
            return [:]
        }
        return presets
    }

    /// Delete a routing preset.
    static func deleteRoutingPreset(name: String, key: String) {
        var presets = loadRoutingPresets(key: key)
        presets.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Also clean multi-route version
        var multi = loadMultiRoutingPresets(key: key)
        multi.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(multi) {
            UserDefaults.standard.set(data, forKey: key + "_multi")
        }
    }

    /// Save a multi-route routing preset (output dual routing).
    static func saveMultiRoutingPreset(name: String, routes: [Int: Set<Int>], key: String) {
        // Serialize Set<Int> as sorted [Int] for JSON compatibility
        var presets = loadMultiRoutingPresets(key: key)
        let arrayRoutes = Dictionary(uniqueKeysWithValues: routes.map { ($0.key, Array($0.value.sorted())) })
        presets[name] = arrayRoutes
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key + "_multi")
        }
    }

    /// Load all multi-route routing presets for a given key.
    static func loadMultiRoutingPresets(key: String) -> [String: [Int: [Int]]] {
        guard let data = UserDefaults.standard.data(forKey: key + "_multi"),
              let presets = try? JSONDecoder().decode([String: [Int: [Int]]].self, from: data) else {
            return [:]
        }
        return presets
    }

    /// Load multi-route presets converted to Set<Int> form.
    static func loadMultiRoutingPresetsAsSet(key: String) -> [String: [Int: Set<Int>]] {
        let raw = loadMultiRoutingPresets(key: key)
        return Dictionary(uniqueKeysWithValues: raw.map { name, routes in
            (name, Dictionary(uniqueKeysWithValues: routes.map { ($0.key, Set($0.value)) }))
        })
    }

    /// Save a mixer preset.
    static func saveMixerPreset(name: String, channels: [MixerChannelPreset], masterLevel: Double) {
        var presets = loadMixerPresets()
        presets[name] = MixerPreset(channels: channels, masterLevel: masterLevel)
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "mixerPresets")
        }
    }

    /// Load all mixer presets.
    static func loadMixerPresets() -> [String: MixerPreset] {
        guard let data = UserDefaults.standard.data(forKey: "mixerPresets"),
              let presets = try? JSONDecoder().decode([String: MixerPreset].self, from: data) else {
            return [:]
        }
        return presets
    }

    /// Delete a mixer preset.
    static func deleteMixerPreset(name: String) {
        var presets = loadMixerPresets()
        presets.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "mixerPresets")
        }
    }
}

/// Serializable mixer channel state for presets.
struct MixerChannelPreset: Codable, Sendable {
    var level: Double
    var pan: Double
    var isMuted: Bool
    var isSoloed: Bool
}

/// Serializable mixer preset.
struct MixerPreset: Codable, Sendable {
    var channels: [MixerChannelPreset]
    var masterLevel: Double
}
