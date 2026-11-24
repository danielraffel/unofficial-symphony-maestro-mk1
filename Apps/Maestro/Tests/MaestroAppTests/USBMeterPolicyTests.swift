import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// A fake unit that answers every read with silent meters (or a failure) and
/// counts the reads per vendor request and meter group.
private final class MeterReadUnit: XPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [(request: UInt8, group: UInt16)] = []
    private var writeCount = 0
    /// Status the next reads answer with (0 = a good read).
    var status: Int64 = 0

    var meterReads: [UInt16] { lock.withLock { reads.filter { $0.request == 0x30 }.map(\.group) } }
    var writes: Int { lock.withLock { writeCount } }
    var isConnected: Bool { true }

    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        lock.withLock { writeCount += 1 }
    }
    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        let status = lock.withLock { () -> Int64 in reads.append((bRequest, wValue)); return self.status }
        return XPCPropertyReply(status: status, data: status == 0 ? Data(count: Int(dataLength)) : Data())
    }
    func getSoftwareMeterLevels() async -> (Float, Float)? { (0, 0) }
    func setSwReturnMute(_ muted: Bool) {}
    func setSwReturnLevel(_ dB: Double) {}
    func setSwReturnProcessing(_ enabled: Bool) {}
    func resetAudioOutput() {}
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {}
}

@Suite("USB meter plan")
struct USBMeterPlanTests {
    private static let meterPages: [NavigationArea] = [.input, .output, .mixer]

    @Test("nothing is read while Maestro's window cannot be seen, on any page")
    func hiddenWindowReadsNothing() {
        for area in NavigationArea.allCases {
            let plan = USBMeterPlan.plan(area: area, windowVisible: false, outputGroupUsable: true)
            #expect(!plan.active && plan.reads == 0, "\(area)")
        }
    }

    @Test("pages without meters read nothing")
    func pagesWithoutMeters() {
        for area in NavigationArea.allCases where !Self.meterPages.contains(area) {
            let plan = USBMeterPlan.plan(area: area, windowVisible: true, outputGroupUsable: true)
            #expect(!plan.active && plan.reads == 0, "\(area)")
        }
    }

    @Test("each meter page reads only the groups it shows")
    func groupsPerPage() {
        let input = USBMeterPlan.plan(area: .input, windowVisible: true, outputGroupUsable: true)
        #expect(input.active && input.input && !input.output && !input.mixer)
        let output = USBMeterPlan.plan(area: .output, windowVisible: true, outputGroupUsable: true)
        #expect(output.active && output.output && !output.input && !output.mixer)
        let mixer = USBMeterPlan.plan(area: .mixer, windowVisible: true, outputGroupUsable: true)
        #expect(mixer.active && mixer.input && mixer.mixer && !mixer.output)
        // Output group known to be residue: software output meters, no unit read.
        let software = USBMeterPlan.plan(area: .output, windowVisible: true, outputGroupUsable: false)
        #expect(software.active && software.reads == 0)
    }

    @Test("no page asks the unit for more than 20 groups a second")
    func readRate() {
        for area in Self.meterPages {
            let plan = USBMeterPlan.plan(area: area, windowVisible: true, outputGroupUsable: true)
            let seconds = Double(plan.interval.components.attoseconds) / 1e18 + Double(plan.interval.components.seconds)
            #expect(Double(plan.reads) / seconds <= 20, "\(area)")
        }
    }
}

@Suite("USB loss detector")
struct USBLossDetectorTests {
    @Test("one failed read, then a good one, is not a loss")
    func oneFailure() {
        var detector = USBLossDetector()
        let t = Date()
        detector.failed(.readFailed, at: t)
        #expect(detector.isFailing && !detector.lost)
        let r1 = detector.succeeded()
        #expect(!r1)
        #expect(!detector.isFailing)
    }

    @Test("the helper's 2 s meter backoff alone is not a loss")
    func backoffIsNotALoss() {
        var detector = USBLossDetector()
        let t = Date()
        for ms in stride(from: 0, through: 2000, by: 50) {
            detector.failed(.readFailed, at: t.addingTimeInterval(Double(ms) / 1000))
        }
        let r2 = detector.succeeded()
        #expect(!r2)
    }

    @Test("reads failing for longer than the backoff are a loss")
    func sustainedFailure() {
        var detector = USBLossDetector()
        let t = Date()
        detector.failed(.readFailed, at: t)
        detector.failed(.readFailed, at: t.addingTimeInterval(2.6))
        #expect(detector.lost)
        let r3 = detector.succeeded()
        #expect(r3)
        let r4 = detector.succeeded()
        #expect(!r4, "a loss is reported once")
    }

    @Test("the helper saying it has no unit open is a loss at once")
    func unitGone() {
        var detector = USBLossDetector()
        detector.failed(USBLossDetector.failure(for: DeviceConnectionError.notConnected), at: Date())
        let r5 = detector.succeeded()
        #expect(r5)
        #expect(USBLossDetector.failure(for: DeviceConnectionError.transportError("timeout")) == .readFailed)
    }
}

