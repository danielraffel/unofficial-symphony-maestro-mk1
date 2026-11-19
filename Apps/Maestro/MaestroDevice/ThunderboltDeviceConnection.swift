/// Thunderbolt device connection for Symphony IO via ThunderBridge.
///
/// Uses two communication paths:
/// 1. CoreAudio HAL properties (volume, mute, sample rate) — direct to dext
/// 2. IOUserClient (mic gain, phantom, routing, clock, mixer, etc.) — via DextUserClient
///
/// The IOUserClient path sends vendor commands through the dext's XLink control
/// pipe, matching the same protocol the USB proxy uses for EP0 transfers.

import MaestroCore
import CoreAudio
import Foundation

// MARK: - ThunderboltDeviceConnection

public final class ThunderboltDeviceConnection: DeviceConnection, @unchecked Sendable {

    /// DriverKit-local command handled by the card FPGA, not sent over XLink.
    private static let mixerSoftwareReturnSourceCommand: UInt8 = 0xB4

    public let identifier: USBDeviceIdentifier
    public private(set) var isConnected: Bool = true

    /// CoreAudio device ID for the ThunderBridge dext audio device.
    private let audioDeviceID: AudioDeviceID

    /// Whether Core Audio currently has an active I/O cycle for this device.
    /// ThunderBridge can remain enumerated over PCIe after the Symphony is
    /// powered down, so enumeration alone is not evidence that meter DMA is
    /// producing fresh audio data.
    public var isAudioRunning: Bool? {
        CoreAudioDeviceConnection.isDeviceRunning(audioDeviceID)
    }

    /// IOUserClient connection for vendor commands (mic gain, phantom, etc.)
    private let dextClient = DextUserClient()

    /// Listener storage (NSLock-protected, same pattern as XPCDeviceConnection).
    private let listenerLock = NSLock()
    private let presetLock = NSRecursiveLock()
    private var presetOutputRoutes: [UInt8: UInt8] = [:]
    private var presetCardInputRoutes: [Int: Int] = [:]
    /// Where the clock source answer comes from; see `ThunderboltClockState`.
    let clockState = ThunderboltClockState()
    private var listeners: [AudioPropertySelector: [WeakListener]] = [:]

    /// Property selectors handled via CoreAudio HAL (more efficient path).
    private static let coreAudioSelectors: Set<AudioPropertySelector> = [
        .outputLevel,       // → kAudioDevicePropertyVolumeDecibels
        .outputMute,        // → kAudioDevicePropertyMute
        .sampleRate,        // → kAudioDevicePropertyNominalSampleRate
    ]

    /// Property selectors routed through vendor commands via dext custom property.
    /// This covers the full XMOS command surface — matches SymphonyIOPropertyMapper.buildWriteRequest.
    private static let dextSelectors: Set<AudioPropertySelector> = [
        // Mic preamp
        .micGain, .instrumentGain, .phantom, .phaseReverse, .highPassFilter, .softLimit,
        // MicPre8 group / insert (0xC7 / 0xC8 / 0xC9). Inert on a unit with no
        // MicPre module — the Input page never offers the controls, so nothing
        // is ever written for them.
        .groupID, .insertID, .insertReturnEnable,
        // Analog / digital input
        .analogIOType, .digitalRefLevel,
        // Output monitoring
        .outputDim, .outputSumToMono,
        .headphone1Level, .headphone2Level,
        .headphone1Mute, .headphone2Mute,
        .headphone1Dim, .headphone2Dim,
        .headphone1SumToMono, .headphone2SumToMono,
        .headphone1RoutingID, .headphone2RoutingID,
        .activeSpeakerSet,
        // Routing
        .routing,
        // Card-mixer software-return source. ThunderBridge handles this in the
        // card FPGA, rather than through the USB-only Symphony IO crosspoint.
        .mixerSoftwareReturnID,
        // Clock
        .clockSource,
        // Mixer
        .mixerChannelLevel, .mixerChannelPan, .mixerChannelMute, .mixerChannelSolo,
        // Metering / status
        .frontPanelMeterBank, .metersShowInput,
        .peakHoldMode, .oversHoldMode, .peaksClear, .prefix,
        // Optical / SPDIF
        .opticalInFormat, .opticalOutFormat,
        .spdifReplaceID, .spdifMirrorID,
        // Speaker
        .speakerOutputMode,
    ]

    /// Settings this transport can write but has no way to read back. They are
    /// kept in `settingsStore`: recorded when a write succeeds, returned by
    /// `getProperty`, and written back to the hardware by
    /// `reapplyStoredSettings()` on connect. See ``DeviceSettingsStore`` for why
    /// the Mac, not the unit, owns them.
    ///
    /// Without this every such read threw `unsupportedProperty`, so a view that
    /// re-reads the device each time it appears (System Setup, Device Settings,
    /// the Output tab's monitor section) fell back to its hard-coded defaults:
    /// the user set Peak Hold or Line output mode, switched tabs, and came back
    /// to the default on screen while the hardware kept what they had chosen.
    ///
    /// A value is only ever returned after it was written through the app, so
    /// nothing is invented: until then the read still throws and the caller
    /// keeps showing its default, exactly as before.
    ///
    /// Deliberately a short list, not all of `dextSelectors`: per-channel input,
    /// mixer and routing state has its own stores and restore paths, and
    /// answering those reads here would put a second source of truth under them.
    /// The list itself is ``DeviceSettingsStore/ownedSettings``, shared with USB.
    static let storedSelectors = Set(DeviceSettingsStore.ownedSettings)

    /// In-memory unless the app hands in a persistent one.
    public let settingsStore: DeviceSettingsStore

    private nonisolated func remember(_ value: PropertyValue, for address: PropertyAddress) {
        guard Self.storedSelectors.contains(address.selector) else { return }
        settingsStore.record(value, for: address)
    }

    private nonisolated func rememberedValue(for address: PropertyAddress) -> PropertyValue? {
        guard Self.storedSelectors.contains(address.selector) else { return nil }
        return settingsStore.value(for: address)
    }

    /// Write every stored setting to the hardware. Called once per connect, as
    /// the original daemon did, so a unit that was power-cycled or whose driver
    /// restarted is put back to what the app is showing.
    ///
    /// A setting the hardware refuses stays stored and is reported in `failed`.
    public func reapplyStoredSettings() async -> DeviceSettingsReplay {
        var replay = DeviceSettingsReplay()
        for entry in settingsStore.entries() where Self.storedSelectors.contains(entry.address.selector) {
            do {
                try await setProperty(entry.address, value: entry.value)
                replay.applied += 1
            } catch {
                replay.failed.append(entry.address.selector)
            }
        }
        return replay
    }

