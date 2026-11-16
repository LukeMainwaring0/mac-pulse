import Foundation
import XCTest
@testable import InternetSpeed

final class AppSettingsTests: XCTestCase {
    func testUsageAccumulatesWithinTheSameDay() {
        let defaults = InMemoryPreferences()

        let settings = AppSettings(defaults: defaults)
        settings.addUsage(1_000)
        settings.addUsage(2_000)

        XCTAssertEqual(settings.usageToday(), 3_000)
    }

    func testLaunchAtLoginWritesLaunchAgent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InternetSpeedTests-\(UUID().uuidString)")
        let plistURL = directory.appendingPathComponent("login.plist")
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = AppSettings(
            launchAgentURL: plistURL,
            appBundlePath: "/Applications/Mac Pulse.app"
        )
        try settings.setLaunchAtLogin(true)

        XCTAssertTrue(settings.launchAtLoginEnabled)
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, "com.lukemainwaring.internetspeed")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/usr/bin/open", "-gj", "/Applications/Mac Pulse.app"]
        )
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    }

    func testRetiredEstimatorAndScheduleSettingsAreCleared() {
        let defaults = InMemoryPreferences()
        defaults.set(Data("{\"estimatedMbps\":58}".utf8), forKey: "estimatorSnapshot")
        defaults.set(true, forKey: "measurementsPaused")
        defaults.set(90.0, forKey: "measurementInterval")
        defaults.set("wifi|unmetered", forKey: "networkSignature")

        _ = AppSettings(defaults: defaults)

        for key in ["estimatorSnapshot", "measurementsPaused", "measurementInterval", "networkSignature"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }
}
