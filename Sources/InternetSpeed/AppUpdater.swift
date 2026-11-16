import Foundation
import OSLog
import Sparkle

struct AppUpdateConfiguration: Equatable {
    static let feedURLKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"

    let feedURL: URL
    let publicEDKey: String

    static func load(from infoDictionary: [String: Any]?) -> AppUpdateConfiguration? {
        guard let infoDictionary,
              let feedValue = infoDictionary[feedURLKey] as? String,
              let feedURL = URL(string: feedValue),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil,
              let key = infoDictionary[publicKeyKey] as? String,
              let decodedKey = Data(base64Encoded: key),
              decodedKey.count == 32
        else {
            return nil
        }

        return AppUpdateConfiguration(feedURL: feedURL, publicEDKey: key)
    }
}

@MainActor
protocol AppUpdating: AnyObject {
    var isConfigured: Bool { get }
    func start()
    func checkForUpdates()
}

@MainActor
final class SparkleAppUpdater: AppUpdating {
    private let logger = Logger(
        subsystem: "com.lukemainwaring.internetspeed",
        category: "Updates"
    )
    private let updaterController: SPUStandardUpdaterController?

    var isConfigured: Bool { updaterController != nil }

    init(bundle: Bundle = .main) {
        guard AppUpdateConfiguration.load(from: bundle.infoDictionary) != nil else {
            updaterController = nil
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func start() {
        guard let updaterController else {
            logger.notice("Automatic updates are unavailable in this development build")
            return
        }
        updaterController.startUpdater()
        logger.info("Automatic update checks started")
    }

    func checkForUpdates() {
        guard let updaterController else { return }
        updaterController.checkForUpdates(nil)
    }
}
