import Foundation

/// Editable routing for the older XLink converters (AD-16X, DA-16X, DD-16X,
/// Rosetta) on a ThunderBridge or Symphony 64 PCIe card.
///
/// The card's routing tables are the converters' only router, and Apogee's
/// Maestro let them be edited both ways (`SymphonyPCIeRoutingController.cpp`
/// :1280-1365 → `routeSymphonyHW`): any DAW playback channel or card mixer
/// output to any converter output channel, and any converter input channel to
/// any DAW input channel. "Reset" put both back on the default placement.
///
/// The driver (dext 131, `SymphonyCardMixerRouting.h`) takes three vendor
/// commands, built here:
/// * 0xB5 `[xlinkTX, tdmSlot, enable]`: converter output at bus position
///   `xlinkTX` (port × 32 + slot) ← TDM slot (DAW playback n = 64 + n, card
///   mixer m side s = 128 + 2m + s).
/// * 0xB6 `[hostInput, xlinkRx, enable]`: DAW input ← converter input at bus
///   position `xlinkRx`.
/// * 0xB7, no payload: both tables back on the default placement.
///
/// The default placement is `ConverterRules.hostMap`, the same table the
/// driver programs (`ApplyConverterRouting`): host output n plays to the unit
/// channel the map puts at host n (1-2 included, no mixer routed, as the
/// original's ResetRouting left it); host input n records the unit channel
/// the map puts at host n.
public enum ConverterRouting {
    public static let outputRouteCommand: UInt8 = 0xB5
    public static let inputRouteCommand: UInt8 = 0xB6
    public static let resetCommand: UInt8 = 0xB7

    /// TDM slot of host playback channel 0 (`kTDM_PCIOut0`).
    public static let pciOutBase = 64
    /// TDM slot of card mixer 0 left (`kTDM_Mixer0Out`).
    public static let mixerOutBase = 128
    /// The slot byte sent with a disabled output route. The driver writes it
    /// without the enable bit, so it is never heard.
    public static let disabledSlot: UInt8 = 0

    /// One vendor command for the driver.
    public struct Command: Sendable, Equatable, CustomStringConvertible {
        public let command: UInt8
        public let payload: [UInt8]

        public init(command: UInt8, payload: [UInt8]) {
            self.command = command
            self.payload = payload
        }

        public var description: String {
            "0x" + String(command, radix: 16, uppercase: true) + " " + payload.map(String.init).joined(separator: ",")
        }
    }

    /// 0xB5: converter output `bus` ← `source` (a TDM slot), or disabled when nil.
    public static func outputCommand(bus: Int, source: Int?) -> Command {
        Command(command: outputRouteCommand,
                payload: [UInt8(clamping: bus), source.map { UInt8(clamping: $0) } ?? disabledSlot,
                          source == nil ? 0 : 1])
    }

    /// 0xB6: DAW input `host` ← converter input `bus`, or nothing when nil.
    public static func inputCommand(host: Int, bus: Int?) -> Command {
        Command(command: inputRouteCommand,
                payload: [UInt8(clamping: host), UInt8(clamping: bus ?? 0), bus == nil ? 0 : 1])
    }

    /// 0xB7: Reset Routing.
    public static let resetRoutingCommand = Command(command: resetCommand, payload: [])

    /// TDM slot of DAW playback channel `host` (0-based).
    public static func playbackSource(host: Int) -> Int { pciOutBase + host }

    /// TDM slot of card mixer `mixer` (0 or 1), `side` 0 = left, 1 = right.
    /// The same slots the Symphony I/O output grid's Mixer rows reach
    /// (`ThunderboltCardRouting.slot(forSource:)`).
    public static func mixerSource(mixer: Int, side: Int) -> Int { mixerOutBase + 2 * mixer + side }
}

/// The converter channels on the bus, their names, and the default placement,
/// for the routing pages.
public struct ConverterRoutingLayout: Sendable, Equatable {
    /// One converter channel on the bus.
    public struct Channel: Sendable, Equatable {
        /// Bus position: port × 32 + slot (0-63), the driver's XLink entry.
        public let bus: Int
        /// "C Line 1", "A Out 1".
        public let name: String
        /// Index over all counted units (A = 0).
        public let unit: Int
        /// 0-based within the unit.
        public let element: Int

        public init(bus: Int, name: String, unit: Int, element: Int) {
            self.bus = bus; self.name = name; self.unit = unit; self.element = element
        }
    }

    /// Two neighbouring channels of one unit: one grid column.
    public struct Pair: Sendable, Equatable {
        public let left: Channel
        public let right: Channel?

        /// "C Line 1/2".
        public var name: String {
            CardLayout.stereoName(left: left.name, right: right?.name ?? CardLayout.notApplicable)
        }

