import Foundation
import MaestroCore

/// Symphony I/O card and per-unit recall. The host owns write-only channel and mixer
/// settings, as in og_source/maestrolink/Software/SymphonyIO.cpp:1395-1412.
/// This is deliberately separate from the legacy daemon's plist format.
public struct ThunderboltPreset: Codable, Sendable, Equatable {
    public static let fileName = "ThunderBridge.plist"
    public var version = 1
    public var boards: [UInt8]
    public var metadata: MaestroPreset
    public var globals: [UInt32: UInt32] = [:]
    public var inputRoutes: [UInt8] = []
    /// Optional for older B4a bundles: absence leaves card inputs alone.
    public var cardInputRoutes: [Int]?
    public var outputRoutes: [UInt8] = []
    public var mixers: [Mixer] = []
    public var routingMode: Int = 1
    public var frontPanelSelection: UInt8?
    public var unitID: Data?
    /// Version 2 adds the second peripheral; absent in single-unit bundles.
    public var unitB: Peripheral?

    public struct Peripheral: Codable, Sendable, Equatable {
        public var boards: [UInt8]
        public var metadata: MaestroPreset
        public var globals: [UInt32: UInt32]
        public var inputRoutes: [UInt8]
        public var frontPanelSelection: UInt8?
        public var unitID: Data?
        public var mixers: [Mixer]
        public var routingMode: Int

        public init(_ preset: ThunderboltPreset) {
            boards = preset.boards; metadata = preset.metadata; globals = preset.globals
            inputRoutes = preset.inputRoutes; frontPanelSelection = preset.frontPanelSelection
            unitID = preset.unitID; mixers = preset.mixers; routingMode = preset.routingMode
        }

        public func preset(layout: CardLayout) -> ThunderboltPreset {
            var value = ThunderboltPreset(layout: layout, metadata: metadata)
            value.boards = boards; value.globals = globals; value.inputRoutes = inputRoutes
            value.frontPanelSelection = frontPanelSelection; value.unitID = unitID
            value.mixers = mixers; value.routingMode = routingMode
            value.outputRoutes = Array(0..<32)
            return value
        }
    }

    /// Original card layer identity-extends when a second port appears.
    /// og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:1817-1860.
    public static func cardTable(_ saved: [Int], channels: Int) throws -> [Int] {
        guard [32, 64].contains(saved.count), [32, 64].contains(channels) else {
            throw RecallError.unsupported("incomplete card table.")
        }
        return (0..<channels).map { $0 < saved.count ? saved[$0] : $0 }
    }

    public func unitBSkipReason(layout: CardLayout?, configured: Bool) -> String? {
        guard let unitB else { return nil }
        guard configured, let layout, layout.isKnown else { return "Unit B skipped: not configured at 64 channels." }
        guard unitB.boards == [layout.slot1.rawValue, layout.slot2.rawValue] else {
            return "Unit B skipped: the installed cards differ from the saved cards."
        }
        return nil
    }

    public struct Mixer: Codable, Sendable, Equatable {
        public var channels: [MixerChannelState]
        public var softwareReturn: MixerChannelState
        public var source: UInt32
        public var master: Double

        public init(snapshot: MixerStateSnapshot) {
            channels = snapshot.channels
            softwareReturn = snapshot.swReturnChannel
            source = snapshot.softwareReturnSource
            master = snapshot.masterLevel
        }
    }

    public init(layout: CardLayout, metadata: MaestroPreset) {
        boards = [layout.slot1.rawValue, layout.slot2.rawValue]
        self.metadata = metadata
    }

