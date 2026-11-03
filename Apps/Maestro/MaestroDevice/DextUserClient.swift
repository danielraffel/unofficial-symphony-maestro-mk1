/// Vendor command transport to the SymphonyThunderbridge dext.
///
/// Sends vendor commands (mic gain, phantom power, routing, clock, mixer, etc.)
/// via IOKit IOUserClient (IOConnectCallStructMethod). Each command is sent
/// directly to the dext's SymphonyUserClient::ExternalMethod, which routes
/// to SendVendorCommand() → XLink → Symphony IO hardware.
///
/// Wire format matches SymphonyThunderbridgeShared.h:
///   {magic:4, command:1, reserved:3, value:4, payloadLen:2, payload:64} = 78 bytes

import Foundation
import IOKit
import CoreAudio  // for AudioDeviceID type in connect() signature

// MARK: - DextUserClient

/// Sends vendor commands to the ThunderBridge dext via IOKit IOUserClient.
public final class DextUserClient: @unchecked Sendable {

    // Constants matching SymphonyThunderbridgeShared.h
    private static let magic: UInt32 = 0x53594D50  // 'SYMP'
    private static let selectorSendVendor: UInt32 = 0
    // kSymphonyUserClientType ('SYMC'). The dext's NewUserClient routes only this
    // type to SymphonyUserClient; all other types (incl. 0, used by coreaudiod) go
    // to IOUserAudioDriver. Must match SymphonyThunderbridgeShared.h.
    private static let userClientType: UInt32 = 0x53594D43  // 'SYMC'
    private static let inputSize = 78   // sizeof(SymphonyVendorCommandInput)
    private static let dextIdentifier = "SymphonyThunderbridge"  // IOUserClass from personality

    /// IOKit connection to the dext's SymphonyUserClient.
    private var connection: io_connect_t = IO_OBJECT_NULL
    private let lock = NSLock()

    public init() {}

    // MARK: - Connection

    /// Open an IOUserClient connection to the ThunderBridge dext.
    /// Uses IOServiceNameMatching (Apple's recommended pattern from the
    /// "Communicating between a DriverKit extension and a client app" sample).
    public func connect(audioDeviceID: AudioDeviceID) {
        lock.lock()
        defer { lock.unlock() }

        // Close any existing connection
        if connection != IO_OBJECT_NULL {
            IOServiceClose(connection)
            connection = IO_OBJECT_NULL
        }

        // Find the ThunderBridge dext using IOServiceNameMatching
        // (matches IOUserClass from the personality, per Apple's sample code)
        guard let matchDict = IOServiceNameMatching(Self.dextIdentifier) else {
            print("[DextUserClient] Failed to create matching dictionary")
            return
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchDict)
        guard service != IO_OBJECT_NULL else {
            print("[DextUserClient] ThunderBridge dext IOService not found (name=\(Self.dextIdentifier))")
            return
        }
        defer { IOObjectRelease(service) }

        // Open IOUserClient connection with our custom type so NewUserClient hands
        // back a SymphonyUserClient (type 0 now routes to IOUserAudioDriver instead).
        var conn: io_connect_t = IO_OBJECT_NULL
        let openResult = IOServiceOpen(service, mach_task_self_, Self.userClientType, &conn)
        guard openResult == KERN_SUCCESS else {
            print("[DextUserClient] IOServiceOpen failed: 0x\(String(openResult, radix: 16))")
            return
        }

        connection = conn
        print("[DextUserClient] Connected to dext via IOUserClient (connection=\(conn))")
    }

