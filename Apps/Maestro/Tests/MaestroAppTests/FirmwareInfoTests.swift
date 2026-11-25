import Foundation
import Testing
@testable import MaestroApp

struct FirmwareInfoTests {
    @Test func daemonSoftwareIsNotHardwareFirmware() throws {
        let items: [[String: Any]] = [["Children": [
            ["name": "USB Daemon", "info": ["version": "1.23.0"]],
            ["name": "Symphony I/O", "info": ["XMOS version": "1.6.72", "FPGA version": "v73"]]
        ]]]
        let data = try PropertyListSerialization.data(fromPropertyList: items, format: .xml, options: 0)
        let xml = String(decoding: data, as: UTF8.self)
        let info = try #require(FirmwareInfo.parse(xml))
        #expect(info.firmwareVersion == nil)
        #expect(info.xmosVersion == "1.6.72")
        #expect(info.fpgaVersion == "v73")
    }

    @Test func daemonOnlyReplyDoesNotTriggerAnExtraHardwareRead() throws {
        let items: [[String: Any]] = [["name": "USB Daemon", "info": ["version": "1.23.0"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: items, format: .xml, options: 0)
        let info = try #require(FirmwareInfo.parse(String(decoding: data, as: UTF8.self)))
        #expect(info.firmwareVersion == nil)
        #expect(info.xmosVersion == nil)
    }

    @Test func isolatedComponentIsNotDiscarded() throws {
        let items: [[String: Any]] = [["name": "Symphony I/O", "info": ["IOBoard2 version": "vFF"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: items, format: .xml, options: 0)
        let info = try #require(FirmwareInfo.parse(String(decoding: data, as: UTF8.self)))
        #expect(info.ioBoard2Version == "vFF")
        #expect(info.firmwareVersion == nil)
    }
}
