import AppKit
import CoreAudio
import Foundation
import MaestroCore
import MaestroDevice

/// Diagnostics: while it is on, Maestro records what it and the driver are
/// doing into a working folder, and on stop saves one redacted text file to the
/// Desktop for the user to share.
///
/// Rules this follows:
/// - Read-only. Nothing here changes the hardware, routing or audio. The
///   driver's timing health (a bus round trip) is read only at start, at stop
///   and with each note; the link state, which costs no bus traffic, every few
///   seconds.
/// - Never blocks the app: every system call runs off the main actor with a
///   time limit, so a wedged Core Audio cannot stop the recording or the save.
/// - Written as it goes, to ~/Library/Logs/Maestro/Diagnostics In Progress,
///   so a freeze, force quit or crash keeps what was recorded; the next launch
///   offers to save it.
/// - The system log is recorded live (`log stream`): the stored log keeps few
///   of the driver's lines (checked on a test Mac: none over three days).
@MainActor
@Observable
final class DiagnosticsRecorder {
    nonisolated static let maxDuration: TimeInterval = 60 * 60
    nonisolated static let snapshotInterval: TimeInterval = 5
    nonisolated static let sizeCapBytes = 20 * 1024 * 1024
    nonisolated static let sendTo = "thegenerouscorp@gmail.com"
    nonisolated static let ourTeamID = "95CX6P84C4"

    private(set) var isRecording = false
    private(set) var isSaving = false
    private(set) var startedAt: Date?
    /// A working folder left by a session that did not finish (crash, force quit).
    private(set) var hasUnfinishedSession = false
    /// Set after a save, for the confirmation.
    var lastSaved: URL?

    @ObservationIgnored weak var appState: AppState?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var logStream: Process?
    @ObservationIgnored private var stdoutTee: StdoutTee?
    @ObservationIgnored private var lastLink: (irq: UInt64, wraps: UInt32)?
    @ObservationIgnored private var lastSnapshotText = ""
    @ObservationIgnored private var lastFullSnapshot = Date.distantPast
    @ObservationIgnored private var proxyLogOffset: UInt64 = 0

