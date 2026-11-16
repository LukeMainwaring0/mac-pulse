import AppKit
import SwiftUI
import XCTest
@testable import InternetSpeed

/// Renders every meaningful popover state in light and dark appearance so the
/// design can be reviewed as a set. Images go to $TMPDIR/mac-pulse-gallery.
final class PopoverGalleryTests: XCTestCase {
    private func healthy() -> [MacPulseHealthMetric] {
        [
            MacPulseHealthMetric(id: "battery", label: "Battery", detail: "100% · 5 cycles", symbol: "battery.100percent", tone: .normal),
            MacPulseHealthMetric(id: "storage", label: "Storage", detail: "Verified · 41% used · 3 GB written today", symbol: "internaldrive", tone: .normal),
            MacPulseHealthMetric(id: "heat", label: "Heat", detail: "52° avg · 71° peak · 0m ≥90°", symbol: "thermometer.medium", tone: .normal),
            MacPulseHealthMetric(id: "reliability", label: "Reliability", detail: "No panics in 30 days", symbol: "checkmark.shield", tone: .normal)
        ]
    }

    private func wave(_ base: Double, _ amp: Double, _ n: Int = 120, phase: Double = 0, every interval: TimeInterval = 1) -> [MetricHistoryPoint] {
        let now = Date()
        return (0..<n).map { index in
            let value = base + amp * sin(Double(index) / 14 + phase) + amp * 0.25 * sin(Double(index) / 3.1)
            return MetricHistoryPoint(capturedAt: now.addingTimeInterval(-Double(n - 1 - index) * interval), value: value)
        }
    }

    private func scenarios() -> [(String, MacPulsePopoverSnapshot)] {
        var calm = MacPulsePopoverSnapshot()
        calm.download = "452 Mbps"; calm.memory = "41 GB"; calm.memoryDetail = "of 128 GB"
        calm.batteryPercentage = "100%"; calm.batteryTime = "6 hr 12 min of battery"; calm.batteryFlow = .charged
        calm.temperature = "48°C"
        calm.downloadHistory = wave(440, 25, 7, every: 90); calm.memoryHistory = wave(41, 1.5, phase: 1); calm.temperatureHistory = wave(48, 2, phase: 2)
        calm.performance = "Normal"; calm.performanceLevel = 0.18; calm.topMemory = "Safari 6 GB · Mail 2 GB"
        calm.cpu = CPUActivity(groups: [
            CPUCoreGroup(name: "Super", usages: [0.12, 0.08, 0.2, 0.05, 0.1, 0.03]),
            CPUCoreGroup(name: "Performance", usages: [0.18, 0.1, 0.06, 0.04, 0.02, 0.01, 0.09, 0.05, 0.03, 0.02, 0.01, 0.0])
        ])
        calm.cpuHistory = wave(8, 3, phase: 0.5)
        calm.powerUseWatts = 9.4; calm.powerInWatts = 11.2; calm.adapterWatts = 94
        calm.gpuUsage = 0.06; calm.gpuCores = 40
        calm.temperatureCelsius = 48
        calm.cpuBreakdown = CPUBreakdown(apps: [TopCPUApp(name: "Safari", share: 0.03), TopCPUApp(name: "Mail", share: 0.01)], readableShare: 0.05)
        calm.memoryPressure = .normal; calm.latencyMilliseconds = 14
        calm.macHealth = "Good"; calm.macHealthMetrics = healthy()
        calm.launchAtLogin = true; calm.lidClosedOperationAvailable = true

        var busy = calm
        busy.download = "301 Mbps"; busy.memory = "105 GB"; busy.temperature = "84°C"
        busy.batteryPercentage = "100%"; busy.batteryTime = "1 hr 7 min of battery"; busy.batteryFlow = .pluggedIn
        busy.performanceLevel = 0.66; busy.fanRPMs = [3_420, 3_510]; busy.topMemory = "Codex 38 GB · Chrome 21 GB"
        busy.cpu = CPUActivity(groups: [
            CPUCoreGroup(name: "Super", usages: [0.92, 0.88, 0.95, 0.71, 0.84, 0.66]),
            CPUCoreGroup(name: "Performance", usages: [0.71, 0.63, 0.66, 0.58, 0.69, 0.61, 0.08, 0.04, 0.12, 0.03, 0.02, 0.05])
        ])
        busy.cpuHistory = wave(58, 30, phase: 1.5)
        busy.powerUseWatts = 62; busy.powerInWatts = 64; busy.adapterWatts = 94
        busy.gpuUsage = 0.71
        busy.temperatureCelsius = 84
        busy.cpuBreakdown = CPUBreakdown(apps: [TopCPUApp(name: "ChatGPT", share: 0.21), TopCPUApp(name: "Ambient", share: 0.09),
                                                TopCPUApp(name: "Chrome", share: 0.06)], readableShare: 0.38)
        busy.memoryPressure = .elevated; busy.latencyMilliseconds = 132
        busy.macHealth = "Attention"; busy.macHealthTone = .attention
        busy.macHealthMetrics = [
            MacPulseHealthMetric(id: "battery", label: "Battery", detail: "100% · 5 cycles", symbol: "battery.100percent", tone: .normal),
            MacPulseHealthMetric(id: "storage", label: "Storage", detail: "Verified · 93% used · 141 GB written today", symbol: "internaldrive", tone: .attention),
            MacPulseHealthMetric(id: "heat", label: "Heat", detail: "57° avg · 84° peak · 0m ≥90°", symbol: "thermometer.medium", tone: .normal),
            MacPulseHealthMetric(id: "reliability", label: "Reliability", detail: "2 panics in 30 days · AppleInterruptControllerV3", symbol: "checkmark.shield", tone: .attention)
        ]
        busy.panicSignature = "AppleInterruptControllerV3"; busy.panicClassification = "Apple kernel panic"
        busy.panicTaskContext = "kernel_task was active when the panic occurred; cause not established"
        busy.lidClosedOperation = true

        var hot = busy
        hot.temperature = "96°C"; hot.temperatureIsWarning = true; hot.performanceLevel = 0.91
        hot.temperatureCelsius = 96
        hot.temperatureHistory = wave(90, 4)

        var battery = calm
        battery.batteryPercentage = "14%"; battery.batteryTime = "28 min remaining"; battery.batteryFlow = .discharging
        battery.batteryTimeTone = .critical
        battery.powerInWatts = nil; battery.powerUseWatts = 7.8

        var charging = calm
        charging.batteryPercentage = "62%"; charging.batteryTime = "34 min to 80%"; charging.batteryFlow = .charging; charging.powerUseWatts = 14; charging.powerInWatts = 52

        var offline = calm
        offline.isOffline = true; offline.download = "Offline"; offline.latencyMilliseconds = nil

        var testing = MacPulsePopoverSnapshot()
        testing.isTesting = true; testing.download = "Measuring…"
        testing.errorMessage = "Couldn’t complete the speed test. The request timed out."

        return [("calm", calm), ("busy", busy), ("hot", hot), ("battery", battery),
                ("charging", charging), ("offline", offline), ("loading", testing)]
    }

    @MainActor
    func testRenderGallery() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mac-pulse-gallery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, snapshot) in scenarios() {
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let model = MacPulsePopoverModel()
                model.snapshot = snapshot
                let view = MacPulsePopoverView(model: model)
                    .background(appearanceName == "dark" ? Color(white: 0.17) : Color(white: 0.96))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                XCTAssertLessThan(size.height, 860, "\(name) must fit without scrolling")
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("\(name)-\(appearanceName).png"))
            }
        }
    }
}
