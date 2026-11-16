import XCTest
@testable import InternetSpeed

final class MetricHistoryTests: XCTestCase {
    func testRecordsAndConvertsRecentMetricValues() {
        var history = RecentMetricHistory()
        let start = Date(timeIntervalSince1970: 1_000)

        history.recordDownload(megabitsPerSecond: 180, at: start)
        history.recordSystem(
            memoryUsedBytes: 48 * 1_073_741_824,
            temperatureCelsius: 61,
            at: start
        )

        XCTAssertEqual(history.downloadValues, [180])
        XCTAssertEqual(history.memoryValues, [48])
        XCTAssertEqual(history.temperatureValues, [61])
    }

    func testDownloadKeepsADayOfTestsWhileLiveMetricsKeepTenMinutes() {
        var history = RecentMetricHistory()
        let start = Date(timeIntervalSince1970: 1_000)
        history.recordDownload(megabitsPerSecond: 100, at: start)
        history.recordSystem(memoryUsedBytes: 1_073_741_824, temperatureCelsius: 50, at: start)
        let later = start.addingTimeInterval(RecentMetricHistory.retention + 1)
        history.recordDownload(megabitsPerSecond: 200, at: later)
        history.recordSystem(memoryUsedBytes: 2 * 1_073_741_824, temperatureCelsius: 60, at: later)

        XCTAssertEqual(history.downloadValues, [100, 200])
        XCTAssertEqual(history.memoryValues, [2])

        history.recordDownload(
            megabitsPerSecond: 300,
            at: start.addingTimeInterval(RecentMetricHistory.downloadRetention + 1)
        )
        XCTAssertEqual(history.downloadValues, [200, 300])
    }

    func testStorageAndRenderingRemainBounded() {
        var history = RecentMetricHistory()
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<(RecentMetricHistory.maximumPointsPerMetric + 50) {
            history.recordSystem(
                memoryUsedBytes: UInt64(index + 1) * 1_073_741_824,
                temperatureCelsius: Double(index + 1),
                at: start.addingTimeInterval(Double(index) * 0.5)
            )
        }

        XCTAssertEqual(history.memory.count, RecentMetricHistory.maximumPointsPerMetric)
        XCTAssertEqual(history.temperature.count, RecentMetricHistory.maximumPointsPerMetric)
        XCTAssertEqual(history.memoryValues.count, RecentMetricHistory.maximumRenderedPoints)
        XCTAssertEqual(history.memoryValues.last, Double(RecentMetricHistory.maximumPointsPerMetric + 50))
    }

    func testInvalidValuesAreIgnored() {
        var history = RecentMetricHistory()
        let now = Date(timeIntervalSince1970: 1_000)

        history.recordDownload(megabitsPerSecond: -.infinity, at: now)
        history.recordSystem(
            memoryUsedBytes: nil,
            temperatureCelsius: .nan,
            at: now
        )

        XCTAssertTrue(history.downloadValues.isEmpty)
        XCTAssertTrue(history.memoryValues.isEmpty)
        XCTAssertTrue(history.temperatureValues.isEmpty)
    }
}
