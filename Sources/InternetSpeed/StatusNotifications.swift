import Foundation
import UserNotifications

/// Missing readings never imply recovery; each red episode produces one alert.
struct RedStatusTracker {
    private(set) var redIDs: Set<String> = []

    mutating func update(_ statuses: [String: TileStatus]) -> [String] {
        var entered: [String] = []
        for (id, status) in statuses {
            if status.level == .bad {
                if redIDs.insert(id).inserted { entered.append(id) }
            } else {
                redIDs.remove(id)
            }
        }
        return entered.sorted()
    }
}

@MainActor
final class StatusNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var tracker = RedStatusTracker()
    private var isAuthorized = false
    private var latestSnapshot: MacPulsePopoverSnapshot?
    var openApp: (() -> Void)?
    /// Called when the set of red statuses changes, so the menu bar can follow.
    var onRedChange: (() -> Void)?
    /// Plain explanations for everything currently red, worst first by name.
    private(set) var redSummaries: [String] = []
    /// Which dots are red, keyed by section (for example "processors").
    private(set) var redIDs: Set<String> = []

    private static func selectedSound() -> UNNotificationSound {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mac Pulse/alert-sound.json")
        guard let data = try? Data(contentsOf: url),
              let choice = try? JSONDecoder().decode([String: String].self, from: data),
              let filename = choice["filename"],
              filename.hasPrefix("MacPulse-"), filename.hasSuffix(".aiff"),
              !filename.contains("/"),
              FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds/" + filename).path)
        else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: filename))
    }

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error { NSLog("Mac Pulse notification authorization: %@", error.localizedDescription) }
            Task { @MainActor in
                guard let self else { return }
                self.isAuthorized = granted
                if let snapshot = self.latestSnapshot { self.update(snapshot) }
            }
        }
    }

    func update(_ snapshot: MacPulsePopoverSnapshot) {
        latestSnapshot = snapshot
        let rules = SectionStatus(snapshot: snapshot)
        var statuses: [String: TileStatus] = [:]
        var titles: [String: String] = [:]
        // Overview repeats the other dots, so it does not create duplicate alerts.
        for section in AppSection.allCases where section != .overview {
            statuses[section.rawValue] = rules.status(for: section)
            titles[section.rawValue] = section.title
        }
        if let sample = snapshot.commandCenter {
            let thermal = CommandCenterFormatting.thermal(sample.thermalState)
            statuses["thermalState"] = TileStatus(level: thermal.level, explanation: "Thermal state is \(thermal.text.lowercased())")
            titles["thermalState"] = "Thermal state"
        }
        let summaries = statuses.keys.sorted().compactMap { id -> String? in
            guard let status = statuses[id], status.level == .bad else { return nil }
            return "\(titles[id] ?? id): \(status.explanation)"
        }
        if summaries != redSummaries {
            redSummaries = summaries
            redIDs = Set(statuses.filter { $0.value.level == .bad }.keys)
            onRedChange?()
        }
        guard isAuthorized else { return }
        for id in tracker.update(statuses) {
            let content = UNMutableNotificationContent()
            content.title = "\(titles[id] ?? id) needs attention"
            content.body = statuses[id]?.explanation ?? "Status has turned red."
            content.sound = Self.selectedSound()
            let request = UNNotificationRequest(identifier: "mac-pulse.red.\(id)", content: content, trigger: nil)
            center.add(request) { error in
                if let error { NSLog("Mac Pulse notification delivery: %@", error.localizedDescription) }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.openApp?() }
        completionHandler()
    }
}
