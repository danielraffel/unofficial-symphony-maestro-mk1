import Foundation

// MARK: - Two Symphony I/Os on ThunderBridge (64 channels)
//
// With 64 channels running and a Symphony I/O on ThunderBridge port 2, there
// are two units: unit A on port 1 (channels 1-32) and unit B on port 2
// (channels 33-64). The original kept unit B as its own peripheral with its own
// cards, settings and meters, and named its channels with its own prefix
// letter (`og_source/maestrolink/Software/SymphonyIOSymphonyPeripheralDevice.cpp`).
// The driver configures unit B when 64 channels start (Loop Sync slave of unit A,
// routing, unlock) and reports it through selector 11 (`UnitBState`).
//
// Everything here is transport-free so the rules can be tested without a
// ThunderBridge.

/// Which Symphony I/O a page or a command is for.
public enum DeviceUnit: Int, CaseIterable, Sendable, Identifiable, Hashable {
    /// The unit on ThunderBridge port 1 (channels 1-32). The only unit
    /// everywhere else (USB, 32 channels, converters).
    case a = 0
    /// The unit on ThunderBridge port 2 (channels 33-64), only while 64
    /// channels run.
    case b = 1

    public var id: Int { rawValue }

    /// The port byte of the driver's vendor command and read
    /// (`SymphonyVendorCommandInput.port`): 0 for port 1, 1 for port 2.
    public var portByte: UInt8 { UInt8(rawValue) }

    /// "Unit A" / "Unit B".
    public var name: String { self == .a ? "Unit A" : "Unit B" }

    /// The ThunderBridge port the unit is on, as printed on the card.
    public var portName: String { self == .a ? "Port 1 (channels 1–32)" : "Port 2 (channels 33–64)" }
}

/// What the driver reports about unit B (selector 11), without the transport.
public struct SecondUnitInfo: Sendable, Equatable {
    /// Unit B's two option-board slots. `.none` for a slot whose read failed:
    /// check `slotValid` before calling that knowledge.
    public let slot1: IOCardType
    public let slot2: IOCardType
    /// Whether each slot's type was read from the unit.
    public let slotValid: [Bool]
    /// Whether each read slot's raw type is one the app knows. A type it does
    /// not know is shown as no board (`slot1`/`slot2` `.none`), but it is not
    /// knowledge of an empty slot: the driver keeps its card-by-card tables
    /// for it (`SymphonyAnalogFirstApplies`), see ``channelOrderSlot1``.
    public let slotTypeKnown: [Bool]
    /// The letter the unit keeps (0x37), raw. 0 or 0xFF when it has none.
    public let prefixByte: UInt8
    /// The clock source the driver set (3 = Loop Sync; 2 = Word Clock from older builds).
    public let clockSource: UInt8
    /// Bit 0: the set-up completed (the unit unlocked after it). Other bits
    /// identify a mandatory ConfigureUnitB stage that failed.
    public let setupFlags: UInt32
    /// Messages to unit B that failed since the driver started.
    public let txErrors: UInt32

    public static let clockSourceWordClock: UInt8 = 2
    public static let clockSourceLoopSync: UInt8 = 3

    public init(slot1: IOCardType, slot2: IOCardType, slotValid: [Bool] = [true, true],
                slotTypeKnown: [Bool] = [true, true],
                prefixByte: UInt8 = 0, clockSource: UInt8 = SecondUnitInfo.clockSourceLoopSync,
                setupFlags: UInt32 = 1, txErrors: UInt32 = 0) {
        self.slot1 = slot1
        self.slot2 = slot2
        self.slotValid = slotValid.count == 2 ? slotValid : [true, true]
        self.slotTypeKnown = slotTypeKnown.count == 2 ? slotTypeKnown : [true, true]
        self.prefixByte = prefixByte
        self.clockSource = clockSource
        self.setupFlags = setupFlags
        self.txErrors = txErrors
    }

