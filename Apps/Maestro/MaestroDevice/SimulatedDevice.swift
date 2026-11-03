/// Simulated device for testing without hardware.
///
/// Implements DeviceConnection with an in-memory property store.
/// Supports property get/set, listeners, and configurable supported properties.
///
/// Evidence: `og_source/maestro2/App/Resources/deviceDescriptions.plist`
/// — simulated mode uses "Simulated_Symphony I/O" modelUID.

import MaestroCore
import Foundation

// MARK: - Simulated Device Connection

/// In-memory mock of a connected Apogee device.
///
/// All property values are stored in a dictionary keyed by PropertyAddress.
/// Listeners are notified on set. Thread-safe via actor isolation.
public final class SimulatedDevice: DeviceConnection, @unchecked Sendable {
    public let identifier: USBDeviceIdentifier

    private let storage = PropertyStorage()

    public init(identifier: USBDeviceIdentifier) {
        self.identifier = identifier
    }

    /// Convenience: create a simulated Symphony IO in 16ch mode.
    public static func symphonyIO16ch(deviceUID: String = "simulated-symphony-16ch") -> SimulatedDevice {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: deviceUID
        )!
        let device = SimulatedDevice(identifier: id)
        device.loadDefaults()
        return device
    }

    /// Convenience: create a simulated Symphony IO in 32ch mode.
    public static func symphonyIO32ch(deviceUID: String = "simulated-symphony-32ch") -> SimulatedDevice {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid32ch,
            deviceUID: deviceUID
        )!
        let device = SimulatedDevice(identifier: id)
        device.loadDefaults()
        return device
    }

    // MARK: - Card Simulation Harness

    /// The option-board configuration this simulated unit is presenting.
    /// `.none` in both slots means "no cards", which is the historical default.
    public private(set) var cardConfiguration: CardConfiguration =
        CardConfiguration(slot1: .none, slot2: .none)

    /// Create a simulated Symphony I/O presenting a specific pair of option boards.
    ///
    /// This is how the app gets screenshotted with hardware we do not own — an
    /// 8MicPre above all. The configuration is validated, so an impossible
    /// pairing (a MicPre in slot 1, or a MicPre with no analog-input host)
    /// throws rather than producing a misleading screenshot.
    public static func symphonyIO(
        configuration: CardConfiguration,
        deviceUID: String = "simulated-symphony-cards"
    ) throws -> SimulatedDevice {
        try configuration.validate()
        // Channel count follows the modules, not the USB product ID: a unit whose
        // cards total more than 16 input or output channels enumerates as 32ch.
        let wide = max(configuration.totalInputChannels, configuration.totalOutputChannels) > 16
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: wide ? ApogeeUSB.SymphonyIO.pid32ch : ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: deviceUID
        )!
        let device = SimulatedDevice(identifier: id)
        device.loadDefaults()
        device.applyCardConfiguration(configuration)
        return device
    }

    /// Present `configuration` on this simulated device: publish the board-type
    /// properties `readCardTypes()` reads, size the per-channel property set to
    /// the modules' real channel counts, and install mic-pre controls only on the
    /// channels that actually have a preamp in front of them.
    public func applyCardConfiguration(_ configuration: CardConfiguration) {
        cardConfiguration = configuration

        // Board types — exactly what a working 0xA1 read would return.
        storage.setValue(
            .uint32(UInt32(configuration.slot1.rawValue)),
            for: PropertyAddress(selector: .primaryBoardType)
        )
        storage.markReadOnly(PropertyAddress(selector: .primaryBoardType))
        storage.setValue(
            .uint32(UInt32(configuration.slot2.rawValue)),
            for: PropertyAddress(selector: .secondaryBoardType)
        )
        storage.markReadOnly(PropertyAddress(selector: .secondaryBoardType))

        // Per-input controls. loadDefaults() installed micGain/phantom on every
        // channel of the USB mode; re-scope them to the channels a MicPre covers.
        for ch in UInt32(0)..<UInt32(max(identifier.mode.channelCount, configuration.totalInputChannels)) {
            storage.removeValue(for: PropertyAddress(selector: .micGain, scope: .input, element: ch))
            storage.removeValue(for: PropertyAddress(selector: .phantom, scope: .input, element: ch))
        }
        for ch in 0..<configuration.micPreChannelCount {
            let el = UInt32(ch)
            storage.setValue(.uint32(0), for: PropertyAddress(selector: .micGain, scope: .input, element: el))
            storage.setValue(.bool(false), for: PropertyAddress(selector: .phantom, scope: .input, element: el))
        }
    }

    /// Channel labels this configuration should show on the Input page.
    ///
    /// Numbering is continuous across the whole device, not per-card, and a
    /// MicPre-backed channel is named from its *current* analog level — `Mic N` /
    /// `Inst N` — falling through to `Line N` otherwise.
    /// Evidence: `og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:914-961`,
    /// `SymphonyIO_Stream.cpp:653-655`.
    public func simulatedInputLabels(micChannelsUseInstrument: Set<Int> = []) -> [String] {
        let config = cardConfiguration
        var labels: [String] = []
        for ch in 0..<config.totalInputChannels {
            let n = ch + 1
            if ch < config.micPreChannelCount {
                labels.append(micChannelsUseInstrument.contains(ch) ? "Inst \(n)" : "Mic \(n)")
            } else if ch < config.analogInputChannels {
                labels.append("Line \(n)")
            } else {
                // The 2x6's first digital pair is AES; every other module has a
                // single digital plug type. Numbering stays the simulator's
                // device-wide channel number as before.
                let digitalLabel = config.slot1 == .twoBySix
                    ? config.slot1.digitalLabel(forChannel: ch - config.analogInputChannels)
                    : config.slot1.digitalRoutingLabel
                labels.append("\(digitalLabel) \(n)")
            }
        }
        return labels
    }

    /// Meter payload size for this configuration.
    ///
    /// Always 32 words: slots 0-15 belong to card slot 1, 16-31 to card slot 2,
    /// rigid and card-independent. Only `totalInputChannels` of them carry data.
    /// Evidence: `Docs/issue-1-research.md` "Metering — slot map".
    public var simulatedMeterWordCount: Int { CardConfiguration.meterWordCount }

    /// Meter payload indices that actually carry a signal for this configuration.
    /// Within a board's 16 slots, analog comes first and digital follows.
    public func simulatedActiveMeterSlots(isInput: Bool) -> [Int] {
        let config = cardConfiguration
        var slots: [Int] = []
        let perBoard = CardConfiguration.meterSlotsPerBoard
        for (boardIndex, card) in [config.slot1, config.slot2].enumerated() {
            let analog = isInput ? card.analogInputChannels : card.analogOutputChannels
            let digital = isInput ? card.digitalInputChannels : card.digitalOutputChannels
            let base = boardIndex * perBoard
            for i in 0..<min(analog + digital, perBoard) { slots.append(base + i) }
        }
        return slots
    }

    // MARK: - Card Simulation: process-level activation (debug only)

    /// Read the debug card-simulation request for this process.
    ///
    /// Inert unless one of `CardSimulation.primaryKey` / `.secondaryKey` is present
    /// as a launch argument (`-MaestroSimulatePrimaryBoard analogADDA16`) or as a
    /// `UserDefaults` value. Nothing in the normal UI writes either key.
    ///
    /// Returns `nil` when no simulation was requested. Throws when the requested
    /// pairing cannot exist in hardware.
    public static func simulationRequest(
        defaults: UserDefaults = .standard
    ) throws -> CardConfiguration? {
        // `UserDefaults.standard` already folds in `-key value` launch arguments
        // (NSArgumentDomain), so one lookup covers both entry points.
        let primary = defaults.string(forKey: CardSimulation.primaryKey)
        let secondary = defaults.string(forKey: CardSimulation.secondaryKey)
        return try CardSimulation.resolve(primaryToken: primary, secondaryToken: secondary)
    }

    /// True when this process was launched with a card-simulation request.
    public static func isSimulatingCards(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: CardSimulation.primaryKey) != nil
            || defaults.string(forKey: CardSimulation.secondaryKey) != nil
    }

    /// Preset analog input levels requested for this process (debug only), or
    /// nil when the `CardSimulation.analogLevelsKey` argument is absent. Only
    /// honoured under a card-simulation request.
    public static func simulatedAnalogLevels(
        defaults: UserDefaults = .standard
    ) -> [CardSimulation.AnalogLevelPreset?]? {
        guard isSimulatingCards(defaults: defaults),
              let value = defaults.string(forKey: CardSimulation.analogLevelsKey)
        else { return nil }
        return CardSimulation.parseAnalogLevels(value)
    }

    // MARK: - DeviceConnection

    public var isConnected: Bool {
        storage.connected
    }

    public func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        guard storage.connected else { throw DeviceConnectionError.notConnected }
        guard let value = storage.getValue(for: address) else {
            throw DeviceConnectionError.unsupportedProperty(address.selector)
        }
        return value
    }

    public func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        guard storage.connected else { throw DeviceConnectionError.notConnected }
        guard storage.isSettable(address) else {
            throw DeviceConnectionError.readOnly(address.selector)
        }
        storage.setValue(value, for: address)
        let change = PropertyChange(address: address, value: value)
        await storage.notifyListeners(for: address, change: change)
    }

    public func hasProperty(_ address: PropertyAddress) async -> Bool {
        storage.getValue(for: address) != nil
    }

    public func isPropertySettable(_ address: PropertyAddress) async -> Bool {
        storage.isSettable(address)
    }

    public func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        storage.addListener(listener, for: address)
    }

    public func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {
        storage.removeListener(listener, for: address)
    }

    public func disconnect() async {
        storage.connected = false
    }

    // MARK: - Test Helpers

    /// Directly set a property value without triggering listeners (for test setup).
    public func setPropertyDirect(_ address: PropertyAddress, value: PropertyValue) {
        storage.setValue(value, for: address)
    }

    /// Mark a property as read-only.
    public func markReadOnly(_ address: PropertyAddress) {
        storage.markReadOnly(address)
    }

    /// Reconnect (for testing disconnect/reconnect flows).
    public func reconnect() {
        storage.connected = true
    }

    /// Load default Symphony IO property values.
    private func loadDefaults() {
        let mode = identifier.mode

        // Sample rate
        storage.setValue(
            .float64(48000.0),
            for: PropertyAddress(selector: .sampleRate)
        )

        // Clock source — internal
        storage.setValue(
            .uint32(0), // Internal
            for: PropertyAddress(selector: .clockSource)
        )

        // Clock status — locked
        storage.setValue(
            .uint32(0), // Locked
            for: PropertyAddress(selector: .clockStatus)
        )
        storage.markReadOnly(PropertyAddress(selector: .clockStatus))

        // Version info — read only
        storage.setValue(
            .string("1.0.0-sim"),
            for: PropertyAddress(selector: .version)
        )
        storage.markReadOnly(PropertyAddress(selector: .version))

        // Output level range
        storage.setValue(
            .range(min: -64.0, max: 0.0),
            for: PropertyAddress(selector: .outputLevelRange)
        )
        storage.markReadOnly(PropertyAddress(selector: .outputLevelRange))

        // Main output level
        storage.setValue(
            .float64(0.0),
            for: PropertyAddress(selector: .outputLevel)
        )

        // Main output mute/dim/sum
        storage.setValue(.bool(false), for: PropertyAddress(selector: .outputMute))
        storage.setValue(.bool(false), for: PropertyAddress(selector: .outputDim))
        storage.setValue(.bool(false), for: PropertyAddress(selector: .outputSumToMono))

        // Per-input: mic gain at 0 dB for each channel
        for ch in UInt32(0)..<UInt32(mode.channelCount) {
            storage.setValue(
                .uint32(0),
                for: PropertyAddress(selector: .micGain, scope: .input, element: ch)
            )
            storage.setValue(
                .bool(false),
                for: PropertyAddress(selector: .phantom, scope: .input, element: ch)
            )
        }
    }
}

