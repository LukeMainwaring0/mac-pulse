import Foundation
import XCTest
@testable import InternetSpeed

final class PanicMonitorTests: XCTestCase {
    private final class FixedDiscovery: PanicReportDiscovering {
        var urls: [URL]
        init(_ urls: [URL]) { self.urls = urls }
        func reportURLs() -> [URL] { urls }
    }

    private final class RecordingContextProvider: PanicContextProviding {
        var captures = 0
        var result: PanicContextSnapshot?

        init(result: PanicContextSnapshot?) { self.result = result }

        func capture(at date: Date, temperatureCelsius: Double?) -> PanicContextSnapshot? {
            captures += 1
            return result
        }
    }

    private let incident = "1F68976A-F9F6-4A63-ADF0-2C971994CC0B"
    private let timestamp = "2026-08-04 11:05:40.00 -0700"

    func testParsesConfirmedPMCDisplayPowerSignature() throws {
        let url = try fixtureURL()
        let report = try XCTUnwrap(PanicReportParser().parse(url: url))

        XCTAssertEqual(report.incidentID, incident)
        XCTAssertEqual(report.osVersion, "macOS 26.5.2 (25F84)")
        XCTAssertEqual(report.model, "Mac17,7")
        XCTAssertEqual(report.signature, "PMC0 0x4c · DCS · AppleT6050")
        XCTAssertEqual(report.classification, "Apple SoC display/power panic")
        XCTAssertEqual(report.panickedTask, "CallHistorySyncHelper")
        XCTAssertTrue(report.taskContext?.contains("cause not established") == true)
        XCTAssertTrue(report.compressorStatus?.contains("(OK)") == true)
        XCTAssertTrue(report.compressorStatus?.contains("swap space") == true)
        XCTAssertEqual(
            report.appleKernelExtensions.map(\.name),
            ["com.apple.driver.AppleT6050", "com.apple.driver.AppleInterruptControllerV3"]
        )
        XCTAssertTrue(report.thirdPartyKernelExtensions.isEmpty)
        XCTAssertEqual(report.path, url.path)
    }

    func testFingerprintIgnoresAddressPIDIncidentTimestampAndActiveTask() throws {
        let first = try XCTUnwrap(PanicReportParser().parse(url: fixtureURL()))
        let second = try XCTUnwrap(PanicReportParser().parse(url: fixtureURL(
            incident: "00000000-1111-2222-3333-444444444444",
            timestamp: "2026-08-05 09:01:02.00 -0700",
            caller: "0xfffffe00ABCDEF00",
            pid: 999,
            task: "WindowServer"
        )))

        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(second.panickedTask, "WindowServer")
        XCTAssertFalse(second.classification.localizedCaseInsensitiveContains("WindowServer"))
        XCTAssertTrue(second.taskContext?.contains("cause not established") == true)
    }

    func testDifferentAssertProducesDistinctFingerprint() throws {
        let first = try XCTUnwrap(PanicReportParser().parse(url: fixtureURL(assertID: "0x4c")))
        let second = try XCTUnwrap(PanicReportParser().parse(url: fixtureURL(assertID: "0x4d")))

        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(second.signature, "PMC0 0x4d · DCS · AppleT6050")
    }

    func testMalformedReportIsIgnored() throws {
        let url = temporaryDirectory().appendingPathComponent("broken.panic")
        try Data("not json\n{}".utf8).write(to: url)
        XCTAssertNil(PanicReportParser().parse(url: url))
    }