    /// From the driver's raw bytes. A board type the app does not know is
    /// shown as no board.
    public init(boardType: [UInt8], boardValid: [UInt8], prefix: UInt8, clockSource: UInt8,
                setupFlags: UInt32, txErrors: UInt32) {
        func card(_ i: Int) -> IOCardType {
            guard i < boardType.count, i < boardValid.count, boardValid[i] != 0 else { return .none }
            return IOCardType(rawValue: boardType[i]) ?? .none
        }
        self.init(slot1: card(0), slot2: card(1),
                  slotValid: [0, 1].map { $0 < boardValid.count && boardValid[$0] != 0 },
                  slotTypeKnown: [0, 1].map { $0 < boardType.count && IOCardType(rawValue: boardType[$0]) != nil },
                  prefixByte: prefix, clockSource: clockSource,
                  setupFlags: setupFlags, txErrors: txErrors)
    }

    /// Slot 1's card as the driver orders unit B's host channels from it:
    /// nil while the slot is unread or its raw type is unknown, where the
    /// driver keeps the card-by-card tables (`SymphonyAnalogFirstApplies`).
    public var channelOrderSlot1: IOCardType? { slotValid[0] && slotTypeKnown[0] ? slot1 : nil }
    /// Slot 2's counterpart of ``channelOrderSlot1``.
    public var channelOrderSlot2: IOCardType? { slotValid[1] && slotTypeKnown[1] ? slot2 : nil }

    /// The set-up the driver sends when 64 channels start went through.
    public var setupComplete: Bool { setupFlags & 1 != 0 }

    /// The unit's own letter, or nil when it keeps none.
    public var prefixLetter: String? {
        (0x41...0x5A).contains(prefixByte) ? String(UnicodeScalar(prefixByte)) : nil
    }

    /// The letter unit B's channels are named with: its own, or the letter
    /// after unit A's when it has none, 'A' after 'Z' (as the driver names
    /// channels 33-64).
    public func prefix(after unitAPrefix: String) -> String {
        if let prefixLetter { return prefixLetter }
        guard let ascii = unitAPrefix.first?.asciiValue, ascii >= 0x41, ascii <= 0x5A else { return "B" }
        return ascii == 0x5A ? "A" : String(UnicodeScalar(ascii + 1))
    }

    /// Unit B's card layout, from its own board types. Unknown until a slot
    /// was read.
    public func layout(naming: CardLayout.ChannelNaming = CardLayout.ChannelNaming()) -> CardLayout {
        CardLayout(slot1: slot1, slot2: slot2,
                   isKnown: slotValid.contains(true)
                       && CardLayout.readingsDescribeAUnit(slot1: slot1, slot2: slot2),
                   fallbackChannelCount: 32, naming: naming)
    }

    /// The clock source as Device Info shows it.
    public var clockSourceName: String {
        switch clockSource {
        case 1: return "Internal"
        case Self.clockSourceLoopSync: return "Loop Sync"
        case Self.clockSourceWordClock: return "Word Clock"
        case 0: return "Not set"
        default: return "Source \(clockSource)"
        }
    }

    /// One line per fact, for Device Info's copied text and the Diagnostics report.
    public func reportLines(unitAPrefix: String) -> [String] {
        func slot(_ card: IOCardType, _ valid: Bool) -> String { valid ? card.productName : "not read" }
        return [
            "Unit B (port 2): Symphony I/O",
            "Unit B IOBoard 1: \(slot(slot1, slotValid[0]))",
            "Unit B IOBoard 2: \(slot(slot2, slotValid[1]))",
            "Unit B prefix: \(prefix(after: unitAPrefix))" + (prefixLetter == nil ? " (none kept on the unit)" : ""),
            "Unit B clock: \(clockSourceName)",
            "Unit B set-up: \(setupComplete ? "complete" : "incomplete (0x" + String(setupFlags, radix: 16) + ")")",
            "Unit B message errors: \(txErrors)",
        ]
    }
}

