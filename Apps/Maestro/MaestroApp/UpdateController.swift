import Combine
import Foundation
import MaestroCore
import Sparkle

/// Sparkle owns persistence and scheduling. Opting out stops scheduled checks;
/// a manual check remains available. Automatic installation is disabled in Info.plist.
///
/// Stable and Beta channels: one feed, beta items tagged
/// `<sparkle:channel>beta</sparkle:channel>`. `UpdateChannelDelegate` tells
/// Sparkle which channels this copy follows. Maestro reads the feed itself
/// (`loadFeed()`) only on a user action about updates, or when Preferences
/// appears with scheduled checks on; never at launch and never on a timer.
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }

    /// The user's explicit choice, or nil when they never chose.
    @Published private(set) var channelPreference: UpdateChannel?
    @Published private(set) var effectiveChannel: UpdateChannel = .stable
    /// What the last feed read said about this version (survives relaunch).
    @Published private(set) var derivedChannel: DerivedChannel?
    @Published private(set) var sessionInProgress = false
    /// The last feed Maestro fetched and verified itself in this run.
    @Published private(set) var snapshot: FeedSnapshot?
    /// The `SUFeedURL` user default, when a test feed is in use.
    @Published private(set) var feedOverride: String?

    let installedVersion: String
    let publicKey: String?
    /// The verified download used to go back to stable.
    let reinstaller: StableReinstaller

    private let controller: SPUStandardUpdaterController
    /// Sparkle holds its delegate weakly; this keeps it alive.
    private let channelDelegate: UpdateChannelDelegate
    private let store: ChannelStore
    private var lastFeedRead: Date?
    private var subscriptions = Set<AnyCancellable>()

    init(store: ChannelStore = ChannelStore(), bundle: Bundle = .main) {
        self.store = store
        installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0.0.0"
        publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        reinstaller = StableReinstaller(publicKey: publicKey)
        channelDelegate = UpdateChannelDelegate(store: store, installedVersion: installedVersion)
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: channelDelegate, userDriverDelegate: nil)
        automaticallyChecksForUpdates = false
        channelDelegate.onChange = { [weak self] in self?.refreshChannelState() }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        // Every write of sessionInProgress in Sparkle 2.10.0 goes through the
        // property setter, so KVO sees it, though the header does not promise
        // it. The end of each cycle refreshes it too (delegate), and every
        // channel action reads the updater directly before it starts.
        controller.updater.publisher(for: \.sessionInProgress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sessionInProgress = $0 }
            .store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, self.automaticallyChecksForUpdates != value else { return }
                self.automaticallyChecksForUpdates = value
            }
            .store(in: &subscriptions)
        // Sparkle may have persisted the old pre-release default (off) from an
        // earlier build. On the first run of this updater integration, migrate
        // to the product default (on); subsequent user choices are retained.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "maestroAutomaticUpdatesConfigured") {
            controller.updater.automaticallyChecksForUpdates = true
            defaults.set(true, forKey: "maestroAutomaticUpdatesConfigured")
        }
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        feedOverride = UserDefaults.standard.string(forKey: "SUFeedURL")
        refreshChannelState()
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// True while Sparkle has a check, a dialog, a download or an install
    /// going. Read from the updater itself, so a missed notification cannot
    /// start a check Sparkle would ignore.
    var isSessionInProgress: Bool {
        let live = controller.updater.sessionInProgress
        if live != sessionInProgress { sessionInProgress = live }
        return live
    }

    func refreshChannelState() {
        channelPreference = store.preference
        derivedChannel = store.derived
        effectiveChannel = store.effective(installed: installedVersion, snapshot: snapshot)
        feedOverride = UserDefaults.standard.string(forKey: "SUFeedURL")
        sessionInProgress = controller.updater.sessionInProgress
    }

    /// The newest stable version from the last feed read, for display.
    var newestStableForDisplay: String? {
        guard let derivedChannel, derivedChannel.applies(to: installedVersion) else { return nil }
        return derivedChannel.newestStable
    }

    /// "You're running beta X. The latest stable version is Y."
    var isRunningBetaOnStable: Bool {
        ChannelRule.isRunningBetaOnStable(effective: effectiveChannel, installed: installedVersion, stored: derivedChannel)
    }

    /// The link of "What's in the current beta".
    var currentBetaNotesURL: URL { snapshot?.currentBetaNotesURL ?? UpdateLinks.releasesPage }
    var hasCurrentBeta: Bool { snapshot?.hasCurrentBeta ?? false }

    // MARK: Maestro's own feed read

    enum FeedError: Error, CustomStringConvertible {
        case noFeedURL
        case noPublicKey
        case network(String)
        case unsigned
        case parse(String)

        var description: String {
            switch self {
            case .noFeedURL: "no update feed is configured"
            case .noPublicKey: "this copy of Maestro has no update key"
            case .network(let detail): "the update feed could not be downloaded (\(detail))"
            case .unsigned: "the update feed is not signed with Maestro's key"
            case .parse(let detail): detail
            }
        }
    }

    /// Fetches the feed Sparkle uses (so a test-feed override applies),
    /// verifies its signature with the app's `SUPublicEDKey`, and applies the
    /// channel rule. Does not touch Sparkle's schedule.
    @discardableResult
    func loadFeed() async throws -> FeedSnapshot {
        guard let url = controller.updater.feedURL else { throw FeedError.noFeedURL }
        guard let publicKey else { throw FeedError.noPublicKey }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Maestro/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FeedError.network("HTTP \(http.statusCode)")
            }
            data = body
        } catch let error as FeedError {
            throw error
        } catch {
            throw FeedError.network(error.localizedDescription)
        }
        guard let content = SignedFeed.verifiedContent(data, publicKeyBase64: publicKey) else { throw FeedError.unsigned }
        let parsed: FeedSnapshot
        do { parsed = try FeedSnapshot(content: content) } catch { throw FeedError.parse(String(describing: error)) }
        snapshot = parsed
        lastFeedRead = Date()
        store.record(snapshot: parsed, installed: installedVersion)
        refreshChannelState()
        return parsed
    }

    /// Preferences appearing: refresh the display from the feed when
    /// scheduled checks are on (so no new kind of connection is made for
    /// someone who turned them off) and the last read is over ten minutes old.
    /// Failures are silent.
    func refreshForPreferencesIfAllowed() {
        refreshChannelState()
        guard automaticallyChecksForUpdates else { return }
        if let lastFeedRead, Date().timeIntervalSince(lastFeedRead) < 600 { return }
        Task { try? await self.loadFeed() }
    }

    // MARK: Channel actions

    /// After the Beta confirmation: save Beta, then check, so the current
    /// beta is offered at once.
    func chooseBeta() {
        guard !isSessionInProgress else { return }
        store.preference = .beta
        refreshChannelState()
        checkForUpdates()
    }

    enum StableChoice {
        /// Saved; nothing more to show.
        case done
        /// Installed version above the newest stable: ask (go-back dialog).
        case askToGoBack(FeedItem)
        /// Saved; the feed could not be downloaded (offline, server down).
        case savedFeedUnreachable(String)
        /// Saved; the feed was read but cannot be used to go back (unsigned,
        /// no stable package, below the floor).
        case savedRefused(String)
    }

    /// Choosing Stable (plan §5). Cancel in the go-back dialog leaves the
    /// preference as it was, so nothing is saved for `.askToGoBack`.
    func chooseStable() async -> StableChoice {
        guard !isSessionInProgress else { return .done }
        let feed: FeedSnapshot
        do {
            feed = try await loadFeed()
        } catch let error as FeedError {
            setPreference(.stable)
            if case .network = error { return .savedFeedUnreachable(error.description) }
            return .savedRefused(error.description)
        } catch {
            setPreference(.stable)
            return .savedFeedUnreachable(String(describing: error))
        }
        switch StableTarget.choose(snapshot: feed, installed: installedVersion, macOS: ProcessInfo.processInfo.operatingSystemVersion) {
        case .upToDate:
            setPreference(.stable)
            return .done
        case .sparkleWillOffer:
            setPreference(.stable)
            if !isSessionInProgress { checkForUpdates() }
            return .done
        case .goBack(let item):
            return .askToGoBack(item)
        case .refused(let reason):
            setPreference(.stable)
            return .savedRefused(reason.description)
        }
    }

    /// "Install X…" in Preferences: re-read and verify the feed, never trust
    /// the stored number.
    func stableTargetForInstall() async throws -> StableTarget {
        let feed = try await loadFeed()
        return StableTarget.choose(snapshot: feed, installed: installedVersion, macOS: ProcessInfo.processInfo.operatingSystemVersion)
    }

    func setPreference(_ channel: UpdateChannel) {
        store.preference = channel
        refreshChannelState()
    }
}

/// Tells Sparkle which channels this copy follows. Sparkle calls
/// `didFinishLoadingAppcast` with the whole feed before it filters by
/// channel (SUAppcastDriver.m:200 before :208-220), so the rule's result
/// applies to the same check.
@MainActor
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    private let store: ChannelStore
    private let installedVersion: String
    var onChange: (() -> Void)?

    init(store: ChannelStore, installedVersion: String) {
        self.store = store
        self.installedVersion = installedVersion
    }

    /// The channel set for the current state; `[]` is stable items only.
    func currentAllowedChannels() -> Set<String> {
        store.effective(installed: installedVersion, snapshot: nil).sparkleAllowedChannels
    }

    /// Applies the rule to the items Sparkle loaded (channel and version only).
    func record(items: [FeedItem]) {
        store.record(snapshot: FeedSnapshot(items: items), installed: installedVersion)
        onChange?()
    }

    @objc(allowedChannelsForUpdater:)
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        currentAllowedChannels()
    }

    @objc(updater:didFinishLoadingAppcast:)
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        record(items: appcast.items.map { FeedItem(version: $0.versionString, displayVersion: $0.displayVersionString, channel: $0.channel) })
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        onChange?()
    }
}