        /// The grid header's two lines ("C Line", "1/2").
        public var header: (type: String, channels: String) { CardLayout.headerLines(name) }

        public var channels: [Channel] { [left] + (right.map { [$0] } ?? []) }
    }

    /// Converter output channels on the bus, unit by unit (port 1's, then
    /// port 2's while 64 channels run).
    public let outputs: [Channel]
    /// Converter input channels on the bus, unit by unit.
    public let inputs: [Channel]
    /// DAW channels each way: 32, or 64 while port 2 carries converters.
    public let hostChannels: Int
    /// Converter output bus position → its default source (TDM slot).
    public let defaultOutputSources: [Int: Int]
    /// DAW input (0-based) → its default converter input bus position.
    public let defaultInputSources: [Int: Int]

    public init(system: ConverterSystem) {
        let chain = system.chain
        hostChannels = system.hostCapacity
        func channels(input: Bool) -> [Channel] {
            let map = ConverterRules.hostMap(chain, input: input).map
            return map.indices.compactMap { host in
                guard let m = map[host] else { return nil }
                return Channel(bus: m.meterWord,
                               name: ConverterRules.hostChannelName(chain, map: map, input: input, host: host),
                               unit: m.unit, element: m.element)
            }
        }
        outputs = channels(input: false)
        inputs = channels(input: true)
        var outDefaults: [Int: Int] = [:]
        var inDefaults: [Int: Int] = [:]
        let outMap = ConverterRules.hostMap(chain, input: false).map
        let inMap = ConverterRules.hostMap(chain, input: true).map
        for host in 0..<min(hostChannels, ConverterRules.maxHostChannels) {
            // Every DAW output straight to its converter output, 1-2 included:
            // the original's ResetRouting cleared both mixers, so no mixer is
            // routed until the user routes one.
            if let m = outMap[host] { outDefaults[m.meterWord] = ConverterRouting.playbackSource(host: host) }
            if let m = inMap[host] { inDefaults[host] = m.meterWord }
        }
        defaultOutputSources = outDefaults
        defaultInputSources = inDefaults
    }

    /// Output channels two by two within each unit.
    public var outputPairs: [Pair] { Self.pairs(outputs) }
    /// Input channels two by two within each unit.
    public var inputPairs: [Pair] { Self.pairs(inputs) }

    static func pairs(_ channels: [Channel]) -> [Pair] {
        var result: [Pair] = []
        var i = 0
        while i < channels.count {
            let left = channels[i]
            if i + 1 < channels.count, channels[i + 1].unit == left.unit {
                result.append(Pair(left: left, right: channels[i + 1]))
                i += 2
            } else {
                result.append(Pair(left: left, right: nil))
                i += 1
            }
        }
        return result
    }

    /// DAW playback pairs (rows before the two mixer rows).
    public var playbackPairCount: Int { hostChannels / 2 }
    /// DAW input pairs (input grid rows).
    public var inputPairCount: Int { hostChannels / 2 }

    /// The left TDM slot an output-grid row stands for: DAW playback pair
    /// rows, then Mixer 1 and Mixer 2. Nil past the last row.
    public func outputRowSource(row: Int) -> Int? {
        if row >= 0 && row < playbackPairCount { return ConverterRouting.playbackSource(host: row * 2) }
        if row == playbackPairCount { return ConverterRouting.mixerSource(mixer: 0, side: 0) }
        if row == playbackPairCount + 1 { return ConverterRouting.mixerSource(mixer: 1, side: 0) }
        return nil
    }

    /// The output-grid row a source slot belongs to.
    public func outputRow(forSource source: Int) -> Int? {
        let playback = source - ConverterRouting.pciOutBase
        if playback >= 0 && playback < hostChannels { return playback / 2 }
        let mixer = source - ConverterRouting.mixerOutBase
        if mixer >= 0 && mixer < 4 { return playbackPairCount + mixer / 2 }
        return nil
    }

    /// Every output channel's source in effect: the default with `edits`
    /// on top. A missing key means disabled.
    public func outputSources(_ edits: ConverterRoutingEdits) -> [Int: Int] {
        var sources = defaultOutputSources
        for (bus, source) in edits.outputs where outputs.contains(where: { $0.bus == bus }) {
            if source < 0 { sources.removeValue(forKey: bus) } else { sources[bus] = source }
        }
        return sources
    }

    /// Every DAW input's converter input in effect. A missing key means none.
    public func inputSources(_ edits: ConverterRoutingEdits) -> [Int: Int] {
        var sources = defaultInputSources
        for (host, bus) in edits.inputs where host >= 0 && host < hostChannels {
            if bus < 0 { sources.removeValue(forKey: host) } else { sources[host] = bus }
        }
        return sources
    }