    func testDiscoveryRecursesIntoRetiredAndOnlyReturnsPanicReports() throws {
        let root = temporaryDirectory()
        let retired = root.appendingPathComponent("Retired", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let panic = retired.appendingPathComponent("real.panic")
        let other = retired.appendingPathComponent("ordinary.ips")
        try Data().write(to: panic)
        try Data().write(to: other)

        let found = FileSystemPanicReportDiscovery(roots: [root]).reportURLs()
        XCTAssertEqual(found.map(\.standardizedFileURL.path), [panic.standardizedFileURL.path])
    }

    func testDuplicateReportIsSurfacedAndContextCapturedOnlyOnce() throws {
        let url = try fixtureURL()
        let now = Date(timeIntervalSince1970: 1_785_877_200)
        let context = PanicContextSnapshot(
            capturedAt: now,
            sidecarPresent: true,
            displayTopology: ["Built-in Retina Display", "Luke’s iPad"],
            windowServerCPUPercent: 4.2,
            memoryPressure: "System-wide memory free percentage: 49%",
            swap: "total = 8192.00M used = 6890.00M free = 1302.00M",
            temperatureCelsius: 49,
            osVersion: "Version 26.5.2 (Build 25F84)"
        )
        let contextProvider = RecordingContextProvider(result: context)
        let monitor = PanicMonitor(
            discovery: FixedDiscovery([url]),
            contextProvider: contextProvider,
            defaults: InMemoryPreferences()
        )

        let first = monitor.scan(at: now, temperatureCelsius: 49)
        let second = monitor.scan(at: now.addingTimeInterval(60), temperatureCelsius: 50)

        XCTAssertEqual(first.newlyDetected?.report.signature, "PMC0 0x4c · DCS · AppleT6050")
        XCTAssertEqual(first.latest?.postRebootContext, context)
        XCTAssertNil(second.newlyDetected)
        XCTAssertEqual(second.recentCount, 1)
        XCTAssertEqual(second.fingerprintCount, 1)
        XCTAssertEqual(contextProvider.captures, 1)
    }

    func testSeenIdentityPersistsAcrossMonitorInstances() throws {
        let url = try fixtureURL()
        let defaults = InMemoryPreferences()
        let firstContext = RecordingContextProvider(result: nil)
        let first = PanicMonitor(
            discovery: FixedDiscovery([url]),
            contextProvider: firstContext,
            defaults: defaults
        )
        _ = first.scan(at: Date(timeIntervalSince1970: 1_785_877_200), temperatureCelsius: nil)

        let secondContext = RecordingContextProvider(result: nil)
        let second = PanicMonitor(
            discovery: FixedDiscovery([url]),
            contextProvider: secondContext,
            defaults: defaults
        )
        let result = second.scan(at: Date(timeIntervalSince1970: 1_785_877_260), temperatureCelsius: nil)

        XCTAssertNil(result.newlyDetected)
        XCTAssertEqual(result.recentCount, 1)
        XCTAssertEqual(secondContext.captures, 0)
    }

    func testMissingPostRebootContextDoesNotHidePanic() throws {
        let url = try fixtureURL()
        let provider = RecordingContextProvider(result: nil)
        let result = PanicMonitor(
            discovery: FixedDiscovery([url]),
            contextProvider: provider,
            defaults: InMemoryPreferences()
        ).scan(at: Date(timeIntervalSince1970: 1_785_877_200), temperatureCelsius: nil)

        XCTAssertEqual(result.recentCount, 1)
        XCTAssertNotNil(result.newlyDetected)
        XCTAssertNil(result.latest?.postRebootContext)
        XCTAssertEqual(provider.captures, 1)
    }

    private func fixtureURL(
        incident: String? = nil,
        timestamp: String? = nil,
        caller: String = "0xfffffe0012345678",
        pid: Int = 73_246,
        task: String = "CallHistorySyncHelper",
        assertID: String = "0x4c"
    ) throws -> URL {
        let panicString = """
        panic(cpu 1 caller \(caller)): \"PMC0 Assert ID: \(assertID), rail:DCS, Apple SoC error\" @AppleSoCErrorHandlerT6050.cpp:3272
        Compressor Info: 24% of compressed pages limit (OK) and 24 swapfiles and OK swap space
        Panicked task 0xfffffe1234: 321 pages, 9 threads: pid \(pid): \(task)
        Kernel Extensions in backtrace:
           com.apple.driver.AppleT6050(1.0)[AAAA]@0xfffffe001000->0xfffffe001999
              dependency: com.apple.driver.AppleARMPlatform(1.0.2)
           com.apple.driver.AppleInterruptControllerV3(1.0d1)[BBBB]@0xfffffe002000->0xfffffe002999
        last started kext at 123: com.apple.filesystems.smbfs
        """
        let header: [String: Any] = [
            "bug_type": "210",
            "timestamp": timestamp ?? self.timestamp,
            "os_version": "macOS 26.5.2 (25F84)",
            "incident_id": incident ?? self.incident
        ]
        let body: [String: Any] = [
            "product": "Mac17,7",
            "incident": incident ?? self.incident,
            "date": timestamp ?? self.timestamp,
            "build": "macOS 26.5.2 (25F84)",
            "panicString": panicString
        ]
        let data = try JSONSerialization.data(withJSONObject: header)
            + Data([0x0A])
            + JSONSerialization.data(withJSONObject: body)
        let url = temporaryDirectory().appendingPathComponent("fixture-\(UUID().uuidString).panic")
        try data.write(to: url)
        return url
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPulsePanicTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
