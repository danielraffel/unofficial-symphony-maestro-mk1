import Combine
import Sparkle

/// Sparkle owns persistence and scheduling. Opting out stops scheduled checks;
/// a manual check remains available. Automatic installation is disabled in Info.plist.
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
    private let controller: SPUStandardUpdaterController
    private var subscriptions = Set<AnyCancellable>()

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = false
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
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
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
