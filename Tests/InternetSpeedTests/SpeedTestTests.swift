import XCTest
@testable import InternetSpeed

final class SpeedTestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func shouldTest(
        _ reason: SpeedTestReason,
        resultAge: TimeInterval?,
        attemptAge: TimeInterval? = nil,
        metered: Bool = false,
        offline: Bool = false
    ) -> Bool {
        SpeedTestSchedule.shouldTest(
            reason,
            lastResultAt: resultAge.map { now.addingTimeInterval(-$0) },
            lastAttemptAt: (attemptAge ?? resultAge).map { now.addingTimeInterval(-$0) },
            isMeteredNetwork: metered,
            isOffline: offline,
            now: now
        )
    }

    func testReadsApplesSpeedTestOutput() throws {
        let output = Data(#"{"base_rtt":11.78,"dl_bytes_transferred":187059800,"dl_flows":3,"dl_throughput":516971968,"interface_name":"en0"}"#.utf8)
        let result = try AppleSpeedTest.parse(output, at: now)
        XCTAssertEqual(result.downloadMbps, 516.97, accuracy: 0.01)
        XCTAssertEqual(result.bytesTransferred, 187_059_800)
        XCTAssertEqual(result.measuredAt, now)
    }

    func testRejectsOutputWithoutADownloadResult() {
        XCTAssertThrowsError(try AppleSpeedTest.parse(Data(#"{"dl_throughput":0}"#.utf8), at: now))
        XCTAssertThrowsError(try AppleSpeedTest.parse(Data("networkQuality: error".utf8), at: now))
    }

    /// The old estimator could hold one bad reading for hours. Now the
    /// number can never be more than an hour old while online.
    func testHourlyBackupReplacesAnyResultOlderThanAnHour() {
        XCTAssertFalse(shouldTest(.hourly, resultAge: 59 * 60))
        XCTAssertTrue(shouldTest(.hourly, resultAge: 60 * 60))
        XCTAssertTrue(shouldTest(.hourly, resultAge: nil))
    }

    func testFailedHourlyTestRetriesAfterTwoMinutesNotEveryMinute() {
        XCTAssertFalse(shouldTest(.hourly, resultAge: 2 * 60 * 60, attemptAge: 60))
        XCTAssertTrue(shouldTest(.hourly, resultAge: 2 * 60 * 60, attemptAge: 2 * 60))
    }

    func testOpeningTheMenuRefreshesOnlyStaleResults() {
        XCTAssertFalse(shouldTest(.menuOpened, resultAge: 14 * 60))
        XCTAssertTrue(shouldTest(.menuOpened, resultAge: 15 * 60))
        XCTAssertTrue(shouldTest(.menuOpened, resultAge: nil))
    }

    func testSlowConnectionTestsAtMostOncePerTenMinutes() {
        XCTAssertTrue(shouldTest(.connectionWorse, resultAge: 30 * 60, attemptAge: 10 * 60))
        XCTAssertFalse(shouldTest(.connectionWorse, resultAge: 30 * 60, attemptAge: 9 * 60))
    }

    func testWakeAndNetworkChangesTestOnceWhenTheyArriveTogether() {
        XCTAssertTrue(shouldTest(.networkChange, resultAge: 10 * 60))
        XCTAssertFalse(shouldTest(.networkChange, resultAge: 10))
        // A failed wake test doesn't block the network change that follows.
        XCTAssertTrue(shouldTest(.networkChange, resultAge: 10 * 60, attemptAge: 5))
    }

    func testHotspotsAndOfflineOnlyTestWhenAsked() {
        for reason in [SpeedTestReason.launch, .wake, .networkChange, .menuOpened, .hourly, .connectionWorse] {
            XCTAssertFalse(shouldTest(reason, resultAge: nil, metered: true), reason.rawValue)
            XCTAssertFalse(shouldTest(reason, resultAge: nil, offline: true), reason.rawValue)
        }
        XCTAssertTrue(shouldTest(.manual, resultAge: 1, metered: true))
    }

    func testNetworkDotFollowsTheConnectionCheck() {
        XCTAssertEqual(TileStatusRules.connection(latency: 20, isOffline: false)?.level, .good)
        XCTAssertEqual(TileStatusRules.connection(latency: 300, isOffline: false)?.level, .bad)
        XCTAssertEqual(TileStatusRules.connection(latency: 20, isOffline: true)?.level, .bad)
        XCTAssertNil(TileStatusRules.connection(latency: nil, isOffline: false))
    }
}