    /// Disconnect from the dext.
    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if connection != IO_OBJECT_NULL {
            IOServiceClose(connection)
            connection = IO_OBJECT_NULL
            print("[DextUserClient] Disconnected")
        }
    }

    /// Whether we have an active IOUserClient connection.
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != IO_OBJECT_NULL
    }

    // MARK: - Send Command

    /// Send a vendor command to the Symphony IO via the dext.
    /// Each command is sent immediately via IOConnectCallStructMethod —
    /// no batching needed since IOUserClient calls are fast (~μs IPC).
    ///
    /// - `command`: bRequest opcode (SymphonyIOCommand)
    /// - `value`: nValue = (wValue << 16) | wIndex
    /// - `payload`: command data (max 64 bytes)
    public func sendVendorCommand(
        command: UInt8,
        value: UInt32,
        payload: Data = Data()
    ) throws {
        guard payload.count <= 64 else {
            throw DextUserClientError.payloadTooLarge(payload.count)
        }

        lock.lock()
        guard connection != IO_OBJECT_NULL else {
            lock.unlock()
            throw DextUserClientError.notConnected
        }
        let conn = connection
        lock.unlock()

        // Pack the input struct (matches SymphonyVendorCommandInput layout)
        var input = Data(count: Self.inputSize)
        input.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            ptr.storeBytes(of: Self.magic, as: UInt32.self)
            ptr.storeBytes(of: command, toByteOffset: 4, as: UInt8.self)
            // reserved[3] at offsets 5-7 (zeroed by Data init)
            ptr.storeBytes(of: value, toByteOffset: 8, as: UInt32.self)
            let payloadLen = UInt16(payload.count)
            ptr.storeBytes(of: payloadLen, toByteOffset: 12, as: UInt16.self)
            if !payload.isEmpty {
                payload.withUnsafeBytes { payloadPtr in
                    (ptr + 14).copyMemory(from: payloadPtr.baseAddress!, byteCount: payload.count)
                }
            }
        }

        // Call the dext's ExternalMethod via IOKit IPC
        var outputData = Data(count: 4)  // SymphonyVendorCommandOutput = 4 bytes
        var outputSize = 4

        let kr = input.withUnsafeBytes { inputPtr -> kern_return_t in
            outputData.withUnsafeMutableBytes { outputPtr -> kern_return_t in
                IOConnectCallStructMethod(
                    conn,
                    Self.selectorSendVendor,
                    inputPtr.baseAddress,
                    Self.inputSize,
                    outputPtr.baseAddress,
                    &outputSize
                )
            }
        }

        guard kr == KERN_SUCCESS else {
            print("[DextUserClient] IOConnectCallStructMethod failed: 0x\(String(kr, radix: 16)) cmd=0x\(String(command, radix: 16))")
            throw DextUserClientError.ipcFailed(kr)
        }

        // Check dext-side status from output struct
        let status = outputData.withUnsafeBytes { $0.load(as: UInt32.self) }
        if status != 0 {
            print("[DextUserClient] Dext returned error: 0x\(String(status, radix: 16)) cmd=0x\(String(command, radix: 16))")
            throw DextUserClientError.dextError(status)
        }
    }

    // kSelectorReadMeters — snapshot the card FPGA meter DMA buffer (256 words).
    private static let selectorReadMeters: UInt32 = 1

    /// Read the 256-word card meter buffer. Returns nil if not connected or metering
    /// unavailable (FPGA < 20). Per word: peak = bits[31:24], over = bit 1.
    public func readMeters() -> [UInt32]? {
        lock.lock()
        let conn = connection
        lock.unlock()
        guard conn != IO_OBJECT_NULL else { return nil }
        // SymphonyMeterOutput { UInt32 status; UInt32 words[256] } = 1028 bytes.
        var out = [UInt32](repeating: 0, count: 257)
        var outSize = 257 * MemoryLayout<UInt32>.size
        let kr = out.withUnsafeMutableBytes { p in
            IOConnectCallStructMethod(conn, Self.selectorReadMeters, nil, 0,
                                      p.baseAddress, &outSize)
        }
        guard kr == KERN_SUCCESS, out[0] == 0 else { return nil }
        return Array(out[1...256])
    }

    // kSelectorReadBoardTypes — the fitted option board in each slot.
    private static let selectorReadBoardTypes: UInt32 = 2

    /// Perform a read-only XLink transaction documented by the original
    /// Symphony protocol to verify that the FPGA behind the still-enumerated
    /// PCI endpoint is actually responding. The clock-rate/lock command is a
    /// pure five-byte read and is also used by the dext's original startup
    /// path. A routing read is stateful and is not a reliable liveness probe.
    public func probeHardwareResponse() -> Bool {
        // A power transition can leave one XLink transaction in flight while
        // the FPGA is already answering again. Retry once inside the same poll
        // so a single boundary timeout cannot tear down an otherwise healthy
        // Core Audio connection.
        for attempt in 1...2 {
            do {
                let response = try readVendorCommand(
                    command: SymphonyIOCommand.clockRateAndLock.rawValue,
                    value: 0,
                    responseLength: 5
                )
                // [0] is clock-lock state and [1...4] is the measured rate in
                // big-endian form. Some firmware revisions report zero while
                // the clock is settling, so response success is the liveness
                // signal; do not reject a live unit merely because it is not
                // locked yet.
                if response.count == 5 { return true }
            } catch {
                if attempt == 2 {
                    print("[DextUserClient] ThunderBridge liveness read failed after retry: \(error)")
                }
            }
        }
        return false
    }

    /// Read the dext's link-watch state (selector 5). No PCI transaction: this is
    /// what the app's 2 s presence loop calls. `nil` = the user client did not answer.
    public func readLinkState() -> LinkState? {
        lock.lock()
        let conn = connection
        lock.unlock()
        guard conn != IO_OBJECT_NULL else { return nil }
        // The dext checks the output size exactly: 16 words from dext 117 on, 12
        // before. Try the current size first, then the older one.
        for count in [16, 12] {
            var out = [UInt32](repeating: 0, count: count)
            var outSize = out.count * MemoryLayout<UInt32>.size
            let kr = out.withUnsafeMutableBytes { p in
                IOConnectCallStructMethod(conn, 5, nil, 0, p.baseAddress, &outSize)
            }
            if kr == KERN_SUCCESS { return LinkState.decode(out) }
        }
        return nil
    }

    /// Read the dext's timing and FPGA health snapshot for latency studies.
    public func readTimingHealth() -> TimingHealth? {
        lock.lock()
        let conn = connection
        lock.unlock()
        guard conn != IO_OBJECT_NULL else { return nil }
        var out = [UInt32](repeating: 0, count: 12)
        var outSize = out.count * MemoryLayout<UInt32>.size
        let kr = out.withUnsafeMutableBytes { p in
            IOConnectCallStructMethod(conn, 3, nil, 0, p.baseAddress, &outSize)
        }
        guard kr == KERN_SUCCESS, out.count == 12, out[0] == 0 else { return nil }
        return TimingHealth(clkCtrl: out[1], intStatus: out[2], xlinkStatus: out[3],
                            gcsr: out[4], frameReadback: out[5], expectedFrame: out[6],
                            sampleRate: out[7], inputLatency: out[8], outputLatency: out[9],
                            inputSafety: out[10], outputSafety: out[11])
    }

    /// The option board fitted in each of the two slots, as the dext read it with
    /// OptionBoardType (0xA1) when it started. `nil` for a slot whose read failed —
    /// which is NOT the same as an empty slot, and must not be rendered as one.
    ///
    /// Over USB the app reads 0xA1 itself through the proxy's EP0 path. Thunderbolt
    /// has no EP0: only the dext talks to the card, so this is the only way the app
    /// can learn which cards are fitted, and without it every card-driven surface
    /// (routing grids, strip counts, mixer channels, headphone sources) falls back
    /// to a generic 32-channel guess.
    public func readBoardTypes() -> (primary: UInt8?, secondary: UInt8?)? {
        lock.lock()
        let conn = connection
        lock.unlock()
        guard conn != IO_OBJECT_NULL else { return nil }
        // SymphonyBoardTypesOutput { UInt32 status; UInt8 board[2]; UInt8 valid[2] } = 8 bytes.
        var out = [UInt8](repeating: 0, count: 8)
        var outSize = 8
        let kr = out.withUnsafeMutableBytes { p in
            IOConnectCallStructMethod(conn, Self.selectorReadBoardTypes, nil, 0,
                                      p.baseAddress, &outSize)
        }
        guard kr == KERN_SUCCESS else {
            print("[DextUserClient] readBoardTypes failed: 0x\(String(kr, radix: 16))")
            return nil
        }
        // loadUnaligned: the byte buffer carries no 4-byte alignment guarantee.
        let status = out.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard status == 0 else { return nil }
        return (out[6] == 1 ? out[4] : nil, out[7] == 1 ? out[5] : nil)
    }

    /// Read a bounded XLink vendor response through the dext. Used by routing
    /// views to distinguish live hardware state from cached/default state.
    public func readVendorCommand(command: UInt8, value: UInt32, responseLength: Int) throws -> Data {
        guard (1...64).contains(responseLength) else { throw DextUserClientError.payloadTooLarge(responseLength) }
        lock.lock()
        let conn = connection
        lock.unlock()
        guard conn != IO_OBJECT_NULL else { throw DextUserClientError.notConnected }

        var input = Data(count: 16)
        input.withUnsafeMutableBytes { p in
            let ptr = p.baseAddress!
            ptr.storeBytes(of: Self.magic, as: UInt32.self)
            ptr.storeBytes(of: command, toByteOffset: 4, as: UInt8.self)
            ptr.storeBytes(of: value, toByteOffset: 8, as: UInt32.self)
            ptr.storeBytes(of: UInt16(responseLength), toByteOffset: 12, as: UInt16.self)
        }
        var output = Data(count: 72)
        var outputSize = output.count
        let kr = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(conn, 4, inPtr.baseAddress, input.count,
                                          outPtr.baseAddress, &outputSize)
            }
        }
        guard kr == KERN_SUCCESS else { throw DextUserClientError.ipcFailed(kr) }
        let status = output.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard status == 0 else { throw DextUserClientError.dextError(status) }
        return output.subdata(in: 8..<(8 + responseLength))
    }

    /// Convenience: send a command from a USBControlRequest.
    public func sendFromUSBRequest(_ request: USBControlRequest) throws {
        let nValue = (UInt32(request.value) << 16) | UInt32(request.index)
        try sendVendorCommand(
            command: request.request,
            value: nValue,
            payload: request.data
        )
    }
}