    public enum RecallError: LocalizedError {
        case unsupported(String)
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported(let why): return "Cannot recall this preset: \(why)"
            case .failed(let why): return "Preset recall failed: \(why)"
            }
        }
    }

    public static let monitorOrder: [AudioPropertySelector] = [
        .speakerOutputMode, .outputLevel, .outputMute, .outputDim, .outputSumToMono, .activeSpeakerSet,
        .headphone1Level, .headphone1Mute, .headphone1Dim, .headphone1SumToMono,
        .headphone2Level, .headphone2Mute, .headphone2Dim, .headphone2SumToMono,
    ]
    public static let booleanSelectors: Set<AudioPropertySelector> = [
        .outputMute, .outputDim, .outputSumToMono,
        .headphone1Mute, .headphone1Dim, .headphone1SumToMono,
        .headphone2Mute, .headphone2Dim, .headphone2SumToMono,
    ]

    public enum Write: Sendable, Equatable {
        case property(PropertyAddress, PropertyValue)
        case output(ThunderboltCardRouting.Route)
        case cardInput(ConverterRouting.Command)
        case frontPanel(UInt8)

        public var isCardRoute: Bool {
            switch self { case .cardInput, .output: return true; default: return false }
        }
    }

    /// Validate everything before the first write, including data that the wire
    /// mapper would otherwise truncate. Old app-only presets have no routes,
    /// mixer, or extra monitor fields; absence means leave that setting alone.
    public func writes(layout: CardLayout, legacy: Bool = false, currentUnitID: Data? = nil, hostChannels: Int = 32, peripheralB: Bool = false,
                       cardInputSupported: Bool = true, onSkipped: ((String) -> Void)? = nil) throws -> [Write] {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw RecallError.unsupported(reason) }
        }
        try require([1, 2].contains(version) && metadata.version == 1 && (version == 2 || unitB == nil), "unknown format version.")
        try require(version == 2 || (outputRoutes.count <= 32 && (cardInputRoutes?.count ?? 0) <= 32),
                    "two-port card tables require format version 2.")
        try require(layout.isKnown && layout.converter == nil && layout.converterLayout == nil,
                    "the Symphony I/O card layout is not known.")
        try require(boards == [layout.slot1.rawValue, layout.slot2.rawValue], "the installed cards differ from the saved cards.")
        let inputs = metadata.inputChannelStates
        let outputs = metadata.outputChannelStates
        try require(inputs.count == layout.analogInputStripCount || (legacy && inputs.isEmpty), "input channel count differs.")
        try require(outputs.count == layout.analogOutputStripCount || (legacy && outputs.isEmpty), "output channel count differs.")
        try require((inputRoutes.count == 32 && [32, 64].contains(outputRoutes.count) && mixers.count == 2)
                    || (legacy && inputRoutes.isEmpty && outputRoutes.isEmpty && mixers.isEmpty), "incomplete routing or mixer state.")
        try require(routingMode == 0 || routingMode == 1, "unsupported mixer routing mode.")
        try require([32, 64].contains(hostChannels), "unsupported channel count.")
        let allowedGlobals = Set((Self.monitorOrder + (peripheralB ? [] : [.clockSource]) + [.headphone1RoutingID, .headphone2RoutingID]).map(\.rawValue))
        try require(Set(globals.keys).isSubset(of: allowedGlobals), "unknown device settings.")
        // A save may contain the readable subset when one vendor read was
        // unavailable. Missing fields are intentionally left unchanged on
        // recall (the write loop already skips absent globals).
        if let selection = frontPanelSelection { try require(selection <= (layout.slot2 == .micPre8 ? 10 : 2), "invalid front panel selection.") }
        for (selector, value) in globals {
            let s = AudioPropertySelector(rawValue: selector)
            if Self.booleanSelectors.contains(s) { try require(value <= 1, "invalid monitor switch.") }
            else if [.outputLevel, .headphone1Level, .headphone2Level].contains(s) { try require(value <= 64, "invalid monitor level.") }
            else if s == .speakerOutputMode { try require(value <= 255 && SymphonyIOSpeakerMode(rawValue: UInt8(value)) != nil, "invalid speaker mode.") }
            else if s == .activeSpeakerSet { try require(value <= 7, "invalid speaker set.") }
            else if s == .clockSource { try require(ClockSourceMenu.decode(value) != nil, "invalid clock source.") }
            else { try require(value <= 15, "invalid headphone source.") }
        }
        for (index, state) in inputs.enumerated() {
            try require(AnalogInputLevel(rawValue: state.inputType) != nil && state.trim.isFinite && (state.inputType == AnalogInputLevel.variable.rawValue ? (0...25).contains(state.trim) : abs(state.trim) <= 2)
                        && state.digitalRefLevel <= 5 && state.softLimit <= 4, "invalid input settings.")
            try require(state.micGain.isFinite && (0...85).contains(state.micGain)
                        && state.instrumentGain.isFinite && (0...65).contains(state.instrumentGain)
                        && state.group <= 8 && state.insert <= 8, "invalid preamp settings.")
            if AnalogInputLevel(rawValue: state.inputType)?.isPreampLevel == true {
                try require(layout.slot2 == .micPre8 && index < 8, "a preamp setting requires an 8MicPre channel.")
            }
        }
        for state in outputs {
            try require((1...2).contains(state.analogRefLevel) && state.digitalRefLevel <= 5
                        && state.trim.isFinite && abs(state.trim) <= 2, "invalid output settings.")
        }
        try require(metadata.peakHoldMode <= 2 && metadata.overHoldMode <= 3
                    && metadata.meterBank1Source <= 15 && metadata.meterBank2Source <= 15, "invalid meter settings.")
        let digitalSettings = PresetDigitalWrites.settings(of: metadata)
        for slot in 0..<2 {
            let card = layout.card(atSlot: slot)
            if card.hasOpticalPorts {
                let format = digitalSettings.opticalFormat[slot]
                try require((legacy && format == nil) || (format != nil && format! <= 1), "invalid or missing optical format.")
            }
            if card.hasSPDIFCoax {
                let replace = digitalSettings.spdifReplace[slot], mirror = digitalSettings.spdifMirror[slot]
                try require((legacy && replace == nil) || (replace != nil && replace! <= 8), "invalid or missing coax replacement.")
                try require((legacy && (mirror == nil || mirror == 0)) || (mirror != nil && (0...8).contains(mirror!)), "invalid or missing coax mirror.")
            }
        }
        if mixers.count == 2 {
            try require(mixers[0].softwareReturn == mixers[1].softwareReturn,
                        "independent software-return strips are not supported by this preset format.")
        }
        for mixer in mixers {
            try require(mixer.channels.count == layout.mixerChannelCount && mixer.source < (hostChannels == 64 || outputRoutes.count == 64 ? 32 : 8),
                        "unsupported mixer channels or software return source.")
            for channel in mixer.channels + [mixer.softwareReturn] {
                try require(channel.level.isFinite && (-48...6).contains(channel.level)
                            && channel.pan.isFinite && (-1...1).contains(channel.pan), "invalid mixer setting.")
            }
            try require(mixer.master.isFinite && (-48...6).contains(mixer.master), "invalid master level.")
        }
        var result: [Write] = []
        func put(_ selector: AudioPropertySelector, _ value: PropertyValue,
                 scope: PropertyScope = .global, element: UInt32 = 0) {
            result.append(.property(PropertyAddress(selector: selector, scope: scope, element: element), value))
        }
        // Card routing precedes peripheral recall: og_source/maestrolink/Software/
        // SymphonyController.cpp:696-704; SymphonyCard.cpp:412-415.
        if let cardInputRoutes, cardInputSupported {
            let table = try Self.cardTable(cardInputRoutes, channels: hostChannels)
            try require(cardInputRoutes.allSatisfy { $0 >= -1 && $0 < cardInputRoutes.count }, "invalid card input source.")
            let routing = SymphonyCardInputRouting(model: .init(topology: .symphonyOnly, hostChannels: hostChannels, unitBConfigured: hostChannels == 64))
            for (host, saved) in table.enumerated() {
                let source = saved >= hostChannels ? -1 : saved
                try require(source >= -1, "invalid card input source.")
                guard let command = routing.command(host: host, source: source == -1 ? nil : source) else {
                    throw RecallError.unsupported("unsupported card input route.")
                }
                result.append(.cardInput(command))
            }
        } else if cardInputRoutes != nil {
            onSkipped?("card input routing not restored: serving driver does not support it")
        }
        for (index, source) in inputRoutes.enumerated() {
            try require((32...63).contains(source) || source == SymphonyIORoutingAddress.none,
                        "unsupported input route.")
            put(.routing, .uint32(UInt32(source)), scope: .input,
                element: UInt32(SymphonyIORoutingAddress.p2pBase) + UInt32(index))
        }
        for source in outputRoutes {
            try require(ThunderboltCardRouting.route(destination: 32, source: source, unitBActive: outputRoutes.count == 64 || hostChannels == 64) != nil,
                        "unsupported output route.")
        }
        let outputsOnCard = legacy ? [] : try Self.cardTable(outputRoutes.map(Int.init), channels: hostChannels)
        for (index, saved) in outputsOnCard.enumerated() {
            let source = UInt8(saved >= hostChannels && saved < 64 ? Int(SymphonyIORoutingAddress.none) : saved)
            let local = ThunderboltCardRouting.route(destination: UInt8(index % 32 + 32), source: source, unitBActive: hostChannels == 64)!
            result.append(.output(.init(channel: UInt8(index), slot: local.enabled ? local.slot : UInt8(64 + index), enabled: local.enabled)))
        }
        // og_source/maestrolink/Software/SymphonyIO.cpp:4660-4708.
        for selector in Self.monitorOrder {
            guard let value = globals[selector.rawValue] else { continue }
            put(selector, Self.booleanSelectors.contains(selector) ? .bool(value != 0) : .uint32(value))
        }
        put(.metersShowInput, .uint32(metadata.meterBank1Source), element: 1)
        put(.metersShowInput, .uint32(metadata.meterBank2Source), element: 2)
        if let selection = frontPanelSelection { result.append(.frontPanel(selection)) }
        put(.peakHoldMode, .uint32(metadata.peakHoldMode))
        put(.oversHoldMode, .uint32(metadata.overHoldMode))
        if let clock = globals[AudioPropertySelector.clockSource.rawValue] { put(.clockSource, .uint32(clock)) }
        // Board children: coax first, then each analog stream and optical format.
        // og_source/maestrolink/Software/SymphonyIO_IOBoard.cpp:527-565;
        // AnalogIn_SymphonyIO_Stream.cpp:51-110; AnalogOut_SymphonyIO_Stream.cpp:50-108.
        var inputOffset = 0, outputOffset = 0
        for slot in 0..<2 {
            let card = layout.card(atSlot: slot)
            let digital = PresetDigitalWrites.writes(for: metadata, layout: layout).filter { $0.address.element == UInt32(slot) }
            for d in digital where d.address.selector != .opticalInFormat && d.address.selector != .opticalOutFormat {
                result.append(.property(d.address, .uint32(d.value)))
            }
            for index in min(inputOffset, inputs.count)..<min(inputs.count, inputOffset + card.analogInputChannels) {
                let s = inputs[index]
                let level = AnalogInputLevel(rawValue: s.inputType)!
                if !level.isPreampLevel {
                    if layout.slot2 == .micPre8 && index < 8 { put(.phantom, .bool(false), element: UInt32(index)) }
                    put(.analogIOType, .uint32(InputChannelLogic.analogIOTypeWithTrim(level: level, trim: s.trim)), scope: .input, element: UInt32(index))
                }
                put(.digitalRefLevel, .uint32(s.digitalRefLevel), scope: .input, element: UInt32(index))
                put(.softLimit, .uint32(s.softLimit), scope: .input, element: UInt32(index))
            }
            for index in min(outputOffset, outputs.count)..<min(outputs.count, outputOffset + card.analogOutputChannels) {
                let s = outputs[index]
                let trim = UInt32(UInt8(bitPattern: Int8((s.trim * 10).rounded())))
                put(.analogIOType, .uint32((trim << 8) | s.analogRefLevel), scope: .output, element: UInt32(index))
                put(.digitalRefLevel, .uint32(s.digitalRefLevel), scope: .output, element: UInt32(index))
            }
            for d in digital where d.address.selector == .opticalInFormat || d.address.selector == .opticalOutFormat {
                result.append(.property(d.address, .uint32(d.value)))
            }
            inputOffset += card.analogInputChannels
            outputOffset += card.analogOutputChannels
        }
        let identity = legacy ? nil : currentUnitID.flatMap(SymphonyIdentityReader.decode)
        if inputs.enumerated().contains(where: { index, state in
            state.phantom && !state.restoresPhantom(identity: identity, boardSlot: 1, channel: index)
        }) { onSkipped?("phantom power not restored from a bundle") }
        result += MicPreSettingsReplay.writes(inputs: inputs, layout: layout, identity: identity,
                                              includeLineChannels: true, restoresLineType: false)
        // Headphone crosspoints follow restored board output routes, not card
        // source bytes: og_source/maestrolink/Software/SymphonyIO.cpp:2716-2737.
        for (hp, selector) in [AudioPropertySelector.headphone1RoutingID, .headphone2RoutingID].enumerated() {
            guard let id = globals[selector.rawValue] else { continue }
            put(selector, .uint32(id))
            let pair = SymphonyIOHeadphoneRouting.outputPairDestinations(sourceID: id)!
            let dest = SymphonyIOHeadphoneRouting.Headphone(rawValue: hp)!.destinations
            put(.routing, .uint32(UInt32(pair.left - 32)), scope: .output, element: UInt32(dest.left))
            put(.routing, .uint32(UInt32(pair.right - 32)), scope: .output, element: UInt32(dest.right))
        }
        // og_source/maestrolink/Software/SymphonyPCIeCardMixer.cpp:1750-1754.
        for (index, mixer) in mixers.enumerated() {
            let base = UInt32(index + 1) << 16
            // A return pair outside the live card width stays unchanged.
            if mixer.source < (hostChannels == 64 ? 32 : 8) {
                put(.mixerSoftwareReturnID, .uint32(mixer.source), element: base)
            }
            for (channel, s) in (mixer.channels + [mixer.softwareReturn]).enumerated() {
                let id = channel == mixer.channels.count ? 1000 : layout.mixerChannels[channel].hardwareIndex
                let element = base | UInt32(id)
                put(.mixerChannelLevel, .float64(s.level), element: element)
                put(.mixerChannelPan, .float64(s.pan), element: element)
                put(.mixerChannelMute, .bool(s.isMuted || (routingMode == 0 && id != 1000)), element: element)
                put(.mixerChannelSolo, .bool(s.isSoloed), element: element)
            }
            put(.mixerChannelLevel, .float64(mixer.master), element: base | 2000)
        }
        if peripheralB {
            // Card masters/returns belong to A; only B input strips use 32-63.
            return result.compactMap { write in
                switch write {
                case .cardInput, .output: return nil
                case .property(let address, let value):
                    if address.selector == .clockSource || address.selector == .mixerSoftwareReturnID { return nil }
                    if [.mixerChannelLevel, .mixerChannelPan, .mixerChannelMute, .mixerChannelSolo].contains(address.selector) {
                        let channel = address.element & 0xFFFF
                        guard channel < 32 else { return nil }
                        return .property(PropertyAddress(selector: address.selector, scope: address.scope,
                                                         element: address.element + 32), value)
                    }
                    return write
                default: return write
                }
            }
        }
        // The card is routed before any peripheral's ApplySettingsToHardware.
        // og_source/maestrolink/Software/SymphonyController.cpp:696-704.
        return result.filter(\.isCardRoute) + result.filter { !$0.isCardRoute }
    }

    public static func legacy(_ metadata: MaestroPreset, layout: CardLayout) throws -> ThunderboltPreset {
        var preset = ThunderboltPreset(layout: layout, metadata: metadata)
        for level in [metadata.outputLevel, metadata.hp1Level, metadata.hp2Level] {
            guard level.isFinite && (-64...0).contains(level) else {
                throw RecallError.unsupported("invalid monitor level.")
            }
        }
        // App-only bundles historically restored app metadata and names. They
        // never changed monitor state on the ThunderBridge transport.
        preset.globals = [
            AudioPropertySelector.headphone1RoutingID.rawValue: metadata.hp1RoutingID,
            AudioPropertySelector.headphone2RoutingID.rawValue: metadata.hp2RoutingID,
        ]
        _ = try preset.writes(layout: layout, legacy: true)
        return preset
    }

    /// Caller holds the connection's serial lock for this entire synchronous
    /// transaction. Always finish with SetPeripheralReady, including failures.
    /// No mute-first or load-lock write: the original recall had neither.
    /// og_source/maestrolink/Software/SymphonyIO.cpp:4712-4735.
    public static func recall(_ writes: [Write], send: (Write) throws -> Void,
                              unlock: () throws -> Bool, retryDelay: () -> Void = { Thread.sleep(forTimeInterval: 0.005) }) throws {
        var failure: String?
        for (index, write) in writes.enumerated() {
            do { try send(write) } catch {
                failure = "write \(index + 1) (\(write)): \(error)"
                break
            }
        }
        if failure != nil {
            for off in MicPreSettingsReplay.phantomOffWrites(writes) {
                do { try send(off) } catch { failure = "\(failure ?? ""); phantom OFF failed: \(error)" }
            }
        }
        var ready = false
        for attempt in 0..<10 {
            if attempt == 9 && failure == nil {
                let offWrites = MicPreSettingsReplay.phantomOffWrites(writes)
                if !offWrites.isEmpty {
                    failure = "preference unlock timed out; phantom power cleared"
                    for off in offWrites {
                        do { try send(off) } catch { failure = "phantom OFF failed: \(error)" }
                    }
                }
            }
            do { ready = try unlock() } catch { ready = false }
            if ready { break }
            if attempt < 9 { retryDelay() }
        }
        if !ready { throw RecallError.failed("\(failure.map { "\($0); " } ?? "")the unit did not confirm the preference unlock.") }
        if let failure { throw RecallError.failed(failure) }
    }
}

