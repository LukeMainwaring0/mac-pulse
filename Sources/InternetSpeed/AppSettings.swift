import Foundation

final class AppSettings {
    private enum Keys {
        static let usageDate = "usageDate"
        static let usageBytes = "usageBytes"
        static let launchAtLoginConfigured = "launchAtLoginConfigured"
        /// Left behind by the old estimator and test-interval settings.
        static let retired = ["measurementInterval", "measurementsPaused", "estimatorSnapshot", "networkSignature"]
    }

    private let defaults: PreferencesStore
    private let calendar: Calendar
    private let launchAgentURL: URL
    private let appBundlePath: String

    init(
        defaults: PreferencesStore = UserDefaults.standard,
        calendar: Calendar = .current,
        launchAgentURL: URL? = nil,
        appBundlePath: String? = nil
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.launchAgentURL = launchAgentURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.lukemainwaring.internetspeed.plist")
        self.appBundlePath = appBundlePath ?? Bundle.main.bundleURL.path
        Keys.retired.forEach(defaults.removeObject(forKey:))
    }

    func addUsage(_ bytes: Int64, at date: Date = Date()) {
        resetUsageIfNeeded(at: date)
        let current = defaults.object(forKey: Keys.usageBytes) as? Int64 ?? 0
        defaults.set(current + bytes, forKey: Keys.usageBytes)
    }

    func usageToday(at date: Date = Date()) -> Int64 {
        resetUsageIfNeeded(at: date)
        return defaults.object(forKey: Keys.usageBytes) as? Int64 ?? 0
    }

    private func resetUsageIfNeeded(at date: Date) {
        let storedDate = defaults.object(forKey: Keys.usageDate) as? Date
        if storedDate == nil || !calendar.isDate(storedDate!, inSameDayAs: date) {
            defaults.set(date, forKey: Keys.usageDate)
            defaults.set(Int64(0), forKey: Keys.usageBytes)
        }
    }

    var launchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            let plist: [String: Any] = [
                "Label": "com.lukemainwaring.internetspeed",
                "ProgramArguments": ["/usr/bin/open", "-gj", appBundlePath],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "AssociatedBundleIdentifiers": ["com.lukemainwaring.internetspeed"]
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: launchAgentURL, options: .atomic)
        } else {
            unloadLaunchAgentIfNeeded()
            try? FileManager.default.removeItem(at: launchAgentURL)
        }
        defaults.set(true, forKey: Keys.launchAtLoginConfigured)
    }

    func enableLaunchAtLoginIfInstalled() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        if launchAtLoginEnabled {
            // Keep an enabled agent's command synchronized across app upgrades.
            try? setLaunchAtLogin(true)
            return
        }
        guard defaults.object(forKey: Keys.launchAtLoginConfigured) == nil else { return }
        try? setLaunchAtLogin(true)
    }

    private func unloadLaunchAgentIfNeeded() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "bootout",
            "gui/\(getuid())/com.lukemainwaring.internetspeed"
        ]
        try? process.run()
        process.waitUntilExit()
    }
}
