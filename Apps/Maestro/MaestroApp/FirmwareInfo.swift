import Foundation
import MaestroCore
import MaestroDevice

/// Parsed firmware/device info from the 'AEt1' (versionString) daemon property.
/// The daemon returns an XML plist string with nested dicts for USB Daemon and Symphony I/O.
struct FirmwareInfo {
    // No mismatch alert from these display strings. The table DOES exist at
    // og_source/maestrolink/Software/SymphonyDaemonConstants.plist:32-112,
    // but SymphonyIO.cpp:1445,1483-1487,1534-1538 drops FPGA minor/build bytes in XML.
    // ServerHook.cpp:365-420 compares complete tuples (including newer versions
    // when AllowNewerVersions is false). Guessing the omitted bytes is unsafe.
    // SymphonyIO.cpp:336-365 excludes MicPre; its updater is not for converters.
    var deviceName: String?
    var firmwareVersion: String?
    var fpgaVersion: String?
    var hardwareID: String?
    var ioBoard1Type: String?
    var ioBoard1Version: String?
    var ioBoard2Type: String?
    var ioBoard2Version: String?
    var xmosVersion: String?

    static func parse(_ xmlString: String) -> FirmwareInfo? {
        guard let data = xmlString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }

        // The daemon returns an array of dicts (root is <array>).
        // Each dict may have a "Children" array of component dicts.
        // Each component dict has "name" (String) and "info" (dict with properties).
        // Screenshot confirmed structure: [{ "Children": [{ "name": "USB Daemon", "info": { "version": "1.23.0" } },
        //   { "name": "Symphony I/O", "info": { "FPGA version": "v73", "Hardware ID": "...",
        //     "IOBoard1 Type": "8ch Analog-Optical", "IOBoard1 version": "v33", ... } }] }]
        var info = FirmwareInfo()
        var hasDaemonVersion = false
        info.deviceName = "Symphony I/O"

        func processItems(_ items: [[String: Any]]) {
            for item in items {
                let name = item["name"] as? String ?? ""
                let itemInfo = item["info"] as? [String: Any] ?? [:]
                if name == "USB Daemon" {
                    // Keep the same read/fallback decision without mislabelling
                    // host software as firmware or adding a hardware read.
                    hasDaemonVersion = itemInfo["version"] is String
                } else if name == "Symphony I/O" {
                    // Symphony I/O or similar hardware component
                    if let v = itemInfo["FPGA version"] as? String { info.fpgaVersion = v }
                    if let v = itemInfo["Hardware ID"] as? String { info.hardwareID = v }
                    if let v = itemInfo["XMOS version"] as? String { info.xmosVersion = v }
                    if let v = itemInfo["IOBoard1 Type"] as? String { info.ioBoard1Type = v }
                    if let v = itemInfo["IOBoard1 version"] as? String { info.ioBoard1Version = v }
                    if let v = itemInfo["IOBoard2 Type"] as? String { info.ioBoard2Type = v }
                    if let v = itemInfo["IOBoard2 version"] as? String { info.ioBoard2Version = v }
                }
                if let children = item["Children"] as? [[String: Any]] {
                    processItems(children)
                }
            }
        }

        if let rootArray = plist as? [[String: Any]] {
            processItems(rootArray)
        } else if let rootDict = plist as? [String: Any] {
            processItems([rootDict])
        }

        guard hasDaemonVersion || info.fpgaVersion != nil || info.hardwareID != nil || info.xmosVersion != nil
                || info.ioBoard1Version != nil || info.ioBoard2Version != nil
                || info.ioBoard1Type != nil || info.ioBoard2Type != nil else { return nil }
        return info
    }

    /// Construct FirmwareInfo from static device knowledge when daemon XML is unavailable.
    /// On macOS 26, the daemon is broken and USB vendor reads fail, so we populate
    /// what we can from the USBDeviceIdentifier and any firmware version string we got.
    static func fromDevice(_ device: any DeviceConnection, firmwareVersion: String) -> FirmwareInfo {
        var info = FirmwareInfo()
        info.deviceName = device.identifier.displayName
        if firmwareVersion != "—" {
            info.firmwareVersion = firmwareVersion
        }
        return info
    }

    /// Board type the daemon's version XML reported for a slot, if it can be
    /// mapped onto a known module. A value here came off the device, so it counts
    /// as a live detection.
    func xmlBoardType(slot: Int) -> IOCardType? {
        let label = slot == 1 ? ioBoard1Type : ioBoard2Type
        guard let label, !label.isEmpty else { return nil }
        return IOCardType.fromLegacyLabel(label)
    }

    /// Build the Device Info panel's content.
    ///
    /// Board types are passed in as `BoardTypeReading`s rather than strings so the
    /// panel can say whether each slot was actually read back or is a stale cache.
    func report(
        connectionMode: String,
        board1: BoardTypeReading,
        board2: BoardTypeReading,
        deviceModel: String? = nil,
        mode: String? = nil,
        channelCount: Int? = nil,
        connectedUnit: String? = nil,
        connectedUnitModel: String? = nil
    ) -> DeviceInfoReport {
        DeviceInfoReport(
            deviceName: connectedUnitModel ?? deviceName ?? "Symphony I/O",
            connection: connectionMode,
            firmwareVersion: firmwareVersion,
            fpgaVersion: fpgaVersion,
            hardwareID: hardwareID,
            xmosVersion: xmosVersion,
            board1: board1,
            board1Version: ioBoard1Version,
            board2: board2,
            board2Version: ioBoard2Version,
            deviceModel: deviceModel,
            mode: mode,
            channelCount: channelCount,
            connectedUnit: connectedUnit
        )
    }
}

