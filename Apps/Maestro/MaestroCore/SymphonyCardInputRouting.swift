import Foundation

/// Host destinations and card RX sources are independent. No peripheral port
/// byte belongs in these commands. Evidence: og_source/maestrolink/Software/
/// SymphonyPCIeRoutingController.cpp:976-1069,1860-1888.
public struct SymphonyCardInputRouting: Sendable {
    public let model: SymphonyRoutingModel

    public init(model: SymphonyRoutingModel) { self.model = model }

    /// Build 132 first accepts Symphony I/O card input commands (0xB6/0xB7).
    /// Unknown/older serving drivers retain the per-unit routing surface only.
    public init(model: SymphonyRoutingModel, servingBuild: ServingDextBuild?) {
        if case .build(let build) = servingBuild, build >= 132 {
            self.model = model
        } else {
            self.model = SymphonyRoutingModel(topology: .unknown, hostChannels: model.hostChannels,
                                             unitBConfigured: model.unitBConfigured)
        }
    }

    /// B1b's Symphony rules: even a 64-channel personality exposes only 32
    /// routes until B is configured. Mixed/converter routing has its own owner.
    public var channelCount: Int {
        guard case .symphonyOnly = model.topology,
              model.allows(.cardInput, at: .card) else { return 0 }
        return model.hostChannels == 64 && model.unitBConfigured ? 64 : 32
    }

    public func command(host: Int, source: Int?) -> ConverterRouting.Command? {
        guard (0..<channelCount).contains(host),
              source == nil || (0..<channelCount).contains(source!) else { return nil }
        return ConverterRouting.inputCommand(host: host, bus: source)
    }

    public var resetCommand: ConverterRouting.Command? {
        channelCount > 0 && model.allows(.cardReset, at: .card) ? ConverterRouting.resetRoutingCommand : nil
    }

    /// Sparse overrides; -1 is explicitly disconnected, absence is straight
    /// through. Reject malformed/unavailable routes rather than clamping bytes.
    public func commands(edits: [Int: Int]) -> [ConverterRouting.Command] {
        edits.sorted { $0.key < $1.key }.compactMap { host, source in
            guard source >= -1 else { return nil }
            return command(host: host, source: source == -1 ? nil : source)
        }
    }

    /// Only acknowledged routes may enter persistence. A refused reset keeps
    /// all choices; a partial pair keeps only the side that reached hardware.
    public static func applying(_ accepted: [ConverterRouting.Command], to previous: [Int: Int]) -> [Int: Int] {
        var result = previous
        for command in accepted {
            if command == ConverterRouting.resetRoutingCommand { result = [:] }
            else if command.command == ConverterRouting.inputRouteCommand, command.payload.count == 3 {
                result[Int(command.payload[0])] = command.payload[2] == 0 ? -1 : Int(command.payload[1])
            }
        }
        return result
    }

    public func source(host: Int, edits: [Int: Int]) -> Int? {
        let source = edits[host] ?? host
        guard command(host: host, source: source) != nil else { return nil }
        return source
    }
}

/// Separate from both per-unit P2P tables and converter routes. Scope includes
/// the known card layouts and active channel count; simulations are isolated.
public struct SymphonyCardInputStore {
    public let key: String
    private let defaults: UserDefaults

    public init(scope: String, defaults: UserDefaults = .standard) {
        key = "symphonyCardInputs." + scope
        self.defaults = defaults
    }

    public func load() -> [Int: Int] {
        guard let data = defaults.data(forKey: key),
              let routes = try? JSONDecoder().decode([Int: Int].self, from: data) else { return [:] }
        return routes
    }

    public func save(_ routes: [Int: Int]) {
        if routes.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(routes) { defaults.set(data, forKey: key) }
    }
}

/// Selectors 12 (monitor), 13 (Loop Sync), and 14 (observed gain) arrived
/// together with card-input routing in serving dext build 132.
public enum SymphonyExtendedSelectors {
    public static func supported(by servingBuild: ServingDextBuild?) -> Bool {
        guard case .build(let build) = servingBuild else { return false }
        return build >= 132
    }
}
