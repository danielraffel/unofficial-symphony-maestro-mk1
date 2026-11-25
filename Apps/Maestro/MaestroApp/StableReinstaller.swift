import AppKit
import Foundation
import MaestroCore

/// Going back to stable (release-channels plan §5, steps 4-7): download the
/// stable package the verified feed names, check it, and hand it to
/// Installer.app. Sparkle cannot do this because it never installs a lower
/// version, so this path brings its own checks:
///
/// 1. The enclosure is downloaded into a new private directory
///    (`~/Library/Caches/com.danielraffel.maestro/StableReinstall/<uuid>/`,
///    mode 700); the file is made read-only once written.
/// 2. Its byte count must equal the feed's `length`, then its Ed25519
///    signature must match `sparkle:edSignature` with the app's own key.
/// 3. `spctl --assess --type install` must accept it as notarized and signed
///    by Developer ID Installer with Maestro's team ID.
/// 4. Only then is it opened (Installer.app). Nothing else is clicked in
///    Maestro; the user confirms in Installer and types their password there.
@MainActor
final class StableReinstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(version: String, fraction: Double?)
        case checking(version: String)
        case handedOff(version: String)
        case failed(String)
    }

    struct Environment {
        /// Writes the download to `destination`, reporting progress (0...1).
        var download: (_ url: URL, _ destination: URL, _ expectedLength: Int, _ progress: @escaping @MainActor (Double) -> Void) async throws -> Void
        /// Runs `spctl --assess --type install -vv` and returns its status and both output streams.
        var assess: (_ file: URL) async -> (status: Int32, output: String)
        /// Opens the package (Installer.app).
        var open: (_ file: URL) -> Bool
        var cacheRoot: URL
        /// Whether one of Apogee's kernel drivers for the ThunderBridge or PCIe
        /// card is loaded right now (ApogeeDriverConflict.swift).
        var apogeeKernelDriverLoaded: () -> Bool = { false }

        static var live: Environment {
            Environment(
                download: StableReinstaller.liveDownload,
                assess: StableReinstaller.liveAssess,
                open: { NSWorkspace.shared.open($0) },
                cacheRoot: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.danielraffel.maestro", isDirectory: true)
                    .appendingPathComponent("StableReinstall", isDirectory: true),
                apogeeKernelDriverLoaded: { AppState.currentOriginalApogeeDrivers().hasLoadedPCIKernelDriver }
            )
        }
    }

    @Published private(set) var phase: Phase = .idle
    private(set) var downloadedFile: URL?
    private let environment: Environment
    private let publicKey: String?
    private var task: Task<Void, Never>?

    init(publicKey: String?, environment: Environment = .live) {
        self.publicKey = publicKey
        self.environment = environment
    }

    /// Shown in brackets under the failure headline.
    static let apogeeDriverLoadedReason = "Apogee's original Symphony driver is loaded: run Apogee's own "
        + "uninstaller and restart your Mac first; Device Settings has the steps"

    var isBusy: Bool {
        switch phase {
        case .downloading, .checking: true
        default: false
        }
    }

    func start(item: FeedItem) {
        guard !isBusy else { return }
        // Busy at once, before the task runs: the progress sheet treats idle
        // as "cancelled" and would close itself.
        phase = .downloading(version: item.displayVersion, fraction: nil)
        task = Task { await run(item: item) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func reset() {
        if !isBusy { phase = .idle }
    }

    /// The whole sequence; `start` runs it in a task.
    func run(item: FeedItem) async {
        let version = item.displayVersion
        // Installing another version replaces Maestro's driver, and stopping
        // it next to Apogee's loaded kernel driver is what crashed a user's
        // Mac. An older stable package does not check for this itself.
        guard !environment.apogeeKernelDriverLoaded() else {
            phase = .failed(Self.apogeeDriverLoadedReason)
            return
        }
        guard let url = item.enclosureURL, let length = item.length, let signature = item.edSignature else {
            phase = .failed("the update feed does not describe a package to download")
            return
        }
        guard UpdateLinks.isAllowedDownload(url) else {
            phase = .failed("the package address is not a secure download")
            return
        }
        guard let publicKey else {
            phase = .failed("this copy of Maestro has no update key")
            return
        }
        let file: URL
        do {
            file = try makePrivateDirectory().appendingPathComponent("UnofficialSymphonyMaestro-\(item.version).pkg")
        } catch {
            phase = .failed("Maestro could not create a folder for the download (\(error.localizedDescription))")
            return
        }
        phase = .downloading(version: version, fraction: 0)
        do {
            try await environment.download(url, file, length) { [weak self] fraction in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(version: version, fraction: fraction)
            }
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        } catch is CancellationError {
            phase = .idle
            return
        } catch {
            if Task.isCancelled { phase = .idle; return }
            phase = .failed("the download did not finish (\(error.localizedDescription))")
            return
        }
        phase = .checking(version: version)
        if let failure = await Self.check(file: file, length: length, signature: signature, publicKey: publicKey, assess: environment.assess) {
            phase = .failed(failure.description)
            return
        }
        guard !Task.isCancelled else { phase = .idle; return }
        downloadedFile = file
        if environment.open(file) {
            phase = .handedOff(version: version)
        } else {
            phase = .failed("Installer could not be opened")
        }
    }

    /// Steps 5-6: length, Ed25519 signature, then the installer signature.
    static func check(file: URL, length: Int, signature: String, publicKey: String,
                      assess: (URL) async -> (status: Int32, output: String)) async -> PackageCheckFailure? {
        let actual = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        guard actual == length else { return .wrongLength(expected: length, actual: actual) }
        guard PackageSignature.verify(file: file, signatureBase64: signature, publicKeyBase64: publicKey) else { return .badSignature }
        let result = await assess(file)
        return InstallerAssessment.check(exitStatus: result.status, output: result.output)
    }

    private func makePrivateDirectory() throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: environment.cacheRoot, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let directory = environment.cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        return directory
    }

    // MARK: Live implementations

    enum DownloadError: LocalizedError {
        case http(Int)
        case tooLong

        var errorDescription: String? {
            switch self {
            case .http(let status): "HTTP \(status)"
            case .tooLong: "the server sent more data than the update feed lists"
            }
        }
    }

    nonisolated static func liveDownload(url: URL, destination: URL, expectedLength: Int,
                                         progress: @escaping @MainActor (Double) -> Void) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Maestro", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.http(http.statusCode)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written = 0
        var lastReported = -1
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 16 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                guard written <= expectedLength else { throw DownloadError.tooLong }
                let percent = expectedLength > 0 ? min(100, written * 100 / expectedLength) : 0
                if percent != lastReported {
                    lastReported = percent
                    await progress(Double(percent) / 100)
                }
            }
        }
        try handle.write(contentsOf: buffer)
        written += buffer.count
        guard written <= expectedLength else { throw DownloadError.tooLong }
        await progress(1)
    }

    nonisolated static func liveAssess(file: URL) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
                process.arguments = ["--assess", "--type", "install", "-vv", file.path]
                let pipe = Pipe()
                // spctl prints its verdict on stderr; read both.
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "spctl could not run: \(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