/// Help's answer for two units, after `PortSelection.helpText`. The cabling
/// follows Apogee's Symphony I/O User's Guide ("2 Symphony I/Os together with
/// Symphony 64 Thunderbridge or PCI", p. 87) and the ThunderBridge Quick Start
/// Guide ("Connecting Multiple Apogee Interfaces", pp. 17-18); the clock line
/// describes the default and the original's System Setup clocking choices,
/// which Maestro keeps in Device Settings › Clock.
public enum SecondUnitHelp {
    public static let lines = [
        "**Cabling.** Connect the main port of each Symphony I/O to the ThunderBridge with a PC-32 cable: "
            + "the first unit to port 1 (channels 1–32), the second to port 2 (channels 33–64). "
            + "Apogee allows one Symphony I/O per port, so two is the most. Set both units to Symphony mode "
            + "(SYM AIM) on their front panels.",
        "**Clock.** In Device Settings › Clock, Use Loop Sync is on by default, with Unit A as Loop Sync Master. "
            + "Connect the units' Loop Sync BNC connectors (Out to In, and back). You can choose either unit "
            + "as master and set its clock source on that unit's page. With Use Loop Sync off, unit B uses "
            + "Word Clock and unit A's Loop Sync output is off.",
        "**In Maestro.** Once 64 channels run and the driver has set up the second unit, Input, Output, "
            + "Input Routing and Device Settings show a **Unit A / Unit B** picker at the top; each page then "
            + "shows and sets the chosen unit. The Mixer shows both units' inputs, the second unit's after the "
            + "first's and named with its prefix letter. Output Routing has no picker: it is one grid for the "
            + "card, with the first unit's outputs and then the second unit's, each block headed by its unit, "
            + "and any software output pair or mixer can go to any output on either unit (scroll sideways to "
            + "see them all). Its presets and Reset Routing cover both units. Software 33–64 play on the "
            + "second unit until you route them elsewhere.",
        "The clock master's source cannot be Loop Sync. Configured Role and Clock Status show the "
            + "selected topology and measured lock separately.",
    ]
}

/// When the Unit A / Unit B picker is shown.
public enum UnitPicker {
    /// Only on ThunderBridge, only for a Symphony I/O (not converters), and only
    /// while the driver reports unit B configured, which it does only while
    /// 64 channels run. A device that publishes the port selection must also
    /// say 64 channels.
    public static func isVisible(transport: TransportType?, unitB: SecondUnitInfo?,
                                 portSelection: PortSelection?, convertersPresent: Bool) -> Bool {
        guard transport == .thunderbolt, unitB != nil, !convertersPresent else { return false }
        if let portSelection, portSelection != .ports1And2 { return false }
        return true
    }

    /// The pages that belong to one unit and follow the picker. The Mixer and
    /// Output Routing are the card's and show both units at once. Input
    /// Routing edits the chosen unit's own P2P table.
    public static func isPerUnit(page: String) -> Bool {
        ["Input", "Output", "Input Routing", "Device Settings"].contains(page)
    }

    /// The picker's segment label: the unit and its prefix letter.
    public static func label(_ unit: DeviceUnit, prefix: String) -> String {
        "\(unit.name) (\(prefix))"
    }
}

/// The card mixer while 64 channels run with unit B: unit A's input strips,
/// then unit B's (mixer channels 32-63, which are unit B's XLink RX 0-31).
/// The original's card mixer covered 64 inputs
/// (`og_source/maestrolink/Software/SymphonyPCIeCardMixer.cpp`).
public enum TwoUnitMixer {
    /// Mixer channel of unit B's first input.
    public static let unitBChannelBase = 32

    /// Prefix a channel name exactly as the driver does: unavailable channels
    /// remain the bare `N.A.` marker, while a real board name carries the
    /// peripheral's own prefix.  Keep this in one place so mixer strips and
    /// routing grids cannot drift apart when board/rate settings change.
    public static func unitChannelName(_ name: String, prefix: String) -> String {
        name == CardLayout.notApplicable ? name : "\(CardLayout.peripheralPrefix(prefix)) \(name)"
    }