    nonisolated static var workDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Maestro/Diagnostics In Progress", isDirectory: true)
    }
    private var sessionFile: URL { Self.workDir.appendingPathComponent("session.txt") }
    private var systemLogFile: URL { Self.workDir.appendingPathComponent("system-log.txt") }
    private var appOutputFile: URL { Self.workDir.appendingPathComponent("maestro-output.txt") }
    private var metaFile: URL { Self.workDir.appendingPathComponent("started-at.txt") }

    init() {
        hasUnfinishedSession = FileManager.default.fileExists(atPath: Self.workDir.path)
    }

    // MARK: - Start / stop

    func start() {
        guard !isRecording, !isSaving else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: Self.workDir)
        try? fm.createDirectory(at: Self.workDir, withIntermediateDirectories: true)
        let now = Date()
        startedAt = now
        isRecording = true
        hasUnfinishedSession = false
        lastLink = nil
        lastSnapshotText = ""
        lastFullSnapshot = .distantPast
        try? String(now.timeIntervalSince1970).write(to: metaFile, atomically: true, encoding: .utf8)
        fm.createFile(atPath: sessionFile.path, contents: nil)
        fm.createFile(atPath: systemLogFile.path, contents: nil)
        fm.createFile(atPath: appOutputFile.path, contents: nil)
        proxyLogOffset = (try? fm.attributesOfItem(atPath: Self.proxyLogPath)[.size] as? UInt64) ?? 0

        append("Maestro diagnostics\nStarted: \(Self.stamp(now))\n")
        startLogStream(since: now)
        stdoutTee = StdoutTee(file: appOutputFile)
        print("[Maestro] Diagnostics started")

        let report = appState?.diagnosticsText ?? ""
        append(section("Maestro and device (at start)", report))
        Task { await runChecks() }
        // What happened just before: people often turn this on right after
        // a crash or a jam. Read off the main actor (about 20 s), into its own
        // file so it lands in order in the saved report.
        let beforeFile = Self.workDir.appendingPathComponent("before-log.txt")
        Task.detached(priority: .utility) {
            let text = Self.systemLog(minutesBefore: Self.beforeMinutes, until: now)
            try? text.write(to: beforeFile, atomically: true, encoding: .utf8)
        }
        if let appState {
            Task { if let t = await Self.timingHealthText(appState) { append(section("Driver timing health (at start)", t)) } }
        }
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.snapshot()
                if let started = self.startedAt, Date().timeIntervalSince(started) >= Self.maxDuration {
                    self.append("\n[\(Self.stamp(Date()))] One hour reached; diagnostics stopped automatically.\n")
                    await self.stopAndSave()
                    return
                }
                try? await Task.sleep(for: .seconds(Self.snapshotInterval))
            }
        }
    }

    /// Stop recording and save the file to the Desktop.
    func stopAndSave() async {
        guard isRecording else { return }
        isRecording = false
        snapshotTask?.cancel()
        snapshotTask = nil
        if let appState, let t = await Self.timingHealthText(appState) {
            append(section("Driver timing health (at end)", t))
        }
        // What is installed and connected, again, so the file shows the
        // start and the end without anyone pressing anything.
        await runChecks()
        append(section("Maestro and device (at end)", appState?.diagnosticsText ?? ""))
        print("[Maestro] Diagnostics stopped")
        stdoutTee?.stop()
        stdoutTee = nil
        logStream?.terminate()
        logStream = nil
        await save()
    }

    /// Save what an unfinished session left behind.
    func saveUnfinished() async {
        guard hasUnfinishedSession, !isRecording else { return }
        append("\n[\(Self.stamp(Date()))] This session did not finish (Maestro quit, froze or crashed). Saved on the next launch.\n")
        await save()
    }

    func discardUnfinished() {
        try? FileManager.default.removeItem(at: Self.workDir)
        hasUnfinishedSession = false
    }

    func addNote(_ text: String) {
        guard isRecording else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append("\n[\(Self.stamp(Date()))] NOTE: \(trimmed)\n")
        print("[Maestro] Diagnostics note: \(trimmed)")
        if let appState {
            Task { if let t = await Self.timingHealthText(appState) { append(section("Driver timing health (at note)", t)) } }
        }
    }

    func runChecksNow() {
        guard isRecording else { return }
        Task { await runChecks() }
    }

    // MARK: - Writing

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8),
              let h = try? FileHandle(forWritingTo: sessionFile) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    private func section(_ title: String, _ body: String) -> String {
        "\n== \(title) — \(Self.stamp(Date())) ==\n\(body.trimmingCharacters(in: .newlines))\n"
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let work = Self.workDir
        let started = (try? String(contentsOf: metaFile, encoding: .utf8)).flatMap(Double.init)
            .map(Date.init(timeIntervalSince1970:)) ?? Date()
        let proxyOffset = proxyLogOffset
        let url = await Task.detached(priority: .utility) { () -> URL? in
            let fm = FileManager.default
            func read(_ name: String) -> String {
                (try? String(contentsOf: work.appendingPathComponent(name), encoding: .utf8)) ?? ""
            }
            var parts: [String] = [read("session.txt")]
            parts.append("\n== Maestro's own output ==\n" + Self.capped(read("maestro-output.txt"), 2 * 1024 * 1024))
            parts.append("\n== USB helper log (last \(Self.proxyLinesBefore) lines before diagnostics started) ==\n"
                         + Self.proxyLogBefore(offset: proxyOffset, lines: Self.proxyLinesBefore))
            parts.append("\n== USB helper log (this session) ==\n" + Self.capped(Self.proxyLog(since: proxyOffset), 3 * 1024 * 1024))
            parts.append("\n== Crash, hang and CPU reports (last 7 days) ==\n" + Self.crashReports(since: started))
            let before = read("before-log.txt")
            parts.append("\n== System log, \(Self.beforeMinutes) minutes before diagnostics started (driver, USB helper, Maestro, Core Audio about our devices) ==\n"
                         + (before.isEmpty ? "not read yet (diagnostics was stopped within about 20 seconds of starting)" : Self.capped(before, 4 * 1024 * 1024)))
            parts.append("\n== System log, this session ==\n"
                         + Self.capped(read("system-log.txt"), 12 * 1024 * 1024))
            parts.append("\n== Not included ==\nAnything inside your DAW, fields macOS marks <private>, card state the driver does not report, and system log lines older than \(Self.beforeMinutes) minutes before diagnostics was turned on.\n")
            let text = Self.redactor().redact(parts.joined())
            let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            var dest = desktop.appendingPathComponent(DiagnosticsRedactor.fileName(for: started))
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = desktop.appendingPathComponent(
                    DiagnosticsRedactor.fileName(for: started).replacingOccurrences(of: ".txt", with: " \(n).txt"))
                n += 1
            }
            do {
                try text.write(to: dest, atomically: true, encoding: .utf8)
                try? fm.removeItem(at: work)
                return dest
            } catch {
                return nil
            }
        }.value
        hasUnfinishedSession = url == nil && FileManager.default.fileExists(atPath: work.path)
        lastSaved = url
    }

    // MARK: - Snapshots

    private func snapshot() async {
        guard let appState else { return }
        var lines: [String] = []
        lines.append("connection=\(appState.connectionMode) transport=\(appState.transportType.map { "\($0)" } ?? "none") present=\(appState.transportPresent) status=\"\(appState.statusMessage)\"")
        // The monitor controls as the app holds them, and whether it treats the
        // cable as converters only (which greys out speaker and headphones), with
        // the driver's probe word behind that, so a speaker or headphone report
        // can be checked against what the unit and Core Audio say.
        lines.append(String(format: "monitor (app): speaker=%.1f dB muted=%@ mode=%u, HP1=%.1f dB muted=%@, HP2=%.1f dB muted=%@; converter mode=%@ (probe 0x%08x)",
                            appState.speakerLevel, appState.speakerMuted ? "yes" : "no", appState.speakerOutputMode,
                            appState.hp1Level, appState.hp1Muted ? "yes" : "no",
                            appState.hp2Level, appState.hp2Muted ? "yes" : "no",
                            appState.converterVolumeKeys ? "yes" : "no", appState.connectedUnitProbeWord))
        // The clock as Maestro shows it: the source the unit reports, the
        // unit's own lock flag (ThunderBridge and PCIe), the driver's Clock
        // Source selector, and the Clock Status wording on screen. Snapshots
        // are written when they change, so a change of source is timestamped.
        do {
            let key = appState.reportedClockSource
            let name = key.flatMap { _ in appState.reportedClockSourceName(sampleRate: nil) } ?? "not reported"
            let flag = (appState.device as? ThunderboltDeviceConnection)?.lastExternalClockLocked
            let selector = (appState.device as? ThunderboltDeviceConnection).flatMap { $0.clockSelectorValue }
            let shown = appState.reportedClockLocked.map { PortStatusMessage.clock(locked: $0) } ?? "from Core Audio rates"
            lines.append("clock (app): source=\(name) key=\(key.map { String(format: "0x%04x", $0) } ?? "none")"
                + " unit lock flag=\(flag.map { $0 ? "locked" : "not locked" } ?? "none")"
                + " driver selector=\(selector.map(String.init) ?? "none") status=\(shown)")
        }
        if let tb = appState.device as? ThunderboltDeviceConnection, appState.connectedUnit != nil {
            // Converters (dext 131+): flags, phase and health counters, so an
            // unlock or recovery shows when it happened.
            if let cs = await Self.withTimeout(2) { tb.converterState() } ?? nil {
                lines.append(String(format: "converters flags=0x%02x units=%d+%d phase=0x%08x/0x%08x checks=%u phaseErrors=%u unlocks=%u recoveries=%u latency=%u/%u host=%u/%u config=0x%08x",
                                    cs.flags, cs.unitCount[0], cs.unitCount[1], cs.phase[0], cs.phase[1],
                                    cs.healthTicks, cs.phaseErrors, cs.unlocks, cs.recoveries,
                                    cs.latencyIn, cs.latencyOut, cs.hostInputs, cs.hostOutputs, cs.config))
            }
        }
        if let tb = appState.device as? ThunderboltDeviceConnection {
            let ls = await Self.withTimeout(2) { tb.linkState() } ?? nil
            if let ls {
                var delta = ""
                if let last = lastLink {
                    // A replug or driver upgrade starts a new driver instance whose
                    // counters begin at 0: say so instead of printing a wrapped delta.
                    delta = (ls.irqCount < last.irq || ls.audioWraps < last.wraps)
                        ? " counters reset (driver restarted) irq=\(ls.irqCount) wraps=\(ls.audioWraps)"
                        : " irq+\(ls.irqCount - last.irq) wraps+\(ls.audioWraps - last.wraps)"
                }
                lastLink = (ls.irqCount, ls.audioWraps)
                lines.append("link state=\(ls.state) clock=\(ls.clockPresent) ioRunning=\(ls.ioRunning) configured=\(ls.linkConfigured) suspended=\(ls.hwSuspended) recoveries=\(ls.recoveryCount) cardReinits=\(ls.cardReinitCount)\(delta) gcsr=0x\(String(ls.lastGcsr, radix: 16)) xlink=0x\(String(ls.lastXlinkStatus, radix: 16))")
            } else {
                lines.append("link state: no answer from the driver (or it took longer than 2 s)")
            }
        }
        let audio = await Self.withTimeout(2) { Self.coreAudioSummary() } ?? "Core Audio: no answer within 2 s"
        lines.append(audio)
        // Only record what changed, plus a full line every minute, so a long
        // session stays readable. The irq/wrap counts change every time while
        // audio runs, so compare without them (and without the converter
        // health check count, which also rises every time).
        let comparable = lines.map { $0.replacingOccurrences(of: #" irq\+\d+ wraps\+\d+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #" checks=\d+"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        let now = Date()
        let changed = comparable != lastSnapshotText
        let ioLine = lines.contains { $0.contains("ioRunning=true") }
        if changed || ioLine || now.timeIntervalSince(lastFullSnapshot) >= 60 {
            append("\n[\(Self.stamp(now))]\(changed ? " (changed)" : "")\n" + lines.joined(separator: "\n") + "\n")
            lastSnapshotText = comparable
            lastFullSnapshot = now
        }
    }

    // MARK: - Checks

    private func runChecks() async {
        let pciPresent = SystemExtensionInstaller.shared.isThunderBridgePresent()
        // Each tool call has its own limit; Core Audio's device list does not,
        // so the whole set gets one: a stuck Core Audio must never hold up
        // Stop Diagnostics or the save.
        let text = await Self.withTimeout(45) { () -> String in
            var out: [String] = []
            out.append(Self.systemBlock())
            out.append(Self.installedBlock())
            out.append(Self.leftoverApogeeBlock())
            out.append(Self.usbBlock())
            out.append(pciPresent ? Self.pciBlock() : "ThunderBridge / PCIe card: not present")
            out.append(Self.thunderboltBlock())
            out.append(Self.audioAppsBlock())
            out.append(Self.coreAudioHealth())
            out.append(Self.coreAudioSummary())
            return out.joined(separator: "\n\n")
        } ?? "\(Self.coreAudioHealth())\nThe checks did not finish within 45 s (Core Audio or a system tool not answering)."
        append(section("Checks", text))
    }

    nonisolated private static func systemBlock() -> String {
        let p = ProcessInfo.processInfo
        let mem = Double(p.physicalMemory) / 1_073_741_824
        return """
        Mac model: \(sysctl("hw.model") ?? "?")
        Chip: \(sysctl("machdep.cpu.brand_string") ?? "?")
        Memory: \(String(format: "%.0f", mem)) GB
        macOS: \(p.operatingSystemVersionString)
        """
    }

    nonisolated private static func installedBlock() -> String {
        let fm = FileManager.default
        var out = ["Installed:"]
        for (label, path) in [("USB helper", "/usr/local/bin/MaestroVolumeProxy"),
                              ("USB helper launch daemon", "/Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist"),
                              ("Audio plug-in", "/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver")] {
            out.append("  \(label): \(fm.fileExists(atPath: path) ? "yes" : "NO") (\(path))")
        }
        let running = run("/usr/bin/pgrep", ["-x", "MaestroVolumeProxy"], timeout: 5)
        out.append("  USB helper running: \(running.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "NO" : "yes")")
        out.append("Driver extensions:\n" + run("/usr/bin/systemextensionsctl", ["list"], timeout: 10)
            .split(separator: "\n").filter { $0.localizedCaseInsensitiveContains("maestro") || $0.localizedCaseInsensitiveContains("symphony") }
            .map { "  " + $0 }.joined(separator: "\n"))
        return out.joined(separator: "\n")
    }

    /// The original Apogee software conflicts with Maestro (the installer's
    /// warning page). Anything Apogee-named that is not signed by us.
    nonisolated private static func leftoverApogeeBlock() -> String {
        let fm = FileManager.default
        var found: [String] = []
        let dirs = ["/Library/Audio/Plug-Ins/HAL", "/Library/Extensions",
                    OriginalApogeeDrivers.stagedExtensionsDirectory, "/Library/LaunchDaemons",
                    "/Library/LaunchAgents", "/Applications", "/Library/Application Support"]
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where
                name.localizedCaseInsensitiveContains("apogee") || name.localizedCaseInsensitiveContains("symphony") {
                let path = dir + "/" + name
                if path == "/Applications/Maestro.app" { continue }
                let team = teamID(path)
                if team == ourTeamID { continue }
                found.append("  \(path)\(team.map { " (signed by team \($0))" } ?? "")")
            }
        }
        // Core Audio hosts our own plug-in in a process named
        // "Core Audio Driver (ApogeeSymIO.driver)"; that is Maestro's, not
        // Apogee's, when the installed plug-in carries our signature (the
        // file check above reports it when it does not).
        // Match the program's name or path only, never its arguments: our own
        // `log stream` has "apogee" in its filter.
        let ourPlugIn = teamID("/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver") == ourTeamID
        let procs = run("/bin/ps", ["-axo", "pid=,comm="], timeout: 5)
            .split(separator: "\n")
            .filter { $0.localizedCaseInsensitiveContains("apogee") || $0.localizedCaseInsensitiveContains("symphony") }
            .filter { !$0.localizedCaseInsensitiveContains("maestro") }
            .filter { !(ourPlugIn && $0.contains("Core Audio Driver (ApogeeSymIO.driver)")) }
            .map { "  running: " + $0.trimmingCharacters(in: .whitespaces) }
        found.append(contentsOf: procs)
        // A legacy Apogee kernel extension still loaded is what makes some
        // Macs restart instead of shutting down; the installer warns about it.
        let kexts = run("/usr/bin/kmutil", ["showloaded", "--list-only"], timeout: 10)
            .split(separator: "\n")
            .filter { $0.localizedCaseInsensitiveContains("apogee") || $0.localizedCaseInsensitiveContains("symphony") }
            .filter { !$0.localizedCaseInsensitiveContains("maestro") }
            .map { "  loaded kernel extension: " + $0.trimmingCharacters(in: .whitespaces) }
        found.append(contentsOf: kexts)
        // Still in macOS's auxiliary kernel collection, loaded or not: where a
        // user found Apogee's three kexts after uninstalling and after the
        // staged folder was empty (GitHub issue 32, 2026-11-20). Read-only and
        // needs no administrator rights.
        let aux = run("/usr/bin/kmutil", ["showloaded", "--collection", "aux", "--show", "all", "--list-only"], timeout: 10)
            .split(separator: "\n")
            .filter { $0.localizedCaseInsensitiveContains("apogee") || $0.localizedCaseInsensitiveContains("symphony") }
            .filter { !$0.localizedCaseInsensitiveContains("maestro") }
            .map { "  in macOS's boot collection (loaded or not): " + $0.trimmingCharacters(in: .whitespaces) }
        found.append(contentsOf: aux)
        return "Original Apogee software (conflicts with Maestro if present):\n"
            + (found.isEmpty ? "  none found" : found.joined(separator: "\n"))
    }

    /// What is on the Thunderbolt ports: names the chassis a PCIe card sits
    /// in, and a ThunderBridge, with link speed. Identifiers are left out.
    nonisolated static func thunderboltBlock() -> String {
        let raw = run("/usr/sbin/system_profiler", ["SPThunderboltDataType"], timeout: 15)
        let keep = ["Vendor Name:", "Device Name:", "Firmware Version:", "Speed:", "Link Status:", "Status:", "Receptacle:"]
        let lines = raw.split(separator: "\n")
            .filter { line in keep.contains { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) } }
            .map { "  " + $0.trimmingCharacters(in: .whitespaces) }
        return "Thunderbolt:\n" + (lines.isEmpty ? "  nothing reported" : lines.joined(separator: "\n"))
    }

    /// DAWs and audio apps that are open, since nobody remembers to say.
    nonisolated static let knownAudioApps = ["Logic Pro", "MainStage", "Ableton Live", "Live", "Pro Tools", "Cubase", "Nuendo",
                                             "REAPER", "Studio One", "Bitwig Studio", "GarageBand", "Digital Performer",
                                             "Reason", "FL Studio", "Audio MIDI Setup", "Apogee Maestro"]

    nonisolated static func audioAppsBlock() -> String {
        let names = Set(run("/bin/ps", ["-axo", "comm="], timeout: 5)
            .split(separator: "\n")
            .map { String($0.split(separator: "/").last ?? "") })
        let open = knownAudioApps.filter { app in names.contains { $0 == app || $0.hasPrefix(app + " ") } }
        return "Audio apps open: " + (open.isEmpty ? "none of the common DAWs" : open.joined(separator: ", "))
    }

    nonisolated private static func usbBlock() -> String {
        let raw = run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w0", "-r", "-c", "IOUSBHostDevice"], timeout: 10)
        // Keep the Apogee devices (vendor 0x0C60 = 3168), without serial numbers.
        let blocks = raw.components(separatedBy: "+-o ").filter { $0.contains("\"idVendor\" = 3168") }
        guard !blocks.isEmpty else { return "Symphony over USB: not present" }
        let keep = ["USB Product Name", "idProduct", "bcdDevice", "Device Speed", "UsbLinkSpeed", "kUSBCurrentConfiguration"]
        return "Symphony over USB:\n" + blocks.map { b in
            b.split(separator: "\n").filter { line in keep.contains { line.contains($0) } }
                .map { "  " + $0.trimmingCharacters(in: CharacterSet(charactersIn: " |")) }.joined(separator: "\n")
        }.joined(separator: "\n  --\n")
    }

    nonisolated private static func pciBlock() -> String {
        var out = ["ThunderBridge / PCIe card:"]
        let raw = run("/usr/sbin/ioreg", ["-r", "-c", "IOPCIDevice", "-l", "-w0"], timeout: 10)
        let blocks = raw.components(separatedBy: "+-o ").filter { $0.contains("\"vendor-id\" = <c2190000>") }
        let keep = ["IOName", "device-id", "revision-id", "subsystem", "IOPCIMSIMode", "IOInterruptSpecifiers", "IOPCIExpressLinkStatus", "IOPCIExpressLinkCapabilities", "pcidebug", "IOPCITunnelled", "assigned-addresses"]
        for b in blocks {
            out.append(b.split(separator: "\n").prefix(1).map { "  " + $0 }.joined())
            out.append(contentsOf: b.split(separator: "\n").filter { line in keep.contains { line.contains($0) } }
                .map { "  " + $0.trimmingCharacters(in: CharacterSet(charactersIn: " |")) })
        }
        // Chassis and link details; -detailLevel mini leaves out serial numbers,
        // and any line that still names one is dropped.
        let profile = run("/usr/sbin/system_profiler", ["-detailLevel", "mini", "SPThunderboltDataType", "SPPCIDataType"], timeout: 30)
        out.append("System report (Thunderbolt and PCI):")
        out.append(contentsOf: profile.split(separator: "\n")
            .filter { !$0.localizedCaseInsensitiveContains("serial") && !$0.contains("UID") && !$0.contains("UUID") }
            .map { "  " + $0 })
        return out.joined(separator: "\n")
    }

    // MARK: - Core Audio (our devices only)

    /// Our devices only (name contains Symphony or Maestro): other devices'
    /// names can be personal ("Jane's AirPods"). For the defaults, only
    /// whether they are ours.
    nonisolated static func coreAudioSummary() -> String {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return "Core Audio: could not list devices"
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return "Core Audio: could not list devices"
        }
        func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr, let cf else { return nil }
            return cf.takeRetainedValue() as String
        }
        func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0; var s = UInt32(4)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? v : nil
        }
        func f64(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Double? {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var v: Float64 = 0; var s = UInt32(8)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? v : nil
        }
        func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr, s > 0 else { return 0 }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, raw) == noErr else { return 0 }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        var ours: [AudioDeviceID: String] = [:]
        var lines: [String] = []
        for id in ids {
            guard let name = string(id, kAudioObjectPropertyName),
                  name.localizedCaseInsensitiveContains("symphony") || name.localizedCaseInsensitiveContains("maestro") else { continue }
            ours[id] = name
            let rate = f64(id, kAudioDevicePropertyNominalSampleRate).map { String(format: "%.0f", $0) } ?? "?"
            let buffer = u32(id, kAudioDevicePropertyBufferFrameSize).map(String.init) ?? "?"
            let running = u32(id, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 ? "yes" : "no" } ?? "?"
            let alive = u32(id, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 ? "yes" : "no" } ?? "?"
            // The device's own output volume and mute (over ThunderBridge/PCIe the
            // driver's control, which it forwards to the Symphony's speaker output).
            var va = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                                mScope: kAudioObjectPropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
            var vdb: Float32 = 0; var vs = UInt32(4)
            let volume = AudioObjectGetPropertyData(id, &va, 0, nil, &vs, &vdb) == noErr
                ? String(format: "%.1f dB", vdb) : "none"
            let muted = u32(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
                .map { $0 != 0 ? "yes" : "no" } ?? "none"
            lines.append("  \"\(name)\" rate=\(rate) buffer=\(buffer) in=\(channels(id, kAudioObjectPropertyScopeInput)) out=\(channels(id, kAudioObjectPropertyScopeOutput)) runningSomewhere=\(running) alive=\(alive) volume=\(volume) muted=\(muted)")
        }
        func defaultIs(_ sel: AudioObjectPropertySelector) -> String {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var id = AudioDeviceID(0); var s = UInt32(4)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &id) == noErr else { return "?" }
            return ours[id].map { "\"\($0)\"" } ?? "another device"
        }
        lines.append("  default output: \(defaultIs(kAudioHardwarePropertyDefaultOutputDevice)), default input: \(defaultIs(kAudioHardwarePropertyDefaultInputDevice))")
        return "Core Audio (our devices):\n" + (lines.count > 1 ? "" : "  none found\n") + lines.joined(separator: "\n")
    }

    // MARK: - Timing health

    private static func timingHealthText(_ appState: AppState) async -> String? {
        guard let tb = appState.device as? ThunderboltDeviceConnection else { return nil }
        guard let th = await withTimeout(3, { tb.readTimingHealth() }) ?? nil else {
            return "no answer from the driver (or it took longer than 3 s)"
        }
        return "clkCtrl=0x\(String(th.clkCtrl, radix: 16)) intStatus=0x\(String(th.intStatus, radix: 16)) xlinkStatus=0x\(String(th.xlinkStatus, radix: 16)) gcsr=0x\(String(th.gcsr, radix: 16)) frame=\(th.frameReadback)/\(th.expectedFrame) rate=\(th.sampleRate) latency in/out=\(th.inputLatency)/\(th.outputLatency) safety in/out=\(th.inputSafety)/\(th.outputSafety)"
    }

    // MARK: - System log, USB helper log, crash reports

    nonisolated static let proxyLogPath = "/tmp/MaestroVolumeProxy.log"

    /// Our own lines only: Maestro's and the USB helper's log subsystems (not
    /// the frameworks inside them, which are mostly window and Spotlight
    /// chatter), the driver's "SymphonyTB" lines, and what the kernel, system
    /// extension daemon and Core Audio say about our hardware. The helper's
    /// once-a-second meter dump is left out (its own log keeps the changes).
    nonisolated static let logPredicate = #"(eventMessage CONTAINS "SymphonyTB" OR subsystem BEGINSWITH[c] "com.danielraffel." OR ((process == "kernel" OR process == "sysextd" OR process == "coreaudiod") AND (eventMessage CONTAINS[c] "symphony" OR eventMessage CONTAINS[c] "thunderbridge" OR eventMessage CONTAINS[c] "maestro" OR eventMessage CONTAINS[c] "apogee"))) AND NOT eventMessage BEGINSWITH "METERDUMP" AND NOT eventMessage BEGINSWITH "Sandbox:""#

    private func startLogStream(since: Date) {
        // Through a small shell that ends `log stream` when Maestro goes away
        // (quit, crash or force quit), so it can never run on by itself, and
        // when Maestro stops it (terminate sends TERM to the shell).
        // (The shell's own stderr is silenced on the way out, so its
        // "Terminated" job notice does not land in the file.)
        let watcher = #"/usr/bin/log "$@" & L=$!; trap 'exec 2>/dev/null; kill $L; exit 0' TERM INT; while kill -0 "$MAESTRO_PID" 2>/dev/null && kill -0 $L 2>/dev/null; do sleep 2; done; exec 2>/dev/null; kill $L"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.environment = ["MAESTRO_PID": String(ProcessInfo.processInfo.processIdentifier), "PATH": "/usr/bin:/bin"]
        p.arguments = ["-c", watcher, "sh", "stream", "--style", "compact", "--level", "info", "--predicate", Self.logPredicate]
        guard let h = try? FileHandle(forWritingTo: systemLogFile) else { return }
        p.standardOutput = h
        p.standardError = h
        do {
            try p.run()
            logStream = p
        } catch {
            append("\nSystem log: could not start recording (\(error.localizedDescription)).\n")
        }
    }

    nonisolated private static func proxyLog(since offset: UInt64) -> String {
        guard let h = FileHandle(forReadingAtPath: proxyLogPath) else { return "not readable or not present" }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        // The file can be rotated or truncated; then take its last 2 MB.
        let start = offset <= end ? offset : (end > 2_000_000 ? end - 2_000_000 : 0)
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        let text = Self.dropRepeatedMeterDumps(String(decoding: data, as: UTF8.self))
        return text.isEmpty ? "nothing new during this session" : text
    }

    nonisolated static let beforeMinutes = 30
    nonisolated static let proxyLinesBefore = 300

    /// The USB helper's last lines before the session (meter repeats left
    /// out), for a problem that happened just before diagnostics was on.
    nonisolated private static func proxyLogBefore(offset: UInt64, lines: Int) -> String {
        guard offset > 0, let h = FileHandle(forReadingAtPath: proxyLogPath) else { return "none" }
        defer { try? h.close() }
        let window: UInt64 = 512 * 1024
        try? h.seek(toOffset: offset > window ? offset - window : 0)
        guard let data = try? h.read(upToCount: Int(min(offset, window))) else { return "none" }
        let text = dropRepeatedMeterDumps(String(decoding: data, as: UTF8.self))
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines)
        return kept.isEmpty ? "none" : kept.joined(separator: "\n")
    }

    /// Our lines from the stored system log for the minutes before `until`
    /// (the same filter as the live recording). Slow: run it off the main actor.
    nonisolated static func systemLog(minutesBefore minutes: Int, until end: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let out = run("/usr/bin/log", ["show", "--style", "compact", "--info",
                                       "--start", f.string(from: end.addingTimeInterval(TimeInterval(-minutes * 60))),
                                       "--end", f.string(from: end),
                                       "--predicate", logPredicate], timeout: 90)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "nothing logged" : out
    }

    /// The helper logs its meter readings once a second, mostly unchanged:
    /// keep a reading only when it differs from the one before.
    nonisolated static func dropRepeatedMeterDumps(_ text: String) -> String {
        var last: [String: String] = [:]  // per meter group ("grp=0")
        var dropped = 0
        var out: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let r = line.range(of: "METERDUMP ") {
                let reading = String(line[r.upperBound...])
                let group = String(reading.prefix { $0 != ":" })
                if last[group] == reading { dropped += 1; continue }
                last[group] = reading
            }
            out.append(line)
        }
        let joined = out.joined(separator: "\n")
        return dropped == 0 ? joined : joined + "\n(\(dropped) unchanged meter readings left out)\n"
    }

    /// Crash, hang, spin and CPU reports from the last week for Maestro, the
    /// USB helper, Core Audio and its plug-in hosts, our driver, and kernel
    /// panics: often the problem happened just before diagnostics was turned
    /// on. The newest few are included in full, the rest listed.
    nonisolated static let crashReportWindow: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let crashReportPrefixes = ["MaestroApp", "MaestroVolumeProxy", "coreaudiod", "Core Audio Driver",
                                                  "com.danielraffel", "panic", "Kernel"]

    nonisolated private static func crashReports(since sessionStart: Date) -> String {
        let fm = FileManager.default
        let dirs = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports").path,
                    "/Library/Logs/DiagnosticReports"]
        let oldest = sessionStart.addingTimeInterval(-crashReportWindow)
        var found: [(path: String, name: String, date: Date)] = []
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            where crashReportPrefixes.contains(where: { name.hasPrefix($0) }) {
                let path = dir + "/" + name
                guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      date >= oldest else { continue }
                found.append((path, name, date))
            }
        }
        guard !found.isEmpty else { return "none in the last 7 days" }
        found.sort { $0.date > $1.date }
        let when = { (d: Date) in d >= sessionStart ? "during this session" : "before diagnostics started" }
        var out = ["\(found.count) in the last 7 days, newest first:"]
        out += found.map { "  \(stamp($0.date))  \($0.name)  (\(when($0.date)))" }
        for report in found.prefix(5) {
            let text = (try? String(contentsOfFile: report.path, encoding: .utf8))
                ?? "(not readable by this account)"
            out.append("\n--- \(report.name) (\(when(report.date))) ---\n"
                       + text.split(separator: "\n", omittingEmptySubsequences: false).prefix(300).joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }

    /// Core Audio's uptime and CPU: a recent restart, or one stuck near
    /// 100%, explains apps (Maestro included) waiting at launch.
    nonisolated static func coreAudioHealth() -> String {
        let pid = run("/usr/bin/pgrep", ["-x", "coreaudiod"], timeout: 5)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !pid.isEmpty else { return "Core Audio daemon: not running" }
        let ps = run("/bin/ps", ["-o", "etime=,%cpu=", "-p", pid], timeout: 5)
            .split(whereSeparator: \.isWhitespace)
        guard ps.count >= 2 else { return "Core Audio daemon: running (no details)" }
        return "Core Audio daemon: running for \(ps[0]), CPU \(ps[1])%"
    }

    // MARK: - Redaction

    nonisolated static func redactor() -> DiagnosticsRedactor {
        var r = DiagnosticsRedactor()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        r.add(home, as: "~")
        r.add(NSUserName(), as: "<user>", wholeWord: true)
        r.add(NSFullUserName(), as: "<full name>", wholeWord: true)
        r.add(Host.current().localizedName, as: "<computer>", wholeWord: true)
        r.add(ProcessInfo.processInfo.hostName, as: "<computer>", wholeWord: true)
        let local = run("/usr/sbin/scutil", ["--get", "LocalHostName"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)
        r.add(local, as: "<computer>", wholeWord: true)
        r.add(local.isEmpty ? nil : local + ".local", as: "<computer>", wholeWord: true)
        let platform = run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"], timeout: 5)
        for key in ["IOPlatformSerialNumber", "IOPlatformUUID", "provisioning-UDID"] {
            if let line = platform.split(separator: "\n").first(where: { $0.contains("\"\(key)\"") }),
               let value = line.split(separator: "\"").dropLast().last {
                r.add(String(value), as: key == "IOPlatformSerialNumber" ? "<serial>" : "<hardware id>")
            }
        }
        return r
    }

    // MARK: - Helpers

    nonisolated static func capped(_ text: String, _ limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let tail = String(decoding: Data(text.utf8).suffix(limit), as: UTF8.self)
        return "[Earlier lines left out to keep the file under \(limit / 1_048_576) MB.]\n" + tail
    }

    nonisolated static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: date)
    }

    nonisolated private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    nonisolated private static func teamID(_ path: String) -> String? {
        let out = run("/usr/bin/codesign", ["-dv", "--verbose=2", path], timeout: 10)
        return out.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
    }

    /// Run a tool and return its output (stdout and stderr), or a note if it
    /// failed or took too long. Never throws.
    nonisolated static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "(\(tool) could not run: \(error.localizedDescription))" }
        var data = Data()
        let reader = DispatchQueue.global(qos: .utility)
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return "(\(URL(fileURLWithPath: tool).lastPathComponent) took longer than \(Int(timeout)) s)"
        }
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Run blocking work off the main actor; nil if it takes longer than
    /// `seconds` (the work is left to finish on its own).
    nonisolated static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ value: T?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            DispatchQueue.global(qos: .utility).async { finish(work()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { finish(nil) }
        }
    }
}

