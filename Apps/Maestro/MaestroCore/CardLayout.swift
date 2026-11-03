/// The channel layout a pair of option boards actually presents to the user.
///
/// # Why this type exists
///
/// `IOCardType` carries **two different channel vocabularies** and they are not
/// interchangeable:
///
/// * `*PairsPerBoard` — the fixed 16-channel XLink **bus slice** a slot owns.
///   Always 8 pairs for any installed board, whatever the board is. Correct for
///   routing-byte arithmetic, wrong for anything a user reads.
/// * `analog*Channels` / `digital*Channels` — what the module's converters
///   physically contribute. Zero for an 8MicPre, which is a delegate module.
///
/// Every view in the app used to reach for the first one, so an 8MicPre — whose
/// `default:` branch yields 8 pairs — produced eight analog strips, eight mixer
/// strips, eight routing columns and eight headphone sources that do not exist.
/// On a 16 Analog In + 8MicPre unit that meant sixteen *analog output* strips on
/// a pair of cards with zero analog outputs.
///
/// `CardLayout` is the single place that turns a card pair into user-facing
/// counts. Views ask it; nothing else does the arithmetic.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO.cpp:955-961` →
/// `SymphonyIO_IOBoard.cpp:606-627` (MicPre delegates onto the other board);
/// do **not** copy `SymphonyIO.cpp:975-978`, which adds 16 in/out for every
/// non-None board — that is bus allocation, not channel count.
/// `Docs/issue-1-research.md` and `Docs/Roadmap.md` carry the long form.
public struct CardLayout: Sendable, Equatable {

    /// Primary slot ("IOBoard 1", `0xA1` wIndex 0).
    public let slot1: IOCardType
    /// Secondary slot ("IOBoard 2", `0xA1` wIndex 1). The only slot an 8MicPre
    /// can occupy.
    public let slot2: IOCardType

    /// Whether the board types come from an actual reading (detected, cached or
    /// simulated).
    ///
    /// `false` means "nothing read yet", which is **not** the same as "no cards
    /// installed". An unknown layout falls back to `fallbackChannelCount` strips
    /// so the pages are not blank while the `0xA1` reads are in flight; a *known*
    /// empty slot contributes nothing at all, which is what stops a click landing
    /// on a phantom routing column.
    public let isKnown: Bool

    /// Channel count to present while the layout is unknown — the USB/TB mode's
    /// channel count.
    public let fallbackChannelCount: Int

    public init(
        slot1: IOCardType = .none,
        slot2: IOCardType = .none,
        isKnown: Bool = true,
        fallbackChannelCount: Int = 16
    ) {
        self.slot1 = slot1
        self.slot2 = slot2
        self.isKnown = isKnown
        self.fallbackChannelCount = fallbackChannelCount
    }

    /// Build a layout from a validated `CardConfiguration`.
    public init(configuration: CardConfiguration, fallbackChannelCount: Int = 16) {
        self.init(slot1: configuration.slot1, slot2: configuration.slot2,
                  isKnown: true, fallbackChannelCount: fallbackChannelCount)
    }

    // MARK: - Saved-state scope

    /// Identifier that scopes per-channel saved state (input/output strips,
    /// mixer faders) to THIS card pair.
    ///
    /// Per-channel state used to be stored under one global key, so a 24-strip
    /// configuration was restored into a 16-strip one after a module swap
    /// (or under card simulation). Keying by layout keeps each card pair's
    /// settings separate. `nil` while the layout is unknown, in which case the
    /// unscoped legacy key is used.
    public var savedStateScope: String? {
        guard isKnown else { return nil }
        return "\(slot1.caseName)+\(slot2.caseName)"
    }

    /// The two slots in order, so callers can iterate without repeating the pair.
    public var slots: [IOCardType] { [slot1, slot2] }

    /// The card in `index` (0 = primary, 1 = secondary).
    public func card(atSlot index: Int) -> IOCardType { index == 0 ? slot1 : slot2 }

    /// True when at least one module is installed (or nothing is known yet).
    public var hasAnyCard: Bool { !isKnown || slot1 != .none || slot2 != .none }

    // MARK: - Analog channel strips

    /// Analog INPUT strips to draw. An 8MicPre adds none — its preamps sit in
    /// front of the *host* board's analog inputs and are already counted there.
    public var analogInputStripCount: Int {
        guard isKnown else { return fallbackChannelCount }
        return slot1.analogInputChannels + slot2.analogInputChannels
    }

    /// Analog OUTPUT strips to draw.
    public var analogOutputStripCount: Int {
        guard isKnown else { return fallbackChannelCount }
        return slot1.analogOutputChannels + slot2.analogOutputChannels
    }