    /// Unit B's hardware-input strips, moved into the card mixer's 32–63
    /// channel range.  The underlying layout supplies the board, optical and
    /// sample-rate names; this method supplies only the unit prefix.
    public static func unitBChannels(layout: CardLayout, prefix: String,
                                     inputNumbers: [Int?]? = nil) -> [CardLayout.MixerChannel] {
        layout.mixerChannels.enumerated().map { index, channel in
            let hardwareIndex: Int
            if let inputNumbers, index < inputNumbers.count,
               let number = inputNumbers[index] {
                hardwareIndex = unitBChannelBase + number
            } else if inputNumbers != nil {
                hardwareIndex = -1
            } else {
                hardwareIndex = unitBChannelBase + channel.hardwareIndex
            }
            return CardLayout.MixerChannel(label: unitChannelName(channel.label, prefix: prefix),
                                           hardwareIndex: hardwareIndex,
                                           boardIndex: channel.boardIndex, channelOnBoard: channel.channelOnBoard)
        }
    }

    /// Add a unit prefix to routing-column pair names while preserving the
    /// routing byte and board metadata.  `N.A.` remains unprefixed, matching
    /// Core Audio's channel names and the original Maestro grids.
    public static func unitRoutingColumns(_ columns: [CardLayout.RoutingColumn], prefix: String)
        -> [CardLayout.RoutingColumn] {
        columns.map { column in
            let named = unitChannelName(column.stereoName, prefix: prefix)
            let header = CardLayout.headerLines(named)
            return CardLayout.RoutingColumn(type: header.type, channels: header.channels,
                                            boardIndex: column.boardIndex,
                                            isDigital: column.isDigital,
                                            routingByte: column.routingByte)
        }
    }

    /// Unit B's input or output columns with the same naming rule used by its
    /// mixer strips.  This is also the entry point for B1a Input Routing.
    public static func unitBRoutingColumns(layout: CardLayout, prefix: String, isInput: Bool)
        -> [CardLayout.RoutingColumn] {
        unitRoutingColumns(isInput ? layout.inputRoutingColumns : layout.outputRoutingColumns,
                           prefix: prefix)
    }

    /// Every hardware-input strip: unit A's, then unit B's with their
    /// channel IDs moved up by 32. Unit B's labels carry its prefix letter so
    /// the two "Line 1" strips can be told apart; unit A's keep theirs.
    public static func channels(unitA: CardLayout, unitB: CardLayout?, prefixB: String) -> [CardLayout.MixerChannel] {
        let a = unitA.mixerChannels
        guard let unitB else { return a }
        return a + unitBChannels(layout: unitB, prefix: prefixB)
    }

    /// Software Return source pairs: with one unit 8 (USB, and the card driver
    /// before build 144, which takes 0-7) or 16 (the card driver from 144,
    /// every pair of the port, as the original); 32 (0-31, the 64 playback
    /// channels) with unit B.
    public static func softwareReturnPairCount(unitBActive: Bool, oneUnitPairs: Int = 8) -> Int {
        unitBActive ? 32 : oneUnitPairs
    }

    /// Pairs with one unit for a connection: 16 on the card from driver 144.
    public static func oneUnitPairs(card: Bool, build: ServingDextBuild?) -> Int {
        if card, case .build(let n)? = build, n >= 144 { return 16 }
        return 8
    }

    /// The Software Return source to show for a saved one: a source beyond
    /// the pairs on offer (DAW 17-64 saved while unit B was there) shows as 1-2.
    public static func shownSoftwareReturnSource(_ saved: UInt32, pairCount: Int) -> UInt32 {
        saved < UInt32(max(pairCount, 0)) ? saved : 0
    }

    /// Whether a saved Software Return source must be put back to 1-2: it is
    /// beyond the one-unit pairs (0-7) and unit B is known to be gone, as the
    /// driver resets it on leaving 64 channels. Not while unit B may still
    /// appear (at launch, before the driver was asked).
    public static func resetsSavedSoftwareReturn(_ saved: UInt32, unitBKnownAbsent: Bool) -> Bool {
        unitBKnownAbsent && saved >= UInt32(softwareReturnPairCount(unitBActive: false))
    }