/// Copies Maestro's own output (its `print` lines) into the diagnostics folder
/// while recording, and still to wherever it went before.
///
/// The copy runs on Foundation's file-handle queue while `stop()` runs on the
/// main actor. They share the two descriptors, so both go through one lock and
/// the copy does nothing once stopped. The file is written with `write(2)`,
/// not `FileHandle.write`: on a closed handle that raises an Objective-C
/// exception, which `try?` does not catch, and it aborted Maestro when Stop
/// Diagnostics was pressed while output was in flight (report 04CB0C0D,
/// 2026-11-21: `closure #1 in StdoutTee.init(file:)` under
/// `_NSFileHandleRaiseOperationExceptionWhileReading`).
private final class StdoutTee: @unchecked Sendable {
    private let pipe = Pipe()
    private let lock = NSLock()
    private var original: Int32
    private var fileFD: Int32
    private var stopped = false

    init(file url: URL) {
        fileFD = open(url.path, O_WRONLY | O_APPEND)
        original = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            self.copy(data)
        }
    }

    private func copy(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        data.withUnsafeBytes { bytes in
            if original >= 0 { _ = write(original, bytes.baseAddress, bytes.count) }
            if fileFD >= 0 { _ = write(fileFD, bytes.baseAddress, bytes.count) }
        }
    }

    func stop() {
        fflush(stdout)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if original >= 0 { dup2(original, STDOUT_FILENO); close(original); original = -1 }
        if fileFD >= 0 { close(fileFD); fileFD = -1 }
        lock.unlock()
        try? pipe.fileHandleForWriting.close()
    }
}
