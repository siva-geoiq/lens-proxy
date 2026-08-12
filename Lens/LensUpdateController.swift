import Foundation
import Observation
import Sparkle

struct LensAvailableUpdate: Equatable, Sendable {
    let version: String
    let build: String
}

@MainActor
@Observable
final class LensUpdateController: NSObject, SPUUpdaterDelegate {
    private(set) var availableUpdate: LensAvailableUpdate?
    private(set) var isConfigured = false
    private(set) var configurationMessage = "Updates are unavailable in this build."

    @ObservationIgnored
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    @ObservationIgnored
    private var hasStarted = false

    var canCheckForUpdates: Bool {
        isConfigured && (!hasStarted || updaterController.updater.canCheckForUpdates)
    }

    override init() {
        super.init()
        validateConfiguration()
    }

    func start() {
        guard isConfigured, !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()
        updaterController.updater.checkForUpdateInformation()
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        if !hasStarted {
            hasStarted = true
            updaterController.startUpdater()
        }
        updaterController.checkForUpdates(nil)
    }

    func installAvailableUpdate() {
        checkForUpdates()
    }

    func dismissAvailableUpdate() {
        availableUpdate = nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdate = LensAvailableUpdate(
            version: item.displayVersionString,
            build: item.versionString
        )
    }

    private func validateConfiguration() {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let feedURL,
              let url = URL(string: feedURL),
              url.scheme == "https",
              let publicKey,
              !publicKey.isEmpty else {
            isConfigured = false
            configurationMessage = "This development build has no update feed."
            return
        }
        isConfigured = true
        configurationMessage = ""
    }
}