    /// What to save for a mixer's Software Return source: the one shown,
    /// except that a saved DAW 17-64 shown as 1-2 (unit B not on the Mixer
    /// yet) stays saved until unit B is known to be gone.
    public static func sourceToSave(shown: UInt32, saved: UInt32, pairCount: Int) -> UInt32 {
        isHeld(shown: shown, saved: saved, pairCount: pairCount) ? saved : shown
    }

    /// A saved DAW 17-64 source shown as 1-2 while unit B is not on the Mixer
    /// (yet): neither saved over nor sent to the card, which keeps its own.
    public static func isHeld(shown: UInt32, saved: UInt32, pairCount: Int) -> Bool {
        shown == 0 && saved >= UInt32(max(pairCount, 0))
    }

    /// "1-2", "3-4", ... "63-64".
    public static func softwareReturnName(_ source: UInt32) -> String {
        "\(source * 2 + 1)-\(source * 2 + 2)"
    }

    public static func softwareReturnMenuName(_ source: UInt32) -> String {
        "Out \(source * 2 + 1)-\(source * 2 + 2)"
    }
}

/// Output Routing while 64 channels run with unit B. Rows are the 32 DAW
/// playback pairs, then Mixer 1 and Mixer 2; unit B's outputs follow unit A's
/// as extra columns. Unit A's saved routes keep their single-unit row numbers
/// (DAW pairs, then the two mixers right after them), so nothing saved for
/// unit A changes meaning; additional DAW pairs follow those two saved mixer rows.
public enum TwoUnitOutputRouting {
    /// DAW pairs at 64 channels.
    public static let dawPairCount = SymphonyRoutingModel.hostChannelCount / 2
    /// Grid rows of the mixers at 64 channels.
    public static var mixer1Row: Int { dawPairCount }
    public static var mixer2Row: Int { dawPairCount + 1 }
    public static var rowCount: Int { dawPairCount + 2 }

    /// A row of unit A's saved table (its DAW pairs, then two mixers) on the
    /// 64-channel grid. Nil for a row that table cannot hold.
    public static func gridRow(unitARow row: Int, unitAPairs: Int) -> Int? {
        if row >= 0 && row < unitAPairs { return row }
        if row == unitAPairs { return mixer1Row }
        if row == unitAPairs + 1 { return mixer2Row }
        if row >= unitAPairs + 2 && row < rowCount { return row - 2 }
        return nil
    }

    /// The inverse, retaining the existing saved mixer rows before the extra DAW pairs.
    public static func unitARow(gridRow row: Int, unitAPairs: Int) -> Int? {
        if row >= 0 && row < unitAPairs { return row }
        if row == mixer1Row { return unitAPairs }
        if row == mixer2Row { return unitAPairs + 1 }
        if row >= unitAPairs && row < dawPairCount { return row + 2 }
        return nil
    }

    /// Both ports may select every playback pair and both card mixers.
    /// Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:1173-1187.
    public static func unitAAccepts(gridRow row: Int, unitAPairs: Int) -> Bool {
        unitARow(gridRow: row, unitAPairs: unitAPairs) != nil
    }

    /// Playback pair in unit A's saved numbering; extra pairs are unavailable
    /// at 32 channels, and never alias the existing mixer rows.
    public static func playbackPair(unitARow row: Int, unitAPairs: Int, unitBActive: Bool) -> Int? {
        if row >= 0 && row < unitAPairs { return row }
        guard unitBActive, row >= unitAPairs + 2, row < rowCount else { return nil }
        return row - 2
    }

    /// The card's start-up routing for unit B: unit B output channel c
    /// (XLink TX 32 + c) plays DAW channel 33 + c (`Port2ProgramRouting`:
    /// output n <- PCI OUT 64 + n). Returns the DAW pair row for an output
    /// pair whose left channel is c.
    public static func defaultRow(unitBChannel c: Int) -> Int {
        (unitBChannelBaseDAW + c) / 2
    }

