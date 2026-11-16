import AppKit
import Foundation
import OSLog

@main
final class InternetSpeedApp {
    private static let logger = Logger(subsystem: "com.lukemainwaring.internetspeed", category: "Lifecycle")
    private static var controller: SpeedController?

    static func main() {
        if CommandLine.arguments.contains("--measure-once") {
            runOneMeasurement()
            return
        }
        if CommandLine.arguments.contains("--system-stats") {
            printSystemStats()
            return
        }
        if CommandLine.arguments.contains("--resource-stats") {
            printResourceStats()
            return
        }
        if CommandLine.arguments.contains("--battery-watch") {
            watchBattery()
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        logger.info("Starting from bundle \(Bundle.main.bundleURL.path, privacy: .public)")
        controller = SpeedController()
        controller?.start()
        app.run()
    }

    private static func runOneMeasurement() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                let result = try await AppleSpeedTest().run()
                let payload: [String: Any] = [
                    "downloadMbps": result.downloadMbps,
                    "bytesTransferred": result.bytesTransferred
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("Measurement failed: \(error.localizedDescription)\n", stderr)
            }
        }
        semaphore.wait()
    }

    private static func printSystemStats() {
        let snapshot = SystemStatsProvider().currentSnapshot()
        let health = MacHealthMonitor().update(
            thermal: snapshot.thermal,
            at: snapshot.capturedAt
        )
        var payload: [String: Any] = ["capturedAt": snapshot.capturedAt.timeIntervalSince1970]
        if let memory = snapshot.memory {
            payload["memoryUsedBytes"] = memory.usedBytes
            payload["memoryTotalBytes"] = memory.totalBytes
            payload["memoryDetail"] = SystemStatsFormatting.detailedMemory(memory)
        }
        if let battery = snapshot.battery {
            payload["batteryPercent"] = battery.percentage
            payload["batteryFlow"] = battery.flow.rawValue
            payload["batteryCompact"] = SystemStatsFormatting.compactBattery(battery)
            payload["batteryDetail"] = SystemStatsFormatting.batteryDetail(battery)
            if let minutes = battery.timeRemainingMinutes {
                payload["batteryTimeRemainingMinutes"] = minutes
            }
            payload["batteryConfidence"] = battery.estimate.confidence.rawValue
            payload["batteryEstimatorMethod"] = battery.estimate.method
            payload["batterySampleWindowMinutes"] = battery.estimate.sampleWindowMinutes
            if let lower = battery.estimate.lowerBoundMinutes {
                payload["batteryLowerBoundMinutes"] = lower
            }
            if let upper = battery.estimate.upperBoundMinutes {
                payload["batteryUpperBoundMinutes"] = upper
            }
            if let amperage = battery.amperageMa { payload["batteryAmperageMa"] = amperage }
            if let voltage = battery.voltageMv { payload["batteryVoltageMv"] = voltage }
            if let temperature = battery.temperatureCelsius {
                payload["batteryTemperatureCelsius"] = temperature
            }
            if let load = battery.systemLoadMw { payload["systemLoadMw"] = load }
        }
        payload["thermalState"] = snapshot.thermal.state.rawValue
        if let temperature = snapshot.thermal.processorTemperatureCelsius {
            payload["processorTemperatureCelsius"] = temperature
        }
        payload["macHealth"] = health.level.rawValue
        payload["macHealthBattery"] = health.batteryDetail
        payload["macHealthStorage"] = health.storageDetail
        payload["macHealthHeatToday"] = health.heatDetail
        payload["macHealthReliability"] = health.reliabilityDetail
        payload["macHealthIssues"] = health.issues
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("System stats failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func watchBattery() {
        let arguments = CommandLine.arguments
        let requestedCount = arguments.firstIndex(of: "--battery-watch").flatMap { index in
            arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
        }
        let count = min(120, max(1, requestedCount ?? 13))
        let provider = SystemStatsProvider()
        for index in 0..<count {
            let snapshot = provider.currentSnapshot()
            if let battery = snapshot.battery {
                let estimate = battery.estimate
                let fields = [
                    ISO8601DateFormatter().string(from: snapshot.capturedAt),
                    battery.flow.rawValue,
                    "\(battery.percentage)%",
                    "eta=\(estimate.minutes.map(String.init) ?? "nil")",
                    "range=\(estimate.lowerBoundMinutes.map(String.init) ?? "nil")-\(estimate.upperBoundMinutes.map(String.init) ?? "nil")",
                    "confidence=\(estimate.confidence.rawValue)",
                    String(format: "history=%.1fm", estimate.sampleWindowMinutes),
                    "current=\(battery.amperageMa.map { String(format: "%.0fmA", $0) } ?? "nil")",
                    "load=\(battery.systemLoadMw.map { String(format: "%.1fW", $0 / 1_000) } ?? "nil")"
                ]
                print(fields.joined(separator: "  "))
                fflush(stdout)
            }
            if index + 1 < count { Thread.sleep(forTimeInterval: 5) }
        }
    }

    private static func printResourceStats() {
        let monitor = ResourceMonitor(
            analyzer: ResourceAnalyzer(store: EphemeralResourceHistoryStore())
        )
        _ = monitor.sample()
        Thread.sleep(forTimeInterval: 1)
        guard let snapshot = monitor.sample() else {
            fputs("Resource sample failed\n", stderr)
            return
        }
        let sample = snapshot.sample
        var payload: [String: Any] = [
            "capturedAt": sample.capturedAt.timeIntervalSince1970,
            "pressure": sample.pressure.displayName,
            "pressureSource": "Estimated from public Mach VM counters",
            "memoryUsedBytes": sample.memory.usedBytes,
            "memoryWiredBytes": sample.memory.wiredBytes,
            "memoryCompressedBytes": sample.memory.compressedBytes,
            "memoryCompressedLogicalBytes": sample.memory.compressedLogicalBytes,
            "memoryActiveBytes": sample.memory.activeBytes,
            "memoryInactiveBytes": sample.memory.inactiveBytes,
            "memoryFreeBytes": sample.memory.freeBytes,
            "memoryFileBackedBytes": sample.memory.fileBackedBytes,
            "swapUsedBytes": sample.swapUsedBytes,
            "swapTotalBytes": sample.swapTotalBytes,
            "swapInBytesLastInterval": sample.swapInBytes,
            "swapOutBytesLastInterval": sample.swapOutBytes,
            "pageOutBytesLastInterval": sample.pageOutBytes,
            "swapPresentation": snapshot.swapDetail,
            "cpuPercent": sample.cpuPercent,
            "load1": sample.load1,
            "load5": sample.load5,
            "load15": sample.load15,
            "ssdHostReadBytesLastInterval": sample.diskReadBytes,
            "ssdHostWriteBytesLastInterval": sample.diskWriteBytes,
            "thermalState": sample.thermalState.rawValue,
            "monitorOverheadMilliseconds": snapshot.monitorOverheadMilliseconds,
            "alerts": snapshot.alerts.map(\.cause),
            "families": sample.families.map { family in
                [
                    "name": family.family.displayName,
                    "rssBytes": family.residentBytes,
                    "processCount": family.processCount,
                    "cpuPercent": family.cpuPercent
                ] as [String: Any]
            }
        ]
        payload["topMemory"] = snapshot.topMemoryDetail
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Resource stats failed: \(error.localizedDescription)\n", stderr)
        }
    }

}