// MARK: - Simulated Device Discovery

/// In-memory device discovery for testing.
///
/// Allows adding/removing simulated devices and emitting discovery events.
public final class SimulatedDiscovery: DeviceDiscovery, @unchecked Sendable {
    private var devices: [DiscoveredDevice] = []
    private var eventContinuation: AsyncStream<DeviceDiscoveryEvent>.Continuation?
    public let events: AsyncStream<DeviceDiscoveryEvent>
    private var monitoring = false

    public init() {
        var cont: AsyncStream<DeviceDiscoveryEvent>.Continuation!
        self.events = AsyncStream { continuation in
            cont = continuation
        }
        self.eventContinuation = cont
    }

    public func scan() async throws -> [DiscoveredDevice] {
        devices
    }

    public func startMonitoring() async throws {
        monitoring = true
    }

    public func stopMonitoring() async {
        monitoring = false
    }

    // MARK: - Test Helpers

    /// Simulate a device being plugged in.
    public func addDevice(_ device: DiscoveredDevice) {
        devices.append(device)
        if monitoring {
            eventContinuation?.yield(.deviceAdded(device))
        }
    }

    /// Simulate a device being unplugged.
    public func removeDevice(uid: String) {
        devices.removeAll { $0.id == uid }
        if monitoring {
            eventContinuation?.yield(.deviceRemoved(deviceUID: uid))
        }
    }