    /// Whether the output-grid cell is on: the column's left channel plays
    /// the row's left source.
    public func outputCellActive(row: Int, column: Int, sources: [Int: Int]) -> Bool {
        let pairs = outputPairs
        guard column >= 0, column < pairs.count, let source = outputRowSource(row: row) else { return false }
        return sources[pairs[column].left.bus] == source
    }

    /// The input-grid column a DAW input pair records from, by its left input.
    public func inputColumn(row: Int, sources: [Int: Int]) -> Int? {
        guard let bus = sources[row * 2] else { return nil }
        return inputPairs.firstIndex { $0.left.bus == bus }
    }

    /// The input grid's row names: the converter pair each DAW input pair
    /// records from, "N.A." when none.
    public func inputRowNames(sources: [Int: Int]) -> [String] {
        let pairs = inputPairs
        return (0..<inputPairCount).map { row in
            inputColumn(row: row, sources: sources).map { pairs[$0].name } ?? CardLayout.notApplicable
        }
    }

    /// The output grid's DAW row names: the converter channels the default
    /// placement plays each DAW pair to, as the driver names them in Core Audio.
    public func playbackRowNames(system: ConverterSystem) -> [String] {
        let names = system.hostChannelNames(input: false)
        return (0..<playbackPairCount).map { pair in
            let l = pair * 2 < names.count ? names[pair * 2] : CardLayout.notApplicable
            let r = pair * 2 + 1 < names.count ? names[pair * 2 + 1] : CardLayout.notApplicable
            return CardLayout.stereoName(left: l, right: r)
        }
    }

    // MARK: Clicks

    /// Output-grid click: the cell's pair plays the row's source, or (when it
    /// already does) goes silent. Returns the new edits and the commands.
    public func toggleOutput(row: Int, column: Int, edits: ConverterRoutingEdits)
        -> (edits: ConverterRoutingEdits, commands: [ConverterRouting.Command])? {
        let pairs = outputPairs
        guard column >= 0, column < pairs.count, let source = outputRowSource(row: row) else { return nil }
        let clearing = outputCellActive(row: row, column: column, sources: outputSources(edits))
        var edits = edits
        var commands: [ConverterRouting.Command] = []
        for (side, channel) in pairs[column].channels.enumerated() {
            let value: Int? = clearing ? nil : source + side
            edits.setOutput(bus: channel.bus, source: value, default: defaultOutputSources[channel.bus])
            commands.append(ConverterRouting.outputCommand(bus: channel.bus, source: value))
        }
        return (edits, commands)
    }

    /// Input-grid click: the DAW input pair records the column's pair, or
    /// (when it already does) nothing.
    public func toggleInput(row: Int, column: Int, edits: ConverterRoutingEdits)
        -> (edits: ConverterRoutingEdits, commands: [ConverterRouting.Command])? {
        let pairs = inputPairs
        guard row >= 0, row < inputPairCount, column >= 0, column < pairs.count else { return nil }
        let clearing = inputColumn(row: row, sources: inputSources(edits)) == column
        var edits = edits
        var commands: [ConverterRouting.Command] = []
        let channels = pairs[column].channels
        for side in 0..<2 {
            let host = row * 2 + side
            let bus: Int? = clearing || side >= channels.count ? nil : channels[side].bus
            edits.setInput(host: host, bus: bus, default: defaultInputSources[host])
            commands.append(ConverterRouting.inputCommand(host: host, bus: bus))
        }
        return (edits, commands)
    }

    // MARK: Replay

    /// The commands that put `edits` on the driver after a connect: one per
    /// edited entry, on top of the default the driver has programmed.
    public func replayCommands(_ edits: ConverterRoutingEdits) -> [ConverterRouting.Command] {
        var commands: [ConverterRouting.Command] = []
        let outBuses = Set(outputs.map(\.bus))
        for (bus, source) in edits.outputs.sorted(by: { $0.key < $1.key }) where outBuses.contains(bus) {
            commands.append(ConverterRouting.outputCommand(bus: bus, source: source < 0 ? nil : source))
        }
        for (host, bus) in edits.inputs.sorted(by: { $0.key < $1.key }) where host >= 0 && host < hostChannels {
            commands.append(ConverterRouting.inputCommand(host: host, bus: bus < 0 ? nil : bus))
        }
        return commands
    }

    /// Every output channel written explicitly (a preset load).
    public func fullOutputCommands(_ edits: ConverterRoutingEdits) -> [ConverterRouting.Command] {
        let sources = outputSources(edits)
        return outputs.map { ConverterRouting.outputCommand(bus: $0.bus, source: sources[$0.bus]) }
    }

    /// Every DAW input written explicitly (a preset load).
    public func fullInputCommands(_ edits: ConverterRoutingEdits) -> [ConverterRouting.Command] {
        let sources = inputSources(edits)
        return (0..<hostChannels).map { ConverterRouting.inputCommand(host: $0, bus: sources[$0]) }
    }
}

