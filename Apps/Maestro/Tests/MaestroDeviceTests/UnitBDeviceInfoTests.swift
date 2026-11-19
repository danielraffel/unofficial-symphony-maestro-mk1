import Foundation
import Testing
@testable import MaestroDevice
import MaestroCore

@Suite("Unit B Device Info")
struct UnitBDeviceInfoTests {
    final class Transport: VendorTransport, @unchecked Sendable {
        var isConnected = true
        var board2Type = IOCardType.none.rawValue
        var reads: [(UInt8, UInt32, UInt8)] = []
        var failure: Int?
        var short: Int?
        var onRead: (() -> Void)?
        func sendVendorCommand(command: UInt8, value: UInt32, payload: Data, port: UInt8) throws {}
        func readVendorCommand(command: UInt8, value: UInt32, responseLength: Int, port: UInt8) throws -> Data {
            #expect(!Thread.isMainThread)
            reads.append((command, value, port))
            onRead?()
            if failure == reads.count { throw DeviceConnectionError.notConnected }
            if short == reads.count { return Data() }
            switch command {
            case 0xC0: return Data([0xFF, 1, 2, 3, 4, 5, 6, 7])
            case 0xA1: return Data([value == 0 ? IOCardType.analogADDA16.rawValue : board2Type])
            default: return Data([UInt8(value), 2, 3])
            }
        }
    }

    private func connection(_ t: Transport, channels: Int = 64,
                            topology: SymphonyRoutingModel.Topology = .symphonyOnly,
                            configured: Bool = true) -> ThunderboltUnitBConnection {
        ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, transport: t,
            infoRouting: { SymphonyRoutingModel(topology: topology, hostChannels: channels, unitBConfigured: configured) },
            state: { UnitBState(present: true, boardType: [7, 0], boardValid: [1, 1], prefix: 66,
                                clockSource: 3, setupFlags: configured ? 1 : 0, txErrors: 0) })
    }

    @Test func fullReplyAndOncePerConnection() async {
        let t = Transport()
        let b = connection(t)
        let info = await b.readDeviceInfo()
        #expect(info.uniqueID == "1020304050607")
        #expect(info.versions[0] == "0.2.3")
        #expect(info.versions[1] == "1.2.3")
        #expect(info.versions[4] == "4.2.3")
        #expect(info.versions[2] == "2.2.3")
        #expect(info.versions[5] == "5.2.3")
        #expect(info.boards[1] == IOCardType.none)
        #expect(t.reads.map { $0.0 } == [0xC0, 0xA1, 0xA1, 0xA0, 0xA0, 0xA0, 0xA0, 0xA0])
        #expect(t.reads.map { $0.1 } == [0, 0, 1, 0, 1, 4, 2, 5])
        #expect(t.reads.allSatisfy { $0.2 == 1 })
        #expect(await b.readDeviceInfo() == info)
        #expect(t.reads.count == 8)
        #expect(info.rows.contains { $0.label == "IOBoard 2" && $0.value == IOCardType.none.productName })
        #expect(info.rows.contains { $0.label == "IOBoard 2 Version" && $0.value == "Unknown" })
    }

    @Test func bothBoardsHaveIndependentVersionTuples() async {
        let t = Transport()
        t.board2Type = IOCardType.micPre8.rawValue
        let info = await connection(t).readDeviceInfo()
        #expect(info.versions.count == 7)
        #expect(info.versions[3] == "3.2.3")
        #expect(info.versions[6] == "6.2.3")
        #expect(info.reportLines.contains("Unit B IOBoard 2 Version: 3.2.3"))
        #expect(t.reads.count == 10)
    }

    @Test func failureAtEveryReadStopsAndKeepsIndependentFields() async {
        for index in 1...8 {
            for short in [true, false] {
                let t = Transport()
                if short { t.short = index } else { t.failure = index }
                let b = connection(t)
                let info = await b.readDeviceInfo()
                #expect(t.reads.count == index)
                #expect((info.uniqueID != nil) == (index > 1))
                #expect((info.boards[0] != nil) == (index > 2))
                #expect((info.versions[0] != nil) == (index > 4))
                _ = await b.readDeviceInfo()
                #expect(t.reads.count == index)
            }
        }
    }

    @Test func gatesAndReplacement() async {
        for topology: SymphonyRoutingModel.Topology in [.unknown, .symphonyAndConverters([]), .converterOnly(.init(port1: [], port2: []))] {
            let t = Transport()
            _ = await connection(t, topology: topology).readDeviceInfo()
            #expect(t.reads.isEmpty)
        }
        for (channels, configured) in [(32, true), (64, false)] {
            let t = Transport()
            _ = await connection(t, channels: channels, configured: configured).readDeviceInfo()
            #expect(t.reads.isEmpty)
        }
        let t = Transport()
        let old = connection(t)
        _ = await old.readDeviceInfo()
        old.invalidate()
        #expect(old.deviceInfo == SymphonyDeviceInfo())
        let replacement = connection(t)
        #expect(replacement.deviceInfo == SymphonyDeviceInfo())
        let info = await replacement.readDeviceInfo()
        #expect(info.uniqueID != nil)
        #expect(t.reads.count == 16)
    }

    @Test func lossDuringReadDropsReplyAndStops() async {
        let t = Transport()
        let b = connection(t)
        t.onRead = { b.invalidate() }
        #expect(await b.readDeviceInfo() == SymphonyDeviceInfo())
        #expect(t.reads.count == 1)
    }

    @Test func decoderRejectsShortRepliesWithoutErasingOtherFields() {
        var info = SymphonyDeviceInfo()
        let tuple = info.decode(command: 0xA0, value: 6, data: Data([6, 7, 8]))
        let shortID = info.decode(command: 0xC0, value: 0, data: Data(repeating: 1, count: 7))
        let shortTuple = info.decode(command: 0xA0, value: 0, data: Data([1, 2]))
        let emptyBoard = info.decode(command: 0xA1, value: 0, data: Data())
        #expect(tuple)
        #expect(!shortID)
        #expect(!shortTuple)
        #expect(!emptyBoard)
        #expect(info.versions == [6: "6.7.8"])
        #expect(info.rows.first?.value == "Unknown")
    }

    @Test func userClientShortAndErrorReplies() throws {
        let full = Data([0, 0, 0, 0, 3, 0, 0, 0, 1, 2, 3])
        #expect(try DextUserClient.decodeVendorReadOutput(full, outputSize: 11, responseLength: 3) == Data([1, 2, 3]))
        for size in [0, 7, 10] {
            #expect(throws: (any Error).self) {
                try DextUserClient.decodeVendorReadOutput(full, outputSize: size, responseLength: 3)
            }
        }
        var error = full
        error[0] = 1
        #expect(throws: (any Error).self) {
            try DextUserClient.decodeVendorReadOutput(error, outputSize: 11, responseLength: 3)
        }
        var short = full
        short[4] = 2
        #expect(throws: (any Error).self) {
            try DextUserClient.decodeVendorReadOutput(short, outputSize: 11, responseLength: 3)
        }
    }
}
