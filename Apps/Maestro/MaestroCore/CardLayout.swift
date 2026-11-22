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

    /// A recognised older converter in place of a Symphony I/O, when the driver
    /// identified one. It has no option cards, so only the number of strips is
    /// taken from it; everything else stays on the unknown-layout behaviour.
    public let converter: ConnectedUnit?

    /// Every converter unit on both ports, when the driver identified them
    /// (or the older probe word did). Takes over from `converter` for the
    /// strip counts and gives the channels their names and bus slots.
    public let converters: ConverterSystem?

    /// What the channel names depend on besides the cards: the sample rate,
    /// each slot's optical format and each slot's S/PDIF Coax Replaces setting.
    /// See ``digitalChannelName(board:channelOnCard:isInput:)``.
    public let naming: ChannelNaming

    public init(
        slot1: IOCardType = .none,
        slot2: IOCardType = .none,
        isKnown: Bool = true,
        fallbackChannelCount: Int = 16,
        converter: ConnectedUnit? = nil,
        converters: ConverterSystem? = nil,
        naming: ChannelNaming = ChannelNaming()
    ) {
        self.slot1 = slot1
        self.slot2 = slot2
        self.isKnown = isKnown
        self.fallbackChannelCount = fallbackChannelCount
        self.converter = converter
        self.converters = converters
        self.naming = naming
    }

    /// The converter system the layout follows: only when no Symphony I/O
    /// cards are known and every unit that carries audio is one we know.
    public var converterLayout: ConverterSystem? {
        guard !isKnown, let converters, converters.layoutKnown else { return nil }
        return converters
    }

    /// A converter host channel's name (0-based), "A Line 1" or "N.A.". Nil
    /// unless the layout follows converters.
    public func converterChannelName(host: Int, isInput: Bool) -> String? {
        guard let system = converterLayout else { return nil }
        let names = system.hostChannelNames(input: isInput)
        return host >= 0 && host < names.count ? names[host] : nil
    }

    /// The live state Apogee's daemon named channels from. Unknown values name
    /// channels as the hardware starts: 44.1/48 kHz naming, ADAT/SMUX format,
    /// no coax replacement.
    public struct ChannelNaming: Sendable, Equatable {
        /// Current sample rate in Hz, nil when not known.
        public var sampleRate: Double?
        /// Per slot: true when the optical ports are set to S/PDIF, false for
        /// ADAT/SMUX, nil when not known or the slot has no optical ports.
        public var opticalIsSPDIF: [Bool?]
        /// Per slot: the S/PDIF Coax Replaces wire value (0 Off, 1-8 the pair
        /// replaced; `SymphonyIOVendorSpecific.h:940-951`).
        public var spdifReplace: [UInt32]

        /// App analog input settings, indexed by the unit's analog strip order.
        public var analogInputLevels: [AnalogInputLevel]
        public var analogInputLabels: [String]

        public init(sampleRate: Double? = nil,
                    opticalIsSPDIF: [Bool?] = [nil, nil],
                    spdifReplace: [UInt32] = [0, 0],
                    analogInputLevels: [AnalogInputLevel] = [],
                    analogInputLabels: [String] = []) {
            self.sampleRate = sampleRate
            self.opticalIsSPDIF = opticalIsSPDIF
            self.spdifReplace = spdifReplace
            self.analogInputLevels = analogInputLevels
            self.analogInputLabels = analogInputLabels
        }

        func isSPDIF(slot: Int) -> Bool { slot < opticalIsSPDIF.count && opticalIsSPDIF[slot] == true }
        func replace(slot: Int) -> UInt32 { slot < spdifReplace.count ? spdifReplace[slot] : 0 }
    }

    /// Whether a pair of slot readings describes an actual unit.
    ///
    /// Two empty slots are never knowledge, wherever the reading came from. A
    /// working Symphony I/O has at least one card, so "both empty" means the
    /// card-type read was not answered: a failed read, or a unit that is not a
    /// Symphony I/O at all (an AD-16X or DA-16X on a ThunderBridge does not
    /// speak the option-board command). Treating that pair as known drew zero
    /// output strips and an empty mixer, with no way back, because the pair was
    /// also cached. Unknown falls back to the generic layout instead.
    public static func readingsDescribeAUnit(slot1: IOCardType, slot2: IOCardType) -> Bool {
        slot1 != .none || slot2 != .none
    }

    // MARK: - Channel names

    /// The daemon's "not applicable" channel name: an optical channel that the
    /// current rate or format does not carry. The channel stays in every list;
    /// only its name changes (the device's channel count never does).
    public static let notApplicable = "N.A."

    /// The name of one channel on a board as Apogee's daemon gave it to Core
    /// Audio (`kAudioObjectPropertyElementName`), without the one-letter prefix.
    ///
    /// - An input pair the board's S/PDIF coax replaces is "SPDIF Cx n", n
    ///   numbered on from slot 1's coax (`SymphonyIO_IOBoard.cpp:1312-1349`,
    ///   reached from every input stream: `SymphonyIO_Stream.cpp:640-650`,
    ///   `AESIn_SymphonyIO_Stream.cpp:165-188`, `OpticalIn_SymphonyIO_Stream.cpp:170-182`).
    /// - AES is "AES n" at every rate; the double-wide 192 kHz mode is never
    ///   enabled (`AESIn_SymphonyIO_Stream.cpp:27, 95-122`).
    /// - Optical follows the format and the rate
    ///   (`OpticalIn_SymphonyIO_Stream.cpp:166-234`,
    ///   `OpticalOut_SymphonyIO_Stream.cpp:170-232`):
    ///   - S/PDIF, below 176.4 kHz: the first two channels of each eight-channel
    ///     port on inputs, the first two of the stream on outputs, are
    ///     "SPDIF Opt n"; the rest "N.A.".
    ///   - ADAT/SMUX, 88.2/96 kHz: "SMUX n" for the channels SMUX carries (all
    ///     of them on two-port cards, the first four on the 2x6's single port,
    ///     `Optical2x6Module_SymphonyIO_Streams.h:20-35`); the rest "N.A.".
    ///   - ADAT/SMUX, 44.1/48 kHz: "ADAT n".
    ///   - 176.4 kHz and up: "N.A.".
    ///   Numbers continue from slot 1's optical channels in the same direction.
    public func digitalChannelName(board: Int, channelOnCard channel: Int, isInput: Bool) -> String {
        let card = card(atSlot: board)
        let analog = isInput ? card.analogInputChannels : card.analogOutputChannels
        if let coax = coaxReplaceName(board: board, boardChannel: analog + channel, isInput: isInput) {
            return coax
        }
        let label = card.digitalLabel(forChannel: channel)
        let preceding = board == 1 ? slot1.digitalChannelCount(label: label, isInput: isInput) : 0
        let number = card.digitalChannelNumber(forChannel: channel)
        guard label == "ADAT" else { return "\(label) \(preceding + number)" }

        let rate = naming.sampleRate ?? 48000
        guard rate < 176400 else { return Self.notApplicable }
        let opticalChannels = card.digitalChannelCount(label: "ADAT", isInput: isInput)
        if naming.isSPDIF(slot: board) {
            // Inputs test against each 8-channel port, outputs against the
            // whole stream (`OpticalIn_...:187` vs `OpticalOut_...:188`).
            let period = isInput ? 8 : max(opticalChannels, 1)
            guard (number - 1) % period < 2 else { return Self.notApplicable }
            return "SPDIF Opt \(number % 8 + 2 * (number / 8) + preceding / 4)"
        }
        if rate > 48000 {
            let smux = card == .twoBySix ? opticalChannels / 2 : opticalChannels
            return number - 1 < smux ? "SMUX \(preceding + number)" : Self.notApplicable
        }
        return "ADAT \(preceding + number)"
    }

    /// The name of an analog channel, including the MicPre's input type and
    /// the user's label when supplied by the app.
    public func analogChannelName(board: Int, channelOnCard channel: Int, isInput: Bool) -> String {
        let preceding = board == 1
            ? (isInput ? slot1.analogInputChannels : slot1.analogOutputChannels) : 0
        let index = preceding + channel
        if isInput, naming.analogInputLabels.indices.contains(index),
           !naming.analogInputLabels[index].isEmpty {
            return naming.analogInputLabels[index]
        }
        if let coax = coaxReplaceName(board: board, boardChannel: channel, isInput: isInput) {
            return coax
        }
        if isInput, InputChannelLogic.micPreIsUsable(primary: slot1, secondary: slot2),
           InputChannelLogic.isMicPreBacked(number: index + 1, micPreInstalled: true),
           naming.analogInputLevels.indices.contains(index) {
            return InputChannelLogic.channelLabel(number: index + 1, level: naming.analogInputLevels[index])
        }
        return "Line \(index + 1)"
    }

    public func namingAnalogInputs(levels: [AnalogInputLevel], labels: [String]) -> Self {
        var names = naming
        names.analogInputLevels = levels
        names.analogInputLabels = labels
        return Self(slot1: slot1, slot2: slot2, isKnown: isKnown,
                    fallbackChannelCount: fallbackChannelCount, converter: converter,
                    converters: converters, naming: names)
    }

    /// "SPDIF Cx n" for an input channel the board's coax replaces. The
    /// replaced pair is board channels `(wire - 1) * 2` and the next, counted
    /// across the board's inputs analog first (`SymphonyIO_IOBoard.cpp:1319-1346`,
    /// whose menu ID is the wire value plus one).
    private func coaxReplaceName(board: Int, boardChannel: Int, isInput: Bool) -> String? {
        guard isInput, isKnown, card(atSlot: board).hasSPDIFCoax else { return nil }
        let wire = Int(naming.replace(slot: board))
        guard (1...8).contains(wire) else { return nil }
        let left = (wire - 1) * 2
        guard boardChannel == left || boardChannel == left + 1 else { return nil }
        let coaxBefore = board == 1 && slot1.hasSPDIFCoax ? 2 : 0
        return "SPDIF Cx \(coaxBefore + 1 + boardChannel - left)"
    }

    /// A pair's name from its two channel names, as Maestro built it
    /// (`og_source/maestro2/App/APUtilities.m:323-400`): "N.A." when both are
    /// N.A., "Function l/r" when both share a function, else "F l/G r".
    public static func stereoName(left: String, right: String) -> String {
        if left == notApplicable && right == notApplicable { return notApplicable }
        func split(_ name: String) -> (function: String, number: String) {
            guard let space = name.lastIndex(of: " ") else { return ("", name) }
            return (String(name[..<space]), String(name[name.index(after: space)...]))
        }
        let l = split(left), r = split(right)
        if !l.function.isEmpty && l.function == r.function { return "\(l.function) \(l.number)/\(r.number)" }
        return "\(left)/\(right)"
    }

    // MARK: - Peripheral prefix and software channel names

    /// The prefix letter the daemon used when the unit had none assigned:
    /// "A" for the first unit (`SymphonyIO.cpp:1245-1258`).
    public static let defaultPeripheralPrefix = "A"

    /// The prefix letter to show for a stored or read value: its first
    /// character when that is A-Z, else ``defaultPeripheralPrefix``.
    public static func peripheralPrefix(_ raw: String?) -> String {
        guard let first = raw?.first, let ascii = first.asciiValue,
              ascii >= 0x41, ascii <= 0x5A else { return defaultPeripheralPrefix }
        return String(first)
    }

    /// The prefix byte for vendor command 0x37, nil unless `raw` starts with A-Z.
    public static func peripheralPrefixByte(_ raw: String?) -> UInt8? {
        guard let ascii = raw?.first?.asciiValue, ascii >= 0x41, ascii <= 0x5A else { return nil }
        return ascii
    }

    /// Whether a channel or pair name is the daemon's "not applicable".
    public static func isNotApplicable(_ name: String) -> Bool { name == notApplicable }

    /// A host (software) channel pair's name as Maestro labelled it: the
    /// prefix letter, then the stereo name of the hardware pair it is routed
    /// from or to, "A Line 1/2"; a bare "N.A." when both channels are N.A.
    /// (`APUtilities.m:323-400`, from per-channel names "<prefix> <name>",
    /// e.g. `SymphonyIO_Stream.cpp:655`).
    public static func softwarePairName(hardwarePair stereo: String, prefix: String) -> String {
        if isNotApplicable(stereo) || stereo.isEmpty { return notApplicable }
        return "\(peripheralPrefix(prefix)) \(stereo)"
    }

    /// The software INPUT row labels for a routing grid: each row named after
    /// the hardware column routed to it (`routes[row]`), "N.A." when nothing
    /// is. Maestro bound each row to the host channels' Core Audio names
    /// (`APInputRoutingTabRowViewController.m:178-205`), which the daemon set
    /// to the routed hardware channel's (`SymphonyCard.cpp:828-866`), so a row
    /// follows its route, the rate, the optical format and Replaces.
    public static func softwareInputRowNames(rowCount: Int, routes: [Int: Int],
                                             columns: [RoutingColumn], prefix: String) -> [String] {
        (0..<max(0, rowCount)).map { row in
            guard let col = routes[row], col >= 0, col < columns.count else { return notApplicable }
            return softwarePairName(hardwarePair: columns[col].stereoName, prefix: prefix)
        }
    }

    /// The board output a ThunderBridge Mac output plays through by default
    /// (0-based `hostOutput`): slot 1 output n for Mac 1-16, slot 2 output
    /// n-16 for 17-32, the driver's fixed table (`SymphonyHostOutputBoardChannel`
    /// in `SymphonyChannelNames.h`). Nil past the 32.
    public static func thunderboltOutputBoardChannel(hostOutput: Int) -> (board: Int, channel: Int)? {
        guard (0..<32).contains(hostOutput) else { return nil }
        return (hostOutput / 16, hostOutput % 16)
    }

    /// The name of a board OUTPUT channel (0-15 across the card, analog
    /// first) without the prefix, nil when the card has no such output (an
    /// empty slot, a Mic Pre, past the card's outputs).
    public func outputChannelName(board: Int, channel: Int) -> String? {
        let card = card(atSlot: board)
        guard channel >= 0, channel < card.totalOutputChannels else { return nil }
        let analog = card.analogOutputChannels
        return channel < analog
            ? analogChannelName(board: board, channelOnCard: channel, isInput: false)
            : digitalChannelName(board: board, channelOnCard: channel - analog, isInput: false)
    }

    /// A ThunderBridge Mac output's Core Audio name as the driver publishes it
    /// (`SymphonyHostOutputName`): the prefix and the name of the board output
    /// at the same position, "A N.A." included; a bare "N.A." when the card
    /// has no output there. Nil when the layout is not known or past the 32
    /// (the driver publishes no name then). Fixed by position, a deliberate
    /// departure from the original, which followed each output's route.
    public func thunderboltOutputChannelName(hostOutput: Int, prefix: String) -> String? {
        guard isKnown, let at = Self.thunderboltOutputBoardChannel(hostOutput: hostOutput) else { return nil }
        guard let name = outputChannelName(board: at.board, channel: at.channel) else { return Self.notApplicable }
        return "\(Self.peripheralPrefix(prefix)) \(name)"
    }

    /// A ThunderBridge Output Routing software row's label (0-based `pair`,
    /// Mac outputs `2 * pair + 1` and `+ 2`): the pair name of the two board
    /// outputs at the same position, "A Line 1/2", a bare "N.A." when neither
    /// carries anything. It is the pair of the driver's two channel names.
    /// Nil when the layout is not known or past the 32 outputs.
    public func thunderboltOutputPairName(pair: Int, prefix: String) -> String? {
        guard isKnown,
              let left = Self.thunderboltOutputBoardChannel(hostOutput: pair * 2),
              Self.thunderboltOutputBoardChannel(hostOutput: pair * 2 + 1) != nil else { return nil }
        let l = outputChannelName(board: left.board, channel: left.channel) ?? Self.notApplicable
        let r = outputChannelName(board: left.board, channel: left.channel + 1) ?? Self.notApplicable
        return Self.softwarePairName(hardwarePair: Self.stereoName(left: l, right: r), prefix: prefix)
    }

    /// A stereo name split into the routing header's two lines.
    static func headerLines(_ stereo: String) -> (type: String, channels: String) {
        guard let space = stereo.lastIndex(of: " ") else { return (stereo, "") }
        return (String(stereo[..<space]), String(stereo[stereo.index(after: space)...]))
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
        if let system = converterLayout { return system.hostInputCount }
        if !isKnown, let channels = converter?.channels { return channels.inputs }
        guard isKnown else { return fallbackChannelCount }
        return slot1.analogInputChannels + slot2.analogInputChannels
    }

    /// Analog OUTPUT strips to draw.
    public var analogOutputStripCount: Int {
        if let system = converterLayout { return system.hostOutputCount }
        if !isKnown, let channels = converter?.channels { return channels.outputs }
        guard isKnown else { return fallbackChannelCount }
        return slot1.analogOutputChannels + slot2.analogOutputChannels
    }

    /// The card that owns a 0-based analog input strip.
    public func cardForAnalogInputStrip(_ index: Int) -> IOCardType {
        guard isKnown else { return .none }
        return index < slot1.analogInputChannels ? slot1 : slot2
    }

    /// "SPDIF Cx n" when the coax replaces this 0-based analog input strip,
    /// as the daemon renamed the channel (`SymphonyIO_IOBoard.cpp:1312-1349`,
    /// reached from the analog stream at `SymphonyIO_Stream.cpp:640-650`);
    /// nil otherwise.
    public func coaxNameForAnalogInputStrip(_ index: Int) -> String? {
        guard isKnown, index >= 0 else { return nil }
        let board = index < slot1.analogInputChannels ? 0 : 1
        let channel = board == 0 ? index : index - slot1.analogInputChannels
        guard channel < card(atSlot: board).analogInputChannels else { return nil }
        return coaxReplaceName(board: board, boardChannel: channel, isInput: true)
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
        // Named from the channel names, so AES and optical each number from 1
        // across the device and optical follows the rate and format.
        for (boardIndex, card) in slots.enumerated() {
            let count = isInput ? card.digitalInputPairsForUI : card.digitalOutputPairsForUI
            for pair in 0..<count {
                pairs.append(DigitalPair(
                    label: digitalPairName(board: boardIndex, pair: pair, isInput: isInput),
                    boardIndex: boardIndex,
                    pairOnBoard: pair))
            }
        }
        return pairs
    }

    /// The stereo name of a digital pair on a board, e.g. "ADAT 1/2",
    /// "SMUX 9/10", "SPDIF Opt 1/2", "SPDIF Cx 1/2" or "N.A.".
    public func digitalPairName(board: Int, pair: Int, isInput: Bool) -> String {
        Self.stereoName(
            left: digitalChannelName(board: board, channelOnCard: pair * 2, isInput: isInput),
            right: digitalChannelName(board: board, channelOnCard: pair * 2 + 1, isInput: isInput))
    }

    /// The stereo name of an analog pair on a board, e.g. "Line 1/2".
    public func analogPairName(board: Int, pair: Int, isInput: Bool) -> String {
        Self.stereoName(
            left: analogChannelName(board: board, channelOnCard: pair * 2, isInput: isInput),
            right: analogChannelName(board: board, channelOnCard: pair * 2 + 1, isInput: isInput))
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
                                           name: "Optical \(pair * 2 + 1)-\(pair * 2 + 2)"))
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
            options.append(SPDIFOption(
                id: id, name: "\(Self.pairMenuLabel(label)) \(number)-\(number + 1)"))
            digitalChannel[label] = number + 2
            id += 1
        }
        return options
    }

    /// The word Apogee's menus use for a digital pair: "Optical" for the
    /// optical ports, whatever format they carry, and "AES" for AES.
    ///
    /// The channel and routing labels say "ADAT" (the daemon's channel names
    /// at 44.1/48 kHz, `OpticalIn_SymphonyIO_Stream.cpp:222-226`), but the pair
    /// menus never did: the S/PDIF Replaces and Mirrors names are "Optical
    /// n-m" on every optical board (`SymphonyIOBoard_AnalogOptical.cpp:151-155`,
    /// `SymphonyIOBoard_AD16ch.cpp:177-181`, `SymphonyIOBoard_DA16ch.cpp:178-181`,
    /// `SymphonyIOBoard_2x6.cpp:585-684`) and the
    /// headphone source names are "Optical n-m"
    /// (`OpticalOut_SymphonyIO_Stream.cpp:121-150`).
    static func pairMenuLabel(_ label: String) -> String {
        label == "ADAT" ? "Optical" : label
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
        /// The input's channel within its board's 16-channel region: the
        /// card's analog inputs first, then its digital ones (the order of the
        /// routing grid's columns and of the unit's IOBoard routing sources).
        public let channelOnBoard: Int

        public init(label: String, hardwareIndex: Int, boardIndex: Int = 0, channelOnBoard: Int? = nil) {
            self.label = label
            self.hardwareIndex = hardwareIndex
            self.boardIndex = boardIndex
            self.channelOnBoard = channelOnBoard ?? hardwareIndex
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
        if let system = converterLayout { return Self.converterMixerChannels(system) }
        guard isKnown else {
            return (0..<min(fallbackChannelCount, 16)).map {
                MixerChannel(label: "Line \($0 + 1)", hardwareIndex: $0)
            }
        }
        var analog: [(label: String, board: Int, channel: Int)] = []
        var aes: [(label: String, board: Int, channel: Int)] = []
        var optical: [(label: String, board: Int, channel: Int)] = []

        for (boardIndex, card) in slots.enumerated() {
            for channelOnCard in 0..<card.analogInputChannels {
                analog.append((label: analogChannelName(board: boardIndex, channelOnCard: channelOnCard,
                                                        isInput: true),
                               board: boardIndex, channel: channelOnCard))
            }
        }
        for (boardIndex, card) in slots.enumerated() {
            for channelOnCard in 0..<card.digitalInputChannels {
                let entry = (label: digitalChannelName(board: boardIndex, channelOnCard: channelOnCard,
                                                       isInput: true),
                             board: boardIndex, channel: card.analogInputChannels + channelOnCard)
                // AES3 is walked before Optical by the daemon's plug-type loop.
                if card.digitalLabel(forChannel: channelOnCard) == "AES" {
                    aes.append(entry)
                } else {
                    optical.append(entry)
                }
            }
        }
        return (analog + aes + optical).enumerated().map { index, entry in
            MixerChannel(label: entry.label, hardwareIndex: index, boardIndex: entry.board,
                         channelOnBoard: entry.channel)
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

        /// The pair's stereo name on one line, e.g. "SPDIF Opt 1/2" or "N.A.".
        public var stereoName: String { channels.isEmpty ? type : "\(type) \(channels)" }

        /// Whether the pair has no channel the rate or format carries.
        public var isNotApplicable: Bool { CardLayout.isNotApplicable(stereoName) }
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
        // Unknown layout only: digital columns numbered as "Digital n/m".
        var digitalChannel = 1

        // Column headers are the pair's channel names, so they follow the rate,
        // the optical format and S/PDIF Coax Replaces, as the original grid's
        // did: one column per pair whatever its name, "N.A." included
        // (`og_source/maestro2/App/Controllers/APRoutingDeviceColumnViewController.m:107-178`).
        for boardIndex in 0..<2 {
            for pair in 0..<board[boardIndex].analog {
                let header = isKnown
                    ? Self.headerLines(analogPairName(board: boardIndex, pair: pair, isInput: isInput))
                    : (type: "Line", channels: "\(analogChannel)/\(analogChannel + 1)")
                analogColumns.append(RoutingColumn(
                    type: header.type,
                    channels: header.channels,
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
                let header: (type: String, channels: String)
                if isKnown && card != .none {
                    header = Self.headerLines(digitalPairName(board: boardIndex, pair: pair, isInput: isInput))
                } else {
                    header = (type: "Digital", channels: "\(digitalChannel)/\(digitalChannel + 1)")
                    digitalChannel += 2
                }
                digitalColumns.append(RoutingColumn(
                    type: header.type,
                    channels: header.channels,
                    boardIndex: boardIndex,
                    isDigital: true,
                    routingByte: bases[boardIndex] + UInt8(digitalStart + pair * 2)))
            }
        }
        // Column order is analog (both boards) then digital (both boards), which
        // is the order the grid has always drawn and the order the routing-byte
        // map assumes.
        let columns = analogColumns + digitalColumns
        if let system = converterLayout {
            return Self.relabel(columns, converters: system, isInput: isInput, bases: bases)
        }
        return columns
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
                        name: "\(Self.pairMenuLabel(label)) \(number)-\(number + 1)"))
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

// MARK: - Converters

extension CardLayout {
    /// The card mixer's input strips for converters: port 1's host inputs, in
    /// host order, each sent to the card as its bus slot (the driver's mixer
    /// takes the 32 port-1 input slots, `RecomputeCardMixer`). Port 2's
    /// channels are not in the card mixer, as on a Symphony I/O at 64 channels.
    static func converterMixerChannels(_ system: ConverterSystem) -> [MixerChannel] {
        let names = system.hostChannelNames(input: true)
        let map = system.inputMap
        return (0..<system.hostInputCount).compactMap { host -> MixerChannel? in
            guard let channel = map[host], channel.port == 0 else { return nil }
            return MixerChannel(label: names[host], hardwareIndex: channel.slot,
                                boardIndex: channel.slot / 16, channelOnBoard: channel.slot % 16)
        }
    }

    /// Routing grid columns for converters: the generic grid's columns, with
    /// the same order, routing bytes and saved-route indices, each named after
    /// the port-1 unit channels on its slot pair ("A Line 1/2", "N.A." when
    /// nothing is there). Port 2 has no columns in this grid.
    static func relabel(_ columns: [RoutingColumn], converters system: ConverterSystem,
                        isInput: Bool, bases: [UInt8]) -> [RoutingColumn] {
        let names = system.hostChannelNames(input: isInput)
        let map = isInput ? system.inputMap : system.outputMap
        var slotName = [String](repeating: notApplicable, count: ConverterRules.channelsPerPort)
        for host in 0..<names.count {
            if let channel = map[host], channel.port == 0 { slotName[channel.slot] = names[host] }
        }
        return columns.map { column in
            let board = column.routingByte >= bases[1] ? 1 : 0
            let slot = board * 16 + Int(column.routingByte - bases[board])
            guard slot >= 0, slot + 1 < slotName.count else { return column }
            let header = headerLines(stereoName(left: slotName[slot], right: slotName[slot + 1]))
            return RoutingColumn(type: header.type, channels: header.channels, boardIndex: column.boardIndex,
                                 isDigital: column.isDigital, routingByte: column.routingByte)
        }
    }

    /// Converter host channel pair names for a routing grid's software rows
    /// ("A Line 1/2"), nil unless the layout follows converters.
    public func converterPairNames(isInput: Bool, pairCount: Int) -> [String]? {
        guard let system = converterLayout else { return nil }
        let names = system.hostChannelNames(input: isInput)
        return (0..<max(0, pairCount)).map { pair in
            let l = pair * 2 < names.count ? names[pair * 2] : Self.notApplicable
            let r = pair * 2 + 1 < names.count ? names[pair * 2 + 1] : Self.notApplicable
            return Self.stereoName(left: l, right: r)
        }
    }
}