    /// All supported selectors (union of CoreAudio + dext paths).
    private static let supportedSelectors: Set<AudioPropertySelector> = {
        var s = coreAudioSelectors
        s.formUnion(dextSelectors)
        s.insert(.outputLevelRange)
        s.formUnion(readOnlyDextSelectors)
        return s
    }()

    /// Read-only selectors served by an IOUserClient READ selector rather than a
    /// vendor write. Kept out of `dextSelectors` so they never join
    /// `settableSelectors` — writing a board type is meaningless.
    private static let readOnlyDextSelectors: Set<AudioPropertySelector> = [
        .primaryBoardType, .secondaryBoardType,
    ]

    /// Property selectors that are settable.
    private static let settableSelectors: Set<AudioPropertySelector> = {
        var s: Set<AudioPropertySelector> = [.outputLevel, .outputMute, .sampleRate]
        s.formUnion(dextSelectors.subtracting(SymphonyIOPropertyMapper.readOnlySelectors))
        return s
    }()

    public init(identifier: USBDeviceIdentifier, audioDeviceID: AudioDeviceID,
                settingsStore: DeviceSettingsStore = DeviceSettingsStore()) {
        self.identifier = identifier
        self.audioDeviceID = audioDeviceID
        self.settingsStore = settingsStore

        // Connect vendor command transport to the dext's custom property
        dextClient.connect(audioDeviceID: audioDeviceID)
    }

    /// Capture the readable state under the same lock used by recall and UI
    /// writes. Write-only fields in `seed` come from the app's existing stores.
    public func capturePreset(_ seed: ThunderboltPreset, layout: CardLayout) throws -> ThunderboltPreset {
        presetLock.lock()
        defer { presetLock.unlock() }
        try checkPresetLayout(layout)
        var preset = seed
        for (channel, source) in presetOutputRoutes where channel < 32 && preset.outputRoutes.count == 32 {
            preset.outputRoutes[Int(channel)] = source
        }
        if preset.cardInputRoutes?.count == 32 {
            for (host, source) in presetCardInputRoutes where host < 32 {
                preset.cardInputRoutes?[host] = source
            }
        }
        for selector in ThunderboltPreset.monitorOrder + [.headphone1RoutingID, .headphone2RoutingID] {
            let value = try readPresetProperty(PropertyAddress(selector: selector))
            guard let raw = value.asUInt32 ?? value.asBool.map({ $0 ? UInt32(1) : 0 }) else {
                throw ThunderboltPreset.RecallError.unsupported("unreadable monitor setting \(selector).")
            }
            preset.globals[selector.rawValue] = raw
        }
        func monitor(_ selector: AudioPropertySelector) -> UInt32 { preset.globals[selector.rawValue]! }
        preset.metadata.outputLevel = -Double(monitor(.outputLevel))
        preset.metadata.outputMuted = monitor(.outputMute) != 0
        preset.metadata.outputDimmed = monitor(.outputDim) != 0
        preset.metadata.outputSumToMono = monitor(.outputSumToMono) != 0
        preset.metadata.hp1Level = -Double(monitor(.headphone1Level))
        preset.metadata.hp1Muted = monitor(.headphone1Mute) != 0
        preset.metadata.hp1RoutingID = monitor(.headphone1RoutingID)
        preset.metadata.hp2Level = -Double(monitor(.headphone2Level))
        preset.metadata.hp2Muted = monitor(.headphone2Mute) != 0
        preset.metadata.hp2RoutingID = monitor(.headphone2RoutingID)
        preset.globals[AudioPropertySelector.clockSource.rawValue] = try readProperty(PropertyAddress(selector: .clockSource)).asUInt32
        func read(_ selector: AudioPropertySelector, element: UInt32 = 0) throws -> UInt32 {
            guard let value = try readPresetProperty(PropertyAddress(selector: selector, element: element)).asUInt32 else {
                throw ThunderboltPreset.RecallError.unsupported("unreadable setting \(selector).")
            }
            return value
        }
        preset.metadata.meterBank1Source = try read(.metersShowInput, element: 1)
        preset.metadata.meterBank2Source = try read(.metersShowInput, element: 2)
        preset.metadata.peakHoldMode = try read(.peakHoldMode)
        preset.metadata.overHoldMode = try read(.oversHoldMode)
        for slot in 0..<2 {
            let card = layout.card(atSlot: slot)
            if card.hasOpticalPorts {
                let value = try read(card.opticalFormatUsesInput ? .opticalInFormat : .opticalOutFormat, element: UInt32(slot))
                if slot == 0 { preset.metadata.opticalInFormat = value } else { preset.metadata.slot2OpticalFormat = value }
            }
            if card.hasSPDIFCoax {
                let replace = try read(.spdifReplaceID, element: UInt32(slot))
                let mirror = try read(.spdifMirrorID, element: UInt32(slot))
                if slot == 0 {
                    preset.metadata.spdifReplaceID = replace
                    preset.metadata.spdifMirrorID = mirror
                } else {
                    preset.metadata.slot2SPDIFReplaceID = replace
                    preset.metadata.slot2SPDIFMirrorID = mirror
                }
            }
        }
        preset.inputRoutes = try (0..<32).map {
            UInt8(try read(.routing, element: UInt32(SymphonyIORoutingAddress.p2pBase) + UInt32($0)))
        }
        let selection = try dextClient.readVendorCommand(command: 0x2A, value: 0, responseLength: 1)
        guard selection.count == 1 else { throw DeviceConnectionError.transportError("Short front panel selection read") }
        preset.frontPanelSelection = selection[0]
        if layout.slot2 == .micPre8 { preset.unitID = try readPresetUnitID() }
        _ = try preset.writes(layout: layout, currentUnitID: preset.unitID)
        return preset
    }

    private func readPresetUnitID() throws -> Data {
        // og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:1186-1204.
        let data = try dextClient.readVendorCommand(command: 0xC0, value: 0, responseLength: 8)
        guard data.count == 8, data.contains(where: { $0 != 0 }), data.contains(where: { $0 != 0xFF }) else {
            throw ThunderboltPreset.RecallError.unsupported("the unit identity could not be read.")
        }
        return data
    }

