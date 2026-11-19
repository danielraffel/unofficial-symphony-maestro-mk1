import Foundation
import MaestroCore

public protocol MicPreReplayConnection: DeviceConnection {
    func replayMicPreSettings(_ writes: [ThunderboltPreset.Write], layout: CardLayout) async throws
}

public enum MicPreSettingsReplay {
    /// Original per-channel order, including all eight insert masks when enabled.
    /// Evidence: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:2259-2298,1790-1808.
    public static func writes(inputs: [InputChannelState], layout: CardLayout,
                              identity: UInt64?, includeLineChannels: Bool = true, restoresLineType: Bool = true) -> [ThunderboltPreset.Write] {
        guard AnalogChannelSettingsReplay.replays(layout: layout), layout.slot2 == .micPre8 else { return [] }
        var writes: [ThunderboltPreset.Write] = []
        for (index, state) in inputs.prefix(8).enumerated() {
            guard let level = AnalogInputLevel(rawValue: state.inputType),
                  includeLineChannels || level.isPreampLevel else { continue }
            func put(_ selector: AudioPropertySelector, _ value: PropertyValue,
                     scope: PropertyScope = .global, element: Int? = nil) {
                writes.append(.property(PropertyAddress(selector: selector, scope: scope,
                                                        element: UInt32(element ?? index)), value))
            }
            if !level.isPreampLevel && restoresLineType { put(.phantom, .bool(false)) }
            if level.isPreampLevel || restoresLineType {
                put(.analogIOType, .uint32(InputChannelLogic.analogIOTypeWithTrim(level: level, trim: state.trim)), scope: .input)
            }
            put(.insertReturnEnable, .bool(level.isPreampLevel && state.insertReturn))
            if level.isPreampLevel && state.insertReturn {
                for (insert, mask) in InputChannelLogic.insertAssignmentMasks(in: Array(inputs.prefix(8))) {
                    put(.insertID, .uint32(UInt32(mask)), element: insert)
                }
            }
            func gain(_ value: Double, maximum: Double) -> UInt32 {
                value.isFinite ? UInt32(min(max(value.rounded(), 0), maximum)) : 0
            }
            put(.micGain, .uint32(gain(state.micGain, maximum: 85)))
            put(.instrumentGain, .uint32(gain(state.instrumentGain, maximum: 65)))
            put(.groupID, .uint32(min(state.group, 8)))
            put(.phaseReverse, .bool(state.phase))
            put(.phantom, .bool(state.restoresPhantom(identity: identity, boardSlot: 1, channel: index)))
            put(.highPassFilter, .bool(state.hpf))
        }
        return writes
    }

    /// Production transports use their existing serial transaction owners.
    /// The fallback is for simulated/test connections only, never a live HAL.
    public static func apply(_ writes: [ThunderboltPreset.Write], layout: CardLayout,
                             device: any DeviceConnection) async throws {
        guard !writes.isEmpty else { return }
        guard AnalogChannelSettingsReplay.replays(layout: layout) else {
            throw DeviceConnectionError.notConnected
        }
        if let connection = device as? ThunderboltDeviceConnection {
            try await Task.detached(priority: .utility) {
                try connection.applyPresetWrites(writes, layout: layout)
            }.value
        } else if let connection = device as? ThunderboltUnitBConnection {
            try await Task.detached(priority: .utility) {
                try connection.applyPresetWrites(writes, layout: layout) { _, _ in
                    throw DeviceConnectionError.notConnected
                }
            }.value
        } else if let connection = device as? XPCDeviceConnection {
            try await connection.applyMicPreWrites(writes)
        } else if let connection = device as? any MicPreReplayConnection {
            try await connection.replayMicPreSettings(writes, layout: layout)
        } else {
            throw DeviceConnectionError.notConnected
        }
    }

    /// On a partial recall, clear every involved preamp channel, including one
    /// whose ON succeeded before a later failure. Cleanup precedes unlock.
    public static func phantomOffWrites(_ writes: [ThunderboltPreset.Write]) -> [ThunderboltPreset.Write] {
        var channels = Set<UInt32>()
        return writes.compactMap { write in
            guard case .property(let address, _) = write, address.selector == .phantom,
                  channels.insert(address.element).inserted else { return nil }
            return .property(address, .bool(false))
        }
    }
}

extension SimulatedDevice: MicPreReplayConnection {
    public func replayMicPreSettings(_ writes: [ThunderboltPreset.Write], layout: CardLayout) async throws {
        for write in writes {
            if case .property(let address, let value) = write { try await setProperty(address, value: value) }
        }
    }
}