/// The user's converter routes: only where they differ from the default
/// placement. -1 means "nothing" (output silent, DAW input empty).
public struct ConverterRoutingEdits: Sendable, Equatable, Codable {
    /// Converter output bus position → source TDM slot (or -1).
    public var outputs: [Int: Int]
    /// DAW input (0-based) → converter input bus position (or -1).
    public var inputs: [Int: Int]

    public init(outputs: [Int: Int] = [:], inputs: [Int: Int] = [:]) {
        self.outputs = outputs
        self.inputs = inputs
    }

    public var isEmpty: Bool { outputs.isEmpty && inputs.isEmpty }

    /// These edits with each entry a refused command named put back to
    /// `previous`, where it still holds what `attempted` set (a newer change
    /// to the same entry stays). A refused Reset Routing puts everything back
    /// unless something changed since.
    public func reverting(_ refused: [ConverterRouting.Command], attempted: ConverterRoutingEdits,
                          previous: ConverterRoutingEdits) -> ConverterRoutingEdits {
        var result = self
        for command in refused {
            if command.command == ConverterRouting.resetCommand {
                if self == attempted { return previous }
                continue
            }
            guard let key = command.payload.first.map(Int.init) else { continue }
            if command.command == ConverterRouting.outputRouteCommand {
                if result.outputs[key] == attempted.outputs[key] { result.outputs[key] = previous.outputs[key] }
            } else if command.command == ConverterRouting.inputRouteCommand {
                if result.inputs[key] == attempted.inputs[key] { result.inputs[key] = previous.inputs[key] }
            }
        }
        return result
    }

    mutating func setOutput(bus: Int, source: Int?, default fallback: Int?) {
        if source == fallback { outputs.removeValue(forKey: bus) } else { outputs[bus] = source ?? -1 }
    }

    mutating func setInput(host: Int, bus: Int?, default fallback: Int?) {
        if bus == fallback { inputs.removeValue(forKey: host) } else { inputs[host] = bus ?? -1 }
    }
}

/// Where the converter routes are kept: per chain of units, so a different
/// chain (other units, other order, another Device Type, 32 or 64 channels)
/// never inherits routes made for this one. The driver drops its copy when
/// the chain changes too.
public struct ConverterRoutingStore {
    public let signature: String
    private let defaults: UserDefaults

    public init(signature: String, defaults: UserDefaults = .standard) {
        self.signature = signature
        self.defaults = defaults
    }

    public var key: String { "converterRouting." + signature }
    public var outputPresetsKey: String { "converterOutputRoutingPresets." + signature }
    public var inputPresetsKey: String { "converterInputRoutingPresets." + signature }

    public func load() -> ConverterRoutingEdits {
        guard let data = defaults.data(forKey: key),
              let edits = try? JSONDecoder().decode(ConverterRoutingEdits.self, from: data) else {
            return ConverterRoutingEdits()
        }
        return edits
    }

    public func save(_ edits: ConverterRoutingEdits) {
        if edits.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(edits) {
            defaults.set(data, forKey: key)
        }
    }

    // Presets: one direction each, as the pages save them; named per chain.

    public func presets(input: Bool) -> [String: [Int: Int]] {
        guard let data = defaults.data(forKey: input ? inputPresetsKey : outputPresetsKey),
              let presets = try? JSONDecoder().decode([String: [Int: Int]].self, from: data) else { return [:] }
        return presets
    }

    public func presetNames(input: Bool) -> [String] { presets(input: input).keys.sorted() }

    public func savePreset(name: String, input: Bool, routes: [Int: Int]) {
        var all = presets(input: input)
        all[name] = routes
        writePresets(all, input: input)
    }

    public func deletePreset(name: String, input: Bool) {
        var all = presets(input: input)
        all.removeValue(forKey: name)
        writePresets(all, input: input)
    }

    private func writePresets(_ presets: [String: [Int: Int]], input: Bool) {
        let key = input ? inputPresetsKey : outputPresetsKey
        if presets.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: key) }
    }
}

extension ConverterSystem {
    /// The chain the converter routes belong to: port, address, routing byte
    /// (and DA use of a 0x0F unit) of every unit carrying audio, e.g.
    /// `p1u1r03-p1u2r0c`. Port 2's units count only while 64 channels run.
    public var routingSignature: String {
        countedUnits.map { unit in
            let hex = String(unit.routing, radix: 16)
            return "p\(unit.port + 1)u\(unit.address)r\(hex.count < 2 ? "0" + hex : hex)"
                + (unit.kind == .ddAsDA ? "da" : "")
        }.joined(separator: "-")
    }
}