/// Output of the dext's `kSelectorReadLinkState` (dext 113): the driver-owned
/// link watch's view of the ThunderBridge ↔ Symphony link. Reading it costs no
/// PCI transaction, so the app polls it instead of the 0x51 message probe.
public struct LinkState: Sendable, Equatable {
    public enum State: UInt32, Sendable { case unknown = 0, up = 1, down = 2, recovering = 3 }
    public let state: State
    public let clockPresent: Bool
    public let ioRunning: Bool
    public let irqCount: UInt64
    public let recoveryCount: UInt32
    public let hwSuspended: Bool
    public let linkConfigured: Bool
    public let lastClockReg: UInt32
    public let watchTicks: UInt32
    public let audioWraps: UInt32
    /// dext 117+: the last control / XLink status registers the watch sampled and
    /// how many times it re-programmed the card after a power cycle. Zero from
    /// older dexts, which answer 12 words.
    public let lastGcsr: UInt32
    public let lastXlinkStatus: UInt32
    public let cardReinitCount: UInt32

    public init(state: State, clockPresent: Bool, ioRunning: Bool, irqCount: UInt64,
                recoveryCount: UInt32, hwSuspended: Bool, linkConfigured: Bool,
                lastClockReg: UInt32, watchTicks: UInt32, audioWraps: UInt32,
                lastGcsr: UInt32 = 0, lastXlinkStatus: UInt32 = 0, cardReinitCount: UInt32 = 0) {
        self.state = state; self.clockPresent = clockPresent; self.ioRunning = ioRunning
        self.irqCount = irqCount; self.recoveryCount = recoveryCount; self.hwSuspended = hwSuspended
        self.linkConfigured = linkConfigured; self.lastClockReg = lastClockReg
        self.watchTicks = watchTicks; self.audioWraps = audioWraps
        self.lastGcsr = lastGcsr; self.lastXlinkStatus = lastXlinkStatus; self.cardReinitCount = cardReinitCount
    }

