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

    /// `reinstaller` and `startsUpdater` are for tests: a test passes its own
    /// reinstaller and leaves Sparkle unstarted.
    init(store: ChannelStore = ChannelStore(), bundle: Bundle = .main,
         reinstaller: StableReinstaller? = nil, startsUpdater: Bool = true) {
        self.store = store
        installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0.0.0"
        publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        self.reinstaller = reinstaller ?? StableReinstaller(publicKey: publicKey)
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
        // Preferences reads `reinstaller.isBusy` through this object, and
        // SwiftUI only redraws for the object a view holds. Without this the
        // channel picker and "Install X" stayed disabled after a refused
        // go-back, until something else changed (rehearsal row B11(b)).
        self.reinstaller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        refreshChannelState()
        if startsUpdater { controller.startUpdater() }
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
    /// True only when a feed was read and verified in this run and it has no
    /// beta above the newest stable. An unread feed says nothing either way.
    var feedHasNoCurrentBeta: Bool { snapshot.map { !$0.hasCurrentBeta } ?? false }

    // MARK: Maestro's own feed read

    typealias FeedError = FeedReadError

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
        guard FeedRefreshPolicy.shouldRefreshOnPreferences(
            automaticChecks: automaticallyChecksForUpdates, lastRead: lastFeedRead, now: Date()) else { return }
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

    /// Choosing Stable (plan §5). Cancel in the go-back dialog leaves the
    /// preference as it was, so nothing is saved for `.askToGoBack`.
    func chooseStable() async -> StableChoicePlan {
        guard !isSessionInProgress else { return .saveStable }
        let plan: StableChoicePlan
        do {
            let feed = try await loadFeed()
            plan = StableChoicePlan.plan(for: StableTarget.choose(
                snapshot: feed, installed: installedVersion, macOS: ProcessInfo.processInfo.operatingSystemVersion))
        } catch let error as FeedReadError {
            plan = StableChoicePlan.plan(for: error)
        } catch {
            plan = .saveStableOffline
        }
        if plan.savesStable { setPreference(.stable) }
        if plan == .saveStableAndCheck, !isSessionInProgress { checkForUpdates() }
        return plan
    }

    /// "Install X" in Preferences: re-read and verify the feed, never trust
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
    /// Whether one of Apogee's kernel drivers for the ThunderBridge or PCIe
    /// card is loaded right now. Asked once per update Sparkle is about to
    /// offer; a test passes its own.
    private let apogeeKernelDriverLoaded: () -> Bool

    init(store: ChannelStore, installedVersion: String,
         apogeeKernelDriverLoaded: @escaping () -> Bool = {
             AppState.currentOriginalApogeeDrivers().hasLoadedPCIKernelDriver
         }) {
        self.store = store
        self.installedVersion = installedVersion
        self.apogeeKernelDriverLoaded = apogeeKernelDriverLoaded
    }

    /// Why an update must not go ahead now, or nil. While Apogee's kernel
    /// driver is loaded, installing an update replaces Maestro's driver, and
    /// stopping it next to Apogee's is what crashed a user's Mac
    /// (ApogeeDriverConflict.swift). The installer's preinstall refuses too;
    /// this says so before anything is downloaded.
    func updateRefusal() -> NSError? {
        guard apogeeKernelDriverLoaded() else { return nil }
        return NSError(domain: "com.danielraffel.maestro.update", code: 1, userInfo: [
            NSLocalizedDescriptionKey: ApogeeDriverConflict.updateRefusal,
        ])
    }

    /// Sparkle asks before it shows or downloads an update. Throwing stops it;
    /// for a check the user started, Sparkle shows the error's description.
    @objc(updater:shouldProceedWithUpdate:updateCheck:error:)
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        if let refusal = updateRefusal() { throw refusal }
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