extension StandardDefaultsSuites {
@Suite("USB meter polling and recovery", .serialized)
@MainActor
struct USBMeterPollingTests {
    private func makeState(visible: Bool, area: NavigationArea) throws -> (AppState, XPCDeviceConnection, MeterReadUnit) {
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = .usb
        state.isHardwareInitialized = true
        state.selectedArea = area
        state.usbMeterWindowVisible = { visible }
        // No heartbeat inside these short runs unless a test asks for one.
        state.usbHealthInterval = .seconds(60)
        let unit = MeterReadUnit()
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "meter-policy-\(UUID())"))
        let usb = XPCDeviceConnection(identifier: id, transport: unit)
        state.device = usb
        // A known unit, so its mixer state can be restored.
        state.primaryBoardType = .optical
        state.primaryBoardSource = .detected
        state.secondaryBoardType = .none
        state.secondaryBoardSource = .detected
        state.unitAIdentity = 0x4D45_5445_5201
        state.unitAIdentityState = .known(0x4D45_5445_5201)
        return (state, usb, unit)
    }

    @Test("with the window hidden the meter loop reads nothing from the unit")
    func hiddenWindowPollsNothing() async throws {
        let (state, _, unit) = try makeState(visible: false, area: .input)
        state.startMeterPolling()
        try await Task.sleep(for: .milliseconds(400))
        state.stopMeterPolling()
        #expect(unit.meterReads.isEmpty)
    }

    @Test("a page without meters reads nothing; the Input page reads the input group only")
    func pageDecidesReads() async throws {
        let (state, _, unit) = try makeState(visible: true, area: .outputRouting)
        state.startMeterPolling()
        try await Task.sleep(for: .milliseconds(300))
        #expect(unit.meterReads.isEmpty)
        state.selectedArea = .input
        try await Task.sleep(for: .milliseconds(500))
        state.stopMeterPolling()
        let reads = unit.meterReads
        #expect(!reads.isEmpty)
        #expect(reads.allSatisfy { $0 == 0 }, "Input page: no mixer or output group: \(reads)")
    }

    @Test("the heartbeat asks once while nothing else has, and not at all right after a meter read")
    func heartbeat() async throws {
        let (state, _, unit) = try makeState(visible: false, area: .input)
        await state.usbHealthTick()
        #expect(unit.meterReads.count == 1)
        state.usbLastReadOutcomeAt = Date()
        await state.usbHealthTick()
        #expect(unit.meterReads.count == 1)
    }

    @Test("one failed read does not restore the unit")
    func oneFailedReadDoesNotRestore() async throws {
        let (state, _, unit) = try makeState(visible: false, area: .input)
        unit.status = -1
        await state.usbHealthTick()
        unit.status = 0
        state.usbLastReadOutcomeAt = .distantPast
        await state.usbHealthTick()
        #expect(state.deviceRecoveryCount == 0)
        #expect(!state.usbLoss.isFailing)
    }

    @Test("the helper with no unit open, then a good read: the unit is restored")
    func realLossRestores() async throws {
        let (state, _, unit) = try makeState(visible: false, area: .input)
        unit.status = XPCDeviceConnection.helperStatusUnitNotOpen
        await state.usbHealthTick()
        #expect(state.usbLoss.lost)
        unit.status = 0
        state.usbLastReadOutcomeAt = .distantPast
        await state.usbHealthTick()
        #expect(state.deviceRecoveryCount == 1)
    }

    @Test("an older helper (-1 for everything): reads failing past the backoff are a loss")
    func sustainedFailureRestores() async throws {
        let (state, _, _) = try makeState(visible: false, area: .input)
        state.noteUSBReadFailed(DeviceConnectionError.transportError("x"))
        state.usbLoss.failed(.readFailed, at: Date().addingTimeInterval(3))
        state.noteUSBReadSucceeded()
        #expect(state.deviceRecoveryCount == 1)
    }

    @Test("over USB the Mixer page never re-sends a mixer it shows, and resends on reset only once it is written")
    func mixerPageWrites() throws {
        let (state, _, _) = try makeState(visible: true, area: .mixer)
        #expect(!state.mixerPageMayWriteStrips(mixer: 0, recalling: true), "before the restore")
        #expect(!state.mixerPageMayWriteStrips(mixer: 0, recalling: false), "a reset before the restore")
        state.usbMixersWritten = (state.unitAGeneration, [true, false])
        #expect(!state.mixerPageMayWriteStrips(mixer: 0, recalling: true), "page open after the restore")
        #expect(state.mixerPageMayWriteStrips(mixer: 0, recalling: false), "a reset after the restore")
        #expect(!state.mixerPageMayWriteStrips(mixer: 1, recalling: false), "a mixer not written")
    }

    @Test("not USB: the Mixer page writes as before")
    func mixerPageWritesOffUSB() {
        let state = AppState()
        state.device = nil
        #expect(state.mixerPageMayWriteStrips(mixer: 0, recalling: true))
    }
}
}