    /// The card that owns a 0-based analog input strip.
    public func cardForAnalogInputStrip(_ index: Int) -> IOCardType {
        guard isKnown else { return .none }
        return index < slot1.analogInputChannels ? slot1 : slot2
    }

    /// The card that owns a 0-based analog output strip.
    public func cardForAnalogOutputStrip(_ index: Int) -> IOCardType {
        guard isKnown else { return .none }
        return index < slot1.analogOutputChannels ? slot1 : slot2
    }

    // MARK: - Digital stereo pairs

    /// One digital (AES / ADAT) stereo pair on one board.
    public struct DigitalPair: Sendable, Equatable {
        /// User-facing label, e.g. `"ADAT 1/2"`. Numbered continuously across
        /// the whole device, per Apogee's own stream naming.
        public let label: String
        /// 0 = primary slot, 1 = secondary slot.
        public let boardIndex: Int
        /// 0-based pair index within that board's digital region.
        public let pairOnBoard: Int

        public init(label: String, boardIndex: Int, pairOnBoard: Int) {
            self.label = label
            self.boardIndex = boardIndex
            self.pairOnBoard = pairOnBoard
        }

        /// Index of this pair's LEFT channel in the app's digital meter arrays,
        /// or `nil` when the meter payload carries no word for it.
        ///
        /// The arrays are `[board 0 digital 0-7][board 1 digital 0-7][spare]`,
        /// i.e. only the first four digital pairs of each board are metered —
        /// `MeterSlotMap.digitalWordIndices` returns at most 8 words per board.
        /// A card with eight digital pairs (AD16/DA16) therefore has pairs 5-8
        /// unmetered; returning `nil` is what keeps the view from reading the
        /// other board's meters — or running off the end of a 24-entry array.
        public var meterIndex: Int? {
            guard pairOnBoard < CardLayout.meteredDigitalPairsPerBoard else { return nil }
            return boardIndex * (CardLayout.meteredDigitalPairsPerBoard * 2) + pairOnBoard * 2
        }
    }

    /// Digital pairs the meter payload can actually carry, per board.
    /// Evidence: `MeterSlotMap.digitalWordIndices` caps at 8 words per board.
    public static let meteredDigitalPairsPerBoard = 4

    /// Digital INPUT stereo pairs across both boards, board 1 first.
    public var digitalInputPairs: [DigitalPair] { digitalPairs(isInput: true) }

    /// Digital OUTPUT stereo pairs across both boards, board 1 first.
    public var digitalOutputPairs: [DigitalPair] { digitalPairs(isInput: false) }

    private func digitalPairs(isInput: Bool) -> [DigitalPair] {
        guard isKnown else { return [] }
        var pairs: [DigitalPair] = []
        // AES and ADAT are different plug types and each is numbered from 1
        // across the device, the way the daemon names its streams
        // (`SymphonyIO_Stream.cpp:485-495`, `OpticalOut_SymphonyIO_Stream.cpp:132-148`).
        var channel: [String: Int] = [:]
        for (boardIndex, card) in slots.enumerated() {
            let count = isInput ? card.digitalInputPairsForUI : card.digitalOutputPairsForUI
            for pair in 0..<count {
                let label = card.digitalLabel(forPair: pair)
                let number = channel[label, default: 1]
                pairs.append(DigitalPair(
                    label: "\(label) \(number)/\(number + 1)",
                    boardIndex: boardIndex,
                    pairOnBoard: pair))
                channel[label] = number + 2
            }
        }
        return pairs
    }

    // MARK: - S/PDIF coax

    /// Whether this slot's module carries the S/PDIF coax RCA pair.
    ///
    /// Every I/O module does — 8x8, 16x16, A16 IP/OP and 2x6 all show the
    /// `SPDIF IN`/`OUT` RCA jacks in the user guide (pp. 10-12). The 8MicPre does
    /// not: it has only instrument jacks and insert DB-25s (p. 13).
    ///
    /// This is deliberately **not** gated on the board having digital *channels*.
    /// A 16x16 has none, and gating the whole DIGITAL column on digital pairs is
    /// what used to hide S/PDIF Replace and S/PDIF Mirrors from a 16x16 owner —
    /// the only digital I/O that card has.
    public func hasSPDIF(slot index: Int) -> Bool {
        guard isKnown else { return true }
        return card(atSlot: index).hasSPDIFCoax
    }

    /// Whether either slot offers S/PDIF coax.
    public var hasSPDIF: Bool { hasSPDIF(slot: 0) || hasSPDIF(slot: 1) }