    private func checkPresetLayout(_ layout: CardLayout) throws {
        guard isConnected, portSelectionID() != PortSelection.ports1And2.rawValue,
              layout.isKnown, layout.converter == nil, layout.converterLayout == nil,
              try readProperty(PropertyAddress(selector: .primaryBoardType)).asUInt32 == UInt32(layout.slot1.rawValue),
              try readProperty(PropertyAddress(selector: .secondaryBoardType)).asUInt32 == UInt32(layout.slot2.rawValue) else {
            throw ThunderboltPreset.RecallError.unsupported("the live card layout could not be verified.")
        }
    }

    private func readPresetProperty(_ address: PropertyAddress) throws -> PropertyValue {
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        let data = try dextClient.readVendorCommand(command: request.request, value: DextUserClient.nValue(for: request),
                                                  responseLength: max(1, request.data.count))
        guard data.count == max(1, request.data.count) else {
            throw DeviceConnectionError.transportError("Short preset read for \(address.selector)")
        }
        if ThunderboltPreset.monitorOrder.contains(address.selector) {
            return .uint32(UInt32(data[0]))
        }
        return try SymphonyIOPropertyMapper.decodeResponse(USBControlResponse(data: data, bytesTransferred: data.count), for: address)
    }

    public func recallPreset(_ preset: ThunderboltPreset, layout: CardLayout, legacy: Bool = false) throws {
        presetLock.lock()
        defer { presetLock.unlock() }
        try checkPresetLayout(layout)
        let identity = preset.metadata.inputChannelStates.contains(where: \.phantom) ? try readPresetUnitID() : nil
        let writes = try preset.writes(layout: layout, legacy: legacy, currentUnitID: identity)
        try ThunderboltPreset.recall(writes, send: { write in
            guard self.isConnected else { throw DeviceConnectionError.notConnected }
            switch write {
            case .property(let address, let value):
                // In Line mode the HAL volume belongs to HP1. A preset's speaker
                // attenuation must still address the speaker, as the original did.
                if address.selector == .outputLevel || address.selector == .outputMute {
                    try self.sendViaDext(SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: value))
                } else {
                    try self.writeProperty(address, value: value)
                }
            case .output(let route): try self.setCardOutputRoute(route)
            case .cardInput(let command): try self.sendConverterRouting(command)
            case .frontPanel(let selection):
                try self.dextClient.sendVendorCommand(command: 0x2A, value: 0, payload: Data([selection]))
            }
        }, unlock: {
            try self.dextClient.sendVendorCommand(command: 0xDD, value: 0, payload: Data([0]))
            let reply = try self.dextClient.readVendorCommand(command: 0xDD, value: 0, responseLength: 1)
            return reply == Data([0])
        })
    }

    /// Both connections share this recursive serial owner, also used by UI
    /// writes and preset recall. Never hold it across an async suspension.
    public func replayTwoUnits(_ plan: TwoUnitReplay, unitB: ThunderboltUnitBConnection,
                               recoveryCount: UInt32) throws {
        presetLock.lock()
        defer { presetLock.unlock() }
        func validate() throws {
            let link = linkState()
            let stateB = readUnitBState()
            let channels = portSelectionID().flatMap(PortSelection.init(rawValue:))?.channelCount ?? 0
            let converters = converterState()
            let model = SymphonyRoutingModel(
                topology: converters.map { $0.flags & 3 == 0 } == true ? .symphonyOnly : .unknown,
                hostChannels: channels, unitBConfigured: stateB?.info?.setupComplete == true)
            guard DeviceUnit.allCases.allSatisfy({ unit in
                let port: SymphonyRoutingModel.Port = unit == .a ? .one : .two
                return model.allows(.unitRouting, at: .peripheral(.init(port: port)!))
                    && model.allows(.monitor, at: .peripheral(.init(port: port)!))
            }), isConnected, unitB.isConnected, link?.recoveryCount == recoveryCount,
                  stateB?.boardType == plan.unitBBoards, stateB?.boardValid == [1, 1],
                  TwoUnitReplay.ready(channels: channels, link: link, unitB: stateB,
                                      port2Locked: (secondPortState()?.flags ?? 0) & SecondPortState.flagLocked != 0) else {
                throw DeviceConnectionError.notConnected
            }
        }
        try plan.run(validate: validate, send: { write in
            switch write {
            case .unit(let unit, let address, let value):
                if address.selector == .prefix {
                    guard let byte = CardLayout.peripheralPrefixByte(value.asString) else {
                        throw DeviceConnectionError.typeMismatch(expected: "letter A-Z", got: "\(value)")
                    }
                    try self.dextClient.sendVendorCommand(command: Self.prefixCommand, value: 0,
                                                           payload: Data([byte]), port: unit.portByte)
                } else if unit == .a { try self.writeProperty(address, value: value) }
                else { try unitB.writeProperty(address, value: value) }
            case .card(let write):
                switch write {
                case .property(let address, let value): try self.writeProperty(address, value: value)
                case .output(let route): try self.setCardOutputRoute(route)
                case .cardInput(let command): try self.sendConverterRouting(command)
                case .frontPanel: throw DeviceConnectionError.notConnected
                }
            case .headphones(.b): try unitB.replayRecoveryHeadphones()
            case .headphones(.a):
                for (hp, selector) in [AudioPropertySelector.headphone1RoutingID, .headphone2RoutingID].enumerated() {
                    guard let id = self.settingsStore.value(for: PropertyAddress(selector: selector))?.asUInt32,
                          let pair = SymphonyIOHeadphoneRouting.outputPairDestinations(sourceID: id),
                          let headphone = SymphonyIOHeadphoneRouting.Headphone(rawValue: hp) else { continue }
                    try validate()
                    try self.sendViaDext(SymphonyIORequestBuilder.setHeadphoneCrosspoint(
                        headphone: headphone, leftSource: pair.left - 32, rightSource: pair.right - 32))
                }
            }
        }, unlock: { unit in
            if unit == .b { return try unitB.finishRecovery() }
            try self.dextClient.sendVendorCommand(command: 0xDD, value: 0, payload: Data([0]))
            try validate()
            return try self.dextClient.readVendorCommand(command: 0xDD, value: 0, responseLength: 1) == Data([0])
        })
    }

    // MARK: - DeviceConnection Protocol

    public func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        try readProperty(address)
    }

    private func readProperty(_ address: PropertyAddress) throws -> PropertyValue {
        presetLock.lock()
        defer { presetLock.unlock() }
        guard isConnected else { throw DeviceConnectionError.notConnected }

        // CoreAudio HAL path (volume, mute, sample rate)
        switch address.selector {
        case .outputLevel:
            return try .float64(Float64(readVolumeDecibels()))
        case .outputMute:
            return try .uint32(readMute() ? 1 : 0)
        case .sampleRate:
            return try .float64(readNominalSampleRate())
        case .outputLevelRange:
            return .range(min: -64.0, max: 0.0)
        case .primaryBoardType, .secondaryBoardType:
            // The dext read OptionBoardType (0xA1) for both slots at Start and kept
            // the bytes; there is no EP0 on this transport for us to read ourselves.
            // A slot whose read failed comes back nil and MUST throw rather than
            // report 0: AppState treats a live 0 as "nothing reported" only because
            // it can tell the two apart, and a fabricated "empty" unlocks writes
            // that silence real outputs.
            guard let types = dextClient.readBoardTypes() else {
                throw DeviceConnectionError.unsupportedProperty(address.selector)
            }
            let raw = (address.selector == .primaryBoardType) ? types.primary : types.secondary
            guard let raw else {
                throw DeviceConnectionError.unsupportedProperty(address.selector)
            }
            return .uint32(UInt32(raw))
        case .clockSource:
            // No vendor read of its own: 0x28 clears the unit's front panel
            // flags on every read, and the front panel poller depends on them.
            // `clockState` holds what the poller last saw and what this
            // connection last wrote; the driver's 'clck' control cannot hold a
            // board input and is the fallback.
            let control = try? readClockSource()
            if let key = clockState.current(control: control, now: Date()) {
                return .uint32(key)
            }
            guard let control else { return try .uint32(readClockSource()) }
            return .uint32(control)
        case .opticalInFormat:
            // Read the current selected value of the dext's DataSource control for this board
            // (element = board+1). Entitlement-free; mirrors the write path. Returns 0=ADAT/SMUX,
            // 1=S/PDIF. Throws if the board has no optical control published (non-optical board).
            return try .uint32(readOpticalFormat(board: address.element))
        case .opticalOutFormat:
            return try .uint32(readOpticalFormat(board: address.element))
        case .spdifReplaceID, .spdifMirrorID:
            // S/PDIF Coax Replaces (0x35) and Mirrors (0x36) are read back from
            // the unit, as the daemon did (`SymphonyIO_IOBoard.cpp:440-484`).
            // Without this the Input and Output tabs fell back to Off / the
            // first pair every time they appeared.
            let read = try Self.vendorRead(for: address)
            let data = try dextClient.readVendorCommand(
                command: read.command, value: read.value, responseLength: 1)
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("ThunderBridge S/PDIF coax read returned no data")
            }
            return .uint32(UInt32(byte))
        case .prefix:
            // The Mac's own choice first (it is written to the unit at
            // connect); otherwise the letter the unit keeps (0x37), which is
            // what the driver names channels with. A unit with no letter yet
            // answers 0xFF, and the read keeps throwing as before.
            if let value = rememberedValue(for: address) { return value }
            let data = try? dextClient.readVendorCommand(
                command: Self.prefixCommand, value: 0, responseLength: 1)
            guard let byte = data?.first, (0x41...0x5A).contains(byte) else {
                throw DeviceConnectionError.unsupportedProperty(address.selector)
            }
            return .string(String(UnicodeScalar(byte)))
        case .routing:
            let data = try dextClient.readVendorCommand(
                command: SymphonyIOCommand.audioRouting.rawValue,
                value: address.element,
                responseLength: 1)
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("ThunderBridge routing read returned no data")
            }
            return .uint32(UInt32(byte))
        default:
            break
        }

        // No hardware read for the remaining vendor commands on this transport.
        // Settings the Mac owns are answered from the settings store (see
        // `storedSelectors`); everything else still throws.
        if let value = rememberedValue(for: address) { return value }
        throw DeviceConnectionError.unsupportedProperty(address.selector)
    }

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        try writeProperty(address, value: value)
    }

    private func writeProperty(_ address: PropertyAddress, value: PropertyValue) throws {
        presetLock.lock()
        defer { presetLock.unlock() }
        guard isConnected else { throw DeviceConnectionError.notConnected }

        // CoreAudio HAL path
        switch address.selector {
        case .outputLevel:
            // The UI sends .outputLevel as a UInt32 ATTENUATION (0..64, where 0 = loudest),
            // matching the USB path (SymphonyIOPropertyMapper). The dext's VolumeControl is in
            // decibels (-64..0), so attenuation N maps to -N dB. Accept both forms (a Float64 dB
            // value from any other caller too) — previously this only accepted Float64, so the
            // app's UInt32 knob writes threw typeMismatch and were silently swallowed (mute worked
            // because it accepts UInt32/Bool; the volume knob did nothing).
            let db: Float32
            if let d = value.asFloat64 {
                db = Float32(d)                     // already dB (negative)
            } else if let atten = value.asUInt32 {
                db = -Float32(atten)                // attenuation 0..64 → -atten dB
            } else {
                throw DeviceConnectionError.typeMismatch(expected: "Float64 or UInt32", got: "\(value)")
            }
            try writeVolumeDecibels(db)
            notifyListeners(for: address.selector, value: value)
            return

        case .outputMute:
            let muted: Bool
            if let u = value.asUInt32 { muted = u != 0 }
            else if let b = value.asBool { muted = b }
            else { throw DeviceConnectionError.typeMismatch(expected: "UInt32/Bool", got: "\(value)") }
            try writeMute(muted)
            notifyListeners(for: address.selector, value: value)
            return

        case .sampleRate:
            guard let rate = value.asFloat64 else {
                throw DeviceConnectionError.typeMismatch(expected: "Float64", got: "\(value)")
            }
            try writeNominalSampleRate(rate)
            notifyListeners(for: address.selector, value: value)
            return

        case .clockSource:
            // Entitlement-free path: the dext publishes a Clock Source AudioDriverKit control
            // object ('clck', Global scope), so we drive it via the standard CoreAudio clock-source
            // property rather than the (Apple-blocked) IOUserClient. The control's selector IDs are
            // the legacy eSymphonyIOClockSource enum values (1..5), so the value maps 1:1.
            guard let key = value.asUInt32, let decoded = ClockSourceMenu.decode(key) else {
                throw DeviceConnectionError.typeMismatch(expected: "clock source key", got: "\(value)")
            }
            if let input = decoded.boardInput {
                let control = try? readClockSource()
                try writeBoardInputClockSource(source: decoded.source, boardInput: input)
                clockState.wroteBoardInput(key, control: control, now: Date())
            } else {
                // The control may still hold this value from before a board
                // input was chosen through the vendor path, and a write that
                // does not change it may never reach the driver. Send the same
                // ClockMode the driver would, directly, in that case only.
                let current = try? readClockSource()
                try writeClockSource(key)
                if current == key {
                    try sendViaDext(Self.clockModeRequest(source: decoded.source, boardInput: 0))
                }
                clockState.wrotePlain()
            }
            notifyListeners(for: address.selector, value: value)
            return

        case .opticalInFormat:
            // Entitlement-free path: the dext publishes a per-optical-board DataSource control
            // object ('dest', Output scope, element = board+1) that drives vendor cmd 0x34. We route
            // the legacy 'AEoi' write through the standard CoreAudio DataSource property rather
            // than the (Apple-blocked) IOUserClient. `address.element` is the 0-based board index;
            // the control lives on element board+1 (element 0/Main holds output volume+mute).
            // Value: 0=ADAT/SMUX, 1=S/PDIF. Only published for boards the dext detected as Optical,
            // so a write to a non-optical board is a no-op OSStatus (safe).
            guard let fmt = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            try writeOpticalFormat(board: address.element, format: fmt)
            notifyListeners(for: address.selector, value: value)
            return

        case .opticalOutFormat:
            guard let fmt = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            try writeOpticalFormat(board: address.element, format: fmt)
            notifyListeners(for: address.selector, value: value)
            return

        default:
            break
        }

        // IOUserClient path — route through DextUserClient
        guard Self.dextSelectors.contains(address.selector) else {
            throw DeviceConnectionError.unsupportedProperty(address.selector)
        }

        // The USB mapper's AEsR implementation writes Symphony IO destinations
        // (0xE4/0xE5). ThunderBridge's original PCIe mixer instead selects a
        // host-playback pair by changing the card FPGA mixer return route.
        if address.selector == .mixerSoftwareReturnID {
            // 0-7 with one unit; 0-31 (the 64 playback channels) while 64
            // channels run with a Symphony I/O on port 2. The driver refuses
            // 8-31 otherwise, and the Mixer offers them only then.
            guard let source = value.asUInt32, source <= 31 else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 software return source 0...31", got: "\(value)")
            }
            guard address.element & 0xFFFF == 0,
                  (1...2).contains(address.element >> 16) else {
                throw DeviceConnectionError.transportError(
                    "Invalid ThunderBridge mixer element \(address.element)")
            }
            try dextClient.sendVendorCommand(
                command: Self.mixerSoftwareReturnSourceCommand,
                value: address.element,
                payload: Data([UInt8(source)]))
            notifyListeners(for: address.selector, value: value)
            return
        }

        // Peripheral Prefix: the daemon kept the letter in the unit (0x37,
        // `SymphonyIOControl.cpp:1568-1600`, firmware
        // `SymphonyIOCore3MainController.cpp:1005-1025`) and named every
        // channel with it; the ThunderBridge driver reads it there and follows
        // this write. The Mac's copy is what the app shows, so it is kept even
        // when the send fails (no driver, an older one): the next connect
        // sends it again from the store.
        if address.selector == .prefix {
            guard let byte = CardLayout.peripheralPrefixByte(value.asString) else {
                throw DeviceConnectionError.typeMismatch(expected: "a letter A-Z", got: "\(value)")
            }
            remember(value, for: address)
            do {
                try dextClient.sendVendorCommand(command: Self.prefixCommand, value: 0, payload: Data([byte]))
            } catch {
                print("[Maestro] ThunderBridge prefix 0x37 write not sent: \(error)")
            }
            notifyListeners(for: address.selector, value: value)
            return
        }

        do {
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: value)
            try sendViaDext(request)
        } catch DeviceConnectionError.cacheOnly {
            // No XMOS opcode (or an unsafe one, e.g. front-panel meter config) —
            // skip the send. Never emit the 0xFF sentinel to the dext (S3).
        }
        // Reached only when the send did not throw, so a failed write is never
        // stored as though it had landed.
        remember(value, for: address)
        notifyListeners(for: address.selector, value: value)
    }

    public func hasProperty(_ address: PropertyAddress) async -> Bool {
        Self.supportedSelectors.contains(address.selector)
    }

    public func isPropertySettable(_ address: PropertyAddress) async -> Bool {
        Self.settableSelectors.contains(address.selector)
    }

    public func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        addListenerSync(listener, for: address.selector)
    }

    public func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        removeListenerSync(listener, for: address.selector)
    }

    // NSLock wrappers — called synchronously to avoid Swift 6 async restriction
    private nonisolated func addListenerSync(_ listener: PropertyListener, for selector: AudioPropertySelector) {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        listeners[selector, default: []].append(WeakListener(listener))
    }

    private nonisolated func removeListenerSync(_ listener: PropertyListener, for selector: AudioPropertySelector) {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        listeners[selector]?.removeAll { $0.ref === listener }
    }

    public func disconnect() async {
        closeDextClient()
    }

    // MARK: - Dext Vendor Command

    /// Send a vendor command to the Symphony IO via the dext's custom property.
    /// Program one XLink TX channel of the card's output routing stage. This is
    /// where host playback routing lives on ThunderBridge — see
    /// ``ThunderboltCardRouting``. Handled by the dext (build 111+), never sent
    /// to the Symphony.
    public func setCardOutputRoute(_ route: ThunderboltCardRouting.Route) throws {
        presetLock.lock()
        defer { presetLock.unlock() }
        guard isConnected, dextClient.isConnected else { throw DeviceConnectionError.notConnected }
        try dextClient.sendVendorCommand(
            command: ThunderboltCardRouting.outputRouteCommand,
            value: 0,
            payload: route.payload)
        if route.channel < 32,
           !route.enabled || (64..<96).contains(route.slot) || (128..<132).contains(route.slot) {
            let source: UInt8
            if !route.enabled { source = SymphonyIORoutingAddress.none }
            else if route.slot >= ThunderboltCardRouting.mixerOutBase {
                let offset = route.slot - ThunderboltCardRouting.mixerOutBase
                source = (offset < 2 ? SymphonyIORoutingAddress.mixer0Base : SymphonyIORoutingAddress.mixer1Base) + offset % 2
            } else { source = route.slot - ThunderboltCardRouting.pciOutBase }
            presetOutputRoutes[route.channel] = source
        }
    }

    /// Send one converter routing command (0xB5 / 0xB6 / 0xB7, see
    /// ``ConverterRouting``). Handled by the dext (build 131+) when converters
    /// are on the cable. B1b also accepts 0xB6/0xB7 for Symphony inputs.
    public func sendConverterRouting(_ command: ConverterRouting.Command) throws {
        presetLock.lock()
        defer { presetLock.unlock() }
        guard isConnected, dextClient.isConnected else { throw DeviceConnectionError.notConnected }
        try dextClient.sendVendorCommand(command: command.command, value: 0, payload: Data(command.payload))
        if command == ConverterRouting.resetRoutingCommand {
            presetCardInputRoutes = Dictionary(uniqueKeysWithValues: (0..<32).map { ($0, $0) })
        } else {
            presetCardInputRoutes = SymphonyCardInputRouting.applying([command], to: presetCardInputRoutes)
        }
    }

    private func sendViaDext(_ request: USBControlRequest) throws {
        guard dextClient.isConnected else {
            throw DeviceConnectionError.notConnected
        }
        try dextClient.sendFromUSBRequest(request)
    }

    /// Read the card FPGA hardware meter buffer (256 raw words), or nil if unavailable.
    /// Word layout: 0-31 = hardware inputs, 64-95 = host playback, 128-131 = mixer0/1 out.
    public func readMeters() -> [UInt32]? {
        dextClient.readMeters()
    }

    /// Read the dext's timing/register snapshot through the same signed
    /// user-client connection Maestro uses for vendor controls. This keeps
    /// latency validation inside the production entitlement boundary; a
    /// standalone unsigned probe cannot open this production user client.
    public func readTimingHealth() -> TimingHealth? {
        dextClient.readTimingHealth()
    }

    /// One serialized liveness probe: the dext's live XLink read plus the
    /// app-side current-link-fault check (see `ThunderboltEndpointHealth`).
    /// This is the only question lifecycle code should ask about the Symphony.
    public func probeEndpoint() -> ThunderboltEndpointVerdict {
        // dext 113: the driver owns the link watch; this read costs no bus traffic.
        // A dext older than 113 rejects selector 5, which reads as `.unavailable`,
        // so fall back to the 0x51 message probe in that one case.
        if let ls = dextClient.readLinkState() {
            lastLinkState = ls
            return ThunderboltEndpointHealth.evaluate(linkState: ls)
        }
        lastLinkState = nil
        return ThunderboltEndpointHealth.evaluate(dextClient.readTimingHealth())
    }

    /// The original round-trip probe (0x51 ClockRateAndLock over XLink). On demand
    /// only — diagnostics and one-off confirmations — never on a timer.
    public func probeEndpointDeep() -> ThunderboltEndpointVerdict {
        ThunderboltEndpointHealth.evaluate(dextClient.readTimingHealth())
    }

    /// Raw link-watch state for diagnostics panels.
    public func linkState() -> LinkState? { dextClient.readLinkState() }

    /// Which dext build serves the card. A dext that answers the link-state
    /// read but not the build read predates the build selector (123): an
    /// older copy is still running. Nil when the user client answers neither.
    public func servingDriverBuild() -> ServingDextBuild? {
        if let build = dextClient.readDriverBuild() { return .build(build) }
        return dextClient.readLinkState() != nil ? .olderThanBuildReporting : nil
    }

    /// EXPERIMENT (64 channels): what the driver found on its second XLink
    /// port. Nil from a driver without that selector (every released one).
    public func secondPortState() -> SecondPortState? { dextClient.readPort2State() }

    /// The second Symphony I/O (unit B) as the driver configured it when 64
    /// channels started (selector 11). Nil from a driver without the selector.
    public func readUnitBState() -> UnitBState? { dextClient.readUnitBState() }

    /// A connection to unit B through this connection's driver client: the
    /// same calls with port byte 1. Unit A's bytes are not affected.
    public func makeUnitBConnection(settingsStore: DeviceSettingsStore = DeviceSettingsStore()) -> ThunderboltUnitBConnection {
        let client = dextClient
        return ThunderboltUnitBConnection(identifier: identifier, transport: client,
                                          settingsStore: settingsStore,
                                          sequenceLock: presetLock,
                                          infoRouting: { [weak self] in
                                              guard let self, let converters = client.readConverterState() else {
                                                  return SymphonyRoutingModel(topology: .unknown, hostChannels: 0)
                                              }
                                              return SymphonyRoutingModel(
                                                  topology: converters.flags & 3 == 0 ? .symphonyOnly : .unknown,
                                                  hostChannels: self.portSelectionID().flatMap(PortSelection.init(rawValue:))?.channelCount ?? 0,
                                                  unitBConfigured: client.readUnitBState()?.info?.setupComplete == true)
                                          },
                                          state: { client.readUnitBState() })
    }

    /// The driver's converter report (dext 131+); nil from older drivers.
    public func converterState() -> ConverterState? { dextClient.readConverterState() }

    /// Send the converter config word (dext 131+); false from older drivers.
    @discardableResult
    public func setConverterConfig(_ config: UInt32) -> Bool { dextClient.setConverterConfig(config) }

    /// EXPERIMENT (64 channels, stage 2): the port selector a two-port driver
    /// publishes on the Core Audio device. Nil from every released driver.
    public func portSelectionID() -> UInt32? { PortSelectionProperty.read(deviceID: audioDeviceID) }

    /// Ask the device for a port selection, as Audio MIDI Setup does.
    public func setPortSelection(_ selection: PortSelection) throws {
        try PortSelectionProperty.write(deviceID: audioDeviceID, selection: selection)
    }

    /// Follow the port selector, whoever changes it.
    public func observePortSelection() throws -> PortSelectionObservation {
        try PortSelectionObservation(deviceID: audioDeviceID)
    }

    /// Ask the driver serving the card to retire for `replacementBuild`
    /// (`DextUserClient.retireForUpgrade`). On acceptance the private client
    /// is closed at once: the driver is terminating and nothing more should
    /// be sent to it.
    public func retireServingDriver(replacementBuild: UInt32) -> DextUserClient.RetireReply {
        let reply = dextClient.retireForUpgrade(replacementBuild: replacementBuild)
        if case .accepted = reply { closeDextClient() }
        return reply
    }

    /// One read of the unit's front panel state (vendor read `0x28`), through
    /// the driver's general vendor read. Nil when the unit does not answer or
    /// the reply is not a real reading. Runs off the caller's thread: the driver
    /// waits up to 200 ms for a reply.
    public func readParameterUpdates() async -> SymphonyIOParameterUpdates? {
        guard isConnected, dextClient.isConnected else { return nil }
        let client = dextClient
        let clockState = self.clockState
        let shouldLog = Self.parameterUpdateLogBudget.take()
        return await Task.detached(priority: .utility) {
            do {
                let data = try client.readVendorCommand(
                    command: SymphonyIOParameterUpdates.readRequest.request, value: 1,
                    responseLength: SymphonyIOParameterUpdates.byteCount)
                let update = SymphonyIOParameterUpdates(data: data)
                // Bytes 5 and 6 are the clock source and board input whatever
                // the rate guard decides: an external source with no signal
                // can report a rate of 0.
                if data.count >= SymphonyIOParameterUpdates.byteCount,
                   let key = Self.clockSourceKey(reportedSource: data[data.startIndex + 5],
                                                 boardInput: data[data.startIndex + 6]) {
                    clockState.reported(key, now: Date())
                }
                if shouldLog {
                    let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("[Maestro] TB front panel read: [\(hex)] \(update == nil ? "REJECTED as not a reading" : "ok")")
                }
                return update
            } catch {
                if shouldLog { print("[Maestro] TB front panel read failed: \(error)") }
                return nil
            }
        }.value
    }

    /// A slot's board hardware major version (0xA0, type 5 or 6), through the
    /// driver's general vendor read. Nil when unanswered.
    public func readBoardHardwareMajor(slot: Int) async -> UInt8? {
        guard isConnected, dextClient.isConnected, slot == 0 || slot == 1 else { return nil }
        let client = dextClient
        return await Task.detached(priority: .utility) {
            guard let data = try? client.readVendorCommand(
                command: 0xA0, value: UInt32(5 + slot), responseLength: 3),
                  data.count >= 3 else { return nil }
            return data[0]
        }.value
    }

    /// SymphonyIOCommands_Prefix: the unit's peripheral prefix letter, one byte.
    static let prefixCommand: UInt8 = 0x37

    /// Diagnostic: the unit's 32 capture routes (0x31 read for P2P 192-223),
    /// logged once per connect, so a hardware run shows which hardware input
    /// each Mac input really carries. Reads only. Stops at the first read the
    /// unit does not answer: each unanswered read holds the driver's command
    /// path for its 200 ms timeout, and a unit that ignores one ignores all 32.
    public func logInputRoutes() async {
        guard isConnected, dextClient.isConnected else { return }
        let client = dextClient
        let line: String = await Task.detached(priority: .utility) {
            Self.inputRouteLogLine { dest in
                (try? client.readVendorCommand(
                    command: SymphonyIOCommand.audioRouting.rawValue, value: dest, responseLength: 1))?.first
            }
        }.value
        print("[Maestro] TB input routes (Mac input=source byte; 32-47 slot 1, 48-63 slot 2, 236 none): \(line)")
    }

    /// The log line for `logInputRoutes`: "1=32 2=33 ...", from `read`
    /// (destination byte → source byte, nil when the unit does not answer).
    /// The first unanswered read ends it: "... 5=no answer, not read further".
    static func inputRouteLogLine(read: (UInt32) -> UInt8?) -> String {
        var parts: [String] = []
        for n in 0..<32 {
            guard let src = read(UInt32(SymphonyIORoutingAddress.p2pBase) + UInt32(n)) else {
                parts.append("\(n + 1)=no answer, not read further")
                break
            }
            parts.append("\(n + 1)=\(src)")
        }
        return parts.joined(separator: " ")
    }

    /// The first few front panel reads of a session are logged in full: whether
    /// the unit answers this read over the ThunderBridge link, and with what,
    /// had never been observed when this was written.
    private static let parameterUpdateLogBudget = LogBudget(12)

    final class LogBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(_ count: Int) { remaining = count }
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    /// The link-watch state behind the most recent `probeEndpoint()` (nil when the
    /// running dext predates selector 5). Read by the lifecycle log.
    public private(set) var lastLinkState: LinkState?

    /// True only when the card FPGA answers a live read. The PCI endpoint and
    /// dext may remain registered after the Symphony loses power.
    public func isHardwareResponsive() -> Bool {
        dextClient.probeHardwareResponse()
    }

    /// Reopen the app's private dext connection after a physical power flap.
    ///
    /// ThunderBridge's PCI service can remain enumerated while the Symphony is
    /// powered off. In that interval the existing IOUserClient may stay alive
    /// but no longer be able to issue XLink transactions. Reopening the client
    /// is deliberately limited to the control path; Core Audio retains the same
    /// device identity and the health loop decides when the hardware is usable.
    public func reconnectDextClient() {
        presetLock.lock()
        defer { presetLock.unlock() }
        presetOutputRoutes.removeAll()
        presetCardInputRoutes.removeAll()
        dextClient.disconnect()
        dextClient.connect(audioDeviceID: audioDeviceID)
    }

    /// Close the private dext client synchronously (the core of `disconnect()`);
    /// also used by a throwaway connection created only to probe the endpoint.
    public func closeDextClient() {
        presetLock.lock()
        defer { presetLock.unlock() }
        isConnected = false
        dextClient.disconnect()
    }

    // MARK: - CoreAudio HAL Property Access

    private func readVolumeDecibels() throws -> Float32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibels,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("VolumeDecibels read failed: \(status)")
        }
        return volume
    }

    private func writeVolumeDecibels(_ db: Float32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibels,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = db
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<Float32>.size), &volume)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("VolumeDecibels write failed: \(status)")
        }
    }

    /// Write the clock source via the dext's AudioDriverKit control object (no entitlement).
    /// `source` is the legacy eSymphonyIOClockSource value (1=Internal..5=IOBoard2), which is
    /// exactly the selector ID the 'clck' control publishes. Global scope, since the control is
    /// created on kAudioObjectPropertyScopeGlobal.
    private func writeClockSource(_ source: UInt32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyClockSource,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var src = source
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &src)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("ClockSource write failed: OSStatus \(status)")
        }
    }

    /// ClockMode (0x50) for a source, as the driver's clock control sends it
    /// (`RequestClockSource`): Loop Sync as slave with loop sync on, anything
    /// else as master with loop sync off. The original forced master for every
    /// source but Loop Sync (`og_source/maestrolink/Software/SymphonyIO/
    /// SymphonyIOControl.cpp:966-967`).
    static func clockModeRequest(source: UInt8, boardInput: UInt8) -> USBControlRequest {
        let loop = source == 3
        return SymphonyIORequestBuilder.setClockMode(
            source: SymphonyIOClockSource(rawValue: source) ?? .internal,
            isMaster: !loop, loopSync: loop, boardIndex: boardInput)
    }

    /// Clock to one input of an I/O board: ClockMode with the board as the
    /// source (4 or 5) and the input in `pData[3]`, which the driver's clock
    /// control cannot express (it always sends 0). Goes through the driver's
    /// vendor path, which runs on the same serial XLink queue as the control.
    /// The control is left as it was: writing it too would queue a second
    /// ClockMode with input 0 that could land after this one.
    private func writeBoardInputClockSource(source: UInt8, boardInput: UInt8) throws {
        guard source == 4 || source == 5 else {
            throw DeviceConnectionError.typeMismatch(expected: "IO board source", got: "\(source)")
        }
        try sendViaDext(Self.clockModeRequest(source: source, boardInput: boardInput))
    }

    /// The vendor read (command, logical nValue) the driver's read path takes
    /// for a setting the unit can report, built from the same request the USB
    /// transport sends so the two cannot disagree on where the board index goes.
    static func vendorRead(for address: PropertyAddress) throws -> (command: UInt8, value: UInt32) {
        let request = try SymphonyIOPropertyMapper.buildReadRequest(for: address)
        return (request.request, (UInt32(request.value) << 16) | UInt32(request.index))
    }

    /// The picker key for a clock source the unit reported, nil when it is not
    /// a source. A board source carries its input; the menu maps it back to a
    /// plain "IO Board" row when that board is not shown by input.
    static func clockSourceKey(reportedSource: UInt8, boardInput: UInt8) -> UInt32? {
        guard (1...5).contains(reportedSource) else { return nil }
        if reportedSource == 4 || reportedSource == 5 {
            guard boardInput <= ClockSourceMenu.maxBoardInput else { return nil }
            return ClockSourceMenu.key(source: reportedSource, boardInput: boardInput)
        }
        return UInt32(reportedSource)
    }

    /// Read the clock source back from the same 'clck' control `writeClockSource` drives.
    /// Throws for anything outside the legacy enum range rather than hand the
    /// caller an ID its picker has no row for.
    private func readClockSource() throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyClockSource,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("ClockSource read failed: OSStatus \(status)")
        }
        guard (1...5).contains(value) else {
            throw DeviceConnectionError.transportError("ClockSource read returned unknown ID \(value)")
        }
        return value
    }

    /// Write the optical output format via the dext's per-board DataSource control object
    /// (no entitlement). `board` is the 0-based board index (0=primary, 1=secondary); the control
    /// lives on `kAudioObjectPropertyScopeOutput` element `board+1` (element 0/Main holds output
    /// volume+mute). `format` is 0=ADAT/SMUX, 1=S/PDIF — the selector value equals the wire byte
    /// the dext forwards as vendor cmd 0x34.
    private func writeOpticalFormat(board: UInt32, format: UInt32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: board &+ 1
        )
        var value: UInt32 = (format != 0) ? 1 : 0
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("OpticalFormat write failed: OSStatus \(status)")
        }
    }

    /// Read the current optical output format from the dext's DataSource control (element
    /// board+1). Returns 0=ADAT/SMUX, 1=S/PDIF. Throws if the board publishes no optical control.
    private func readOpticalFormat(board: UInt32) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: board &+ 1
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("OpticalFormat read failed: OSStatus \(status)")
        }
        return value
    }

    private func readMute() throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("Mute read failed: \(status)")
        }
        return muted != 0
    }

    private func writeMute(_ muted: Bool) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("Mute write failed: \(status)")
        }
    }

    private func readNominalSampleRate() throws -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &rate)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("SampleRate read failed: \(status)")
        }
        return rate
    }

    private func writeNominalSampleRate(_ rate: Float64) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableRate = rate
        let status = AudioObjectSetPropertyData(audioDeviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<Float64>.size), &mutableRate)
        guard status == noErr else {
            throw DeviceConnectionError.transportError("SampleRate write failed: \(status)")
        }
    }

    // MARK: - Listener Notification

    private func notifyListeners(for selector: AudioPropertySelector, value: PropertyValue) {
        listenerLock.lock()
        let weakListeners = listeners[selector] ?? []
        listenerLock.unlock()

        let change = PropertyChange(
            address: PropertyAddress(selector: selector),
            value: value
        )
        for weak in weakListeners {
            if let listener = weak.ref {
                Task { await listener.propertyDidChange(change) }
            }
        }
    }

    // MARK: - Transport Type Discovery

    /// Check if a CoreAudio device is a Thunderbolt device.
    public static func isThunderboltDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return false }
        return transportType == kAudioDeviceTransportTypeThunderbolt
    }
}