    /// DAW channel (0-based) unit B's first output plays by default.
    public static let unitBChannelBaseDAW = SymphonyRoutingModel.Port.two.cardBase

    /// The row played by each unit B output column. An incomplete or empty
    /// saved table inherits the card's default route for unclaimed outputs.
    /// A complete table leaves unclaimed outputs disabled. An invalid saved row
    /// claims its columns but has no route, matching the replay's fail-closed
    /// handling of rows outside the valid source range.
    public static func resolvedRows(saved: [Int: Set<Int>], columns: [CardLayout.RoutingColumn]) -> [Int?] {
        let complete = (0..<rowCount).allSatisfy { saved[$0] != nil }
        return columns.enumerated().map { index, column -> Int? in
            if let owner = saved.keys.sorted().last(where: { saved[$0]?.contains(index) == true }) {
                return (0..<rowCount).contains(owner) ? owner : nil
            }
            // A unit's outputs are destination bytes 32-63: board 0, then board 1.
            let channel = Int(column.routingByte) - outputDestinationBase
            guard !complete, (0..<SymphonyRoutingModel.channelsPerPort).contains(channel) else { return nil }
            return defaultRow(unitBChannel: channel)
        }
    }

    /// Routing bytes as the device layer names them (`SymphonyIORoutingAddress`:
    /// `ioBoard0Base`, `mixer0Base`, `mixer1Base`, `none`); a test checks they agree.
    public static let outputDestinationBase = 32
    public static let mixer0SourceBase: UInt8 = 64
    public static let mixer1SourceBase: UInt8 = 96
    public static let noSource: UInt8 = 236

    /// The destination-to-source table used by replay and the unit B meter map.
    public static func table(saved: [Int: Set<Int>], columns: [CardLayout.RoutingColumn]) -> [UInt8: UInt8] {
        var table: [UInt8: UInt8] = [:]
        let rows = resolvedRows(saved: saved, columns: columns)
        for (index, column) in columns.enumerated() {
            let destination = column.routingByte
            guard let row = rows[index] else {
                table[destination] = noSource
                table[destination &+ 1] = noSource
                continue
            }
            let source: (Int) -> UInt8? = { side in
                if row < dawPairCount { return UInt8(row * 2 + side) }
                if row == mixer1Row { return mixer0SourceBase &+ UInt8(side) }
                if row == mixer2Row { return mixer1SourceBase &+ UInt8(side) }
                return nil
            }
            table[destination] = source(0) ?? noSource
            table[destination &+ 1] = source(1) ?? noSource
        }
        return table
    }
}

/// Debug only: the second-unit simulation's launch argument.
public enum SecondUnitSimulation {
    public static let key = "MaestroSimulateSecondUnit"

    /// "analogADDA16+optical", "16x16", "8x8+A16"... Each `+`-separated token
    /// is a card (`CardSimulation.parseCard`); "16x16" is a 16x16 alone.
    public static func parse(_ value: String) -> SecondUnitInfo? {
        let tokens = value.split(separator: "+").map { String($0).trimmingCharactersInSimpleWhitespace() }
        func card(_ token: String) -> IOCardType? {
            switch token.lowercased() {
            case "16x16": return .analogADDA16
            case "8x8": return .optical
            case "a16", "ad16": return .analogAD16
            case "d16", "da16": return .analogDA16
            default: return CardSimulation.parseCard(token)
            }
        }
        guard let first = tokens.first, let slot1 = card(first) else { return nil }
        let slot2 = tokens.count > 1 ? card(tokens[1]) : IOCardType.none
        guard let slot2, (try? CardConfiguration(slot1: slot1, slot2: slot2).validate()) != nil else { return nil }
        return SecondUnitInfo(slot1: slot1, slot2: slot2)
    }

    public static func request(defaults: UserDefaults = .standard) -> SecondUnitInfo? {
        defaults.string(forKey: key).flatMap(parse)
    }
}
