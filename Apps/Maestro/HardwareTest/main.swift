/// HardwareTest — End-to-end test of USB control transfers with real Symphony IO.
///
/// Modes:
///   (default)       Read-only tests (firmware, clock, output, mic, meters)
///   --round-trip    Include write→read→restore verification tests
///   --coreaudio     CoreAudio diagnostic: enumerate devices, test custom properties
///   --diag          Audio diagnostic: check routing, output state, and optionally reset
///   --reset-routing Reset firmware routing to defaults (IO board loopback)
///   --setup-usb     Route USB playback streams to physical outputs (fixes no-audio)
///   --keep-alive    Keep USB connection open after setup (test firmware reset theory)
///   --probe         Quick probe: check if USB control endpoint responds
///   --proxy-soft-limit  Read Soft Limit through MaestroVolumeProxy (the proxy owns EP0)
///   --proxy-soft-limit-roundtrip  Temporarily write/read -4 dBFS on input 1, then restore
///   --proxy-soft-limit-measure  Play a short near-full-scale tone and compare input peaks
///   --proxy-software-return-roundtrip  Round-trip AEsR sources 1–2 through 15–16 on both mixers
///   --wait          Wait for device to appear (useful after reconnect)
///   --probe-inputs  Probe input/output properties via daemon IPC across channels/scopes
///   --thunderbolt-timing  Read the ThunderBridge dext timing/health snapshot (read-only)
///   --thunderbolt-timing-sweep  Set and verify all six supported ThunderBridge rates
///
/// Run: swift run --package-path Apps/Maestro HardwareTest [--round-trip|--diag|--setup-usb|--keep-alive|--probe|--wait]

import Foundation
import MaestroCore
import MaestroDevice
import CoreAudio
import LegacyCoreAudio

