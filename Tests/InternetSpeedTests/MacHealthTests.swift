import XCTest
@testable import InternetSpeed

final class MacHealthTests: XCTestCase {
    private final class FakeHardwareProvider: HealthHardwareProviding {
        var snapshot: HealthHardwareSnapshot

        init(_ snapshot: HealthHardwareSnapshot) {
            self.snapshot = snapshot
        }

        func currentHealthHardware(at date: Date) -> HealthHardwareSnapshot {
            snapshot
        }
    }

    private final class FakePanicMonitor: PanicMonitoring {
        var snapshot: PanicScanSnapshot

        init(_ snapshot: PanicScanSnapshot = .empty) {
            self.snapshot = snapshot
        }

        func scan(at date: Date, temperatureCelsius: Double?) -> PanicScanSnapshot {
            snapshot
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func healthyHardware(bytesWritten: UInt64 = 1_000) -> HealthHardwareSnapshot {
        HealthHardwareSnapshot(
            battery: BatteryHealthSnapshot(
                maximumCapacityPercent: 100,
                cycleCount: 20,
                condition: "Good",
                temperatureCelsius: 31
            ),
            storage: StorageHealthSnapshot(
                smartStatus: "Verified",
                usedPercent: 29,
                bytesWrittenCounter: bytesWritten,
                readErrors: 0,
                writeErrors: 0
            )
        )
    }

    func testHealthyMacShowsConcreteDetailsWithoutStatusAlert() {
        let defaults = InMemoryPreferences()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let hardware = FakeHardwareProvider(healthyHardware())
        let monitor = MacHealthMonitor(
            hardwareProvider: hardware,
            defaults: defaults,
            calendar: calendar,
            hardwareRefreshInterval: 0,
            now: start
        )

        _ = monitor.update(
            thermal: ThermalSnapshot(state: .nominal, processorTemperatureCelsius: 60),
            at: start
        )
        hardware.snapshot = healthyHardware(bytesWritten: 1_000_001_000)
        let snapshot = monitor.update(
            thermal: ThermalSnapshot(state: .nominal, processorTemperatureCelsius: 62),
            at: start.addingTimeInterval(5)
        )

        XCTAssertEqual(snapshot.level, .good)
        XCTAssertEqual(snapshot.title, "Mac Health: Good")
        XCTAssertEqual(snapshot.batteryDetail, "Battery Health: 100% · 20 cycles")
        XCTAssertTrue(snapshot.storageDetail.contains("Verified · 29% used"))
        XCTAssertTrue(snapshot.storageDetail.contains("1 GB written today"))
        XCTAssertEqual(snapshot.heatDetail, "Heat Today: 62° avg · 62° peak · 0m ≥90°")
        XCTAssertEqual(snapshot.reliabilityDetail, "Reliability: No panics in 30 days")
        XCTAssertFalse(snapshot.shouldShowStatusAlert)
    }

    func testHardwareProblemsProduceIndependentMenuBarAlert() {
        let defaults = InMemoryPreferences()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = FakeHardwareProvider(HealthHardwareSnapshot(
            battery: BatteryHealthSnapshot(
                maximumCapacityPercent: 78,
                cycleCount: 1_001,
                condition: "Service Recommended",
                temperatureCelsius: 42
            ),
            storage: StorageHealthSnapshot(
                smartStatus: "Failing",
                usedPercent: 95,
                bytesWrittenCounter: 100,
                readErrors: 1,
                writeErrors: 2
            )
        ))
        let monitor = MacHealthMonitor(
            hardwareProvider: provider,
            panicMonitor: FakePanicMonitor(PanicScanSnapshot(
                recentCount: 1,
                latest: nil,
                newlyDetected: nil,
                fingerprintCount: 0
            )),
            defaults: defaults,
            calendar: calendar,
            now: date
        )

        let snapshot = monitor.update(
            thermal: ThermalSnapshot(state: .nominal, processorTemperatureCelsius: 60),
            at: date
        )

        XCTAssertEqual(snapshot.level, .attention)
        XCTAssertTrue(snapshot.shouldShowStatusAlert)
        XCTAssertTrue(snapshot.issues.contains("Battery service is recommended"))
        XCTAssertTrue(snapshot.issues.contains("Battery has reached its rated cycle count"))
        XCTAssertTrue(snapshot.issues.contains("Battery temperature is high"))
        XCTAssertTrue(snapshot.issues.contains("Storage health is failing"))
        XCTAssertTrue(snapshot.issues.contains("Storage is nearly full"))
        XCTAssertTrue(snapshot.issues.contains("Storage controller errors were detected"))
        XCTAssertTrue(snapshot.issues.contains("A recent kernel panic was detected"))
    }

    func testLiveThermalWarningDoesNotDuplicateHealthIcon() {
        let defaults = InMemoryPreferences()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let monitor = MacHealthMonitor(
            hardwareProvider: FakeHardwareProvider(healthyHardware()),
            defaults: defaults,
            calendar: calendar,
            now: date
        )

        let snapshot = monitor.update(
            thermal: ThermalSnapshot(state: .nominal, processorTemperatureCelsius: 91),
            at: date
        )

        XCTAssertEqual(snapshot.level, .attention)
        XCTAssertEqual(snapshot.issues, ["Processor temperature is high"])
        XCTAssertFalse(snapshot.shouldShowStatusAlert)
    }

    func testPanicPresentationShowsFingerprintWithoutBlamingActiveTask() {
        let date = Date(timeIntervalSince1970: 1_785_877_200)
        let report = PanicReport(
            identity: "incident:1F68976A-F9F6-4A63-ADF0-2C971994CC0B",
            path: "/Library/Logs/DiagnosticReports/Retired/fixture.panic",
            timestamp: date.addingTimeInterval(-60),
            incidentID: "1F68976A-F9F6-4A63-ADF0-2C971994CC0B",
            osVersion: "macOS 26.5.2 (25F84)",
            model: "Mac17,7",
            panicString: "PMC0 Assert ID: 0x4c, rail:DCS",
            panickedTask: "CallHistorySyncHelper",
            compressorStatus: "OK swap space",
            appleKernelExtensions: [
                PanicKernelExtension(name: "com.apple.driver.AppleT6050", isApple: true)
            ],
            thirdPartyKernelExtensions: [],
            fingerprint: "controller=pmc0|assert=0x4c|rail=dcs|kext=com.apple.driver.applet6050",
            signature: "PMC0 0x4c · DCS · AppleT6050",
            classification: "Apple SoC display/power panic"
        )
        let entry = PanicHistoryEntry(
            report: report,
            firstDetectedAt: date,
            postRebootContext: nil
        )
        let monitor = MacHealthMonitor(
            hardwareProvider: FakeHardwareProvider(healthyHardware()),
            panicMonitor: FakePanicMonitor(PanicScanSnapshot(
                recentCount: 1,
                latest: entry,
                newlyDetected: entry,
                fingerprintCount: 1
            )),
            defaults: InMemoryPreferences(),
            calendar: calendar,
            now: date
        )

        let snapshot = monitor.update(
            thermal: ThermalSnapshot(state: .nominal, processorTemperatureCelsius: 55),
            at: date
        )

        XCTAssertEqual(snapshot.panic?.signature, "PMC0 0x4c · DCS · AppleT6050")
        XCTAssertEqual(snapshot.panic?.classification, "Apple SoC display/power panic")
        XCTAssertEqual(
            snapshot.panic?.taskContext,
            "CallHistorySyncHelper was active when the panic occurred; cause not established"
        )
        XCTAssertEqual(
            snapshot.reliabilityDetail,
            "Reliability: 1 panic in 30 days · PMC0 0x4c · DCS · AppleT6050"
        )
        XCTAssertEqual(snapshot.issues.last, "Apple SoC display/power panic: PMC0 0x4c · DCS · AppleT6050")
        XCTAssertTrue(snapshot.shouldShowStatusAlert)
    }

    func testDailyHistoryDoesNotCountSleepAsHeat() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var history = DailyHealthHistory.empty(at: start, calendar: calendar)
        let hot = ThermalSnapshot(state: .serious, processorTemperatureCelsius: 95)
        history.record(
            thermal: hot,
            storageBytesWrittenCounter: 100,
            at: start,
            calendar: calendar
        )
        history.record(
            thermal: hot,
            storageBytesWrittenCounter: 200,
            at: start.addingTimeInterval(3_600),
            calendar: calendar
        )

        XCTAssertEqual(history.hotSeconds, 15)
        XCTAssertEqual(history.throttledSeconds, 15)
        XCTAssertEqual(history.storageBytesWritten, 100)
    }
}