    /// Decode the dext's output: 16 words (dext 117+) or 12 (dext 113–116). `nil`
    /// when the status word is nonzero or the size is wrong, both of which mean
    /// the selector did not answer.
    public static func decode(_ words: [UInt32]) -> LinkState? {
        guard words.count == 12 || words.count == 16, words[0] == 0 else { return nil }
        let ext = words.count == 16
        return LinkState(state: State(rawValue: words[1]) ?? .unknown,
                         clockPresent: words[2] != 0, ioRunning: words[3] != 0,
                         irqCount: UInt64(words[4]) | (UInt64(words[5]) << 32),
                         recoveryCount: words[6], hwSuspended: words[7] != 0,
                         linkConfigured: words[8] != 0, lastClockReg: words[9],
                         watchTicks: words[10], audioWraps: words[11],
                         lastGcsr: ext ? words[12] : 0, lastXlinkStatus: ext ? words[13] : 0,
                         cardReinitCount: ext ? words[14] : 0)
    }
}

public struct TimingHealth: Sendable, Equatable {
    public let clkCtrl: UInt32
    public let intStatus: UInt32
    public let xlinkStatus: UInt32
    public let gcsr: UInt32
    public let frameReadback: UInt32
    public let expectedFrame: UInt32
    public let sampleRate: UInt32
    public let inputLatency: UInt32
    public let outputLatency: UInt32
    public let inputSafety: UInt32
    public let outputSafety: UInt32
}

// MARK: - Errors

public enum DextUserClientError: Error, LocalizedError {
    case notConnected
    case payloadTooLarge(Int)
    case ipcFailed(kern_return_t)
    case dextError(UInt32)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to dext IOUserClient"
        case .payloadTooLarge(let size):
            return "Payload too large: \(size) bytes (max 64)"
        case .ipcFailed(let kr):
            return "IOConnectCallStructMethod failed: 0x\(String(kr, radix: 16))"
        case .dextError(let status):
            return "Dext returned error: 0x\(String(status, radix: 16))"
        }
    }
}
