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

/// When a downloaded update may install itself and relaunch the app.
enum UpdateInstallPolicy {
    /// Never pull the app away while someone is looking at it.
    static func canInstallNow(menuIsOpen: Bool, windowIsOpen: Bool) -> Bool {
        !menuIsOpen && !windowIsOpen
    }
}

@MainActor
protocol AppUpdating: AnyObject {
    var isConfigured: Bool { get }
    /// Asked before a downloaded update installs and relaunches the app.
    var canInstallNow: () -> Bool { get set }
    func start()
    func checkForUpdates()
    /// Installs an update that was waiting for the app to be idle.
    func installPendingUpdateIfIdle()
}

/// Sparkle normally installs a downloaded update only when the app quits,
/// which an always-on menu bar app rarely does. Mac Pulse takes over that
/// step and installs right away, relaunching itself silently, as soon as
/// neither its menu nor its window is open.
@MainActor
final class SparkleAppUpdater: NSObject, AppUpdating, SPUUpdaterDelegate {
    private let logger = Logger(
        subsystem: "com.lukemainwaring.internetspeed",
        category: "Updates"
    )
    private var updaterController: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    var canInstallNow: () -> Bool = { true }

    var isConfigured: Bool { updaterController != nil }

    init(bundle: Bundle = .main) {
        super.init()
        guard AppUpdateConfiguration.load(from: bundle.infoDictionary) != nil else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
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

    func installPendingUpdateIfIdle() {
        guard let install = pendingInstall, canInstallNow() else { return }
        pendingInstall = nil
        logger.info("Installing downloaded update and relaunching")
        install()
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            logger.info("Update \(version, privacy: .public) downloaded")
            pendingInstall = immediateInstallHandler
            installPendingUpdateIfIdle()
        }
        return true
    }
}
