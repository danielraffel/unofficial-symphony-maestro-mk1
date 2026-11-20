import Foundation

/// The seven components a Symphony I/O reports with `SymphonyIOVersion` (0xA0),
/// as nValue. Same numbering as the original's `SymphonyIOVersionType`
/// (og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h:792-801).
///
/// Named apart from MaestroDevice's older `SymphonyIOVersionType`, which the USB
/// `.version` property uses for type 0 only.
public enum SymphonyVersionComponent: UInt32, CaseIterable, Sendable, Hashable {
    case overall = 0
    case mainFPGA = 1
    case primaryFPGA = 2
    case secondaryFPGA = 3
    case mainBoardHardware = 4
    case primaryBoardHardware = 5
    case secondaryBoardHardware = 6

    /// The FPGA component of an option-board slot (0 or 1).
    public static func fpga(slot: Int) -> SymphonyVersionComponent {
        slot == 0 ? .primaryFPGA : .secondaryFPGA
    }

    /// The hardware component of an option-board slot (0 or 1).
    public static func hardware(slot: Int) -> SymphonyVersionComponent {
        slot == 0 ? .primaryBoardHardware : .secondaryBoardHardware
    }

    /// The text the original's version dictionary showed for this reply.
    ///
    /// - Overall is the unit's (XMOS) firmware, one BCD byte per field, shown
    ///   `%d.%d.%d` (og_source/maestrolink/Software/SymphonyIO.cpp:1436-1442).
    /// - An FPGA is its major byte, `v%X` (SymphonyIO.cpp:1445 for the main FPGA,
    ///   :1483-1487 and :1532-1537 for the boards). The original's "b" suffix
    ///   (:1484) needs an SPI-flash page probe Maestro does not make, so it is
    ///   never added.
    /// - A hardware version is the major byte only; the firmware leaves the
    ///   other two zero (og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/
    ///   SymphonyIO/src/Bulldog/MAL/MainController/SymphonyIOMainController.cpp:459-481).
    public func displayText(_ reply: SymphonyVersionReply) -> String {
        switch self {
        case .overall:
            func bcd(_ byte: UInt8) -> Int { Int(byte >> 4) * 10 + Int(byte & 0x0F) }
            return "\(bcd(reply.major)).\(bcd(reply.minor)).\(bcd(reply.build))"
        case .mainFPGA, .primaryFPGA, .secondaryFPGA:
            return "v" + String(reply.major, radix: 16, uppercase: true)
        case .mainBoardHardware, .primaryBoardHardware, .secondaryBoardHardware:
            return "\(reply.major)"
        }
    }
}

/// One 0xA0 reply: three bytes, major, minor, build
/// (og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:1120-1142).
public struct SymphonyVersionReply: Sendable, Equatable {
    public static let byteCount = 3
    public let major: UInt8
    public let minor: UInt8
    public let build: UInt8

    public init(major: UInt8, minor: UInt8, build: UInt8) {
        self.major = major; self.minor = minor; self.build = build
    }

    /// Nil unless exactly three bytes came back. Zero bytes are a valid reading.
    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        let bytes = Array(data)
        self.init(major: bytes[0], minor: bytes[1], build: bytes[2])
    }
}

/// The versions one Device Settings load read from a ThunderBridge unit.
/// A component that was not read, or whose read failed, is absent and shows
/// "Unknown".
public struct SymphonyVersions: Sendable, Equatable {
    public var replies: [SymphonyVersionComponent: SymphonyVersionReply] = [:]

    public init(replies: [SymphonyVersionComponent: SymphonyVersionReply] = [:]) {
        self.replies = replies
    }

    public func text(_ component: SymphonyVersionComponent) -> String? {
        replies[component].map(component.displayText)
    }

    /// What one load asks for: the firmware and main FPGA, then each slot's FPGA
    /// when that slot holds a board with one. The original read a board's FPGA
    /// only for an installed board (SymphonyIO.cpp:974-996) and never showed one
    /// for an 8MicPre (:1472-1473). Board hardware versions are not here: they are
    /// read once at connect already (AppState, `readBoardHardwareMajor`).
    public static func componentsToRead(slot1: IOCardType?, slot2: IOCardType?) -> [SymphonyVersionComponent] {
        var result: [SymphonyVersionComponent] = [.overall, .mainFPGA]
        for (slot, card) in [slot1, slot2].enumerated() {
            guard let card, card != .none, card != .micPre8 else { continue }
            result.append(.fpga(slot: slot))
        }
        return result
    }

    /// Read `components` one at a time. `allowed` is asked before every read;
    /// the first refusal or failed read ends the attempt, because each
    /// unanswered read holds the driver's command path for its timeout. A reply
    /// of the wrong size is not a reading and also ends it.
    public static func read(_ components: [SymphonyVersionComponent],
                            allowed: () -> Bool,
                            read: (SymphonyVersionComponent) throws -> Data) -> SymphonyVersions {
        var result = SymphonyVersions()
        for component in components {
            guard allowed() else { break }
            guard let data = try? read(component), let reply = SymphonyVersionReply(data: data) else { break }
            result.replies[component] = reply
        }
        return result
    }
}

/// The unit identity (0xC0) as the original displayed it: converted from big
/// endian, top byte masked off, `%qX`
/// (og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:1203-1207;
/// SymphonyIO.cpp:1434).
public enum SymphonyHardwareID {
    public static let mask: UInt64 = 0x00FF_FFFF_FFFF_FFFF

    public static func text(_ identity: UInt64) -> String {
        String(identity & mask, radix: 16, uppercase: true)
    }
}
