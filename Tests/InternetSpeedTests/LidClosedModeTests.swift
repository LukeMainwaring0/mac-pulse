import XCTest
@testable import InternetSpeed

final class LidClosedModeTests: XCTestCase {
    func testReadsEnabledOpenStateFromIORegistryProperties() {
        let status = LidClosedModeStatus.fromIORegistryProperties([
            "SleepDisabled": true,
            "AppleClamshellState": false
        ])

        XCTAssertEqual(status, LidClosedModeStatus(isEnabled: true, isLidClosed: false))
        XCTAssertEqual(status?.menuTitle, "Clamshell: On")
    }

    func testReadsDisabledClosedStateFromNSNumberProperties() {
        let status = LidClosedModeStatus.fromIORegistryProperties([
            "SleepDisabled": NSNumber(value: 0),
            "AppleClamshellState": NSNumber(value: 1)
        ])

        XCTAssertEqual(status, LidClosedModeStatus(isEnabled: false, isLidClosed: true))
        XCTAssertEqual(status?.menuTitle, "Clamshell: Off")
    }

    func testMissingRegistryStateIsUnavailable() {
        XCTAssertNil(LidClosedModeStatus.fromIORegistryProperties([
            "AppleClamshellState": false
        ]))
    }

    func testTurningOffAppliesBothTenMinuteDisplaySleepTimeouts() {
        XCTAssertEqual(
            LidClosedModeProvider.privilegedScript(enabled: false),
            "do shell script \"/usr/bin/pmset -c disablesleep 0 && /usr/bin/pmset -b displaysleep 10 && /usr/bin/pmset -c displaysleep 10\" with administrator privileges"
        )
    }

    func testTurningOnDoesNotChangeDisplaySleepTimeouts() {
        XCTAssertEqual(
            LidClosedModeProvider.privilegedScript(enabled: true),
            "do shell script \"/usr/bin/pmset -c disablesleep 1\" with administrator privileges"
        )
        XCTAssertFalse(LidClosedModeProvider.privilegedScript(enabled: true).contains("displaysleep"))
    }

    func testParsesBothPowerModeTenMinuteDisplaySleepTimeouts() {
        let settings = LidClosedModeProvider.parseDisplaySleepSettings("""
        Battery Power:
         displaysleep         10
        AC Power:
         displaysleep         10
        """)

        XCTAssertEqual(
            settings,
            LidClosedModeDisplaySleepSettings(batteryMinutes: 10, powerMinutes: 10)
        )
        XCTAssertTrue(settings?.hasRequiredOffTimeouts == true)
    }

    func testOffStateFailsComplianceWhenEitherTimerIsWrong() {
        let settings = LidClosedModeDisplaySleepSettings(batteryMinutes: 10, powerMinutes: 0)

        XCTAssertFalse(settings.hasRequiredOffTimeouts)
        XCTAssertEqual(
            LidClosedModeError.displaySleepDidNotApply.errorDescription,
            "macOS didn’t restore the 10-minute display sleep setting."
        )
    }
}