public extension ThunderboltPreset {
    func writeBundle(to url: URL) throws {
        // Read/validate/encode before replacing a previous file. A failed save
        // must not leave an app-only bundle that appears to contain hardware.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let hardware = try encoder.encode(self)
        let app = try encoder.encode(metadata)
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".maestro-\(UUID().uuidString).mst2")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        try hardware.write(to: temporary.appendingPathComponent(ThunderboltPreset.fileName), options: .atomic)
        try app.write(to: temporary.appendingPathComponent("MaestroApp.plist"), options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: url)
        }
    }

    static func loadBundle(from url: URL, layout: CardLayout) throws -> (preset: ThunderboltPreset, legacy: Bool) {
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        let preset: ThunderboltPreset
        let legacy: Bool
        if directory.boolValue {
            let hardwareURL = url.appendingPathComponent(ThunderboltPreset.fileName)
            if FileManager.default.fileExists(atPath: hardwareURL.path) {
                let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                guard !files.contains(where: {
                    $0.pathExtension == "plist" && ![fileName, "MaestroApp.plist"].contains($0.lastPathComponent)
                }) else {
                    throw RecallError.unsupported("the bundle contains additional hardware settings.")
                }
                preset = try PropertyListDecoder().decode(ThunderboltPreset.self, from: Data(contentsOf: hardwareURL))
                legacy = false
            } else {
                // Old app-only bundles carry the same payload as a flat preset.
                // A daemon plist cannot be interpreted by the native transport:
                // reject it visibly rather than restore only its display names.
                let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                guard !files.contains(where: { $0.pathExtension == "plist" && $0.lastPathComponent != "MaestroApp.plist" }) else {
                    throw ThunderboltPreset.RecallError.unsupported("this bundle contains legacy daemon hardware settings; recall it through the legacy connection.")
                }
                preset = try ThunderboltPreset.legacy(MaestroPreset.load(from: url.appendingPathComponent("MaestroApp.plist")), layout: layout)
                legacy = true
            }
        } else {
            preset = try ThunderboltPreset.legacy(MaestroPreset.load(from: url), layout: layout)
            legacy = true
        }
        return (preset, legacy)
    }
}
