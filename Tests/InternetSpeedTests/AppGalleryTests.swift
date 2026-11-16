import AppKit
import SwiftUI
import XCTest
@testable import InternetSpeed

/// Renders each section of the full app for visual review in
/// $TMPDIR/mac-pulse-app-gallery.
final class AppGalleryTests: XCTestCase {
    private func points(_ base: Double, _ amp: Double, every: TimeInterval = 5, count: Int = 120) -> [MetricHistoryPoint] {
        let now = Date()
        return (0..<count).map { i in
            MetricHistoryPoint(capturedAt: now.addingTimeInterval(-Double(count - 1 - i) * every),
                               value: base + amp * sin(Double(i) / 9) + amp * 0.3 * sin(Double(i) / 2.3))
        }
    }

    @MainActor
    func testRenderAppSections() throws {
        var s = MacPulsePopoverSnapshot()
        s.download = "452 Mbps"; s.latencyMilliseconds = 36; s.downloadHistory = points(440, 30, every: 90, count: 7)
        s.memory = "99 GB"; s.memoryDetail = "of 128 GB"; s.memoryHistory = points(99, 2); s.memoryPressure = .normal
        s.temperature = "66°C"; s.temperatureCelsius = 66; s.temperatureHistory = points(65, 4)
        s.batteryPercentage = "100%"; s.batteryTime = "1 hr 53 min of battery"; s.batteryFlow = .pluggedIn
        s.powerUseWatts = 48; s.powerInWatts = 48; s.adapterWatts = 94; s.powerHistory = points(46, 8)
        s.performance = "Normal"; s.performanceLevel = 0.42; s.performanceDetail = "0 MB allocated · inactive in latest sample"
        s.cpu = CPUActivity(groups: [
            CPUCoreGroup(name: "Super", usages: [0.62, 0.48, 0.71, 0.33, 0.55, 0.4]),
            CPUCoreGroup(name: "Performance", usages: [0.9, 0.85, 0.88, 0.8, 0.92, 0.86, 0.05, 0.03, 0.08, 0.02, 0.04, 0.01])
        ])
        s.cpuHistory = points(42, 15); s.gpuUsage = 0.34; s.gpuCores = 40; s.gpuHistory = points(33, 10)
        s.cpuBreakdown = CPUBreakdown(apps: [
            TopCPUApp(name: "ChatGPT", share: 0.12, memoryBytes: 24_000_000_000),
            TopCPUApp(name: "Ambient", share: 0.08, memoryBytes: 3_200_000_000),
            TopCPUApp(name: "Safari", share: 0.03, memoryBytes: 9_100_000_000),
            TopCPUApp(name: "Passwords", share: 0.02, memoryBytes: 400_000_000)
        ], readableShare: 0.27)
        s.usageTodayBytes = 1_240_000_000; s.lastMeasuredAt = Date().addingTimeInterval(-40)
        s.macHealth = "Attention"; s.macHealthTone = .attention
        s.macHealthDetail = "Storage is nearly full"
        s.macHealthMetrics = [
            MacPulseHealthMetric(id: "battery", label: "Battery", detail: "100% · 6 cycles", symbol: "battery.100percent", tone: .normal),
            MacPulseHealthMetric(id: "storage", label: "Storage", detail: "Verified · 91% used · 141 GB written today", symbol: "internaldrive", tone: .attention),
            MacPulseHealthMetric(id: "heat", label: "Heat", detail: "63° avg · 77° peak · 0m ≥90°", symbol: "thermometer.medium", tone: .normal),
            MacPulseHealthMetric(id: "reliability", label: "Reliability", detail: "2 panics in 30 days · AppleInterruptControllerV3", symbol: "checkmark.shield", tone: .attention)
        ]
        s.panicSignature = "AppleInterruptControllerV3"; s.panicClassification = "Apple kernel panic"
        s.panicTaskContext = "kernel_task was active when the panic occurred; cause not established"
        s.launchAtLogin = true; s.lidClosedOperation = true; s.lidClosedOperationAvailable = true

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mac-pulse-app-gallery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for section in AppSection.allCases {
            let model = MacPulsePopoverModel()
            model.snapshot = s
            let host = NSHostingView(rootView: MacPulseAppView(model: model, initialSection: section))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 1080, height: 760)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("\(section.rawValue).png"))
        }
    }
}
