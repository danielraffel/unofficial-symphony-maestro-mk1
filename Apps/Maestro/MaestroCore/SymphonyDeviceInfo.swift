import Foundation

/// Per-peripheral readings, never the ThunderBridge card's serial.
/// Evidence: og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h:339-348,394-400,792-801,830-848.
/// Evidence: og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:1120-1142,1186-1235,1276-1295.
public struct SymphonyDeviceInfo: Sendable, Equatable {
    public var versions: [UInt32: String] = [:]
    public var boards: [UInt32: IOCardType] = [:]
    public var uniqueID: String?

    public init() {}

    /// Reject short replies independently; zero version bytes are valid tuples.
    public mutating func decode(command: UInt8, value: UInt32, data: Data) -> Bool {
        let bytes = Array(data)
        switch command {
        case 0xA0:
            guard bytes.count == 3, value <= 6 else { return false }
            versions[value] = bytes.map(String.init).joined(separator: ".")
        case 0xA1:
            guard bytes.count == 1, value < 2 else { return false }
            boards[value] = IOCardType(rawValue: bytes[0])
        case 0xC0:
            guard bytes.count == 8, value == 0 else { return false }
            // The original converts big endian to host and masks the top byte.
            let id = bytes.dropFirst().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            uniqueID = String(id, radix: 16, uppercase: true)
        default: return false
        }
        return true
    }

    public struct Row: Sendable, Equatable {
        public let label: String
        public let value: String
    }

    public var rows: [Row] {
        var result: [Row] = [
            .init(label: "Firmware", value: DeviceInfoReport.versionText(versions[0])),
            .init(label: "FPGA Version", value: DeviceInfoReport.versionText(versions[1])),
            .init(label: "Hardware ID", value: uniqueID ?? "Unknown"),
            .init(label: "Main Board Hardware Version", value: DeviceInfoReport.versionText(versions[4]))]
        for slot: UInt32 in 0..<2 {
            result.append(.init(label: "IOBoard \(slot + 1)", value: boards[slot]?.productName ?? "Unknown"))
            result.append(.init(label: "IOBoard \(slot + 1) Version", value: DeviceInfoReport.versionText(versions[slot + 2])))
            result.append(.init(label: "IOBoard \(slot + 1) Hardware Version", value: DeviceInfoReport.versionText(versions[slot + 5])))
        }
        return result
    }

    public var reportLines: [String] { rows.map { "Unit B \($0.label): \($0.value)" } }
}
