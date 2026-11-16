import XCTest
@testable import InternetSpeed

final class StatusNotificationsTests: XCTestCase {
    func testRedEpisodesAndMissingReadings() {
        var tracker = RedStatusTracker()
        let red = TileStatus(level: .bad, explanation: "Hot")
        let green = TileStatus(level: .good, explanation: "Normal")
        XCTAssertEqual(tracker.update(["temperature": green]), [])
        XCTAssertEqual(tracker.update(["temperature": red]), ["temperature"])
        XCTAssertEqual(tracker.update(["temperature": red]), [])
        XCTAssertEqual(tracker.update([:]), [])
        XCTAssertEqual(tracker.update(["temperature": red]), [])
        XCTAssertEqual(tracker.update(["temperature": green]), [])
        XCTAssertEqual(tracker.update(["temperature": red]), ["temperature"])
    }

    func testIndependentDotsAndInitialRed() {
        var tracker = RedStatusTracker()
        let red = TileStatus(level: .bad, explanation: "Critical")
        XCTAssertEqual(tracker.update(["memory": red, "cpu": red]), ["cpu", "memory"])
        XCTAssertEqual(tracker.update(["memory": red, "cpu": red]), [])
    }

    func testSharedDotThresholds() {
        var snapshot = MacPulsePopoverSnapshot()
        snapshot.temperatureCelsius = 90
        snapshot.latencyMilliseconds = 250
        snapshot.memoryPressure = .critical
        snapshot.batteryTimeTone = .critical
        let status = SectionStatus(snapshot: snapshot)
        for section in [AppSection.temperature, .network, .memory, .power] {
            XCTAssertEqual(status.status(for: section)?.level, .bad)
        }
    }
}
