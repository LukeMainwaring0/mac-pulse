import AppKit
import SwiftUI
import XCTest
@testable import InternetSpeed

final class StatusPopoverTests: XCTestCase {
    func testBackgroundRefreshRebuildsPopoverOnlyWhileVisible() {
        XCTAssertFalse(PopoverRefreshPolicy.shouldRebuild(isShown: false))
        XCTAssertTrue(PopoverRefreshPolicy.shouldRebuild(isShown: true))
    }

    func testStatusItemRefreshAppliesOnlyVisibleChanges() {
        XCTAssertTrue(
            StatusItemRefreshPolicy.shouldApply(
                previousFingerprint: nil,
                nextFingerprint: "download|memory|battery"
            )
        )
        XCTAssertFalse(
            StatusItemRefreshPolicy.shouldApply(
                previousFingerprint: "download|memory|battery",
                nextFingerprint: "download|memory|battery"
            )
        )
        XCTAssertTrue(
            StatusItemRefreshPolicy.shouldApply(
                previousFingerprint: "download|memory|battery",
                nextFingerprint: "download|memory|battery changed"
            )
        )
    }

    func testStatusIconsShareOneCanvasAndBaseline() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let offset = StatusItemIconLayout.baselineOffset(for: font)

        // Wide enough for horizontal glyphs (memory chip, battery) drawn upright.
        XCTAssertEqual(StatusItemIconLayout.canvasSize, NSSize(width: 20, height: 16))
        XCTAssertEqual(offset + 8, font.capHeight / 2, accuracy: 0.51)
        XCTAssertEqual(StatusItemIconLayout.fittedRect(for: NSSize(width: 9, height: 14)).midX, 10, accuracy: 0.001)
        XCTAssertEqual(StatusItemIconLayout.fittedRect(for: NSSize(width: 20, height: 10)).midY, 8, accuracy: 0.001)
    }

    func testSeparatesLabelsFromValuesForDashboardCards() {
        XCTAssertEqual(
            MacPulsePopoverSnapshot.value(in: "Temperature: 61°C", after: "Temperature"),
            "61°C"
        )
        XCTAssertEqual(
            MacPulsePopoverSnapshot.value(in: "Top Memory: Codex 14 GB · Chrome 12 GB", after: "Top Memory"),
            "Codex 14 GB · Chrome 12 GB"
        )
    }

    func testDoesNotDamageUnexpectedPresentationText() {
        XCTAssertEqual(
            MacPulsePopoverSnapshot.value(in: "Checking…", after: "Performance"),
            "Checking…"
        )
    }

    func testDefaultSnapshotIsCalmAndHonestWhileDataLoads() {
        let snapshot = MacPulsePopoverSnapshot()

        XCTAssertEqual(snapshot.download, "—")
        XCTAssertEqual(snapshot.batteryPercentage, "—")
        XCTAssertEqual(snapshot.batteryTime, "—")
        XCTAssertEqual(snapshot.batteryFlow, .discharging)
        XCTAssertEqual(snapshot.performance, "Checking…")
        XCTAssertFalse(snapshot.lidClosedOperationAvailable)
        XCTAssertNil(snapshot.errorMessage)
    }

    func testPerformanceMeterStateTracksMarkerPosition() {
        XCTAssertEqual(PerformanceMeterState.current(for: -1), .normal)
        XCTAssertEqual(PerformanceMeterState.current(for: 0.34), .normal)
        XCTAssertEqual(PerformanceMeterState.current(for: 0.35), .caution)
        XCTAssertEqual(PerformanceMeterState.current(for: 0.54), .caution)
        XCTAssertEqual(PerformanceMeterState.current(for: 0.55), .elevated)
        XCTAssertEqual(PerformanceMeterState.current(for: 0.81), .elevated)
        XCTAssertEqual(PerformanceMeterState.current(for: 0.82), .critical)
        XCTAssertEqual(PerformanceMeterState.current(for: 2), .critical)
    }

    func testPerformanceMeterGradientUsesFixedThresholdLocations() {
        let actual = PerformanceMeterState.meterGradient.stops.map(\.location)
        let expected: [CGFloat] = [0, 0.35, 0.55, 0.82, 1]

        XCTAssertEqual(actual.count, expected.count)
        for (actualLocation, expectedLocation) in zip(actual, expected) {
            XCTAssertEqual(actualLocation, expectedLocation, accuracy: 0.000_001)
        }
    }

    @MainActor
    func testPopoverRendersAtDesignedSize() throws {
        let model = MacPulsePopoverModel()
        model.snapshot = MacPulsePopoverSnapshot(
            download: "184 Mbps",
            memory: "47 GB",
            memoryDetail: "of 64 GB",
            batteryPercentage: "80%",
            batteryTime: "1 hr 58 min of battery",
            batteryFlow: .pluggedIn,
            temperature: "60°C",
            downloadHistory: timed([172, 181, 178, 196, 184], every: 90),
            memoryHistory: timed([45.8, 46.1, 46.7, 46.4, 47], every: 1),
            temperatureHistory: timed([58, 59, 61, 60, 60], every: 1),
            performance: "Normal (system)",
            performanceDetail: "0 MB allocated · inactive in latest sample",
            topMemory: "Codex 14 GB · Chrome 12 GB",
            performanceLevel: 0.62,
            fanRPMs: [1_400, 1_800],
            macHealth: "Good",
            macHealthDetail: "Battery, storage, heat and reliability look good",
            macHealthMetrics: [
                MacPulseHealthMetric(id: "battery", label: "Battery", detail: "100% · 20 cycles", symbol: "battery.100percent", tone: .normal),
                MacPulseHealthMetric(id: "storage", label: "Storage", detail: "Verified · 93% used · 4 GB written today", symbol: "internaldrive", tone: .attention),
                MacPulseHealthMetric(id: "heat", label: "Heat", detail: "57° avg · 58° peak", symbol: "thermometer.medium", tone: .normal),
                MacPulseHealthMetric(id: "reliability", label: "Reliability", detail: "1 panic in 30 days", symbol: "checkmark.shield", tone: .attention)
            ],
            panicSignature: "PMC0 0x4c · DCS · AppleT6050",
            panicClassification: "Apple SoC display/power panic",
            panicTaskContext: "CallHistorySyncHelper was active when the panic occurred; cause not established",
            isTesting: false,
            launchAtLogin: true,
            lidClosedOperation: true,
            lidClosedOperationAvailable: true
        )

        let hostingView = NSHostingView(rootView: MacPulsePopoverView(model: model))
        let fitting = hostingView.fittingSize
        XCTAssertEqual(fitting.width, 340, accuracy: 0.5)
        // The fullest state must fit below the menu bar on a 13-inch MacBook
        // Air (956 pt tall, about 913 pt below the menu bar) without scrolling.
        XCTAssertLessThan(fitting.height, 860)
        hostingView.frame = NSRect(origin: .zero, size: fitting)
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not create popover preview")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode popover preview")
        }

        let previewURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mac-pulse-popover-preview.png")
        try png.write(to: previewURL, options: .atomic)
        XCTAssertGreaterThan(png.count, 10_000)
    }

    func testHealthRowsShowTheReasonForTheirColor() {
        let storage = MacPulseHealthMetric(id: "storage", label: "Storage", detail: "Verified · 93% used · 141 GB written today", symbol: "internaldrive", tone: .attention)
        let failing = MacPulseHealthMetric(id: "storage", label: "Storage", detail: "Failing · 40% used · 0 B written today", symbol: "internaldrive", tone: .attention)
        let heat = MacPulseHealthMetric(id: "heat", label: "Heat", detail: "57° avg · 77° peak · 0m ≥90°", symbol: "thermometer.medium", tone: .normal)
        let panics = MacPulseHealthMetric(id: "reliability", label: "Reliability", detail: "2 panics in 30 days · AppleInterruptControllerV3", symbol: "checkmark.shield", tone: .attention)

        XCTAssertEqual(HealthRowFormatting.displayValue(for: storage), "93% used")
        XCTAssertEqual(HealthRowFormatting.displayValue(for: failing), "Failing · 40% used")
        XCTAssertEqual(HealthRowFormatting.displayValue(for: heat), "57° avg · 77° peak")
        XCTAssertEqual(HealthRowFormatting.displayValue(for: panics), "2 panics in 30 days")
    }

    private func timed(_ values: [Double], every interval: TimeInterval) -> [MetricHistoryPoint] {
        let now = Date()
        return values.enumerated().map { index, value in
            MetricHistoryPoint(capturedAt: now.addingTimeInterval(-Double(values.count - 1 - index) * interval), value: value)
        }
    }

    func testNewReadingGlidesIntoPlace() {
        let now = Date()
        let points = [
            MetricHistoryPoint(capturedAt: now.addingTimeInterval(-1), value: 40),
            MetricHistoryPoint(capturedAt: now, value: 50)
        ]
        XCTAssertEqual(LiveGraph.currentValue(of: points, at: now, animated: true), 40)
        let midway = LiveGraph.currentValue(of: points, at: now.addingTimeInterval(LiveGraph.settleDuration / 2), animated: true)!
        XCTAssertGreaterThan(midway, 45, "eases out, so it is past halfway at half time")
        XCTAssertLessThan(midway, 50)
        XCTAssertEqual(LiveGraph.currentValue(of: points, at: now.addingTimeInterval(1), animated: true), 50)
        XCTAssertEqual(LiveGraph.currentValue(of: points, at: now, animated: false), 50, "Reduce Motion shows the new value at once")
    }

    func testGraphWindowGrowsWithHistoryThenHolds() {
        let now = Date()
        let fresh = [MetricHistoryPoint(capturedAt: now.addingTimeInterval(-5), value: 1)]
        let partial = [MetricHistoryPoint(capturedAt: now.addingTimeInterval(-45), value: 1)]
        let full = [MetricHistoryPoint(capturedAt: now.addingTimeInterval(-600), value: 1)]
        XCTAssertEqual(LiveGraph.visibleWindow(for: fresh, maximum: 120, at: now), LiveGraph.minimumWindow)
        XCTAssertEqual(LiveGraph.visibleWindow(for: partial, maximum: 120, at: now), 45, accuracy: 0.01)
        XCTAssertEqual(LiveGraph.visibleWindow(for: full, maximum: 120, at: now), 120)
    }

    func testCoresGroupFastestTierFirstUsingAppleSiliconNumbering() {
        // M5 Max: perflevel0 "Super" ×6 owns cpus 12–17; perflevel1
        // "Performance" ×12 owns cpus 0–11 (confirmed in the device tree).
        let usages = (0..<18).map { Double($0) / 100 }
        let activity = CPUActivitySampler.group(usages, tiers: [("Super", 6), ("Performance", 12)])
        XCTAssertEqual(activity.groups.map(\.name), ["Super", "Performance"])
        XCTAssertEqual(activity.groups[0].usages, Array(usages[12...]))
        XCTAssertEqual(activity.groups[1].usages, Array(usages[..<12]))
        XCTAssertEqual(activity.total, usages.reduce(0, +) / 18, accuracy: 1e-9)

        let unknown = CPUActivitySampler.group([0.5, 0.5], tiers: [("Super", 6)])
        XCTAssertEqual(unknown.groups.map(\.name), ["Cores"], "mismatched counts fall back to one honest group")
    }

    func testSamplerMeasuresRealCores() throws {
        let sampler = CPUActivitySampler()
        XCTAssertNil(sampler.sample(), "the first sample is only a baseline")
        Thread.sleep(forTimeInterval: 0.2)
        let activity = try XCTUnwrap(sampler.sample())
        XCTAssertEqual(activity.groups.reduce(0) { $0 + $1.usages.count }, ProcessInfo.processInfo.processorCount)
        XCTAssertTrue(activity.groups.flatMap(\.usages).allSatisfy { (0...1).contains($0) })
    }

    func testCPUSmoothingTurnsASpikeIntoADrift() {
        XCTAssertEqual(TileStatusRules.latency(44).level, .good)
        XCTAssertEqual(TileStatusRules.latency(80).level, .fair)
        XCTAssertEqual(TileStatusRules.latency(140).level, .poor)
        XCTAssertEqual(TileStatusRules.latency(400).level, .bad)
        XCTAssertEqual(TileStatusRules.memory(.normal)?.level, .good)
        XCTAssertEqual(TileStatusRules.memory(.elevated)?.level, .poor)
        XCTAssertNil(TileStatusRules.memory(.unavailable))
        XCTAssertEqual(TileStatusRules.temperature(66).level, .good)
        XCTAssertEqual(TileStatusRules.temperature(80).level, .fair)
        XCTAssertEqual(TileStatusRules.temperature(88).level, .poor)
        XCTAssertEqual(TileStatusRules.temperature(95).level, .bad)
        XCTAssertEqual(TileStatusRules.cpu(state: .caution, total: 0.41).explanation, "Moderate load · 41% CPU")
        XCTAssertEqual(InsightFormatting.latency(18.4).text, "Latency 18 ms")
        XCTAssertEqual(InsightFormatting.latency(18).tone, .normal)
        XCTAssertEqual(InsightFormatting.latency(140).tone, .attention)
        XCTAssertEqual(InsightFormatting.latency(400).tone, .critical)
        XCTAssertEqual(InsightFormatting.pressure(.normal)?.text, "Normal pressure")
        XCTAssertEqual(InsightFormatting.pressure(.elevated)?.tone, .attention)
        XCTAssertNil(InsightFormatting.pressure(.unavailable))
        XCTAssertEqual(InsightFormatting.topApp(TopCPUApp(name: "Codex", share: 0.312)), "Codex 31%")
        let breakdown = CPUBreakdown(
            apps: [TopCPUApp(name: "ChatGPT", share: 0.12), TopCPUApp(name: "Ambient", share: 0.07),
                   TopCPUApp(name: "Safari", share: 0.02), TopCPUApp(name: "Mail", share: 0.015),
                   TopCPUApp(name: "Notes", share: 0.004)],
            readableShare: 0.23
        )
        XCTAssertEqual(InsightFormatting.breakdown(breakdown.parts(total: 0.31)),
                       "ChatGPT 12% · System 8% · Ambient 7%",
                       "the three largest parts, including the hidden system share")
        XCTAssertEqual(breakdown.parts(total: 0.24).map(\.name), ["ChatGPT", "Ambient", "Safari"],
                       "no System entry when nearly everything is accounted for")
        XCTAssertNotNil(TopCPUSampler.responsiblePID(for: getpid()), "macOS responsibility lookup is available")
        XCTAssertEqual(TopCPUSampler.outermostAppBundle(
            in: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        ), "/Applications/Google Chrome.app", "helpers roll up into the outer app")
        XCTAssertNil(TopCPUSampler.outermostAppBundle(in: "/usr/bin/python3"))
        XCTAssertEqual(PowerFormatting.watts(36.4), "36 W")
        XCTAssertEqual(PowerFormatting.watts(6.25), "6.2 W")
        XCTAssertEqual(PowerRows.chargingWatts(flow: .charging, receiving: 60, using: 48), 12)
        XCTAssertNil(PowerRows.chargingWatts(flow: .charged, receiving: 48, using: 48), "a full battery takes nothing")
        XCTAssertNil(PowerRows.chargingWatts(flow: .charging, receiving: 48.4, using: 48), "fractions of a watt are noise")
        let calm = CPUActivity(groups: [CPUCoreGroup(name: "Super", usages: [0.1, 0.1])])
        let spike = CPUActivity(groups: [CPUCoreGroup(name: "Super", usages: [0.9, 0.9])])
        let afterOneSecond = calm.smoothed(toward: spike, elapsed: 1)
        XCTAssertLessThan(afterOneSecond.total, 0.3, "a one-second spike moves the reading only a little")
        XCTAssertGreaterThan(afterOneSecond.total, 0.1)
        let sustained = (0..<20).reduce(calm) { reading, _ in reading.smoothed(toward: spike, elapsed: 1) }
        XCTAssertEqual(sustained.total, 0.9, accuracy: 0.02, "a sustained change is reflected within seconds")
    }
}