    /// Whether the Input/Output pages should draw their DIGITAL column at all.
    public func showsDigitalSection(isInput: Bool) -> Bool {
        if hasSPDIF { return true }
        return !(isInput ? digitalInputPairs : digitalOutputPairs).isEmpty
    }

    /// One entry in an S/PDIF Replace / Mirror popup.
    public struct SPDIFOption: Sendable, Equatable {
        public let id: UInt32
        public let name: String
        public init(id: UInt32, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// S/PDIF Coax Replace (input) / Mirror (output) options for one slot.
    ///
    /// `SymphonyIOBoardSPDIFCoaxReplace` (`SymphonyIOVendorSpecific.h:937-948`)
    /// encodes `Off` plus **eight** values, and its own comment at `:936` warns
    /// that the `Analog…`/`Digital…` names "dont make sense for certain boards
    /// (e.g. AD16 which should have analog 1 through 16 instead of digital)".
    /// The values are therefore pair indices 1-8 within the board's own
    /// 16-channel slice; the analog/digital naming is just the 8x8 card's split.
    /// So the label comes from the installed card, and a card that supplies
    /// fewer than eight pairs offers fewer than eight options.
    ///
    /// The command is per board (`nValue` = board index), so slot 2 gets its own
    /// list; channel numbers stay continuous across the device, matching the
    /// strip labels.
    public func spdifOptions(slot index: Int, isInput: Bool) -> [SPDIFOption] {
        var options = [SPDIFOption(id: 0, name: "Off")]
        guard isKnown else {
            // Nothing read yet — offer the 8x8 card's shape, which is what the
            // enum was named after.
            for pair in 0..<4 {
                options.append(SPDIFOption(id: UInt32(pair + 1),
                                           name: "Analog \(pair * 2 + 1)-\(pair * 2 + 2)"))
            }
            for pair in 0..<4 {
                options.append(SPDIFOption(id: UInt32(pair + 5),
                                           name: "ADAT \(pair * 2 + 1)-\(pair * 2 + 2)"))
            }
            return options
        }

        let card = card(atSlot: index)
        guard card.hasSPDIFCoax else { return options }

        // Channel numbering continues from the other board when this is slot 2 —
        // per plug type, so an AES board does not inherit an optical board's
        // numbering.
        var analogChannel = 1
        // Per plug type, so the 2x6's AES pair and its optical pairs each number
        // from 1 (or continue slot 1's run of the same type).
        var digitalChannel: [String: Int] = [:]
        if index == 1 {
            analogChannel += isInput ? slot1.analogInputChannels : slot1.analogOutputChannels
            for label in ["AES", "ADAT"] {
                digitalChannel[label] = 1 + slot1.digitalChannelCount(label: label, isInput: isInput)
            }
        }

        let analogPairs = isInput ? card.analogInputPairsForUI : card.analogOutputPairsForUI
        let digitalPairs = isInput ? card.digitalInputPairsForUI : card.digitalOutputPairsForUI
        var id: UInt32 = 1
        for _ in 0..<analogPairs where id <= 8 {
            options.append(SPDIFOption(id: id, name: "Analog \(analogChannel)-\(analogChannel + 1)"))
            analogChannel += 2
            id += 1
        }
        for pair in 0..<digitalPairs where id <= 8 {
            let label = card.digitalLabel(forPair: pair)
            let number = digitalChannel[label, default: 1]
            options.append(SPDIFOption(id: id, name: "\(label) \(number)-\(number + 1)"))
            digitalChannel[label] = number + 2
            id += 1
        }
        return options
    }

    // MARK: - Low-latency mixer

    /// One mixer strip.
    public struct MixerChannel: Sendable, Equatable {
        public let label: String
        /// Mixer channel ID sent to the hardware (`0xB0`-`0xB3`
        /// `nValue[15:0]`). The daemon builds a **compacted** vector — one entry
        /// per channel that actually exists, each remembering its own
        /// (board, board channel) for the FPGA coefficients — so the ID is the
        /// strip's position in that vector, with no gap for an empty slot.
        /// Evidence: `SymphonyIOMixer::init`, `SymphonyIOMixer.cpp:121-172`.
        public let hardwareIndex: Int
        /// 0 = primary slot, 1 = secondary slot.
        public let boardIndex: Int

        public init(label: String, hardwareIndex: Int, boardIndex: Int = 0) {
            self.label = label
            self.hardwareIndex = hardwareIndex
            self.boardIndex = boardIndex
        }
    }

    /// The mixer's input strips: every input channel the installed cards actually
    /// provide.
    ///
    /// Order is **by plug type first, then by board**: all analog channels of
    /// board 1 then board 2, then all digital ones the same way. That is exactly
    /// how the daemon fills `m_InputChannelVector` — its outer loop walks
    /// `{Analog, AES3, Optical}` and its inner loop walks the boards
    /// ("set the order in which the mixer channels will be displayed by format
    /// (analog first, then digital)", `SymphonyIOMixer.cpp:142-152`) — and the
    /// index into that vector is the channel ID the `0xB0`-`0xB3` commands take.
    ///
    /// What was wrong was only the count: `totalPairsPerBoard * 2` is the XLink
    /// bus slice, a flat 16 per installed board, so a 16x16 + 8MicPre drew 32
    /// strips for 16 real channels.
    public var mixerChannels: [MixerChannel] {
        guard isKnown else {
            return (0..<min(fallbackChannelCount, 16)).map {
                MixerChannel(label: "Line \($0 + 1)", hardwareIndex: $0)
            }
        }
        var analog: [(label: String, board: Int)] = []
        var aes: [(label: String, board: Int)] = []
        var optical: [(label: String, board: Int)] = []
        var analogChannel = 1
        var digitalChannel: [String: Int] = [:]

        for (boardIndex, card) in slots.enumerated() {
            for _ in 0..<card.analogInputChannels {
                analog.append((label: "Line \(analogChannel)", board: boardIndex))
                analogChannel += 1
            }
        }
        for (boardIndex, card) in slots.enumerated() {
            for channelOnCard in 0..<card.digitalInputChannels {
                let label = card.digitalLabel(forChannel: channelOnCard)
                let number = digitalChannel[label, default: 1]
                let entry = (label: "\(label) \(number)", board: boardIndex)
                // AES3 is walked before Optical by the daemon's plug-type loop.
                if label == "AES" { aes.append(entry) } else { optical.append(entry) }
                digitalChannel[label] = number + 1
            }
        }
        return (analog + aes + optical).enumerated().map { index, entry in
            MixerChannel(label: entry.label, hardwareIndex: index, boardIndex: entry.board)
        }
    }

    /// Number of mixer input strips.
    public var mixerChannelCount: Int { mixerChannels.count }

    // MARK: - Routing grid columns

    /// One hardware column in a routing grid.
    public struct RoutingColumn: Sendable, Equatable {
        /// Column header type line, e.g. `"Line"` / `"ADAT"` / `"AES"`.
        public let type: String
        /// Column header channel line, e.g. `"1/2"`.
        public let channels: String
        /// 0 = primary slot, 1 = secondary slot.
        public let boardIndex: Int
        public let isDigital: Bool
        /// USB routing byte for this column's LEFT channel; the right channel is
        /// always `routingByte + 1`.
        public let routingByte: UInt8

        public init(type: String, channels: String, boardIndex: Int,
                    isDigital: Bool, routingByte: UInt8) {
            self.type = type
            self.channels = channels
            self.boardIndex = boardIndex
            self.isDigital = isDigital
            self.routingByte = routingByte
        }
    }

    /// Hardware INPUT columns for the Input Routing grid.
    public func routingColumns(
        isInput: Bool,
        ioBoard0Base: UInt8 = 32,
        ioBoard1Base: UInt8 = 48
    ) -> [RoutingColumn] {
        let bases = [ioBoard0Base, ioBoard1Base]

        // Per-board analog/digital pair counts. An unknown layout keeps the old
        // "assume a full bus slice" guess so the grid is populated while the
        // 0xA1 reads are in flight; a known-empty slot contributes nothing.
        func pairs(_ boardIndex: Int) -> (analog: Int, digital: Int) {
            let card = card(atSlot: boardIndex)
            guard isKnown else { return isInput ? (8, 0) : (0, 8) }
            guard card != .none else { return (0, 0) }
            return isInput
                ? (card.analogInputPairsForUI, card.digitalInputPairsForUI)
                : (card.analogOutputPairsForUI, card.digitalOutputPairsForUI)
        }

        let board = [pairs(0), pairs(1)]

        var analogColumns: [RoutingColumn] = []
        var digitalColumns: [RoutingColumn] = []
        var analogChannel = 1
        // AES and ADAT are separate plug types, each numbered from 1.
        var digitalChannel: [String: Int] = [:]

        for boardIndex in 0..<2 {
            for pair in 0..<board[boardIndex].analog {
                analogColumns.append(RoutingColumn(
                    type: "Line",
                    channels: "\(analogChannel)/\(analogChannel + 1)",
                    boardIndex: boardIndex,
                    isDigital: false,
                    routingByte: bases[boardIndex] + UInt8(pair * 2)))
                analogChannel += 2
            }
        }
        for boardIndex in 0..<2 {
            let card = card(atSlot: boardIndex)
            // Digital channels sit after that board's analog channels inside its
            // own 16-channel region.
            let digitalStart = board[boardIndex].analog * 2
            for pair in 0..<board[boardIndex].digital {
                let label = card != .none ? card.digitalLabel(forPair: pair) : "ADAT"
                let number = digitalChannel[label, default: 1]
                digitalColumns.append(RoutingColumn(
                    type: label,
                    channels: "\(number)/\(number + 1)",
                    boardIndex: boardIndex,
                    isDigital: true,
                    routingByte: bases[boardIndex] + UInt8(digitalStart + pair * 2)))
                digitalChannel[label] = number + 2
            }
        }
        // Column order is analog (both boards) then digital (both boards), which
        // is the order the grid has always drawn and the order the routing-byte
        // map assumes.
        return analogColumns + digitalColumns
    }

    /// Hardware columns for the input grid.
    public var inputRoutingColumns: [RoutingColumn] { routingColumns(isInput: true) }

    /// Hardware columns for the output grid.
    public var outputRoutingColumns: [RoutingColumn] { routingColumns(isInput: false) }

    // MARK: - Front-panel meter banks

    /// Whether a front-panel meter bank source has any channels on the installed
    /// cards.
    ///
    /// `raw` is `eMaestroEnum_MetersShowValues` (`og_source/generic/mAEstroTypes.h:17-39`):
    /// within each group of four, the order is analog out, analog in, digital out,
    /// digital in, and each group of four steps the channel octet by 8.
    public func hasMeterSource(_ raw: UInt32) -> Bool {
        guard isKnown else { return true }
        let octet = Int(raw) / 4
        let firstChannel = octet * 8 + 1
        let channels: Int
        switch Int(raw) % 4 {
        case 0:  channels = slot1.analogOutputChannels + slot2.analogOutputChannels
        case 1:  channels = slot1.analogInputChannels + slot2.analogInputChannels
        case 2:  channels = slot1.digitalOutputChannels + slot2.digitalOutputChannels
        default: channels = slot1.digitalInputChannels + slot2.digitalInputChannels
        }
        return channels >= firstChannel
    }

    /// Whether the slot's module has selectable optical ports.
    public func hasOpticalPorts(slot index: Int) -> Bool {
        guard isKnown else { return true }
        return card(atSlot: index).hasOpticalPorts
    }

    // MARK: - Headphone sources

    /// One headphone Output Source choice.
    public struct HeadphoneSource: Sendable, Equatable {
        public let id: UInt32
        public let name: String
        public init(id: UInt32, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Headphone Output Source options, as source IDs 0-15.
    ///
    /// `m_aHPSourceIDs[i] = boardIdx * 8 + startChannel/2 + i`
    /// (`SymphonyIO_Stream.cpp:264-276`), so board 0's output pairs are 0-7 and
    /// board 1's are 8-15, analog before digital within each board. A board that
    /// contributes no output pairs contributes no IDs: selecting a source ID in
    /// an empty XLink region silences the headphones while the popup keeps
    /// showing a confident selection.
    public var headphoneSources: [HeadphoneSource] {
        var sources: [HeadphoneSource] = []
        var analogChannel = 1
        var digitalChannel: [String: Int] = [:]
        if isKnown {
            for (boardIndex, card) in slots.enumerated() where card != .none {
                let base = UInt32(boardIndex * IOCardType.busPairsPerBoard)
                var pair: UInt32 = 0
                for _ in 0..<card.analogOutputPairsForUI {
                    sources.append(HeadphoneSource(
                        id: base + pair,
                        name: "Line \(analogChannel)-\(analogChannel + 1)"))
                    analogChannel += 2
                    pair += 1
                }
                for digitalPair in 0..<card.digitalOutputPairsForUI {
                    let label = card.digitalLabel(forPair: digitalPair)
                    let number = digitalChannel[label, default: 1]
                    sources.append(HeadphoneSource(
                        id: base + pair,
                        name: "\(label) \(number)-\(number + 1)"))
                    digitalChannel[label] = number + 2
                    pair += 1
                }
            }
        }
        if sources.isEmpty {
            // Nothing read yet (or a chassis with no modules): offer slot 0's
            // first four analog pairs so the popup is never empty. IDs 0-3 are
            // valid on every MKI card set that has analog outputs at all.
            sources = (0..<4).map {
                HeadphoneSource(id: UInt32($0), name: "Line \($0 * 2 + 1)-\($0 * 2 + 2)")
            }
        }
        return sources
    }
}