// MARK: - Weak Listener Wrapper

private struct WeakListener {
    weak var ref: (any PropertyListener)?
    init(_ listener: any PropertyListener) { self.ref = listener }
}

/// The clock source to report on ThunderBridge, in order of trust:
///
/// 1. What the unit reported in the front panel poller's last 0x28 read, if
///    that was recent. It names the board input.
/// 2. A board input this connection wrote, while the driver's 'clck' control
///    still holds the value it had at that write. The write goes through the
///    vendor path and leaves the control alone, so without this the control's
///    older value would show and selecting that row would send nothing.
///    Once the control changes (Audio MIDI Setup, or a plain row here) the
///    control wins.
/// 3. Nothing; the caller reads the control.
final class ThunderboltClockState: @unchecked Sendable {
    static let reportLifetime: TimeInterval = 3

    private let lock = NSLock()
    private var reportedKey: UInt32?
    private var reportedAt: Date?
    private var boardInputKey: UInt32?
    private var controlAtBoardInputWrite: UInt32?

    func reported(_ key: UInt32, now: Date) {
        lock.lock(); defer { lock.unlock() }
        reportedKey = key
        reportedAt = now
    }

    func wroteBoardInput(_ key: UInt32, control: UInt32?, now: Date) {
        lock.lock(); defer { lock.unlock() }
        boardInputKey = key
        controlAtBoardInputWrite = control
        // A report from before this write is out of date.
        reportedKey = nil
        reportedAt = nil
    }

    func wrotePlain() {
        lock.lock(); defer { lock.unlock() }
        boardInputKey = nil
        controlAtBoardInputWrite = nil
        reportedKey = nil
        reportedAt = nil
    }

    func current(control: UInt32?, now: Date) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        if let key = reportedKey, let at = reportedAt,
           now.timeIntervalSince(at) < Self.reportLifetime {
            return key
        }
        if let key = boardInputKey, control == controlAtBoardInputWrite {
            return key
        }
        return nil
    }
}
