import XCTest
@testable import InternetSpeed

final class BatteryEstimatorTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testStableDischargeConvergesToHighConfidenceLocalEstimate() {
        let estimator = BatteryEstimator()
        var result = BatteryTimeEstimate.unavailable

        for minute in 0...10 {
            result = estimator.update(with: telemetry(
                minute: minute,
                percentage: 80 - minute / 3,
                flow: .discharging,
                appleMinutes: 240 - minute,
                currentCapacity: 4_800 - Double(minute * 20),
                maximumCapacity: 6_000,
                amperage: -1_200
            ))
        }

        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.minutes ?? 0, 230, accuracy: 8)
        XCTAssertNotNil(result.lowerBoundMinutes)
        XCTAssertNotNil(result.upperBoundMinutes)
        XCTAssertTrue(result.method.contains("local trend"))
    }

    func testChargingEstimateTargetsEightyPercent() {
        let estimator = BatteryEstimator()
        let result = estimator.update(with: telemetry(
            minute: 0,
            percentage: 54,
            flow: .charging,
            appleMinutes: 92,
            currentCapacity: 3_240,
            maximumCapacity: 6_000,
            amperage: 2_000
        ))

        // Apple's 92-minute figure targets a full charge. Removing the slow
        // post-80% bands leaves roughly 40 minutes to the requested target.
        XCTAssertEqual(result.minutes ?? 0, 40, accuracy: 8)
        XCTAssertGreaterThan(result.minutes ?? 0, 30)
        XCTAssertLessThan(result.minutes ?? 999, 55)
        XCTAssertEqual(result.confidence, .learning)
    }

    func testChargingAboveEightyPercentHasNoRemainingTarget() {
        let estimator = BatteryEstimator()
        let result = estimator.update(with: telemetry(
            minute: 0,
            percentage: 81,
            flow: .charging,
            appleMinutes: 39,
            currentCapacity: 4_860,
            maximumCapacity: 6_000,
            amperage: 1_800
        ))

        XCTAssertNil(result.minutes)
        XCTAssertNil(result.lowerBoundMinutes)
    }

    func testStableTrendRejectsWildAppleGaugeOutlier() {
        let estimator = BatteryEstimator()
        var result = BatteryTimeEstimate.unavailable
        for minute in 0...9 {
            result = estimator.update(with: telemetry(
                minute: minute,
                percentage: 50,
                flow: .discharging,
                appleMinutes: minute == 9 ? 900 : 180 - minute,
                currentCapacity: 3_000 - Double(minute) * (1_000 / 60),
                maximumCapacity: 6_000,
                amperage: -1_000
            ))
        }

        XCTAssertLessThan(result.minutes ?? 999, 260)
        XCTAssertTrue(result.method.contains("local trend"))
        XCTAssertFalse(result.method.contains("Apple gauge"))
        XCTAssertLessThan(result.upperBoundMinutes ?? 999, 300)
    }

    func testWorkloadStepAdaptsWithoutInstantWhiplash() {
        let estimator = BatteryEstimator()
        for minute in 0...5 {
            _ = estimator.update(with: telemetry(
                minute: minute,
                percentage: 83,
                flow: .discharging,
                appleMinutes: 300 - minute,
                currentCapacity: 5_000 - Double(minute) * (1_000 / 60),
                maximumCapacity: 6_000,
                amperage: -1_000
            ))
        }

        let firstHeavy = estimator.update(with: telemetry(
            minute: 6,
            percentage: 81,
            flow: .discharging,
            appleMinutes: 98,
            currentCapacity: 4_900,
            maximumCapacity: 6_000,
            amperage: -3_000
        ))
        XCTAssertGreaterThan(firstHeavy.minutes ?? 0, 100)
        XCTAssertLessThan(firstHeavy.minutes ?? 999, 260)

        var adapted = firstHeavy
        for minute in 7...11 {
            adapted = estimator.update(with: telemetry(
                minute: minute,
                percentage: 81 - (minute - 7),
                flow: .discharging,
                appleMinutes: 98 - (minute - 6),
                currentCapacity: 4_900 - Double(minute - 6) * 50,
                maximumCapacity: 6_000,
                amperage: -3_000
            ))
        }
        XCTAssertLessThan(adapted.minutes ?? 999, firstHeavy.minutes ?? 0)
        XCTAssertLessThan(adapted.minutes ?? 999, 140)
    }

    func testPowerFlowChangeResetsLearnedHistory() {
        let estimator = BatteryEstimator()
        for minute in 0...9 {
            _ = estimator.update(with: telemetry(
                minute: minute,
                percentage: 70,
                flow: .discharging,
                appleMinutes: 200,
                currentCapacity: 4_200 - Double(minute * 20),
                maximumCapacity: 6_000,
                amperage: -1_200
            ))
        }

        let charging = estimator.update(with: telemetry(
            minute: 10,
            percentage: 68,
            flow: .charging,
            appleMinutes: 90,
            currentCapacity: 4_080,
            maximumCapacity: 6_000,
            amperage: 2_000
        ))
        XCTAssertEqual(charging.confidence, .learning)
        XCTAssertEqual(charging.sampleWindowMinutes, 0)
        XCTAssertFalse(charging.method.contains("local trend"))
    }

    func testInvalidSensorsNeverInventAnEstimate() {
        let estimator = BatteryEstimator()
        let result = estimator.update(with: telemetry(
            minute: 0,
            percentage: 60,
            flow: .discharging,
            appleMinutes: nil,
            currentCapacity: nil,
            maximumCapacity: nil,
            amperage: 0
        ))

        XCTAssertNil(result.minutes)
        XCTAssertNil(result.lowerBoundMinutes)
        XCTAssertEqual(result.confidence, .learning)
    }

    func testEstimateCountsDownNaturallyWhenConditionsStayStable() {
        let estimator = BatteryEstimator()
        let first = estimator.update(with: telemetry(
            minute: 0,
            percentage: 80,
            flow: .discharging,
            appleMinutes: 240,
            currentCapacity: 4_800,
            maximumCapacity: 6_000,
            amperage: -1_200
        ))
        let second = estimator.update(with: telemetry(
            minute: 1,
            percentage: 80,
            flow: .discharging,
            appleMinutes: 239,
            currentCapacity: 4_780,
            maximumCapacity: 6_000,
            amperage: -1_200
        ))

        XCTAssertEqual(first.minutes, 240)
        XCTAssertEqual(second.minutes, 239)
    }

    func testChargedBatteryShowsRuntimeFromStoredEnergyAndSystemLoad() {
        let estimator = BatteryEstimator()
        let result = estimator.update(with: telemetry(
            minute: 0,
            percentage: 100,
            flow: .charged,
            appleMinutes: nil,
            currentCapacity: 6_096,
            maximumCapacity: 6_158,
            amperage: 474,
            systemLoadMw: 28_000
        ))

        XCTAssertEqual(result.minutes ?? 0, 146, accuracy: 3)
        XCTAssertEqual(result.confidence, .learning)
        XCTAssertTrue(result.method.contains("Energy forecast"))
        XCTAssertTrue(result.method.contains("68 Wh"))
        XCTAssertTrue(result.method.contains("28 W"))
    }

    func testPluggedInBatteryShowsRuntimeIfUnplugged() {
        let estimator = BatteryEstimator()
        let result = estimator.update(with: telemetry(
            minute: 0,
            percentage: 80,
            flow: .pluggedIn,
            appleMinutes: nil,
            currentCapacity: 4_900,
            maximumCapacity: 6_158,
            amperage: 0,
            systemLoadMw: 28_000
        ))

        XCTAssertEqual(result.minutes ?? 0, 118, accuracy: 3)
        XCTAssertEqual(result.confidence, .learning)
        XCTAssertTrue(result.method.contains("Energy forecast"))
    }

    func testChargedRuntimeReusesRecentPluggedInLoadHistory() {
        let estimator = BatteryEstimator()
        for minute in 0...4 {
            _ = estimator.update(with: telemetry(
                minute: minute,
                percentage: 99,
                flow: .charging,
                appleMinutes: 5 - minute,
                currentCapacity: 6_000 + Double(minute * 20),
                maximumCapacity: 6_158,
                amperage: 500,
                systemLoadMw: 20_000
            ))
        }

        let result = estimator.update(with: telemetry(
            minute: 5,
            percentage: 100,
            flow: .charged,
            appleMinutes: nil,
            currentCapacity: 6_096,
            maximumCapacity: 6_158,
            amperage: 0,
            systemLoadMw: 20_000
        ))

        XCTAssertEqual(result.confidence, .medium)
        XCTAssertEqual(result.sampleWindowMinutes, 5, accuracy: 0.01)
        XCTAssertEqual(result.minutes ?? 0, 205, accuracy: 4)
    }

    func testChargedRuntimeRespondsSmoothlyToWorkloadSpike() {
        let estimator = BatteryEstimator()
        for minute in 0...3 {
            _ = estimator.update(with: telemetry(
                minute: minute,
                percentage: 100,
                flow: .charged,
                appleMinutes: nil,
                currentCapacity: 6_096,
                maximumCapacity: 6_158,
                amperage: 0,
                systemLoadMw: 20_000
            ))
        }
        let before = estimator.update(with: telemetry(
            minute: 4,
            percentage: 100,
            flow: .charged,
            appleMinutes: nil,
            currentCapacity: 6_096,
            maximumCapacity: 6_158,
            amperage: 0,
            systemLoadMw: 20_000
        ))
        let spike = estimator.update(with: telemetry(
            minute: 5,
            percentage: 100,
            flow: .charged,
            appleMinutes: nil,
            currentCapacity: 6_096,
            maximumCapacity: 6_158,
            amperage: 0,
            systemLoadMw: 80_000
        ))

        XCTAssertLessThan(spike.minutes ?? 999, before.minutes ?? 0)
        XCTAssertGreaterThan(spike.minutes ?? 0, 80)
    }

    func testChargedRuntimeRequiresRealPowerTelemetry() {
        let estimator = BatteryEstimator()
        let result = estimator.update(with: telemetry(
            minute: 0,
            percentage: 100,
            flow: .charged,
            appleMinutes: nil,
            currentCapacity: 6_096,
            maximumCapacity: 6_158,
            amperage: 0,
            systemLoadMw: nil
        ))

        XCTAssertNil(result.minutes)
    }

    private func telemetry(
        minute: Int,
        percentage: Int,
        flow: BatteryFlow,
        appleMinutes: Int?,
        currentCapacity: Double?,
        maximumCapacity: Double?,
        amperage: Double?,
        systemLoadMw: Double? = nil
    ) -> BatteryTelemetry {
        BatteryTelemetry(
            capturedAt: origin.addingTimeInterval(Double(minute) * 60),
            percentage: percentage,
            flow: flow,
            systemEstimateMinutes: appleMinutes,
            currentCapacityMah: currentCapacity,
            maximumCapacityMah: maximumCapacity,
            amperageMa: amperage,
            voltageMv: 12_400,
            temperatureCelsius: 31,
            systemLoadMw: systemLoadMw
        )
    }
}
