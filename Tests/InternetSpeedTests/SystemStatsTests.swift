import XCTest
@testable import InternetSpeed

final class SystemStatsTests: XCTestCase {
    func testSystemThermalWarningOnlyAppearsForSeriousHeat() {
        XCTAssertFalse(MacThermalState.nominal.shouldShowWarning)
        XCTAssertFalse(MacThermalState.fair.shouldShowWarning)
        XCTAssertTrue(MacThermalState.serious.shouldShowWarning)
        XCTAssertTrue(MacThermalState.critical.shouldShowWarning)
    }

    func testThermalReadingUsesNumbersAndWarnsAtNinetyCelsius() {
        let safe = ThermalSnapshot(state: .nominal, processorTemperatureCelsius: 89.4)
        XCTAssertFalse(safe.shouldShowWarning)
        XCTAssertEqual(safe.compactValue, "89°")
        XCTAssertEqual(safe.detail, "Temperature: 89°C")

        let hot = ThermalSnapshot(state: .nominal, processorTemperatureCelsius: 90)
        XCTAssertTrue(hot.shouldShowWarning)
        XCTAssertEqual(hot.compactValue, "90°")
        XCTAssertEqual(hot.detail, "Temperature: 90°C")
    }

    func testThermalStateRemainsAWarningFallback() {
        XCTAssertTrue(ThermalSnapshot(
            state: .serious,
            processorTemperatureCelsius: 82
        ).shouldShowWarning)
        XCTAssertEqual(ThermalSnapshot(
            state: .nominal,
            processorTemperatureCelsius: nil
        ).detail, "Temperature: —")
    }

    func testPluggedInBatteryThatIsDrainingUsesDischargeMode() {
        XCTAssertEqual(
            BatteryFlowResolver.resolve(
                percentage: 92,
                isCharging: false,
                isCharged: false,
                powerState: "AC Power",
                amperageMa: -850
            ),
            .discharging
        )
        XCTAssertEqual(
            BatteryFlowResolver.resolve(
                percentage: 100,
                isCharging: false,
                isCharged: true,
                powerState: "AC Power",
                amperageMa: -850
            ),
            .discharging
        )
        XCTAssertEqual(
            BatteryFlowResolver.resolve(
                percentage: 27,
                isCharging: true,
                isCharged: false,
                powerState: "AC Power",
                amperageMa: -290
            ),
            .charging
        )
    }

    func testPluggedInBatteryIgnoresTinyCurrentNoise() {
        XCTAssertEqual(
            BatteryFlowResolver.resolve(
                percentage: 92,
                isCharging: false,
                isCharged: false,
                powerState: "AC Power",
                amperageMa: -40
            ),
            .pluggedIn
        )
    }

    func testActivityMonitorMemoryAccounting() {
        let usedBytes = MemoryAccounting.activityMonitorUsedBytes(
            totalBytes: 64 * 1_073_741_824,
            freePages: 70_922,
            fileBackedPages: 1_075_387,
            pageSize: 16_384
        )

        XCTAssertEqual(SystemStatsFormatting.compactMemory(usedBytes), "47GB")
        XCTAssertEqual(Double(usedBytes) / Double(1 << 30), 46.51, accuracy: 0.01)
    }

    func testCompactMemoryFormatting() {
        XCTAssertEqual(SystemStatsFormatting.compactMemory(8 * 1_073_741_824), "8.0GB")
        XCTAssertEqual(SystemStatsFormatting.compactMemory(42 * 1_073_741_824), "42GB")
        XCTAssertEqual(SystemStatsFormatting.memoryValue(105 * 1_073_741_824), "105 GB")
    }

    func testCompactBatteryShowsDirectionAndTime() {
        XCTAssertEqual(
            SystemStatsFormatting.compactBattery(BatterySnapshot(
                percentage: 86,
                flow: .discharging,
                timeRemainingMinutes: 965
            )),
            "B↓16h"
        )
        XCTAssertEqual(
            SystemStatsFormatting.compactBattery(BatterySnapshot(
                percentage: 54,
                flow: .charging,
                timeRemainingMinutes: 92
            )),
            "B↑1h32"
        )
    }

    func testBatteryDetailsDescribeTheDestination() {
        XCTAssertEqual(
            SystemStatsFormatting.batteryDetail(BatterySnapshot(
                percentage: 54,
                flow: .charging,
                timeRemainingMinutes: 92
            )),
            "54% · 1 hr 32 min to 80%"
        )
        XCTAssertEqual(
            SystemStatsFormatting.batteryDetail(BatterySnapshot(
                percentage: 86,
                flow: .discharging,
                timeRemainingMinutes: 965
            )),
            "86% · 16 hr 5 min remaining"
        )
        XCTAssertEqual(
            SystemStatsFormatting.batteryDetail(BatterySnapshot(
                percentage: 88,
                flow: .charging,
                timeRemainingMinutes: nil
            )),
            "88%"
        )
        XCTAssertEqual(
            SystemStatsFormatting.batteryDetail(BatterySnapshot(
                percentage: 80,
                flow: .pluggedIn,
                timeRemainingMinutes: 118
            )),
            "80% · 1 hr 58 min of battery"
        )
        XCTAssertEqual(
            SystemStatsFormatting.batteryDetail(BatterySnapshot(
                percentage: 80,
                flow: .pluggedIn,
                timeRemainingMinutes: nil
            )),
            "80% · Estimating battery time"
        )
    }

    func testPoweredBatteryHidesOnlyAboveEightyPercent() {
        XCTAssertTrue(BatterySnapshot(
            percentage: 80,
            flow: .charging,
            timeRemainingMinutes: 1
        ).shouldShowInStatus)
        XCTAssertFalse(BatterySnapshot(
            percentage: 81,
            flow: .charging,
            timeRemainingMinutes: nil
        ).shouldShowInStatus)
        XCTAssertFalse(BatterySnapshot(
            percentage: 90,
            flow: .pluggedIn,
            timeRemainingMinutes: nil
        ).shouldShowInStatus)
        XCTAssertFalse(BatterySnapshot(
            percentage: 100,
            flow: .charged,
            timeRemainingMinutes: nil
        ).shouldShowInStatus)
        XCTAssertTrue(BatterySnapshot(
            percentage: 95,
            flow: .discharging,
            timeRemainingMinutes: 300
        ).shouldShowInStatus)
    }

    func testUnknownBatteryEstimateIsHonest() {
        let battery = BatterySnapshot(
            percentage: 70,
            flow: .discharging,
            timeRemainingMinutes: nil
        )
        XCTAssertEqual(SystemStatsFormatting.compactBattery(battery), "B↓…")
        XCTAssertEqual(
            SystemStatsFormatting.batteryDetail(battery),
            "70% · Estimating time remaining"
        )
    }

    func testChargedBatteryDescribesUnpluggedRuntime() {
        let battery = BatterySnapshot(
            percentage: 100,
            flow: .charged,
            estimate: BatteryTimeEstimate(
                minutes: 146,
                lowerBoundMinutes: 110,
                upperBoundMinutes: 190,
                confidence: .medium,
                method: "Energy forecast · 68 Wh ÷ 28 W current use",
                sampleWindowMinutes: 4
            )
        )

        XCTAssertEqual(SystemStatsFormatting.compactBattery(battery), "B2h26")
        XCTAssertEqual(
            SystemStatsFormatting.batteryDetail(battery),
            "100% · 2 hr 26 min of battery"
        )
    }
}
