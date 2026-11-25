import Foundation
import Testing
@testable import MaestroCore

struct StatusFirmwareParityTests {
    @Test func clockAndBusVocabulary() {
        #expect(PortStatusMessage.clock(locked: true) == "Ready")
        #expect(PortStatusMessage.clock(locked: false) == "Clock Mismatch")
        for link: PortStatusMessage.Link in [.noHardware, .busError] {
            #expect(PortStatusMessage.clock(locked: true, link: link) == "Bus Error")
            #expect(PortStatusMessage.clock(locked: false, link: link) == "Bus Error")
        }
        let secondary = "A bus error has occurred on the Secondary port of the ThunderBridge."
            + "\nVerify that the hardware is properly connected and powered on."
        #expect(PortStatusMessage.busError(port: .secondary) == secondary)
        let unknown = SecondPortState(portCount: 2, audio: 0x11 | (99 << 8))
        #expect(unknown.plainProblemText == "Port Error")
    }

    @Test func allSevenComponentTuplesRemainIndependent() {
        var info = SymphonyDeviceInfo()
        let labels = ["Firmware", "FPGA Version", "IOBoard 1 Version", "IOBoard 2 Version",
                      "Main Board Hardware Version", "IOBoard 1 Hardware Version", "IOBoard 2 Hardware Version"]
        for (index, label) in labels.enumerated() {
            #expect(info.rows.first { $0.label == label }?.value == "Unknown")
            // Includes zero, newer-than-historical-table and non-field-updateable
            // component values. Display does not infer compatibility from them.
            let bytes = Data([UInt8(index), 0, 255])
            let decoded = info.decode(command: 0xA0, value: UInt32(index), data: bytes)
            #expect(decoded)
            // As the original showed each (SymphonyIO.cpp:1436-1445; BCD 0xFF reads 165).
            let expected = ["0.0.165", "v1", "v2", "v3", "4", "5", "6"][index]
            #expect(info.rows.first { $0.label == label }?.value == expected)
        }
        for index: UInt32 in 0...6 {
            var missing = info
            missing.versions[index] = nil
            let unknown = missing.rows.filter { $0.value == "Unknown" && labels.contains($0.label) }
            #expect(unknown.count == 1)
        }
    }

    @Test func versionDisplayPreservesReadingsAndMarksAbsence() {
        for missing: String? in [nil, "", "—"] {
            #expect(DeviceInfoReport.versionText(missing) == "Unknown")
        }
        for value in ["0.0.0", "255.254.253", "v73", "v33b", "1.6.72"] {
            #expect(DeviceInfoReport.versionText(value) == value)
        }
        let converter = DeviceInfoReport(connection: "Thunderbolt", connectedUnit: "AD-16X")
        #expect(!converter.clipboardText.contains("FPGA version"))
        #expect(!converter.clipboardText.contains("XMOS Version"))
        #expect(!converter.clipboardText.contains("updater"))
    }
}