@main
struct HardwareTest {
    static func main() async {
        let args = Set(CommandLine.arguments)
        let runDiag = args.contains("--diag")
        let runRoundTrip = args.contains("--round-trip") || args.contains("--all")
        let runResetRouting = args.contains("--reset-routing")
        let runSetupUSB = args.contains("--setup-usb")
        let keepAlive = args.contains("--keep-alive")
        let probeOnly = args.contains("--probe")
        let waitForDevice = args.contains("--wait")
        let runCoreAudio = args.contains("--coreaudio")
        let runThunderboltTiming = args.contains("--thunderbolt-timing")
        let runThunderboltTimingSweep = args.contains("--thunderbolt-timing-sweep")
        let runDaemonTest = args.contains("--daemon-test")
        let runProbeInputsMode = args.contains("--probe-inputs")
        let runMeterProbe = args.contains("--meter-probe")
        let runProxySoftLimit = args.contains("--proxy-soft-limit")
        let runProxySoftLimitRoundTrip = args.contains("--proxy-soft-limit-roundtrip")
        let runProxySoftLimitMeasure = args.contains("--proxy-soft-limit-measure")
        let runProxySoftwareReturn = args.contains("--proxy-software-return-roundtrip")

        if runProxySoftLimit || runProxySoftLimitRoundTrip || runProxySoftLimitMeasure {
            await runProxySoftLimitProbe(
                roundTrip: runProxySoftLimitRoundTrip,
                measure: runProxySoftLimitMeasure)
            return
        }
        if runProxySoftwareReturn {
            await runProxySoftwareReturnRoundTrip()
            return
        }

        if runMeterProbe {
            await runMeterProbeMode()
            return
        }

        // --daemon-test mode: test mute round-trip via daemon IPC (same code path as app)
        if runDaemonTest {
            await runDaemonMuteTest()
            return
        }

        // --probe-inputs mode: probe all input/output properties via daemon IPC
        if runProbeInputsMode {
            await runProbeInputs()
            return
        }

        // --coreaudio mode: diagnostic for CoreAudio device discovery and properties
        if runCoreAudio {
            await runCoreAudioDiagnostic()
            return
        }
        if runThunderboltTiming {
            runThunderboltTimingHealth()
            return
        }
        if runThunderboltTimingSweep {
            await runThunderboltTimingSweepMode()
            return
        }

        print("=== Symphony IO MKI Hardware Test ===")
        print("")

        // --wait mode: poll for device to appear
        if waitForDevice {
            print("Waiting for Symphony IO device (Ctrl-C to quit)...")
            for i in 1...60 {
                let found = tryFindDevice()
                if found {
                    print("  Device found after \(i) seconds!")
                    break
                }
                if i % 5 == 0 {
                    print("  \(i)s — still scanning...")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        // Step 1: Find and connect to device
        print("[1] Scanning for Symphony IO devices...")
        var foundTransport: IOUSBHostTransport?
        var foundIdentifier: USBDeviceIdentifier?

        for pid in ApogeeUSB.SymphonyIO.allProductIDs.sorted() {
            guard let identifier = USBDeviceIdentifier(
                vendorID: ApogeeUSB.vendorID,
                productID: pid,
                deviceUID: "hw-test-\(pid)"
            ) else { continue }

            let transport = IOUSBHostTransport(deviceIdentifier: identifier)
            do {
                try transport.open()
                print("  FOUND: PID=\(pid) (\(identifier.mode.displayName))")
                foundTransport = transport
                foundIdentifier = identifier
                break
            } catch {
                continue
            }
        }

        guard let transport = foundTransport, let identifier = foundIdentifier else {
            print("  ERROR: Could not open a Symphony IO USB control endpoint.")
            if let (_, coreAudioIdentifier) = CoreAudioDeviceConnection.discoverSymphonyIO() {
                print("  CoreAudio sees the device (PID=\(coreAudioIdentifier.productID)).")
                print("  The production MaestroVolumeProxy owns EP0 on macOS 26, so direct USB probes cannot open it.")
                print("  Use --proxy-soft-limit or --proxy-soft-limit-roundtrip for proxy-path checks.")
            } else {
                print("  No Symphony IO device is visible through CoreAudio either.")
                print("  Check the USB cable and that the legacy driver is disabled.")
                print("  Run: sudo ./Drivers/USB/Scripts/toggle-driver.sh disable")
            }
            return
        }

        print("  Connected! Mode: \(identifier.mode.displayName)")
        print("")

        let connection = USBDeviceConnection(identifier: identifier, transport: transport)
        let channelCount = identifier.mode.channelCount

        // ── Probe Mode ──
        if probeOnly {
            print("Probing USB control endpoint...")
            let responsive = await transport.probeConnection()
            if responsive {
                print("  ✓ Control endpoint responsive — firmware version read succeeded")
            } else {
                print("  ✗ Control endpoint NOT responding")
                print("  The XMOS firmware's EP0 handler is stalled.")
                print("  Fix: Disconnect and reconnect the USB cable, then try again.")
            }
            await transport.close()
            return
        }

        // ── Diagnostic Mode ──
        if runDiag || runResetRouting || runSetupUSB {
            await runDiagnostic(connection: connection, transport: transport, channelCount: channelCount, resetRouting: runResetRouting, setupUSB: runSetupUSB)

            if keepAlive {
                print("── Keeping USB connection alive (Ctrl-C to quit) ──")
                print("  Theory: XMOS firmware may reset state when control session closes.")
                print("  The legacy daemon keeps its connection open continuously.")
                print("  If audio works NOW but stops after Ctrl-C, this confirms the theory.")
                print("")
                print("  Connection open. Play audio and check speakers...")
                // Poll loop — keeps the transport open and alive
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    // Periodic heartbeat read to keep USB session alive
                    let heartbeat = USBControlRequest(
                        direction: .read,
                        request: SymphonyIOCommand.symphonyIOVersion.rawValue,
                        data: Data(count: 4)
                    )
                    if let _ = try? await transport.send(heartbeat) {
                        // Connection still alive
                    } else {
                        print("  WARNING: USB heartbeat failed — device may have disconnected")
                    }
                }
            }

            await transport.close()
            return
        }

        // ── Standard Test Suite ──
        var passed = 0
        var failed = 0

        print("── Part 1: Read Tests ──")
        print("")

        print("[2] Reading firmware version...")
        if await testRead(connection, selector: .version, label: "Firmware Version") { passed += 1 } else { failed += 1 }

        print("[3] Reading sample rate (cached default)...")
        if await testRead(connection, selector: .sampleRate, label: "Sample Rate") { passed += 1 } else { failed += 1 }

        print("[4] Reading clock lock status...")
        if await testRead(connection, selector: .clockStatus, label: "Clock Status") { passed += 1 } else { failed += 1 }

        print("[5] Reading output level...")
        if await testRead(connection, selector: .outputLevel, label: "Output Level") { passed += 1 } else { failed += 1 }

        print("[6] Reading output mute...")
        if await testRead(connection, selector: .outputMute, label: "Output Mute") { passed += 1 } else { failed += 1 }

        print("[7] Reading mic gain (channel 0)...")
        if await testReadChannel(connection, selector: .micGain, scope: .input, element: 0, label: "Mic Gain Ch0") { passed += 1 } else { failed += 1 }

        print("[8] Reading phantom power (channel 0)...")
        if await testReadChannel(connection, selector: .phantom, scope: .input, element: 0, label: "Phantom Ch0") { passed += 1 } else { failed += 1 }

        print("[9] Reading meter data (input group)...")
        if await testMeterRead(connection) { passed += 1 } else { failed += 1 }

        print("[10] Raw USB connectivity test...")
        if await testRawUSB(transport) { passed += 1 } else { failed += 1 }

        // ── Round-Trip Tests ──
        if runRoundTrip {
            print("")
            print("── Part 2: Round-Trip Write Tests (P3B-06) ──")
            print("  These tests write a value, read it back, verify, then restore.")
            print("")

            print("[11] Round-trip: Output Level...")
            if await testRoundTripOutputLevel(connection) { passed += 1 } else { failed += 1 }

            print("[12] Round-trip: Output Mute...")
            if await testRoundTripOutputMute(connection) { passed += 1 } else { failed += 1 }

            print("[13] Round-trip: Mic Gain (channel 0)...")
            if await testRoundTripMicGain(connection, channel: 0) { passed += 1 } else { failed += 1 }

            print("[14] Round-trip: Phantom Power (channel 0)...")
            if await testRoundTripPhantom(connection, channel: 0) { passed += 1 } else { failed += 1 }
        }

        print("=== Results: \(passed)/\(passed + failed) passed ===")
        if failed == 0 {
            print("All hardware tests PASSED.")
        } else {
            print("\(failed) test(s) FAILED.")
        }

        await transport.close()
    }

    // MARK: - Audio Diagnostic

    /// USB playback stream source base index.
    /// Evidence: `SymphonyIORouting.h` — eSymphonyIORoutingSource_FromP2Pch0 = 192
    static let usbPlaybackSourceBase: UInt8 = 192

    /// IOBoard0 destination/source base index.
    /// Evidence: `SymphonyIORouting.h` — eSymphonyIORoutingSource_IOBoard0Ch0 = 32
    static let ioBoard0Base: UInt8 = 32

    static func runDiagnostic(connection: USBDeviceConnection, transport: IOUSBHostTransport, channelCount: Int, resetRouting: Bool, setupUSB: Bool) async {
        print("── Audio Diagnostic ──")
        print("")

        // Output state
        print("Output State:")
        if let level = (try? await connection.getProperty(PropertyAddress(selector: .outputLevel)))?.asFloat64 {
            print("  Level: \(Int(level)) dB \(level == 0 ? "(MAXIMUM)" : level < -50 ? "(VERY LOW)" : "")")
        } else {
            print("  Level: ERROR reading")
        }
        if let mute = (try? await connection.getProperty(PropertyAddress(selector: .outputMute)))?.asBool {
            print("  Mute: \(mute) \(mute ? "⚠ MUTED — no audio will pass!" : "")")
        } else {
            print("  Mute: ERROR reading")
        }
        print("")

        // Clock state
        print("Clock State:")
        if let status = (try? await connection.getProperty(PropertyAddress(selector: .clockStatus)))?.asUInt32 {
            print("  Locked: \(status == 1 ? "YES" : "NO ⚠ Clock not locked!")")
        }
        print("")

        // Read current routing — IOBoard0 output destinations (32-47)
        print("Audio Routing — IOBoard0 Outputs (destinations 32-47):")
        print("  Dest → Source  (192+ = USB playback, 32-47 = IO board input, 64+ = mixer)")
        for ch: UInt16 in 0..<UInt16(channelCount) {
            let dest = UInt16(ioBoard0Base) + ch
            let req = USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.audioRouting.rawValue,
                value: dest,
                data: Data(count: 4)
            )
            if let resp = try? await transport.send(req) {
                let bytes = resp.data.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
                let source = resp.data.count > 0 ? Int(resp.data[0]) : -1
                let expected = Int(usbPlaybackSourceBase) + Int(ch)
                let note: String
                if source == expected {
                    note = "✓ USB playback \(ch)"
                } else if source == Int(ioBoard0Base) + Int(ch) {
                    note = "(loopback — IO input \(ch))"
                } else if source >= 192 {
                    note = "(USB playback \(source - 192))"
                } else if source >= 64 && source < 128 {
                    note = "(mixer bus)"
                } else {
                    note = "(source \(source))"
                }
                print("  IOOut[\(String(format: "%2d", ch))]: source=\(String(format: "%3d", source))  raw=[\(bytes)]  \(note)")
            } else {
                print("  IOOut[\(String(format: "%2d", ch))]: ERROR")
            }
        }
        print("")

        // Speaker output mode — THIS IS LIKELY THE KEY
        print("Speaker Output Config:")
        let speakerModeReq = USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.speakerOutputMode.rawValue,
            data: Data(count: 4)
        )
        if let resp = try? await transport.send(speakerModeReq) {
            let hex = resp.data.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            let mode = resp.data.first ?? 0
            let modeName: String
            switch mode {
            case 0: modeName = "OFF ⚠ No speaker output!"
            case 2: modeName = "Stereo"
            case 6: modeName = "5.1 Surround"
            case 8: modeName = "7.1 Surround"
            default: modeName = "Unknown (\(mode))"
            }
            print("  Speaker Mode (0x25): \(modeName)  raw=[\(hex)]")
        } else {
            print("  Speaker Mode: ERROR reading")
        }

        // Read other potentially relevant opcodes around speaker area
        for opcode: UInt8 in [0x28, 0x29, 0x2A] {
            let req = USBControlRequest(direction: .read, request: opcode, data: Data(count: 4))
            if let resp = try? await transport.send(req) {
                let hex = resp.data.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
                print("  Opcode 0x\(String(format: "%02X", opcode)): [\(hex)]")
            }
        }
        print("")

        // Digital I/O state
        print("Digital I/O:")
        let optReq = SymphonyIORequestBuilder.getOpticalFormat(board: 0)
        if let resp = try? await transport.send(optReq), let byte = resp.data.first {
            print("  Optical Format (Board 0): \(byte == 0 ? "ADAT" : byte == 1 ? "S/PDIF" : "Unknown (\(byte))")")
        } else {
            print("  Optical Format: ERROR reading")
        }

        let spdifInReq = SymphonyIORequestBuilder.getSPDIFCoaxReplaceInput(board: 0)
        if let resp = try? await transport.send(spdifInReq), let byte = resp.data.first {
            print("  S/PDIF Coax Input Replace: \(byte == 0 ? "Off" : "Channel pair \(byte)")")
        } else {
            print("  S/PDIF Coax Input Replace: ERROR reading")
        }

        let spdifOutReq = SymphonyIORequestBuilder.getSPDIFCoaxMirrorOutput(board: 0)
        if let resp = try? await transport.send(spdifOutReq), let byte = resp.data.first {
            print("  S/PDIF Coax Output Mirror: \(byte == 0 ? "Off" : "Channel pair \(byte)")")
        } else {
            print("  S/PDIF Coax Output Mirror: ERROR reading")
        }
        print("")

        // Reset routing if requested
        if resetRouting {
            print("── Resetting Routing to Firmware Defaults ──")
            print("  Sending ResetToDefaultRouting (opcode 0xC2)...")
            let resetReq = SymphonyIORequestBuilder.resetRouting()
            do {
                _ = try await transport.send(resetReq)
                print("  OK: Reset command sent!")
                try await Task.sleep(for: .milliseconds(200))

                // Verify routing after reset
                print("  Verifying routing after reset:")
                for ch: UInt16 in 0..<UInt16(channelCount) {
                    let req = USBControlRequest(
                        direction: .read,
                        request: SymphonyIOCommand.audioRouting.rawValue,
                        value: ch,
                        data: Data(count: 4)
                    )
                    if let resp = try? await transport.send(req), let byte = resp.data.first {
                        let match = Int(byte) == ch ? "✓" : "≠"
                        print("    Route[\(String(format: "%2d", ch))]: source=\(String(format: "%2d", byte))  \(match)")
                    }
                }
            } catch {
                print("  ERROR: \(error)")
            }
            print("")
        }

        // Set up USB playback → physical output routing
        if setupUSB {
            print("── Full Device Initialization (matching legacy daemon sequence) ──")
            print("  Evidence: SymphonyIO.cpp init(), ApplySettingsToHardware()")
            print("")

            // Step 1: Connectivity verification — wait for firmware ready
            print("  Step 1: Checking firmware connectivity...")
            var ready = false
            for attempt in 1...10 {
                let verifyReq = SymphonyIORequestBuilder.getConnectivityVerification()
                if let resp = try? await transport.send(verifyReq), resp.data.count >= 4 {
                    // Firmware returns big-endian: DA E5 C4 A1
                    let code = UInt32(resp.data[0]) << 24 | UInt32(resp.data[1]) << 16 | UInt32(resp.data[2]) << 8 | UInt32(resp.data[3])
                    let hex = resp.data.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
                    if code == SymphonyIOConstants.connectivityVerificationCode {
                        print("  OK: Firmware ready (magic=0xDAE5C4A1) on attempt \(attempt)")
                        ready = true
                        break
                    } else {
                        print("  Attempt \(attempt): got [\(hex)], waiting...")
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if !ready {
                print("  WARNING: Firmware did not return ready code (continuing anyway)")
            }
            print("")

            // Step 2: Speaker output mode
            print("  Step 2: Setting speaker output mode to stereo...")
            do {
                _ = try await transport.send(SymphonyIORequestBuilder.setSpeakerMode(.stereo))
                print("  OK: Speaker mode = stereo")
            } catch {
                print("  ERROR: \(error)")
            }
            try? await Task.sleep(for: .milliseconds(50))

            // Step 3: Active speaker set — enable set A
            print("  Step 3: Enabling speaker set A...")
            do {
                _ = try await transport.send(SymphonyIORequestBuilder.setActiveSpeakerSet(mask: 1))
                print("  OK: Speaker set A enabled")
            } catch {
                print("  ERROR: \(error)")
            }
            try? await Task.sleep(for: .milliseconds(50))

            // Step 4: Speaker volume and UNMUTE
            print("  Step 4: Setting speaker volume (-20 dB) and UNMUTING...")
            do {
                _ = try await transport.send(SymphonyIORequestBuilder.setSpeakerVolume(attenuation: 20))
                print("  OK: Speaker volume = -20 dB")
                _ = try await transport.send(SymphonyIORequestBuilder.setSpeakerMute(muted: false))
                print("  OK: Speaker mute = OFF")
            } catch {
                print("  ERROR: \(error)")
            }
            try? await Task.sleep(for: .milliseconds(50))

            // Step 5: Write audio routing — USB playback → IOBoard0 physical outputs
            // Send routes ONE AT A TIME matching legacy daemon behavior.
            // Evidence: SymphonyIORoutingController::ApplySettingsToHardware() sends
            // individual setAudioRoute(dest, src) calls, not batch.
            print("  Step 5: Routing USB playback → IOBoard0 outputs (one at a time)...")
            print("    dest 32-\(31 + channelCount) → src 192-\(191 + channelCount)")
            var routeErrors = 0
            for ch in 0..<UInt8(channelCount) {
                let dest = ioBoard0Base &+ ch
                let src = usbPlaybackSourceBase &+ ch
                do {
                    _ = try await transport.send(SymphonyIORequestBuilder.setAudioRoute(
                        destination: dest, source: src
                    ))
                } catch {
                    print("  ERROR on route \(ch): \(error)")
                    routeErrors += 1
                }
            }
            if routeErrors == 0 {
                print("  OK: Wrote \(channelCount) routes individually!")
            } else {
                print("  WARNING: \(routeErrors) route(s) failed!")
            }
            try? await Task.sleep(for: .milliseconds(100))

            // Step 6: Preference load lock — signal firmware that init is complete
            print("  Step 6: Releasing preference load lock (signaling init complete)...")
            do {
                _ = try await transport.send(SymphonyIORequestBuilder.setPreferenceLoadLock(locked: false))
                print("  OK: Preference lock released — device should be fully active!")
            } catch {
                print("  ERROR: \(error)")
            }
            try? await Task.sleep(for: .milliseconds(200))

            print("")
            print("  Initialization complete. Audio should now be audible on analog outputs 1-2.")
            print("")
        } else if !resetRouting {
            print("Tip: Run with --setup-usb to route USB audio to physical outputs.")
        }
    }

    // MARK: - Read Tests

    @discardableResult
    static func testRead(_ conn: USBDeviceConnection, selector: AudioPropertySelector, label: String) async -> Bool {
        do {
            let value = try await conn.getProperty(PropertyAddress(selector: selector))
            print("  OK: \(label) = \(formatValue(value))")
            print("")
            return true
        } catch {
            print("  FAIL: \(label) — \(error)")
            print("")
            return false
        }
    }

    @discardableResult
    static func testReadChannel(
        _ conn: USBDeviceConnection,
        selector: AudioPropertySelector,
        scope: PropertyScope,
        element: UInt32,
        label: String
    ) async -> Bool {
        do {
            let value = try await conn.getProperty(
                PropertyAddress(selector: selector, scope: scope, element: element)
            )
            print("  OK: \(label) = \(formatValue(value))")
            print("")
            return true
        } catch {
            print("  FAIL: \(label) — \(error)")
            print("")
            return false
        }
    }

    @discardableResult
    static func testMeterRead(_ conn: USBDeviceConnection) async -> Bool {
        do {
            let value = try await conn.getProperty(
                PropertyAddress(selector: .meterData, scope: .input, element: 0)
            )
            switch value {
            case .data(let d):
                print("  OK: Meter data = \(d.count) bytes")
                if d.count >= 4 {
                    let preview = d.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("  Preview: \(preview)")
                }
            default:
                print("  OK: Meter data = \(formatValue(value))")
            }
            print("")
            return true
        } catch {
            print("  FAIL: Meter data — \(error)")
            print("")
            return false
        }
    }

    @discardableResult
    static func testRawUSB(_ transport: IOUSBHostTransport) async -> Bool {
        let request = USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.symphonyIOVersion.rawValue,
            value: 0,
            index: 0,
            data: Data(count: 4)
        )
        do {
            let response = try await transport.send(request)
            let hex = response.data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("  OK: Raw version = [\(hex)] (\(response.bytesTransferred) bytes)")
            print("")
            return true
        } catch {
            print("  FAIL: Raw USB transfer — \(error)")
            print("")
            return false
        }
    }

    // MARK: - Round-Trip Write Tests (P3B-06)

    @discardableResult
    static func testRoundTripOutputLevel(_ conn: USBDeviceConnection) async -> Bool {
        let address = PropertyAddress(selector: .outputLevel)
        do {
            let original = try await conn.getProperty(address)
            guard let originalLevel = original.asFloat64 else {
                print("  FAIL: Could not read original output level")
                print("")
                return false
            }
            print("  Original level: \(Int(originalLevel)) dB")

            let testLevel: Double = (originalLevel == -30) ? -25 : -30
            print("  Writing test level: \(Int(testLevel)) dB...")
            try await conn.setProperty(address, value: .float64(testLevel))
            try await Task.sleep(for: .milliseconds(50))

            let readBack = try await conn.getProperty(address)
            guard let readLevel = readBack.asFloat64 else {
                print("  FAIL: Could not read back output level")
                try? await conn.setProperty(address, value: original)
                print("")
                return false
            }
            print("  Read back: \(Int(readLevel)) dB")

            let match = abs(readLevel - testLevel) < 1.0
            if match {
                print("  MATCH: Write verified!")
            } else {
                print("  MISMATCH: Expected \(Int(testLevel)) dB, got \(Int(readLevel)) dB")
            }

            print("  Restoring original: \(Int(originalLevel)) dB")
            try await conn.setProperty(address, value: .float64(originalLevel))
            try await Task.sleep(for: .milliseconds(50))

            let restored = try await conn.getProperty(address)
            if let restoredLevel = restored.asFloat64 {
                print("  Restored: \(Int(restoredLevel)) dB")
            }
            print("")
            return match
        } catch {
            print("  FAIL: \(error)")
            print("")
            return false
        }
    }

    @discardableResult
    static func testRoundTripOutputMute(_ conn: USBDeviceConnection) async -> Bool {
        let address = PropertyAddress(selector: .outputMute)
        do {
            let original = try await conn.getProperty(address)
            guard let originalMute = original.asBool else {
                print("  FAIL: Could not read original mute state")
                print("")
                return false
            }
            print("  Original mute: \(originalMute)")

            let testMute = !originalMute
            print("  Writing test mute: \(testMute)...")
            try await conn.setProperty(address, value: .bool(testMute))
            try await Task.sleep(for: .milliseconds(50))

            let readBack = try await conn.getProperty(address)
            guard let readMute = readBack.asBool else {
                print("  FAIL: Could not read back mute state")
                try? await conn.setProperty(address, value: original)
                print("")
                return false
            }
            print("  Read back: \(readMute)")

            let match = readMute == testMute
            if match {
                print("  MATCH: Write verified!")
            } else {
                print("  MISMATCH: Expected \(testMute), got \(readMute)")
            }

            print("  Restoring original: \(originalMute)")
            try await conn.setProperty(address, value: .bool(originalMute))
            try await Task.sleep(for: .milliseconds(50))
            print("")
            return match
        } catch {
            print("  FAIL: \(error)")
            print("")
            return false
        }
    }

    @discardableResult
    static func testRoundTripMicGain(_ conn: USBDeviceConnection, channel: UInt32) async -> Bool {
        let address = PropertyAddress(selector: .micGain, scope: .input, element: channel)
        do {
            let original = try await conn.getProperty(address)
            guard let originalGain = original.asUInt32 else {
                print("  FAIL: Could not read original mic gain")
                print("")
                return false
            }
            print("  Original gain: \(originalGain) dB")

            let testGain: UInt32 = (originalGain == 10) ? 15 : 10
            print("  Writing test gain: \(testGain) dB...")
            try await conn.setProperty(address, value: .uint32(testGain))
            try await Task.sleep(for: .milliseconds(50))

            let readBack = try await conn.getProperty(address)
            guard let readGain = readBack.asUInt32 else {
                print("  FAIL: Could not read back mic gain")
                try? await conn.setProperty(address, value: original)
                print("")
                return false
            }
            print("  Read back: \(readGain) dB")

            let match = readGain == testGain
            if match {
                print("  MATCH: Write verified!")
            } else {
                print("  MISMATCH: Expected \(testGain), got \(readGain)")
            }

            print("  Restoring original: \(originalGain) dB")
            try await conn.setProperty(address, value: .uint32(originalGain))
            try await Task.sleep(for: .milliseconds(50))
            print("")
            return match
        } catch {
            print("  FAIL: \(error)")
            print("")
            return false
        }
    }

    @discardableResult
    static func testRoundTripPhantom(_ conn: USBDeviceConnection, channel: UInt32) async -> Bool {
        let address = PropertyAddress(selector: .phantom, scope: .input, element: channel)
        do {
            let original = try await conn.getProperty(address)
            guard let originalPhantom = original.asBool else {
                print("  FAIL: Could not read original phantom state")
                print("")
                return false
            }
            print("  Original phantom: \(originalPhantom)")

            let testPhantom = !originalPhantom
            print("  Writing test phantom: \(testPhantom)...")
            try await conn.setProperty(address, value: .bool(testPhantom))
            try await Task.sleep(for: .milliseconds(100))

            let readBack = try await conn.getProperty(address)
            guard let readPhantom = readBack.asBool else {
                print("  FAIL: Could not read back phantom state")
                try? await conn.setProperty(address, value: original)
                print("")
                return false
            }
            print("  Read back: \(readPhantom)")

            let match = readPhantom == testPhantom
            if match {
                print("  MATCH: Write verified!")
            } else {
                print("  MISMATCH: Expected \(testPhantom), got \(readPhantom)")
            }

            print("  Restoring original: \(originalPhantom)")
            try await conn.setProperty(address, value: .bool(originalPhantom))
            try await Task.sleep(for: .milliseconds(100))
            print("")
            return match
        } catch {
            print("  FAIL: \(error)")
            print("")
            return false
        }
    }

    // MARK: - Formatting

    static func formatValue(_ value: PropertyValue) -> String {
        switch value {
        case .uint32(let v): return "\(v) (0x\(String(v, radix: 16)))"
        case .float64(let v): return "\(v)"
        case .bool(let v): return "\(v)"
        case .string(let v): return "\"\(v)\""
        case .data(let d): return "\(d.count) bytes"
        case .int32(let v): return "\(v)"
        case .range(let min, let max): return "\(min)..\(max)"
        }
    }

    /// Quick check if any Symphony IO device is visible in IOKit (without opening).
    static func tryFindDevice() -> Bool {
        for pid in ApogeeUSB.SymphonyIO.allProductIDs {
            guard let identifier = USBDeviceIdentifier(
                vendorID: ApogeeUSB.vendorID,
                productID: pid,
                deviceUID: "probe-\(pid)"
            ) else { continue }
            let transport = IOUSBHostTransport(deviceIdentifier: identifier)
            do {
                try transport.open()
                transport.closeSync()
                return true
            } catch {
                continue
            }
        }
        return false
    }
}

// MARK: - --proxy-soft-limit mode

/// The direct IOUSBHost path cannot open the device while MaestroVolumeProxy
/// owns it. This mode uses the same XPCDeviceConnection/property mapper as the
/// app, proving whether the proxy can reach EP0 and read the real Soft Limit
/// state without changing it.
func runProxySoftLimitProbe(roundTrip: Bool = false, measure: Bool = false) async {
    print("=== Proxy Soft Limit Control-Endpoint Probe ===")
    guard let (audioDeviceID, identifier) = CoreAudioDeviceConnection.discoverSymphonyIO() else {
        print("FAIL: Symphony IO is not visible through CoreAudio.")
        return
    }
    print("Found Symphony IO pid=\(identifier.productID); querying through MaestroVolumeProxy...")

    let connection = XPCDeviceConnection(identifier: identifier)
    var successes = 0
    var failures = 0
    for channel in 0..<min(identifier.mode.channelCount, 16) {
        let address = PropertyAddress(selector: .softLimit, scope: .input, element: UInt32(channel))
        do {
            let value = try await connection.getProperty(address)
            print("  ch\(channel + 1): \(value)")
            successes += 1
        } catch {
            print("  ch\(channel + 1): ERROR \(error)")
            failures += 1
        }
    }
    do {
        let meter = try await connection.getProperty(
            PropertyAddress(selector: .meterData, scope: .input, element: 0))
        if case .data(let bytes) = meter {
            let preview = bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("Input meter read: \(bytes.count) bytes [\(preview)]")
        } else {
            print("Input meter read: \(meter)")
        }
    } catch {
        print("Input meter read ERROR: \(error)")
    }
    if roundTrip {
        let address = PropertyAddress(selector: .softLimit, scope: .input, element: 0)
        do {
            let original = try await connection.getProperty(address)
            print("  input 1 original: \(original); writing -4 dBFS...")
            try await connection.setProperty(address, value: .uint32(UInt32(SymphonyIOSoftLimitMode.limit4dBfs.rawValue)))
            // The proxy serializes vendor writes behind its render/control queue;
            // give the firmware time to apply the write before issuing the readback.
            try? await Task.sleep(for: .milliseconds(200))
            let enabled = try await connection.getProperty(address)
            print("  input 1 after write: \(enabled)")
            if case .uint32(let raw) = original {
                try await connection.setProperty(address, value: .uint32(raw))
                try? await Task.sleep(for: .milliseconds(200))
                print("  input 1 restored: \(try await connection.getProperty(address))")
            }
        } catch {
            print("  Soft Limit write/read/restore ERROR: \(error)")
        }
    }
    if measure {
        await measureProxySoftLimit(connection: connection, audioDeviceID: audioDeviceID)
    }
    await connection.disconnect()
    print("Result: \(successes) successful reads, \(failures) failures")
    if successes > 0 && failures == 0 {
        print("Control endpoint is reachable through the proxy; physical Soft Limit response testing can proceed.")
    } else {
        print("Soft Limit remains unverified: proxy control reads were incomplete.")
    }
}

private func makeSoftLimitTone(at url: URL) throws {
    let sampleRate = 48_000
    let seconds = 1
    let frames = sampleRate * seconds
    // Use short, full-scale bursts rather than a continuous sine. Apogee's
    // Soft Limit is a transient process and is most observable on high-crest-
    // factor material; a steady sine can conceal the distinction.
    let amplitude = 1.0
    let frequency = 1_000.0
    var pcm = Data(capacity: frames * 4)
    for frame in 0..<frames {
        let burstFrame = frame % (sampleRate / 10)
        let inBurst = burstFrame < (sampleRate / 200) // 5 ms every 100 ms
        let raw = inBurst ? amplitude * sin(2.0 * .pi * frequency * Double(frame) / Double(sampleRate)) : 0.0
        let sample = Int16(max(-1.0, min(1.0, raw)) * Double(Int16.max))
        var little = sample.littleEndian
        pcm.append(contentsOf: withUnsafeBytes(of: &little) { Array($0) })
        pcm.append(contentsOf: withUnsafeBytes(of: &little) { Array($0) })
    }
    var wav = Data()
    func appendASCII(_ text: String) { wav.append(contentsOf: text.utf8) }
    func appendU32(_ value: UInt32) {
        var little = value.littleEndian
        wav.append(contentsOf: withUnsafeBytes(of: &little) { Array($0) })
    }
    func appendU16(_ value: UInt16) {
        var little = value.littleEndian
        wav.append(contentsOf: withUnsafeBytes(of: &little) { Array($0) })
    }
    appendASCII("RIFF"); appendU32(UInt32(36 + pcm.count)); appendASCII("WAVE")
    appendASCII("fmt "); appendU32(16); appendU16(1); appendU16(2)
    appendU32(UInt32(sampleRate)); appendU32(UInt32(sampleRate * 4)); appendU16(4); appendU16(16)
    appendASCII("data"); appendU32(UInt32(pcm.count)); wav.append(pcm)
    try wav.write(to: url, options: .atomic)
}

private func inputMeterPeakDBFS(_ value: PropertyValue, channel: Int = 0) -> Double? {
    guard case .data(let bytes) = value, channel >= 0,
          bytes.count >= (channel + 1) * 2 else { return nil }
    let offset = channel * 2
    let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    let peak = raw & 0x3FFF
    guard peak > 0x40 else { return -60.0 }
    return max(20.0 * log10(Double(peak) / 16383.0), -60.0)
}

private func measureProxySoftLimit(connection: XPCDeviceConnection, audioDeviceID: AudioDeviceID) async {
    let toneURL = URL(fileURLWithPath: "/tmp/maestro-soft-limit-tone.wav")
    do {
        try makeSoftLimitTone(at: toneURL)
        let baseline = try await connection.getProperty(
            PropertyAddress(selector: .meterData, scope: .input, element: 0))
        let targetChannel = (0..<min(connection.identifier.mode.channelCount, 16)).max {
            (inputMeterPeakDBFS(baseline, channel: $0) ?? -60.0)
                < (inputMeterPeakDBFS(baseline, channel: $1) ?? -60.0)
        } ?? 0
        print("  selecting input \(targetChannel + 1) for measurement (highest current meter)")
        let softLimitChannels = [0, 1].filter { $0 < min(connection.identifier.mode.channelCount, 16) }
        let softLimitAddresses = softLimitChannels.map {
            PropertyAddress(selector: .softLimit, scope: .input, element: UInt32($0))
        }
        var originalValues: [PropertyValue] = []
        for address in softLimitAddresses {
            originalValues.append(try await connection.getProperty(address))
        }
        guard originalValues.allSatisfy({ if case .uint32 = $0 { return true }; return false }) else {
            print("Soft Limit measurement skipped: unexpected original values \(originalValues)")
            return
        }
        let originalValuesSnapshot = originalValues
        defer {
            try? FileManager.default.removeItem(at: toneURL)
            Task {
                for (address, value) in zip(softLimitAddresses, originalValuesSnapshot) {
                    try? await connection.setProperty(address, value: value)
                }
            }
        }

        let previousDefaultOutput = CoreAudioDeviceConnection.currentDefaultOutputDevice()
        // The proxy exposes a virtual playback device named "Symphony I/O : Maestro USB";
        // applications such as Spotify write there, and the proxy forwards that stream to
        // the physical Symphony USB device. Selecting the physical capture device here
        // would bypass the proxy and produce a silent/irrelevant measurement.
        let playbackDeviceID = CoreAudioDeviceConnection.deviceID(named: "Symphony I/O : Maestro USB") ?? audioDeviceID
        guard CoreAudioDeviceConnection.setDefaultOutputDevice(playbackDeviceID) else {
            print("Soft Limit measurement skipped: could not select Symphony playback output")
            return
        }
        defer { _ = CoreAudioDeviceConnection.setDefaultOutputDevice(previousDefaultOutput) }

        // The proxy's hardware output attenuation is independent of the USB
        // stream peak. Snapshot it and temporarily use unity so the analog
        // loopback can actually reach the Soft Limit threshold.
        let outputLevelAddress = PropertyAddress(selector: .outputLevel, scope: .output, element: 0)
        let savedOutputLevel = try? await connection.getProperty(outputLevelAddress)
        if case .float64 = savedOutputLevel {
            try? await connection.setProperty(outputLevelAddress, value: .float64(0))
        }
        defer {
            if let savedOutputLevel {
                Task { try? await connection.setProperty(outputLevelAddress, value: savedOutputLevel) }
            }
        }

        // Establish the exact physical loopback path used by the test: DAW/USB
        // channels 1–2 to the first analog output pair. Snapshot and restore the
        // two route bytes so this diagnostic cannot leave routing changed.
        let routeAddresses = [UInt32(SymphonyIORoutingAddress.ioBoard0Base),
                              UInt32(SymphonyIORoutingAddress.ioBoard0Base + 1)]
        var savedRoutes: [UInt32] = []
        for destination in routeAddresses {
            if case .uint32(let source) = try await connection.getProperty(
                PropertyAddress(selector: .route, scope: .global, element: destination)) {
                savedRoutes.append(source)
            }
        }
        let routesToRestore = Array(zip(routeAddresses, savedRoutes))
        defer {
            Task {
                for (destination, source) in routesToRestore {
                    try? await connection.setProperty(
                        PropertyAddress(selector: .route, scope: .global, element: destination),
                        value: .uint32(source))
                }
            }
        }
        for (destination, source) in zip(routeAddresses, [UInt32(SymphonyIORoutingAddress.p2pBase),
                                                          UInt32(SymphonyIORoutingAddress.p2pBase + 1)]) {
            try await connection.setProperty(
                PropertyAddress(selector: .route, scope: .global, element: destination),
                value: .uint32(source))
        }

        // 16x16 Analog I/O modules document Soft Limit as On/Off (raw 1),
        // while other modules expose the richer -2/-4 dBFS modes. Test both
        // raw 1 and raw 2 so the physical behavior identifies the module's
        // supported mode instead of assuming the richer enum applies.
        for mode in [SymphonyIOSoftLimitMode.off, .limit2dBfs, .limit4dBfs] {
            for address in softLimitAddresses {
                try await connection.setProperty(address, value: .uint32(UInt32(mode.rawValue)))
            }
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-t", "1", toneURL.path]
            try player.run()
            var peak = -60.0
            var peakChannel = targetChannel
            var softwarePeak = -60.0
            while player.isRunning {
                if let level = try? await connection.getProperty(
                    PropertyAddress(selector: .meterData, scope: .input, element: 0)),
                   let db = inputMeterPeakDBFS(level, channel: targetChannel) {
                    peak = max(peak, db)
                    for channel in 0..<min(connection.identifier.mode.channelCount, 16) {
                        if let candidate = inputMeterPeakDBFS(level, channel: channel), candidate > peak {
                            peak = candidate
                            peakChannel = channel
                        }
                    }
                }
                if let softwarePeaks = await connection.getSoftwareOutputPeaks() {
                    for sample in softwarePeaks {
                        if sample > 0 {
                            softwarePeak = max(softwarePeak, 20.0 * log10(Double(sample)))
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            let peakText = String(format: "%.2f", peak)
            let softwarePeakText = String(format: "%.2f", softwarePeak)
            print("  mode \(mode): input-\(peakChannel + 1) peak \(peakText) dBFS; USB output peak \(softwarePeakText) dBFS")
        }
        for (address, value) in zip(softLimitAddresses, originalValues) {
            try await connection.setProperty(address, value: value)
        }
        print("Soft Limit measurement complete; original mode restored.")
    } catch {
        print("Soft Limit measurement ERROR: \(error)")
    }
}

private func runProxySoftwareReturnRoundTrip() async {
    print("=== Proxy Software Return AEsR Round-Trip ===")
    guard let (_, identifier) = CoreAudioDeviceConnection.discoverSymphonyIO() else {
        print("FAIL: Symphony IO is not visible through CoreAudio.")
        return
    }
    let connection = XPCDeviceConnection(identifier: identifier)
    var failures = 0
    for mixer in 0..<2 {
        let address = PropertyAddress(
            selector: .mixerSoftwareReturnID,
            scope: .global,
            element: UInt32(mixer + 1) << 16)
        do {
            let original = try await connection.getProperty(address)
            print("Mixer \(mixer + 1) original: \(original)")
            for source in SymphonyIOSoftwareReturnSource.allCases {
                try await connection.setProperty(address, value: .uint32(source.rawValue))
                // XMOS routing state is applied asynchronously after the 0x31
                // write; allow the next EP0 read to observe the new route.
                try? await Task.sleep(for: .milliseconds(100))
                let readBack = try await connection.getProperty(address)
                let routeRead = try await connection.getProperty(
                    PropertyAddress(selector: .route, scope: .global,
                                    element: mixer == 0
                                        ? UInt32(SymphonyIORoutingAddress.mixer0AppInputBase)
                                        : UInt32(SymphonyIORoutingAddress.mixer1AppInputBase)))
                guard case .uint32(let raw) = readBack, raw == source.rawValue else {
                    failures += 1
                    print("  \(source.displayName): FAIL read-back \(readBack), raw route \(routeRead)")
                    continue
                }
                print("  \(source.displayName): OK")
            }
            try await connection.setProperty(address, value: original)
            try? await Task.sleep(for: .milliseconds(100))
            print("Mixer \(mixer + 1) restored: \(try await connection.getProperty(address))")
        } catch {
            failures += 1
            print("Mixer \(mixer + 1): ERROR \(error)")
        }
    }
    await connection.disconnect()
    print(failures == 0 ? "AEsR round-trip passed." : "AEsR round-trip had \(failures) failure(s).")
}

// MARK: - ThunderBridge timing health

/// Read-only timing receipt for the connected ThunderBridge dext. This uses
/// the same signed IOUserClient path as Maestro, so a standalone probe cannot
/// accidentally report values from a different transport or a stale simulator.
func runThunderboltTimingHealth() {
    print("=== ThunderBridge Timing Health (read-only) ===")
    let devices = CoreAudioDeviceConnection.discoverAllSymphonyIO()
    guard let discovered = devices.first(where: { $0.transportType == .thunderbolt }) else {
        print("No ThunderBridge Core Audio device is currently visible.")
        return
    }

    let device = ThunderboltDeviceConnection(
        identifier: discovered.identifier,
        audioDeviceID: discovered.audioDeviceID)
    guard let health = device.readTimingHealth() else {
        print("ThunderBridge was discovered, but timing health could not be read.")
        return
    }

    print("Device: \(discovered.name) (AudioDeviceID \(discovered.audioDeviceID))")
    print("Rate: \(health.sampleRate) Hz")
    print("FPGA frame: \(health.frameReadback) (expected \(health.expectedFrame))")
    print("Published latency: input=\(health.inputLatency) frames, output=\(health.outputLatency) frames")
    print("Safety offset: input=\(health.inputSafety) frames, output=\(health.outputSafety) frames")
    print("Registers: ClkCtrl=0x\(String(health.clkCtrl, radix: 16)), GCSR=0x\(String(health.gcsr, radix: 16)), IntStatus=0x\(String(health.intStatus, radix: 16)), XLink=0x\(String(health.xlinkStatus, radix: 16))")
}

private func readCoreAudioTimingTuple(deviceID: AudioDeviceID) ->
    (inputLatency: UInt32, outputLatency: UInt32, inputSafety: UInt32, outputSafety: UInt32, buffer: UInt32)? {
    func read(_ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
    guard let inputLatency = read(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
          let outputLatency = read(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
          let inputSafety = read(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
          let outputSafety = read(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
          let buffer = read(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal) else {
        return nil
    }
    return (inputLatency, outputLatency, inputSafety, outputSafety, buffer)
}

private func readCoreAudioNominalRate(deviceID: AudioDeviceID) -> Double? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value = Double.zero
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
        return nil
    }
    return value
}

/// Nominal-rate changes are asynchronous in HAL. The latency tuple can briefly contain the
/// previous rate's converter latency while the new safety offset has already arrived. Poll
/// until the nominal rate and complete tuple agree, or until a bounded timeout expires.
private func waitForCoreAudioTimingTuple(
    deviceID: AudioDeviceID,
    expectedRate: Double,
    expected: (input: UInt32, output: UInt32, safety: UInt32),
    timeoutMilliseconds: Int = 2_000
) async -> (rate: Double?, tuple: (inputLatency: UInt32, outputLatency: UInt32, inputSafety: UInt32, outputSafety: UInt32, buffer: UInt32)?) {
    let attempts = max(1, timeoutMilliseconds / 50)
    var lastRate: Double?
    var lastTuple: (inputLatency: UInt32, outputLatency: UInt32, inputSafety: UInt32, outputSafety: UInt32, buffer: UInt32)?
    for _ in 0..<attempts {
        lastRate = readCoreAudioNominalRate(deviceID: deviceID)
        lastTuple = readCoreAudioTimingTuple(deviceID: deviceID)
        if let rate = lastRate, let tuple = lastTuple,
           abs(rate - expectedRate) < 0.5,
           tuple.inputLatency == expected.input,
           tuple.outputLatency == expected.output,
           tuple.inputSafety == expected.safety,
           tuple.outputSafety == expected.safety {
            return (rate, tuple)
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return (lastRate, lastTuple)
}

/// Set each supported nominal rate, then read back the complete timing tuple.
/// This is intentionally explicit and opt-in because changing the nominal rate
/// interrupts any active audio stream. It never changes routing or mixer state.
func runThunderboltTimingSweepMode() async {
    print("=== ThunderBridge Timing Sweep ===")
    let devices = CoreAudioDeviceConnection.discoverAllSymphonyIO()
    guard let discovered = devices.first(where: { $0.transportType == .thunderbolt }) else {
        print("No ThunderBridge Core Audio device is currently visible.")
        return
    }

    let device = ThunderboltDeviceConnection(
        identifier: discovered.identifier,
        audioDeviceID: discovered.audioDeviceID)
    let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    let expected: [UInt32: (frame: UInt32, safety: UInt32, input: UInt32, output: UInt32)] = [
        44_100: (4, 10, 33, 33), 48_000: (4, 10, 33, 33),
        88_200: (8, 20, 36, 36), 96_000: (8, 20, 36, 36),
        176_400: (32, 32, 58, 59), 192_000: (32, 32, 58, 59),
    ]
    var failed = false
    for rate in rates {
        let rateInt = UInt32(rate)
        do {
            try await device.setProperty(
                PropertyAddress(selector: .sampleRate),
                value: .float64(rate))
            guard let want = expected[rateInt] else { continue }
            let hal = await waitForCoreAudioTimingTuple(
                deviceID: discovered.audioDeviceID,
                expectedRate: rate,
                expected: (want.input, want.output, want.safety))
            let halTiming = hal.tuple
            guard let health = device.readTimingHealth() else {
                if let halTiming, let nominal = hal.rate {
                    let pass = abs(nominal - rate) < 0.5 &&
                        halTiming.inputLatency == want.input && halTiming.outputLatency == want.output &&
                        halTiming.inputSafety == want.safety && halTiming.outputSafety == want.safety
                    if !pass { failed = true }
                    let status = pass ? "PASS (HAL)" : "FAIL (HAL)"
                    print("\(Int(rate)) Hz: \(status) nominal=\(Int(nominal)) latency=\(halTiming.inputLatency)/\(halTiming.outputLatency) safety=\(halTiming.inputSafety)/\(halTiming.outputSafety) buffer=\(halTiming.buffer)")
                } else {
                    print("\(Int(rate)) Hz: FAIL — setter succeeded, timing health and HAL timing unavailable")
                    failed = true
                }
                continue
            }
            let pass = health.sampleRate == rateInt &&
                health.frameReadback == want.frame && health.expectedFrame == want.frame &&
                health.inputLatency == want.input && health.outputLatency == want.output &&
                health.inputSafety == want.safety && health.outputSafety == want.safety
            if !pass { failed = true }
            let status = pass ? "PASS" : "FAIL"
            print("\(Int(rate)) Hz: \(status) readbackRate=\(health.sampleRate) frame=\(health.frameReadback)/\(health.expectedFrame) latency=\(health.inputLatency)/\(health.outputLatency) safety=\(health.inputSafety)/\(health.outputSafety) gcsr=0x\(String(health.gcsr, radix: 16))")
        } catch {
            print("\(Int(rate)) Hz: FAIL — setter failed: \(error)")
            failed = true
        }
    }

    // Leave the interface at the conventional 48 kHz after the diagnostic. The sweep is
    // deliberately read-only with respect to routing and mixer state, but it must not leave
    // a user's session at the final probe rate.
    do {
        try await device.setProperty(
            PropertyAddress(selector: .sampleRate),
            value: .float64(48_000))
        let restored = await waitForCoreAudioTimingTuple(
            deviceID: discovered.audioDeviceID,
            expectedRate: 48_000,
            expected: (33, 33, 10))
        if let tuple = restored.tuple, let nominal = restored.rate {
            let pass = abs(nominal - 48_000) < 0.5 &&
                tuple.inputLatency == 33 && tuple.outputLatency == 33 &&
                tuple.inputSafety == 10 && tuple.outputSafety == 10
            if !pass { failed = true }
            print("Restore 48000 Hz: " + (pass ? "PASS" : "FAIL") +
                  " nominal=\(Int(nominal)) latency=\(tuple.inputLatency)/\(tuple.outputLatency) safety=\(tuple.inputSafety)/\(tuple.outputSafety)")
        } else {
            print("Restore 48000 Hz: FAIL — timing tuple unavailable")
            failed = true
        }
    } catch {
        print("Restore 48000 Hz: FAIL — setter failed: \(error)")
        failed = true
    }
    print(failed ? "Timing sweep result: FAIL" : "Timing sweep result: PASS")
}

// MARK: - CoreAudio Diagnostic

/// Enumerate all CoreAudio devices, find Symphony IO, test custom property access.
func runCoreAudioDiagnostic() async {
    print("=== CoreAudio Diagnostic ===")
    print("")

    // Step 1: Enumerate ALL audio devices
    var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &devicesAddress, 0, nil, &dataSize
    )
    guard status == noErr else {
        print("FAIL: Cannot enumerate audio devices (error \(status))")
        return
    }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &devicesAddress, 0, nil, &dataSize, &deviceIDs
    )
    guard status == noErr else {
        print("FAIL: Cannot read audio device list (error \(status))")
        return
    }

    print("Found \(deviceCount) audio devices:")
    print("")

    var symphonyDeviceID: AudioDeviceID? = nil

    for deviceID in deviceIDs {
        // Get device name
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name)
        let deviceName = nameStatus == noErr ? (name as String) : "<unknown>"

        // Get device UID
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid)
        let deviceUID = uidStatus == noErr ? (uid as String) : "<no uid>"

        // Get manufacturer
        var mfrAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyManufacturer,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mfr: CFString = "" as CFString
        var mfrSize = UInt32(MemoryLayout<CFString>.size)
        let mfrStatus = AudioObjectGetPropertyData(deviceID, &mfrAddr, 0, nil, &mfrSize, &mfr)
        let manufacturer = mfrStatus == noErr ? (mfr as String) : ""

        // Get input channel count
        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inSize: UInt32 = 0
        var inputCh = 0
        if AudioObjectGetPropertyDataSize(deviceID, &inAddr, 0, nil, &inSize) == noErr, inSize > 0 {
            let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(inSize), alignment: 8)
            defer { buf.deallocate() }
            if AudioObjectGetPropertyData(deviceID, &inAddr, 0, nil, &inSize, buf) == noErr {
                let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
                let count = Int(abl.pointee.mNumberBuffers)
                let offset = MemoryLayout.offset(of: \AudioBufferList.mBuffers)!
                for i in 0..<count {
                    let ab = buf.advanced(by: offset + i * MemoryLayout<AudioBuffer>.stride)
                        .assumingMemoryBound(to: AudioBuffer.self)
                    inputCh += Int(ab.pointee.mNumberChannels)
                }
            }
        }

        let isSymphony = deviceName.lowercased().contains("symphony")
            || deviceName.lowercased().contains("apogee")
            || deviceUID.lowercased().contains("symphony")
            || deviceUID.lowercased().contains("apogee")
            || manufacturer.lowercased().contains("apogee")

        let marker = isSymphony ? " <<<< APOGEE" : ""
        print("  [\(deviceID)] \"\(deviceName)\" (\(inputCh)in) uid=\(deviceUID) mfr=\(manufacturer)\(marker)")

        if isSymphony && symphonyDeviceID == nil {
            symphonyDeviceID = deviceID
        }
    }

    print("")

    guard let targetID = symphonyDeviceID else {
        print("NO APOGEE/SYMPHONY DEVICE FOUND IN COREAUDIO.")
        print("The HAL plugin may not be loaded or the device is not recognized.")
        print("")
        print("Check: ls /Library/Audio/Plug-Ins/HAL/Apogee/")
        print("Check: ps aux | grep symphony")
        return
    }

    print("=== Testing custom properties on device \(targetID) ===")
    print("")

    print("")

    // Step 3: Try reading specific properties through CoreAudio
    let testProperties: [(String, AudioObjectPropertySelector, AudioObjectPropertyScope, AudioObjectPropertyElement)] = [
        // Standard CoreAudio properties that should always work
        ("kAudioDevicePropertyNominalSampleRate", kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0),
        ("kAudioDevicePropertyDeviceIsAlive", kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, 0),

        // Apogee custom properties (our FourCC selectors)
        ("outputMute 'AEm3' (kmAEstroPropertyMainOutMute)", AudioPropertySelector("AEm3").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("outputMute 'AEm1' (kApogeeCustomProperty_OutputMute)", AudioPropertySelector("AEm1").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("outputLevel 'AEl3'", AudioPropertySelector("AEl3").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("sampleRate 'AEf1'", AudioPropertySelector("AEf1").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("clockSource 'AEck'", AudioPropertySelector("AEck").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("clockStatus 'AEs3'", AudioPropertySelector("AEs3").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("micGain 'AEmg' ch0", AudioPropertySelector("AEmg").rawValue, kAudioObjectPropertyScopeInput, 0),
        ("phantom 'AEph' ch0", AudioPropertySelector("AEph").rawValue, kAudioObjectPropertyScopeInput, 0),
        ("meterData 'AEmD'", AudioPropertySelector("AEmD").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("version 'AEve'", AudioPropertySelector("AEve").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("versionString 'AEt1'", AudioPropertySelector("AEt1").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("daemonAlive 'AEda'", AudioPropertySelector("AEda").rawValue, kAudioObjectPropertyScopeGlobal, 0),
        ("deviceType 'AEdt'", AudioPropertySelector("AEdt").rawValue, kAudioObjectPropertyScopeGlobal, 0),
    ]

    for (label, selector, scope, element) in testProperties {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let exists = AudioObjectHasProperty(targetID, &addr)

        if !exists {
            print("  \(label): NOT FOUND (hasProperty=false)")
            continue
        }

        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(targetID, &addr, &settable)

        // Try to get the property size
        var propSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(targetID, &addr, 0, nil, &propSize)
        if sizeStatus != noErr {
            print("  \(label): EXISTS but getSize failed (\(sizeStatus)) settable=\(settable)")
            continue
        }

        // Try to read it
        if propSize <= 8 {
            // Small value — try reading as raw bytes
            var buf = [UInt8](repeating: 0, count: max(Int(propSize), 8))
            var readSize = max(propSize, 8)
            let readStatus = buf.withUnsafeMutableBytes { ptr -> OSStatus in
                AudioObjectGetPropertyData(targetID, &addr, 0, nil, &readSize, ptr.baseAddress!)
            }
            if readStatus == noErr {
                let hexBytes = buf.prefix(Int(readSize)).map { String(format: "%02x", $0) }.joined(separator: " ")
                // Also try interpreting as UInt32 and Float64
                var extra = ""
                if readSize == 4 {
                    let u32 = buf.withUnsafeBytes { $0.load(as: UInt32.self) }
                    extra = " (UInt32=\(u32))"
                } else if readSize == 8 {
                    let f64 = buf.withUnsafeBytes { $0.load(as: Float64.self) }
                    extra = " (Float64=\(f64))"
                }
                print("  \(label): OK size=\(readSize) data=[\(hexBytes)]\(extra) settable=\(settable)")
            } else {
                print("  \(label): EXISTS size=\(propSize) but READ FAILED (\(readStatus)) settable=\(settable)")
            }
        } else {
            // Large value — just report size
            print("  \(label): EXISTS size=\(propSize) settable=\(settable) (large, not read)")
        }
    }

    // Step 4: Try the DEPRECATED AudioDeviceGetProperty API
    // The old AudioDriverPlugIn API (which this plugin uses) intercepts
    // AudioDeviceGetProperty calls, not AudioObjectGetPropertyData calls.
    print("")
    print("=== Testing DEPRECATED AudioDeviceGetProperty API ===")
    print("(This maps directly to AudioDriverPlugInDeviceGetProperty)")
    print("")

    let legacyTests: [(String, UInt32, UInt32, Bool)] = [
        // (label, propertyID, channel, isInput)
        ("outputMute 'AEm3'", AudioPropertySelector("AEm3").rawValue, 0, false),
        ("outputMute 'AEm1'", AudioPropertySelector("AEm1").rawValue, 0, false),
        ("outputLevel 'AEl3'", AudioPropertySelector("AEl3").rawValue, 0, false),
        ("sampleRate 'AEf1'", AudioPropertySelector("AEf1").rawValue, 0, false),
        ("clockSource 'AEck'", AudioPropertySelector("AEck").rawValue, 0, false),
        ("daemonAlive 'AEda'", AudioPropertySelector("AEda").rawValue, 0, false),
        ("micGain 'AEmg' ch0", AudioPropertySelector("AEmg").rawValue, 0, true),
        ("phantom 'AEph' ch0", AudioPropertySelector("AEph").rawValue, 0, true),
        ("version 'AEve'", AudioPropertySelector("AEve").rawValue, 0, false),
        ("deviceType 'AEdt'", AudioPropertySelector("AEdt").rawValue, 0, false),
        ("meterData 'AEmD'", AudioPropertySelector("AEmD").rawValue, 0, false),
    ]

    for (label, propertyID, channel, isInput) in legacyTests {
        // Use the C shim to call the deprecated AudioDeviceGetPropertyInfo/GetProperty
        var propSize: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoStatus = LegacyAudioDeviceGetPropertyInfo(
            targetID, channel, isInput, propertyID, &propSize, &writable
        )

        if infoStatus != noErr {
            print("  \(label): NOT FOUND via legacy API (error \(infoStatus))")
            continue
        }

        let isWritable = writable.boolValue

        // Try to read it
        if propSize > 0 && propSize <= 256 {
            var buf = [UInt8](repeating: 0, count: Int(propSize))
            var readSize = propSize
            let readStatus = LegacyAudioDeviceGetProperty(
                targetID, channel, isInput, propertyID, &readSize, &buf
            )
            if readStatus == noErr {
                let hexBytes = buf.prefix(min(Int(readSize), 16)).map { String(format: "%02x", $0) }.joined(separator: " ")
                var extra = ""
                if readSize == 4 {
                    let u32 = buf.withUnsafeBytes { $0.load(as: UInt32.self) }
                    extra = " (UInt32=\(u32))"
                } else if readSize == 8 {
                    let f64 = buf.withUnsafeBytes { $0.load(as: Float64.self) }
                    extra = " (Float64=\(f64))"
                }
                print("  \(label): OK size=\(readSize) data=[\(hexBytes)]\(extra) writable=\(writable)")
            } else {
                print("  \(label): EXISTS size=\(propSize) but READ FAILED (\(readStatus)) writable=\(writable)")
            }
        } else if propSize > 256 {
            print("  \(label): EXISTS size=\(propSize) writable=\(writable) (large, not read)")
        } else {
            print("  \(label): EXISTS size=0 writable=\(writable)")
        }
    }

    // Step 5: Try the UNIX socket connection to the daemon directly
    print("")
    print("=== Checking daemon socket ===")
    let socketPath = "/var/run/com.apogee.symphonyIOUSBDaemon/Socket"
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: socketPath) {
        print("  Socket exists at \(socketPath)")
        var statBuf = stat()
        if lstat(socketPath, &statBuf) == 0 {
            let isSocket = (statBuf.st_mode & S_IFMT) == S_IFSOCK
            print("  Is UNIX socket: \(isSocket)")
        }
    } else {
        let dirPath = "/var/run/com.apogee.symphonyIOUSBDaemon"
        if fileManager.fileExists(atPath: dirPath) {
            let contents = try? fileManager.contentsOfDirectory(atPath: dirPath)
            print("  Socket dir exists, contents: \(contents ?? [])")
        } else {
            print("  Socket dir NOT FOUND at \(dirPath)")
        }
        print("")
        print("=== Diagnostic complete ===")
        return
    }

    // Step 6: Probe the daemon socket with MaestroLink protocol
    print("")
    print("=== Probing daemon via MaestroLink protocol ===")
    await probeDaemonSocket(socketPath: socketPath, audioDeviceID: targetID)

    print("")
    print("=== Diagnostic complete ===")
}

// MARK: - MaestroLink Daemon Socket Probe

/// Probe the daemon via the MaestroLink IPC protocol.
/// Sends registration + GetProperty messages and checks responses.
///
/// Wire format (Little Endian, no CRC):
///   [4] Magic: 'MLNK' as UInt32 (0x4D4C4E4B on LE = bytes 4B 4E 4C 4D)
///   [4] PacketSize: size of payload after this header
///   [N] Packed message payload
///
/// Evidence: og_source/maestrolink/Software/Messaging/MessageTX.cpp,
///           og_source/maestrolink/Software/Messaging/apogeeDriverPlugInMessageTypes/
func probeDaemonSocket(socketPath: String, audioDeviceID: AudioDeviceID) async {
    // Create UNIX domain socket
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        print("  FAIL: Cannot create socket (errno \(errno))")
        return
    }
    defer { close(fd) }

    // Ignore SIGPIPE (daemon may close connection)
    signal(SIGPIPE, SIG_IGN)

    // Connect to daemon socket
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
        pathBytes.withUnsafeBufferPointer { pathBuf in
            let dest = UnsafeMutableRawPointer(sunPathPtr)
            dest.copyMemory(from: pathBuf.baseAddress!, byteCount: min(pathBuf.count, 104))
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    guard connectResult == 0 else {
        print("  FAIL: Cannot connect to daemon socket (errno \(errno): \(String(cString: strerror(errno))))")
        return
    }
    print("  Connected to daemon socket!")

    // Build and send Registration message
    // Struct layout (all native LE, memcpy'd in sequence):
    //   TransportableContents: [UInt32 totalPackedSize][UInt32 objectType][UInt8 byteOrder][3 pad]  = 12 bytes
    //   MessageContent:        [UInt32 uniqueID][SInt32 priority][UInt32 pid][UInt8 msgType][3 pad] = 16 bytes
    //   RegistrationContent:   [UInt32 audioDeviceID][UInt32 uidStrLen][UInt32 bundleIDStrLen]      = 12 bytes
    //   DeviceUID string:      null-terminated
    //   BundleID string:       null-terminated

    let deviceUID = "AppleUSBAudioEngine:Apogee:Symphony I/O : USB Audio:2100000:1,2"
    let bundleID = "com.apogee.MaestroApp"
    let uidBytes = Array(deviceUID.utf8) + [0]  // null-terminated
    let bundleBytes = Array(bundleID.utf8) + [0]

    let regFixedSize = 12 + 16 + 12  // Transportable + Message + Registration
    let regTotalPacked = regFixedSize + uidBytes.count + bundleBytes.count

    var regPayload = Data(count: regTotalPacked)
    regPayload.withUnsafeMutableBytes { buf in
        var offset = 0
        let ptr = buf.baseAddress!

        // TransportableContents (12 bytes)
        var totalPackedSize = UInt32(regTotalPacked)
        var objectType = UInt32(3)  // cTransportableDataTypeEncoding_ApogeeDriverPlugInMessageRegistration
        var byteOrder: UInt8 = 0x4C  // 'L' for Little Endian

        memcpy(ptr + offset, &totalPackedSize, 4); offset += 4
        memcpy(ptr + offset, &objectType, 4); offset += 4
        memcpy(ptr + offset, &byteOrder, 1); offset += 1
        offset += 3  // padding

        // MessageContent (16 bytes)
        var uniqueID = UInt32(1)
        var priority = Int32(4)  // Registration priority (high)
        var pid = UInt32(getpid())
        var msgType: UInt8 = 0x01  // kmAEstroPlugInMessageCode_PluginRegisters

        memcpy(ptr + offset, &uniqueID, 4); offset += 4
        memcpy(ptr + offset, &priority, 4); offset += 4
        memcpy(ptr + offset, &pid, 4); offset += 4
        memcpy(ptr + offset, &msgType, 1); offset += 1
        offset += 3  // padding

        // RegistrationMessageContent (12 bytes)
        var devID = UInt32(audioDeviceID)
        var uidLen = UInt32(uidBytes.count)
        var bundleLen = UInt32(bundleBytes.count)

        memcpy(ptr + offset, &devID, 4); offset += 4
        memcpy(ptr + offset, &uidLen, 4); offset += 4
        memcpy(ptr + offset, &bundleLen, 4); offset += 4

        // DeviceUID string
        uidBytes.withUnsafeBufferPointer { uidBuf in
            memcpy(ptr + offset, uidBuf.baseAddress!, uidBytes.count)
        }
        offset += uidBytes.count

        // BundleID string
        bundleBytes.withUnsafeBufferPointer { bundleBuf in
            memcpy(ptr + offset, bundleBuf.baseAddress!, bundleBytes.count)
        }
    }

    // Send framed message: [4 magic][4 size][payload]
    let magic = UInt32(0x4D4C4E4B)  // 'MLNK'
    var frame = Data()
    var magicVal = magic
    var packetSize = UInt32(regPayload.count)
    frame.append(Data(bytes: &magicVal, count: 4))
    frame.append(Data(bytes: &packetSize, count: 4))
    frame.append(regPayload)

    let hexPreview = frame.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
    print("  Sending Registration (\(frame.count) bytes): \(hexPreview)...")

    let sent = frame.withUnsafeBytes { buf in
        Darwin.send(fd, buf.baseAddress!, buf.count, 0)
    }
    guard sent == frame.count else {
        print("  FAIL: send() returned \(sent), expected \(frame.count) (errno \(errno))")
        return
    }
    print("  Sent \(sent) bytes")

    // Wait for response with timeout
    var pollFd = pollfd(fd: Int32(fd), events: Int16(POLLIN), revents: 0)
    let pollResult = poll(&pollFd, 1, 2000)  // 2 second timeout
    guard pollResult > 0 else {
        print("  FAIL: No response from daemon (timeout or error, poll=\(pollResult))")
        return
    }

    // Read response frame
    var responseBuf = [UInt8](repeating: 0, count: 4096)
    let bytesRead = recv(fd, &responseBuf, responseBuf.count, 0)
    guard bytesRead > 8 else {
        print("  FAIL: Response too short (\(bytesRead) bytes)")
        return
    }

    let responseHex = responseBuf.prefix(min(bytesRead, 48)).map { String(format: "%02x", $0) }.joined(separator: " ")
    print("  Response (\(bytesRead) bytes): \(responseHex)")

    // Parse response frame header
    let respMagic = responseBuf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
    let respSize = responseBuf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
    print("  Response magic: 0x\(String(respMagic, radix: 16)) size: \(respSize)")

    if respMagic == magic {
        print("  Magic matches MLNK!")
        // Parse Transportable header
        let respObjType = responseBuf.withUnsafeBytes { $0.load(fromByteOffset: 8 + 4, as: UInt32.self) }
        let respByteOrder = responseBuf[8 + 8]
        // Parse MessageContent
        let respMsgType = responseBuf[8 + 12 + 12]
        print("  Object type: \(respObjType), byte order: \(Character(UnicodeScalar(respByteOrder))), msg type: 0x\(String(format: "%02x", respMsgType))")

        if respMsgType == 0x02 {
            print("  GOT REGISTRATION RESPONSE! Daemon accepted our connection!")
            // Parse ResponseContents
            let respReturn = responseBuf.withUnsafeBytes { $0.load(fromByteOffset: 8 + 12 + 16, as: UInt32.self) }
            print("  Return status: \(respReturn) (\(respReturn == 0 ? "SUCCESS" : "error"))")
        }
    } else {
        print("  WARNING: Unexpected magic number")
    }

    // Now try a GetProperty request for 'AEda' (daemonAlive)
    print("")
    print("  Sending GetProperty for daemonAlive 'AEda'...")

    let getFixedSize = 12 + 16 + 28  // Transportable + Message + GetPropertyContents
    var getPayload = Data(count: getFixedSize)
    getPayload.withUnsafeMutableBytes { buf in
        var offset = 0
        let ptr = buf.baseAddress!

        // TransportableContents
        var totalPacked = UInt32(getFixedSize)
        var objType = UInt32(4)  // cTransportableDataTypeEncoding_ApogeeDriverPlugInMessageGetProperty
        var bo: UInt8 = 0x4C
        memcpy(ptr + offset, &totalPacked, 4); offset += 4
        memcpy(ptr + offset, &objType, 4); offset += 4
        memcpy(ptr + offset, &bo, 1); offset += 1
        offset += 3

        // MessageContent
        var uid = UInt32(2)  // second message
        var prio = Int32(3)  // GetProperty priority
        var pidVal = UInt32(getpid())
        var mt: UInt8 = 0x05  // kmAEstroPlugInMessageCode_GetProperty
        memcpy(ptr + offset, &uid, 4); offset += 4
        memcpy(ptr + offset, &prio, 4); offset += 4
        memcpy(ptr + offset, &pidVal, 4); offset += 4
        memcpy(ptr + offset, &mt, 1); offset += 1
        offset += 3

        // GetPropertyContents
        var devCtrl = UInt32(0)
        var nonCA = UInt32(0)
        var propID = AudioPropertySelector("AEda").rawValue  // daemonAlive
        var channel = UInt32(0)
        var maxReturn = UInt32(4096)
        var inputSize = UInt32(0)
        var isInput: UInt8 = 0
        memcpy(ptr + offset, &devCtrl, 4); offset += 4
        memcpy(ptr + offset, &nonCA, 4); offset += 4
        memcpy(ptr + offset, &propID, 4); offset += 4
        memcpy(ptr + offset, &channel, 4); offset += 4
        memcpy(ptr + offset, &maxReturn, 4); offset += 4
        memcpy(ptr + offset, &inputSize, 4); offset += 4
        memcpy(ptr + offset, &isInput, 1); offset += 1
    }

    var getFrame = Data()
    var getMagic = magic
    var getSize = UInt32(getPayload.count)
    getFrame.append(Data(bytes: &getMagic, count: 4))
    getFrame.append(Data(bytes: &getSize, count: 4))
    getFrame.append(getPayload)

    let getSent = getFrame.withUnsafeBytes { buf in
        Darwin.send(fd, buf.baseAddress!, buf.count, 0)
    }
    guard getSent == getFrame.count else {
        print("  FAIL: GetProperty send() returned \(getSent)")
        return
    }

    // Wait for response
    var getPoll = pollfd(fd: Int32(fd), events: Int16(POLLIN), revents: 0)
    let getPollResult = poll(&getPoll, 1, 2000)
    guard getPollResult > 0 else {
        print("  FAIL: No GetProperty response (timeout)")
        return
    }

    var getRespBuf = [UInt8](repeating: 0, count: 4096)
    let getRead = recv(fd, &getRespBuf, getRespBuf.count, 0)
    guard getRead > 8 else {
        print("  FAIL: GetProperty response too short (\(getRead) bytes)")
        return
    }

    let getHex = getRespBuf.prefix(min(getRead, 64)).map { String(format: "%02x", $0) }.joined(separator: " ")
    print("  GetProperty response (\(getRead) bytes): \(getHex)")

    // Parse response
    let getMsgType = getRespBuf[8 + 12 + 12]  // Skip frame + Transportable + msg prefix to get msgType
    print("  Message type: 0x\(String(format: "%02x", getMsgType))")

    if getMsgType == 0x06 {  // GetPropertyResponse
        let status = getRespBuf.withUnsafeBytes { $0.load(fromByteOffset: 8 + 12 + 16, as: UInt32.self) }
        let returnSize = getRespBuf.withUnsafeBytes { $0.load(fromByteOffset: 8 + 12 + 16 + 8, as: UInt32.self) }
        print("  Return status: \(status) (\(status == 0 ? "SUCCESS" : "error")), data size: \(returnSize)")
        if status == 0 && returnSize > 0 {
            let dataOffset = 8 + 12 + 16 + 12  // frame + Transportable + Message + Response header
            let dataHex = getRespBuf[dataOffset..<min(dataOffset + Int(returnSize), getRead)]
                .map { String(format: "%02x", $0) }.joined(separator: " ")
            print("  Return data: [\(dataHex)]")
        }
    }

    // Try more properties
    let probeProperties: [(String, UInt32, UInt32, Bool)] = [
        ("outputMute 'AEm3'", AudioPropertySelector("AEm3").rawValue, 0, false),
        ("outputLevel 'AEl3'", AudioPropertySelector("AEl3").rawValue, 0, false),
        ("version 'AEve'", AudioPropertySelector("AEve").rawValue, 0, false),
        ("meterData 'AEmD'", AudioPropertySelector("AEmD").rawValue, 0, false),
        ("micGain 'AEmg' ch0", AudioPropertySelector("AEmg").rawValue, 0, true),
    ]

    var msgCounter: UInt32 = 3
    for (label, propID, channel, isInput) in probeProperties {
        msgCounter += 1
        var propPayload = Data(count: getFixedSize)
        propPayload.withUnsafeMutableBytes { buf in
            var offset = 0
            let ptr = buf.baseAddress!
            var totalPacked = UInt32(getFixedSize)
            var objType = UInt32(4)
            var bo: UInt8 = 0x4C
            memcpy(ptr + offset, &totalPacked, 4); offset += 4
            memcpy(ptr + offset, &objType, 4); offset += 4
            memcpy(ptr + offset, &bo, 1); offset += 1
            offset += 3
            var uid = msgCounter
            var prio = Int32(3)
            var pidVal = UInt32(getpid())
            var mt: UInt8 = 0x05
            memcpy(ptr + offset, &uid, 4); offset += 4
            memcpy(ptr + offset, &prio, 4); offset += 4
            memcpy(ptr + offset, &pidVal, 4); offset += 4
            memcpy(ptr + offset, &mt, 1); offset += 1
            offset += 3
            var devCtrl = UInt32(0)
            var nonCA = UInt32(0)
            var prop = propID
            var ch = channel
            var maxRet = UInt32(4096)
            var inSize = UInt32(0)
            var isIn: UInt8 = isInput ? 1 : 0
            memcpy(ptr + offset, &devCtrl, 4); offset += 4
            memcpy(ptr + offset, &nonCA, 4); offset += 4
            memcpy(ptr + offset, &prop, 4); offset += 4
            memcpy(ptr + offset, &ch, 4); offset += 4
            memcpy(ptr + offset, &maxRet, 4); offset += 4
            memcpy(ptr + offset, &inSize, 4); offset += 4
            memcpy(ptr + offset, &isIn, 1); offset += 1
        }
        var propFrame = Data()
        var pm = magic
        var ps = UInt32(propPayload.count)
        propFrame.append(Data(bytes: &pm, count: 4))
        propFrame.append(Data(bytes: &ps, count: 4))
        propFrame.append(propPayload)

        let pSent = propFrame.withUnsafeBytes { buf in Darwin.send(fd, buf.baseAddress!, buf.count, 0) }
        guard pSent == propFrame.count else {
            print("  \(label): FAIL send")
            continue
        }

        var pPoll = pollfd(fd: Int32(fd), events: Int16(POLLIN), revents: 0)
        guard poll(&pPoll, 1, 2000) > 0 else {
            print("  \(label): FAIL timeout")
            continue
        }

        var pResp = [UInt8](repeating: 0, count: 4096)
        let pRead = recv(fd, &pResp, pResp.count, 0)
        guard pRead > 8 + 12 + 16 + 12 else {
            print("  \(label): FAIL short response (\(pRead) bytes)")
            continue
        }

        let pMsgType = pResp[8 + 12 + 12]
        let pStatus = pResp.withUnsafeBytes { $0.load(fromByteOffset: 8 + 12 + 16, as: UInt32.self) }
        let pRetSize = pResp.withUnsafeBytes { $0.load(fromByteOffset: 8 + 12 + 16 + 8, as: UInt32.self) }

        if pMsgType == 0x06 && pStatus == 0 {
            let dataOff = 8 + 12 + 16 + 12
            let dataHex = pResp[dataOff..<min(dataOff + min(Int(pRetSize), 16), pRead)]
                .map { String(format: "%02x", $0) }.joined(separator: " ")
            var extra = ""
            if pRetSize == 4 {
                let u32 = pResp.withUnsafeBytes { $0.load(fromByteOffset: dataOff, as: UInt32.self) }
                extra = " (UInt32=\(u32))"
            } else if pRetSize == 8 {
                let f64 = pResp.withUnsafeBytes { $0.load(fromByteOffset: dataOff, as: Float64.self) }
                extra = " (Float64=\(f64))"
            }
            print("  \(label): OK data=[\(dataHex)]\(extra)")
        } else {
            print("  \(label): type=0x\(String(format: "%02x", pMsgType)) status=\(pStatus) retSize=\(pRetSize)")
        }
    }

}

// MARK: - Daemon Mute Round-Trip Test

/// Test mute write→read via the SAME DaemonSocket/CoreAudioDeviceConnection code path
/// the app uses. This is an automated hardware verification test.
func runDaemonMuteTest() async {
        print("=== Daemon IPC Mute Round-Trip Test ===")
        print("Uses the same CoreAudioDeviceConnection code as the app.")
        print("")

        // Step 1: Discover device via CoreAudio
        print("Step 1: Discover Symphony IO via CoreAudio...")
        guard let (audioDeviceID, identifier) = CoreAudioDeviceConnection.discoverSymphonyIO() else {
            print("  FAIL: No Symphony IO device found via CoreAudio.")
            print("  Is the device connected and powered on?")
            return
        }
        print("  PASS: Found device ID=\(audioDeviceID), pid=\(identifier.productID)")

        // Step 2: Connect to daemon
        print("")
        print("Step 2: Connect to daemon socket...")
        let connection = CoreAudioDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
        do {
            try connection.connectToDaemon()
            print("  PASS: Connected and registered with daemon")
        } catch {
            print("  FAIL: \(error)")
            return
        }

        // Step 3: Read current mute state
        print("")
        print("Step 3: Read current outputMute state...")
        let muteAddr = PropertyAddress(selector: .outputMute, scope: .output, element: 0)
        let originalMute: Bool
        do {
            let value = try await connection.getProperty(muteAddr)
            switch value {
            case .bool(let b):
                originalMute = b
                print("  PASS: outputMute = \(b) (decoded as Bool)")
            case .uint32(let v):
                originalMute = v != 0
                print("  PASS: outputMute = \(v) (decoded as UInt32, bool=\(originalMute))")
            default:
                print("  FAIL: Unexpected value type: \(value)")
                return
            }
        } catch {
            print("  FAIL: getProperty(.outputMute) threw: \(error)")
            return
        }

        // Step 4: SetProperty with debug logging
        // DaemonSocket now prints raw response hex for debugging
        let newMute = !originalMute
        print("")
        print("Step 4: Set outputMute = \(newMute) (toggle from \(originalMute))...")
        print("  (DaemonSocket will print raw response hex below)")
        do {
            try await connection.setProperty(muteAddr, value: .bool(newMute))
            print("  PASS: setProperty(.outputMute, .bool(\(newMute))) succeeded")
        } catch {
            print("  Error: \(error)")
            // Don't return early — continue to read-back and restore
        }

        // Step 5: Read back
        print("")
        print("Step 5: Read back mute state...")
        try? await Task.sleep(nanoseconds: 200_000_000)
        do {
            let readBack = try await connection.getProperty(muteAddr)
            print("  outputMute = \(readBack)")
        } catch {
            print("  Read-back error: \(error)")
        }

        // Step 6: Restore original state (ALWAYS try this)
        print("")
        print("Step 6: Restore original mute (\(originalMute))...")
        do {
            try await connection.setProperty(muteAddr, value: .bool(originalMute))
            print("  Restored")
        } catch {
            print("  Restore error: \(error)")
        }

        // Step 7: Read output level
        print("")
        print("Step 7: Read outputLevel...")
        do {
            let v = try await connection.getProperty(
                PropertyAddress(selector: .outputLevel, scope: .output, element: 0))
            print("  outputLevel = \(v)")
        } catch {
            print("  Error: \(error)")
        }

        await connection.disconnect()
        print("")
        print("=== Done ===")
}

// MARK: - --probe-inputs mode

/// Probe all input/output channel properties via the daemon IPC, trying every
/// combination of (property, channel 0-4, isInput true/false) and reporting
/// what the daemon actually returns vs. 'who?' (error 2003332927).
func runProbeInputs() async {
    print("=== Daemon Property Probe: Input/Output Channels ===")
    print("Probes each property × channel × isInput combination.")
    print("Reports raw UInt32 value or error for each combination.")
    print("")

    // Step 1: Discover device via CoreAudio
    print("Discovering Symphony IO via CoreAudio...")
    guard let (audioDeviceID, identifier) = CoreAudioDeviceConnection.discoverSymphonyIO() else {
        print("FAIL: No Symphony IO device found via CoreAudio.")
        return
    }
    print("Found device ID=\(audioDeviceID), pid=\(identifier.productID)")
    print("")

    // Step 2: Connect to daemon
    let connection = CoreAudioDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
    do {
        try connection.connectToDaemon()
        print("Connected to daemon socket.")
    } catch {
        // Modern USB installs use MaestroVolumeProxy for EP0 ownership and do
        // not ship the legacy daemon socket. Keep this diagnostic useful by
        // probing the same proxy path the app uses instead of reporting a
        // false meter failure.
        print("Legacy daemon unavailable: \(error)")
        print("Falling back to MaestroVolumeProxy meter reads...")
        await runProxyMeterProbe(identifier: identifier)
        return
    }
    print("")

    // Access the DaemonSocket directly for raw probing
    // We use the public getProperty on CoreAudioDeviceConnection via PropertyAddress

    // Helper: format a FourCC UInt32 as 'XXXX'
    func fourCC(_ v: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF),
        ]
        let chars = bytes.map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "?" }
        return "'" + chars.joined() + "'"
    }

    // Probe a single (selector, channel, isInput) combination.
    // Returns a human-readable result string.
    func probe(selector: AudioPropertySelector, channel: UInt32, isInput: Bool) async -> String {
        let scope: PropertyScope = isInput ? .input : .output
        let addr = PropertyAddress(selector: selector, scope: scope, element: channel)
        do {
            let val = try await connection.getProperty(addr)
            switch val {
            case .uint32(let v): return "UInt32(\(v))"
            case .bool(let b):   return "Bool(\(b))"
            case .float64(let f): return "Float64(\(f))"
            case .data(let d):
                let hex = d.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                return "Data[\(d.count)] \(hex)\(d.count > 16 ? "..." : "")"
            default: return "\(val)"
            }
        } catch let err as DeviceConnectionError {
            switch err {
            case .transportError(let msg): return "transportError: \(msg)"
            default: return "error: \(err)"
            }
        } catch {
            let desc = "\(error)"
            if desc.contains("2003332927") || desc.contains("who?") || desc.contains("unrecognized") {
                return "who? (2003332927)"
            }
            return "error: \(desc)"
        }
    }

    // ----- Input Channel Properties -----
    // These are per-channel preamp controls. Channels 0=global?, 1-8=physical inputs
    let inputProps: [(name: String, sel: AudioPropertySelector)] = [
        ("micGain",       .micGain),
        ("analogIOType",  .analogIOType),
        ("phantom",       .phantom),
        ("phaseReverse",  .phaseReverse),
        ("highPassFilter",.highPassFilter),
        ("softLimit",     .softLimit),
        ("gainRange",     .gainRange),
        ("insertID",      .insertID),
        ("groupID",       .groupID),
    ]

    print("--- INPUT CHANNEL PROPERTIES ---")
    for prop in inputProps {
        print("Property: \(prop.name) [\(fourCC(prop.sel.rawValue))]")
        for ch: UInt32 in 0...4 {
            for isInput in [true, false] {
                let result = await probe(selector: prop.sel, channel: ch, isInput: isInput)
                let tag = isInput ? "input" : "output"
                print("  ch=\(ch) isInput=\(isInput ? "true " : "false") [\(tag)]: \(result)")
            }
        }
        print("")
    }

    // ----- Output / Peripheral Properties -----
    let outputProps: [(name: String, sel: AudioPropertySelector)] = [
        ("outputLevel",    .outputLevel),
        ("outputMute",     .outputMute),
        ("outputDim",      .outputDim),
        ("outputSumToMono",.outputSumToMono),
    ]

    print("--- OUTPUT / MONITOR PROPERTIES ---")
    for prop in outputProps {
        print("Property: \(prop.name) [\(fourCC(prop.sel.rawValue))]")
        for ch: UInt32 in 0...2 {
            for isInput in [true, false] {
                let result = await probe(selector: prop.sel, channel: ch, isInput: isInput)
                print("  ch=\(ch) isInput=\(isInput ? "true " : "false"): \(result)")
            }
        }
        print("")
    }

    // ----- Headphone Properties -----
    let hpProps: [(name: String, sel: AudioPropertySelector)] = [
        ("headphone1Level",  .headphone1Level),
        ("headphone1Mute",   .headphone1Mute),
        ("headphone1RoutingID", .headphone1RoutingID),
        ("headphone2Level",  .headphone2Level),
        ("headphone2Mute",   .headphone2Mute),
        ("headphone2RoutingID", .headphone2RoutingID),
        ("headphone1RoutingID", .headphone1RoutingID),
        ("headphone2RoutingID", .headphone2RoutingID),
    ]

    print("--- HEADPHONE PROPERTIES ---")
    for prop in hpProps {
        print("Property: \(prop.name) [\(fourCC(prop.sel.rawValue))]")
        for ch: UInt32 in 0...2 {
            for isInput in [true, false] {
                let result = await probe(selector: prop.sel, channel: ch, isInput: isInput)
                print("  ch=\(ch) isInput=\(isInput ? "true " : "false"): \(result)")
            }
        }
        print("")
    }

    // ----- Clock / System Properties -----
    let clockProps: [(name: String, sel: AudioPropertySelector)] = [
        ("clockSource",    .clockSource),
        ("clockStatus",    .clockStatus),
        ("opticalInFormat",.opticalInFormat),
        ("opticalOutFormat",.opticalOutFormat),
        ("digitalRefLevel",.digitalRefLevel),
    ]

    print("--- CLOCK / SYSTEM PROPERTIES ---")
    for prop in clockProps {
        print("Property: \(prop.name) [\(fourCC(prop.sel.rawValue))]")
        for ch: UInt32 in [0, 1] {
            for isInput in [true, false] {
                let result = await probe(selector: prop.sel, channel: ch, isInput: isInput)
                print("  ch=\(ch) isInput=\(isInput ? "true " : "false"): \(result)")
            }
        }
        print("")
    }

    // ----- Device Info Properties -----
    let infoProps: [(name: String, sel: AudioPropertySelector)] = [
        ("version",     .version),
        ("daemonAlive", .daemonAlive),
        ("deviceType",  .deviceType),
        ("dirtyCount",  .dirtyCount),
    ]

    print("--- DEVICE INFO PROPERTIES ---")
    for prop in infoProps {
        print("Property: \(prop.name) [\(fourCC(prop.sel.rawValue))]")
        for ch: UInt32 in [0] {
            for isInput in [true, false] {
                let result = await probe(selector: prop.sel, channel: ch, isInput: isInput)
                print("  ch=\(ch) isInput=\(isInput ? "true " : "false"): \(result)")
            }
        }
        print("")
    }

    await connection.disconnect()
    print("=== Probe Complete ===")
}

/// Read the input meter through the production proxy when the retired daemon
/// socket is absent (the normal path on current macOS USB installs).
private func runProxyMeterProbe(identifier: USBDeviceIdentifier) async {
    let connection = XPCDeviceConnection(identifier: identifier)
    defer { Task { await connection.disconnect() } }

    for attempt in 1...5 {
        do {
            let value = try await connection.getProperty(
                PropertyAddress(selector: .meterData, scope: .input, element: 0))
            switch value {
            case .data(let bytes):
                let preview = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("--- Proxy meter read attempt \(attempt)/5 ---")
                print("  input meter: \(bytes.count) bytes, hex=[\(preview)]")
            default:
                print("--- Proxy meter read attempt \(attempt)/5 ---")
                print("  input meter: \(value)")
            }
        } catch {
            print("--- Proxy meter read attempt \(attempt)/5 ---")
            print("  ERROR: \(error)")
        }
        if attempt < 5 {
            try? await Task.sleep(for: .seconds(2))
        }
    }
    print("=== Proxy Meter Probe Complete ===")
}

/// Focused meter data diagnostic — queries meters via daemon socket repeatedly
/// to see if the daemon's meter collection is working.
func runMeterProbeMode() async {
    print("=== Meter Probe: Daemon AEsm Diagnostic ===")
    print("")

    guard let (audioDeviceID, identifier) = CoreAudioDeviceConnection.discoverSymphonyIO() else {
        print("FAIL: No Symphony IO device found via CoreAudio.")
        return
    }
    print("Found device ID=\(audioDeviceID), pid=\(identifier.productID)")

    let connection = CoreAudioDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
    do {
        try connection.connectToDaemon()
        print("Connected to daemon socket.")
    } catch {
        print("FAIL: connectToDaemon: \(error)")
        return
    }
    print("")

    // Query meter data 5 times, 2 seconds apart
    // This ensures the daemon has time to collect fresh data from hardware
    for attempt in 1...5 {
        print("--- Meter read attempt \(attempt)/5 ---")
        connection.logMeterDiagnostics()
        print("")
        if attempt < 5 {
            print("Waiting 2 seconds for daemon to collect fresh meter data...")
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // Also try querying 'AEmD' (device-level meter) on daemon socket
    print("--- Testing 'AEmD' device-level meter ---")
    let meterDataPropID: UInt32 = 0x41456D44  // 'AEmD'
    let scope_output = PropertyAddress(selector: AudioPropertySelector(rawValue: meterDataPropID),
                                        scope: .output, element: 0)
    do {
        let val = try await connection.getProperty(scope_output)
        switch val {
        case .data(let d):
            let hex = d.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("  AEmD output: \(d.count) bytes, hex=[\(hex)]")
        default:
            print("  AEmD output: \(val)")
        }
    } catch {
        print("  AEmD output: \(error)")
    }
    let scope_input = PropertyAddress(selector: AudioPropertySelector(rawValue: meterDataPropID),
                                       scope: .input, element: 0)
    do {
        let val = try await connection.getProperty(scope_input)
        switch val {
        case .data(let d):
            let hex = d.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("  AEmD input: \(d.count) bytes, hex=[\(hex)]")
        default:
            print("  AEmD input: \(val)")
        }
    } catch {
        print("  AEmD input: \(error)")
    }

    await connection.disconnect()
    print("=== Meter Probe Complete ===")
    print("")
    print("If all meters show -inf, the daemon's meter collection is likely stalled.")
    print("Try restarting the daemon: sudo launchctl kickstart -k system/com.apogee.symphonyIOUSBDaemon")
}
