import Darwin
import XCTest
@testable import InternetSpeed

final class HealthRefreshTests: XCTestCase {
    func testDiagnosticReadsOutputLargerThanAPipeBuffer() throws {
        let data = try XCTUnwrap(BoundedProcess.output(
            executable: "/bin/dd", arguments: ["if=/dev/zero", "bs=1024", "count=256"]
        ))
        XCTAssertEqual(data.count, 262_144)
    }

    func testFailedDiagnosticDoesNotReturnPartialOutput() {
        XCTAssertNil(BoundedProcess.output(
            executable: "/bin/sh", arguments: ["-c", "printf partial; exit 1"]
        ))
        XCTAssertNil(BoundedProcess.output(executable: "/nonexistent/mac-pulse", arguments: []))
    }

    func testHungDiagnosticIsKilledEvenWhenItIgnoresTermination() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-pulse-test-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let start = Date()
        let result = BoundedProcess.output(
            executable: "/bin/sh",
            arguments: ["-c", "echo $$ > \"$1\"; trap '' TERM; exec /bin/sleep 30", "probe", pidFile.path],
            timeout: 0.3
        )
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "The timed-out diagnostic must not remain running")
        XCTAssertEqual(errno, ESRCH)
    }

    private final class BlockingHardware: HealthHardwareProviding {
        let started: XCTestExpectation
        let release = DispatchSemaphore(value: 0)

        init(started: XCTestExpectation) { self.started = started }

        func currentHealthHardware(at date: Date) -> HealthHardwareSnapshot {
            XCTAssertFalse(Thread.isMainThread, "Hardware checks must never run on the UI thread")
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return HealthHardwareSnapshot(battery: nil, storage: nil)
        }
    }

    private struct NoPanics: PanicMonitoring {
        func scan(at date: Date, temperatureCelsius: Double?) -> PanicScanSnapshot { .empty }
    }

    @MainActor
    func testBlockedHealthScanLeavesUIResponsiveAndCoalescesRefreshes() async {
        let started = expectation(description: "Background health probe started once")
        started.assertForOverFulfill = true
        let provider = BlockingHardware(started: started)
        defer { provider.release.signal() }
        let refresher = MacHealthRefresh(monitor: MacHealthMonitor(
            hardwareProvider: provider,
            panicMonitor: NoPanics(),
            defaults: InMemoryPreferences(),
            hardwareRefreshInterval: 0
        ))
        let complete = expectation(description: "Health snapshot delivered")
        let thermal = ThermalSnapshot(state: .nominal, processorTemperatureCelsius: 50)
        refresher.refresh(thermal: thermal, at: Date()) { _ in complete.fulfill() }
        await fulfillment(of: [started], timeout: 1)
        // This executes on the main actor while the hardware provider is blocked.
        refresher.refresh(thermal: thermal, at: Date()) { _ in
            XCTFail("A second refresh should be dropped while the first is running")
        }
        provider.release.signal()
        await fulfillment(of: [complete], timeout: 1)
        let next = expectation(description: "Later refresh still works")
        provider.release.signal()
        // Use the cached hardware so the original started expectation stays singular.
        refresher.refresh(thermal: thermal, at: .distantPast) { _ in next.fulfill() }
        await fulfillment(of: [next], timeout: 1)
    }
}