    /// Stop the event stream.
    public func finish() {
        eventContinuation?.finish()
    }
}

// MARK: - Internal Property Storage

/// Thread-safe property storage for SimulatedDevice.
private final class PropertyStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PropertyAddress: PropertyValue] = [:]
    private var readOnlyProperties: Set<PropertyAddress> = []
    private var listeners: [PropertyAddress: [WeakListener]] = [:]
    var connected: Bool = true

    func getValue(for address: PropertyAddress) -> PropertyValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[address]
    }

    func setValue(_ value: PropertyValue, for address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        values[address] = value
    }

    func removeValue(for address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: address)
        readOnlyProperties.remove(address)
    }

    func isSettable(_ address: PropertyAddress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[address] != nil && !readOnlyProperties.contains(address)
    }

    func markReadOnly(_ address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        readOnlyProperties.insert(address)
    }

    func addListener(_ listener: PropertyListener, for address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        var list = listeners[address] ?? []
        list.append(WeakListener(listener))
        listeners[address] = list
    }

    func removeListener(_ listener: PropertyListener, for address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        listeners[address]?.removeAll { $0.value === listener }
    }

    func getListeners(for address: PropertyAddress) -> [PropertyListener] {
        lock.lock()
        defer { lock.unlock() }
        return (listeners[address] ?? []).compactMap { $0.value }
    }

    func notifyListeners(for address: PropertyAddress, change: PropertyChange) async {
        let listenersToNotify = getListeners(for: address)
        for listener in listenersToNotify {
            await listener.propertyDidChange(change)
        }
    }
}

/// Weak reference wrapper for listeners to avoid retain cycles.
private final class WeakListener: @unchecked Sendable {
    weak var value: PropertyListener?
    init(_ value: PropertyListener) {
        self.value = value
    }
}
