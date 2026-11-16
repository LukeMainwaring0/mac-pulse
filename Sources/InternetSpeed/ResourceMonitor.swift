import Darwin
import Foundation
import IOKit

enum ResourcePressureLevel: String, Codable, Equatable, Sendable {
    case normal
    case elevated
    case critical
    case unavailable

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .elevated: return "Elevated"
        case .critical: return "Critical"
        case .unavailable: return "Unavailable"
        }
    }
}

enum ResourceAlertSeverity: Int, Codable, Equatable, Sendable {
    case attention = 1
    case critical = 2
}

struct ResourceAlert: Codable, Equatable, Sendable {
    let id: String
    let severity: ResourceAlertSeverity
    let cause: String
}

enum AppFamily: String, CaseIterable, Codable, Equatable, Sendable {
    case codex = "Codex"
    case chrome = "Chrome"
    case xcodeSimulator = "Xcode + Simulator"
    case safariWebKit = "Safari + WebKit"

    var displayName: String {
        switch self {
        case .codex: return "Codex task tree"
        default: return rawValue
        }
    }
}

struct ProcessResourceMetric: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let startTimeMicroseconds: UInt64
    let name: String
    let path: String
    let residentBytes: UInt64
    let cpuTimeNanoseconds: UInt64
}

struct AppFamilyMetric: Codable, Equatable, Sendable {
    let family: AppFamily
    let residentBytes: UInt64
    let processCount: Int
    let cpuPercent: Double
}

struct HostCPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 { user &+ system &+ idle &+ nice }
    var busy: UInt64 { user &+ system &+ nice }
}

struct ResourceMemoryMetrics: Equatable, Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let compressedLogicalBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let freeBytes: UInt64
    let fileBackedBytes: UInt64
}

struct ResourceRawSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let uptimeSeconds: TimeInterval
    let pageSize: UInt64
    let memory: ResourceMemoryMetrics
    let memoryStatusLevel: Int?
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let swapIns: UInt64
    let swapOuts: UInt64
    let pageOuts: UInt64
    let cpuTicks: HostCPUTicks
    let loadAverages: [Double]
    let processorCount: Int
    let diskBytesReadCounter: UInt64?
    let diskBytesWrittenCounter: UInt64?
    let thermalState: MacThermalState
    let processes: [ProcessResourceMetric]
}

struct ResourceHistorySample: Codable, Equatable, Sendable {
    let capturedAt: Date
    let uptimeSeconds: TimeInterval
    let pressure: ResourcePressureLevel
    let pressureSource: String?
    let memory: CodableMemoryMetrics
    let memoryStatusLevel: Int?
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let swapInBytes: UInt64
    let swapOutBytes: UInt64
    let pageOutBytes: UInt64
    let cpuPercent: Double
    let load1: Double
    let load5: Double
    let load15: Double
    let processorCount: Int
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let thermalState: MacThermalState
    let families: [AppFamilyMetric]
}

struct CodableMemoryMetrics: Codable, Equatable, Sendable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let compressedLogicalBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let freeBytes: UInt64
    let fileBackedBytes: UInt64

    init(_ metrics: ResourceMemoryMetrics) {
        totalBytes = metrics.totalBytes
        usedBytes = metrics.usedBytes
        wiredBytes = metrics.wiredBytes
        compressedBytes = metrics.compressedBytes
        compressedLogicalBytes = metrics.compressedLogicalBytes
        activeBytes = metrics.activeBytes
        inactiveBytes = metrics.inactiveBytes
        freeBytes = metrics.freeBytes
        fileBackedBytes = metrics.fileBackedBytes
    }
}

struct ResourceEvidenceSummary: Equatable, Sendable {
    let retainedDuration: TimeInterval
    let elevatedDuration: TimeInterval
    let criticalDuration: TimeInterval
    let positiveSwapGrowthHourBytes: UInt64
    let positiveSwapGrowthDayBytes: UInt64
    let peakCompressedBytes: UInt64
    let peakFamilyResidentBytes: [AppFamily: UInt64]
    let highLoadThermalSamples: Int
}

struct ResourceSnapshot: Equatable, Sendable {
    let sample: ResourceHistorySample
    let alerts: [ResourceAlert]
    let evidence: ResourceEvidenceSummary
    let monitorOverheadMilliseconds: Double
    let recentSwapInBytes: UInt64
    let recentSwapOutBytes: UInt64
    let recentSwapNetChangeBytes: Int64
    let recentSwapObservationDuration: TimeInterval

    var statusAlert: ResourceAlert? {
        alerts.max { lhs, rhs in lhs.severity.rawValue < rhs.severity.rawValue }
    }

    var performanceTitle: String {
        let source = sample.pressureSource == "System signal" ? "system" : "estimated"
        return "Performance: \(sample.pressure.displayName) (\(source))"
    }

    var swapDetail: String {
        let allocated = ResourceFormatting.bytes(sample.swapUsedBytes)
        let activity = recentSwapInBytes &+ recentSwapOutBytes
        if activity < 128 * 1_024 * 1_024 && abs(recentSwapNetChangeBytes) < 128 * 1_024 * 1_024 {
            if recentSwapObservationDuration >= 15 * 60 {
                return "Swap: \(allocated) allocated · inactive (no churn in 15m)"
            }
            return "Swap: \(allocated) allocated · inactive in latest sample"
        }
        return "Swap: \(allocated) allocated · active · \(ResourceFormatting.bytes(recentSwapInBytes)) in / \(ResourceFormatting.bytes(recentSwapOutBytes)) out"
    }

    var topMemoryDetail: String {
        let top = sample.families
            .sorted { $0.residentBytes > $1.residentBytes }
            .prefix(2)
            .map { "\($0.family.displayName) \(ResourceFormatting.bytes($0.residentBytes))" }
        return top.isEmpty ? "Top Memory: —" : "Top Memory: " + top.joined(separator: " · ")
    }
}

protocol ResourceMetricProviding {
    func capture(at date: Date) -> ResourceRawSnapshot?
}

protocol ResourceHistoryStoring {
    func load() -> [ResourceHistorySample]
    func append(_ sample: ResourceHistorySample)
    func prune(before cutoff: Date)
}

final class EphemeralResourceHistoryStore: ResourceHistoryStoring {
    private(set) var samples: [ResourceHistorySample] = []
    func load() -> [ResourceHistorySample] { samples }
    func append(_ sample: ResourceHistorySample) { samples.append(sample) }
    func prune(before cutoff: Date) {
        samples.removeAll { $0.capturedAt < cutoff }
    }
}

final class FileResourceHistoryStore: ResourceHistoryStoring {
    private let directory: URL
    private let calendar: Calendar
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Internet Speed/Resource History", isDirectory: true),
        calendar: Calendar = .current
    ) {
        self.directory = directory
        self.calendar = calendar
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func load() -> [ResourceHistorySample] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { url -> [ResourceHistorySample] in
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8)
                else { return [] }
                return text.split(separator: "\n").compactMap { line in
                    try? decoder.decode(ResourceHistorySample.self, from: Data(line.utf8))
                }
            }
    }

    func append(_ sample: ResourceHistorySample) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard var data = try? encoder.encode(sample) else { return }
        data.append(0x0A)
        let url = directory.appendingPathComponent(dayName(sample.capturedAt) + ".jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    func prune(before cutoff: Date) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let oldestName = dayName(cutoff)
        for url in urls where url.pathExtension == "jsonl" {
            if url.deletingPathExtension().lastPathComponent < oldestName {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func dayName(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

enum ProcessFamilyAggregator {
    static func family(name: String, path: String) -> AppFamily? {
        let value = (name + " " + path).lowercased()
        if value.contains("codex") || value.contains("openai") {
            return .codex
        }
        if value.contains("google chrome") || value.contains("chrome helper") || value.contains("chromium") {
            return .chrome
        }
        if value.contains("xcode") || value.contains("simulator") || value.contains("coresimulator") || value.contains("simdisk") {
            return .xcodeSimulator
        }
        if value.contains("safari") || value.contains("webkit") {
            return .safariWebKit
        }
        return nil
    }

    static func aggregate(
        processes: [ProcessResourceMetric],
        previous: [ProcessIdentity: UInt64],
        elapsed: TimeInterval
    ) -> [AppFamilyMetric] {
        var values: [AppFamily: (rss: UInt64, count: Int, cpuNanos: UInt64)] = [:]
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        for process in processes {
            guard let family = resolvedFamily(for: process, byPID: byPID) else { continue }
            let identity = ProcessIdentity(pid: process.pid, startTimeMicroseconds: process.startTimeMicroseconds)
            let cpuDelta = counterDelta(current: process.cpuTimeNanoseconds, previous: previous[identity])
            var value = values[family] ?? (0, 0, 0)
            value.rss &+= process.residentBytes
            value.count += 1
            value.cpuNanos &+= cpuDelta
            values[family] = value
        }
        return AppFamily.allCases.compactMap { family in
            guard let value = values[family] else { return nil }
            let cpu = elapsed > 0 ? Double(value.cpuNanos) / 1_000_000_000 / elapsed * 100 : 0
            return AppFamilyMetric(
                family: family,
                residentBytes: value.rss,
                processCount: value.count,
                cpuPercent: cpu
            )
        }
    }

    private static func resolvedFamily(
        for process: ProcessResourceMetric,
        byPID: [Int32: ProcessResourceMetric]
    ) -> AppFamily? {
        var candidate: ProcessResourceMetric? = process
        var visited: Set<Int32> = []
        while let current = candidate, visited.insert(current.pid).inserted {
            if let family = family(name: current.name, path: current.path) { return family }
            candidate = byPID[current.parentPID]
        }
        return nil
    }
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTimeMicroseconds: UInt64
}

final class ResourceAnalyzer {
    static let defaultMaxSamples = 7 * 24 * 60
    static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60

    private let store: ResourceHistoryStoring
    private let maxSamples: Int
    private(set) var history: [ResourceHistorySample]
    private var previousRaw: ResourceRawSnapshot?
    private var previousProcessCPU: [ProcessIdentity: UInt64] = [:]

    init(
        store: ResourceHistoryStoring,
        maxSamples: Int = ResourceAnalyzer.defaultMaxSamples,
        now: Date = Date()
    ) {
        self.store = store
        self.maxSamples = max(1, maxSamples)
        self.history = Array(store.load().filter {
            $0.capturedAt >= now.addingTimeInterval(-Self.retentionSeconds)
        }.suffix(max(1, maxSamples)))
        store.prune(before: now.addingTimeInterval(-Self.retentionSeconds))
    }

    func ingest(_ raw: ResourceRawSnapshot, monitorOverheadMilliseconds: Double = 0) -> ResourceSnapshot {
        let elapsed = previousRaw.map { raw.capturedAt.timeIntervalSince($0.capturedAt) } ?? 0
        let reset = previousRaw.map {
            raw.uptimeSeconds < $0.uptimeSeconds || raw.capturedAt <= $0.capturedAt
                || raw.capturedAt.timeIntervalSince($0.capturedAt) > 150
        } ?? false
        let validPrevious = reset ? nil : previousRaw

        let families = ProcessFamilyAggregator.aggregate(
            processes: raw.processes,
            previous: reset ? [:] : previousProcessCPU,
            elapsed: elapsed
        )
        let cpuPercent = hostCPUPercent(current: raw.cpuTicks, previous: validPrevious?.cpuTicks)
        let estimatedPressure = Self.derivedPressure(memory: raw.memory)
        let signaledPressure: ResourcePressureLevel? = {
            switch raw.memoryStatusLevel {
            case 3: return .critical
            case 2: return .elevated
            case 1: return .normal
            default: return nil
            }
        }()
        let effectivePressure = [estimatedPressure, signaledPressure ?? .unavailable]
            .max(by: { pressureRank($0) < pressureRank($1) }) ?? estimatedPressure
        let sample = ResourceHistorySample(
            capturedAt: raw.capturedAt,
            uptimeSeconds: raw.uptimeSeconds,
            pressure: effectivePressure,
            pressureSource: signaledPressure.map { pressureRank($0) >= pressureRank(estimatedPressure) ? "System signal" : "Estimated" } ?? "Estimated",
            memory: CodableMemoryMetrics(raw.memory),
            memoryStatusLevel: raw.memoryStatusLevel,
            swapUsedBytes: raw.swapUsedBytes,
            swapTotalBytes: raw.swapTotalBytes,
            swapInBytes: raw.pageSize * counterDelta(current: raw.swapIns, previous: validPrevious?.swapIns),
            swapOutBytes: raw.pageSize * counterDelta(current: raw.swapOuts, previous: validPrevious?.swapOuts),
            pageOutBytes: raw.pageSize * counterDelta(current: raw.pageOuts, previous: validPrevious?.pageOuts),
            cpuPercent: cpuPercent,
            load1: raw.loadAverages[safe: 0] ?? 0,
            load5: raw.loadAverages[safe: 1] ?? 0,
            load15: raw.loadAverages[safe: 2] ?? 0,
            processorCount: raw.processorCount,
            diskReadBytes: counterDelta(current: raw.diskBytesReadCounter, previous: validPrevious?.diskBytesReadCounter),
            diskWriteBytes: counterDelta(current: raw.diskBytesWrittenCounter, previous: validPrevious?.diskBytesWrittenCounter),
            thermalState: raw.thermalState,
            families: families
        )

        history.append(sample)
        if history.count > maxSamples {
            history.removeFirst(history.count - maxSamples)
        }
        store.append(sample)
        previousRaw = raw
        previousProcessCPU = Dictionary(uniqueKeysWithValues: raw.processes.map {
            (ProcessIdentity(pid: $0.pid, startTimeMicroseconds: $0.startTimeMicroseconds), $0.cpuTimeNanoseconds)
        })

        let recentSwap = window(since: raw.capturedAt.addingTimeInterval(-15 * 60))
        let swapStart = recentSwap.first?.swapUsedBytes ?? sample.swapUsedBytes
        let swapEnd = recentSwap.last?.swapUsedBytes ?? sample.swapUsedBytes
        let swapNet = swapEnd >= swapStart
            ? Int64(clamping: swapEnd - swapStart)
            : -Int64(clamping: swapStart - swapEnd)
        let swapObservationDuration = max(
            0,
            (recentSwap.last?.capturedAt ?? sample.capturedAt)
                .timeIntervalSince(recentSwap.first?.capturedAt ?? sample.capturedAt)
        )
        return ResourceSnapshot(
            sample: sample,
            alerts: alerts(at: raw.capturedAt),
            evidence: evidence(at: raw.capturedAt),
            monitorOverheadMilliseconds: monitorOverheadMilliseconds,
            recentSwapInBytes: recentSwap.reduce(0) { $0 &+ $1.swapInBytes },
            recentSwapOutBytes: recentSwap.reduce(0) { $0 &+ $1.swapOutBytes },
            recentSwapNetChangeBytes: swapNet,
            recentSwapObservationDuration: swapObservationDuration
        )
    }

    static func derivedPressure(memory: ResourceMemoryMetrics) -> ResourcePressureLevel {
        guard memory.totalBytes > 0 else { return .unavailable }
        // These bands use public Mach counters and are deliberately labelled
        // estimated. Activity Monitor's exact green/yellow/red formula is not
        // public, so this app must never imply an exact match.
        let compression = Double(memory.compressedBytes) / Double(memory.totalBytes)
        let committed = Double(memory.wiredBytes &+ memory.activeBytes &+ memory.compressedBytes)
            / Double(memory.totalBytes)
        if committed >= 0.90 && compression >= 0.60 { return .critical }
        if compression >= 0.35 || (committed >= 0.75 && compression >= 0.20) { return .elevated }
        return .normal
    }

    private func alerts(at now: Date) -> [ResourceAlert] {
        var results: [ResourceAlert] = []
        if history.last?.pressure == .critical {
            results.append(ResourceAlert(id: "pressure-critical", severity: .critical, cause: "Estimated memory pressure is critical now"))
        } else if sustained(
            since: now.addingTimeInterval(-30 * 60),
            { $0.pressure == .elevated || $0.pressure == .critical }
        ) {
            results.append(ResourceAlert(id: "pressure-elevated", severity: .attention, cause: "Estimated memory pressure has stayed elevated for 30 min"))
        }

        let swapWindow = window(since: now.addingTimeInterval(-15 * 60))
        if let first = swapWindow.first, let last = swapWindow.last,
           last.capturedAt.timeIntervalSince(first.capturedAt) >= 15 * 60,
           last.swapUsedBytes >= first.swapUsedBytes + 1_024 * 1_024 * 1_024,
           hasSustainedSwapGrowth(swapWindow) {
            let hours = max(1.0 / 60, last.capturedAt.timeIntervalSince(first.capturedAt) / 3600)
            let rate = UInt64(Double(last.swapUsedBytes - first.swapUsedBytes) / hours)
            results.append(ResourceAlert(id: "swap-growth", severity: .attention, cause: "Swap is growing at \(ResourceFormatting.bytes(rate))/hr for 15 min"))
        }

        let leakWindow = window(since: now.addingTimeInterval(-2 * 60 * 60))
        if let first = leakWindow.first, let last = leakWindow.last,
           last.capturedAt.timeIntervalSince(first.capturedAt) >= 120 * 60 {
            for family in AppFamily.allCases {
                let points = leakWindow.compactMap { sample in
                    sample.families.first(where: { $0.family == family })?.residentBytes
                }
                let counts = leakWindow.compactMap { sample in
                    sample.families.first(where: { $0.family == family })?.processCount
                }
                guard points.count >= 100, let start = points.first, let end = points.last,
                      end >= start + max(2 * 1_024 * 1_024 * 1_024, rawRAMThreshold()),
                      let minCount = counts.min(), let maxCount = counts.max(),
                      maxCount - minCount <= max(3, Int(Double(maxCount) * 0.10)) else { continue }
                let rises = zip(points.dropFirst(), points).filter { $0.0 >= $0.1 }.count
                if Double(rises) / Double(max(1, points.count - 1)) >= 0.75 {
                    results.append(ResourceAlert(id: "leak-\(family.rawValue)", severity: .attention, cause: "\(family.displayName) memory has grown steadily by \(ResourceFormatting.bytes(end - start)) in 2 hr"))
                }
            }
        }

        let writeWindow = window(since: now.addingTimeInterval(-6 * 60 * 60))
        if let first = writeWindow.first, let last = writeWindow.last,
           last.capturedAt.timeIntervalSince(first.capturedAt) >= 6 * 60 * 60 {
            let total = writeWindow.reduce(UInt64(0)) { $0 &+ $1.diskWriteBytes }
            let hours = max(1.0 / 60, last.capturedAt.timeIntervalSince(first.capturedAt) / 3600)
            let rate = UInt64(Double(total) / hours)
            if total >= 125 * 1_024 * 1_024 * 1_024 {
                results.append(ResourceAlert(id: "disk-writes", severity: .attention, cause: "SSD host writes have sustained \(ResourceFormatting.bytes(rate))/hr for 6 hr"))
            }
        }

        if sustained(since: now.addingTimeInterval(-30 * 60), minimumSpan: 30 * 60, {
            $0.cpuPercent >= 95
                && $0.load5 / Double(max(1, $0.processorCount)) >= 1.15
        }) {
            results.append(ResourceAlert(id: "cpu-saturation", severity: .attention, cause: "CPU saturation and queued load have persisted for 30 min"))
        }
        return results
    }

    private func evidence(at now: Date) -> ResourceEvidenceSummary {
        let samples = window(since: now.addingTimeInterval(-Self.retentionSeconds))
        var elevated: TimeInterval = 0
        var critical: TimeInterval = 0
        for index in samples.indices.dropLast() {
            let duration = min(120, max(0, samples[index + 1].capturedAt.timeIntervalSince(samples[index].capturedAt)))
            if samples[index].pressure == .elevated { elevated += duration }
            if samples[index].pressure == .critical { critical += duration }
        }
        let duration = (samples.first.map { now.timeIntervalSince($0.capturedAt) } ?? 0)
        return ResourceEvidenceSummary(
            retainedDuration: duration,
            elevatedDuration: elevated,
            criticalDuration: critical,
            positiveSwapGrowthHourBytes: positiveSwapGrowth(in: window(since: now.addingTimeInterval(-3600))),
            positiveSwapGrowthDayBytes: positiveSwapGrowth(in: window(since: now.addingTimeInterval(-24 * 3600))),
            peakCompressedBytes: samples.map(\.memory.compressedBytes).max() ?? 0,
            peakFamilyResidentBytes: Dictionary(uniqueKeysWithValues: AppFamily.allCases.map { family in
                (family, samples.compactMap { sample in
                    sample.families.first(where: { $0.family == family })?.residentBytes
                }.max() ?? 0)
            }),
            highLoadThermalSamples: samples.filter { $0.cpuPercent >= 80 && $0.thermalState != .nominal }.count
        )
    }

    private func window(since date: Date) -> [ResourceHistorySample] {
        history.filter { $0.capturedAt >= date }
    }

    private func sustained(
        since date: Date,
        minimumSpan: TimeInterval = 30 * 60,
        _ predicate: (ResourceHistorySample) -> Bool
    ) -> Bool {
        let values = window(since: date)
        guard let first = values.first, let last = values.last,
              last.capturedAt.timeIntervalSince(first.capturedAt) >= minimumSpan,
              values.allSatisfy(predicate) else { return false }
        return zip(values.dropFirst(), values).allSatisfy {
            $0.0.capturedAt.timeIntervalSince($0.1.capturedAt) <= 120
        }
    }

    private func positiveSwapGrowth(in samples: [ResourceHistorySample]) -> UInt64 {
        zip(samples.dropFirst(), samples).reduce(UInt64(0)) { total, pair in
            pair.0.swapUsedBytes > pair.1.swapUsedBytes
                ? total &+ (pair.0.swapUsedBytes - pair.1.swapUsedBytes)
                : total
        }
    }

    private func hasSustainedSwapGrowth(_ samples: [ResourceHistorySample]) -> Bool {
        guard let end = samples.last?.capturedAt else { return false }
        for offset in stride(from: 15, to: 0, by: -5) {
            let bucketStart = end.addingTimeInterval(TimeInterval(-offset * 60))
            let bucketEnd = bucketStart.addingTimeInterval(5 * 60)
            let bucket = samples.filter { $0.capturedAt >= bucketStart && $0.capturedAt <= bucketEnd }
            guard let first = bucket.first, let last = bucket.last,
                  last.swapUsedBytes >= first.swapUsedBytes + 256 * 1_024 * 1_024,
                  bucket.reduce(UInt64(0), { $0 &+ $1.swapOutBytes }) >= 256 * 1_024 * 1_024
            else { return false }
        }
        return true
    }

    private func rawRAMThreshold() -> UInt64 {
        guard let total = history.last?.memory.totalBytes else { return 0 }
        return UInt64(Double(total) * 0.03)
    }
}

final class ResourceMonitor: @unchecked Sendable {
    private let provider: ResourceMetricProviding
    private let analyzer: ResourceAnalyzer
    private let pressureObserver: SystemMemoryPressureObserver

    init(
        provider: ResourceMetricProviding? = nil,
        analyzer: ResourceAnalyzer = ResourceAnalyzer(store: FileResourceHistoryStore()),
        pressureObserver: SystemMemoryPressureObserver = SystemMemoryPressureObserver()
    ) {
        self.provider = provider ?? NativeResourceMetricProvider(pressureObserver: pressureObserver)
        self.analyzer = analyzer
        self.pressureObserver = pressureObserver
    }

    func sample(at date: Date = Date()) -> ResourceSnapshot? {
        let start = ContinuousClock.now
        guard let raw = provider.capture(at: date) else { return nil }
        let duration = start.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return analyzer.ingest(raw, monitorOverheadMilliseconds: milliseconds)
    }

    func setImmediatePressureHandler(_ handler: @escaping @Sendable (ResourceAlert?) -> Void) {
        pressureObserver.setHandler { level in
            let alert = level == .critical
                ? ResourceAlert(id: "pressure-critical", severity: .critical, cause: "System memory pressure is critical now")
                : nil
            handler(alert)
        }
    }
}

final class SystemMemoryPressureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let source: DispatchSourceMemoryPressure
    private var level: ResourcePressureLevel?
    private var handler: (@Sendable (ResourcePressureLevel) -> Void)?

    init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "com.lukemainwaring.internetspeed.memory-pressure", qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.source.data
            let level: ResourcePressureLevel
            if data.contains(.critical) {
                level = .critical
            } else if data.contains(.warning) {
                level = .elevated
            } else {
                level = .normal
            }
            self.lock.lock()
            self.level = level
            let handler = self.handler
            self.lock.unlock()
            handler?(level)
        }
        source.resume()
    }

    var currentCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        switch level {
        case .normal: return 1
        case .elevated: return 2
        case .critical: return 3
        case .unavailable, nil: return nil
        }
    }

    func setHandler(_ handler: @escaping @Sendable (ResourcePressureLevel) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }
}

final class NativeResourceMetricProvider: ResourceMetricProviding {
    private let pressureObserver: SystemMemoryPressureObserver

    init(pressureObserver: SystemMemoryPressureObserver = SystemMemoryPressureObserver()) {
        self.pressureObserver = pressureObserver
    }

    func capture(at date: Date) -> ResourceRawSnapshot? {
        guard let vm = virtualMemory(), let cpuTicks = cpuTicks() else { return nil }
        let swap = swapUsage()
        let storage = storageCounters()
        return ResourceRawSnapshot(
            capturedAt: date,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            pageSize: nativePageSize(),
            memory: vm.memory,
            memoryStatusLevel: pressureObserver.currentCode,
            swapUsedBytes: swap?.used ?? 0,
            swapTotalBytes: swap?.total ?? 0,
            swapIns: vm.swapIns,
            swapOuts: vm.swapOuts,
            pageOuts: vm.pageOuts,
            cpuTicks: cpuTicks,
            loadAverages: loadAverages(),
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            diskBytesReadCounter: storage?.read,
            diskBytesWrittenCounter: storage?.written,
            thermalState: MacThermalState(ProcessInfo.processInfo.thermalState),
            processes: processMetrics()
        )
    }

    private func virtualMemory() -> (memory: ResourceMemoryMetrics, swapIns: UInt64, swapOuts: UInt64, pageOuts: UInt64)? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = nativePageSize()
        let total = ProcessInfo.processInfo.physicalMemory
        let free = UInt64(statistics.free_count) * pageSize
        let fileBacked = UInt64(statistics.external_page_count) * pageSize
        return (
            ResourceMemoryMetrics(
                totalBytes: total,
                usedBytes: MemoryAccounting.activityMonitorUsedBytes(
                    totalBytes: total,
                    freePages: UInt64(statistics.free_count),
                    fileBackedPages: UInt64(statistics.external_page_count),
                    pageSize: pageSize
                ),
                wiredBytes: UInt64(statistics.wire_count) * pageSize,
                compressedBytes: UInt64(statistics.compressor_page_count) * pageSize,
                compressedLogicalBytes: statistics.total_uncompressed_pages_in_compressor * pageSize,
                activeBytes: UInt64(statistics.active_count) * pageSize,
                inactiveBytes: UInt64(statistics.inactive_count) * pageSize,
                freeBytes: free,
                fileBackedBytes: fileBacked
            ),
            statistics.swapins,
            statistics.swapouts,
            statistics.pageouts
        )
    }

    private func swapUsage() -> (used: UInt64, total: UInt64)? {
        var value = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &value, &size, nil, 0) == 0 else { return nil }
        return (value.xsu_used, value.xsu_total)
    }

    private func cpuTicks() -> HostCPUTicks? {
        var value = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return HostCPUTicks(
            user: UInt64(value.cpu_ticks.0),
            system: UInt64(value.cpu_ticks.1),
            idle: UInt64(value.cpu_ticks.2),
            nice: UInt64(value.cpu_ticks.3)
        )
    }

    private func loadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? values : []
    }

    private func processMetrics() -> [ProcessResourceMetric] {
        let capacity = max(256, proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0) / Int32(MemoryLayout<Int32>.size) + 64)
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).compactMap { pid in
            guard pid > 0 else { return nil }
            var all = proc_taskallinfo()
            let result = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, Int32(MemoryLayout<proc_taskallinfo>.size))
            guard result == MemoryLayout<proc_taskallinfo>.size else { return nil }
            var nameBuffer = [CChar](repeating: 0, count: 1_024)
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameLength > 0 ? String(cString: nameBuffer) : "pid \(pid)"
            var pathBuffer = [CChar](repeating: 0, count: 4_096)
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : ""
            let start = all.pbsd.pbi_start_tvsec * 1_000_000 + all.pbsd.pbi_start_tvusec
            return ProcessResourceMetric(
                pid: pid,
                parentPID: Int32(all.pbsd.pbi_ppid),
                startTimeMicroseconds: start,
                name: name,
                path: path,
                residentBytes: all.ptinfo.pti_resident_size,
                // These are Mach ticks on Apple Silicon; convert to nanoseconds.
                cpuTimeNanoseconds: UInt64(Double(all.ptinfo.pti_total_user &+ all.ptinfo.pti_total_system)
                    * TopCPUSampler.nanosecondsPerTick)
            )
        }
    }

    private func storageCounters() -> (read: UInt64, written: UInt64)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleNVMeController"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            service,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: (read: UInt64, written: UInt64)?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["Statistics"] as? [String: Any],
                  let writeNumber = statistics["Bytes (Write)"] as? NSNumber
            else { continue }
            let candidate = (
                read: (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                written: writeNumber.uint64Value
            )
            if best == nil || candidate.written > best!.written { best = candidate }
        }
        return best
    }

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

enum ResourceFormatting {
    static func bytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / Double(1 << 30)
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / Double(1 << 20)
        return String(format: "%.0f MB", mb)
    }
}

private func nativePageSize() -> UInt64 {
    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 4_096 }
    return UInt64(pageSize)
}

private func counterDelta(current: UInt64, previous: UInt64?) -> UInt64 {
    guard let previous, current >= previous else { return 0 }
    return current - previous
}

private func counterDelta(current: UInt64?, previous: UInt64?) -> UInt64 {
    guard let current else { return 0 }
    return counterDelta(current: current, previous: previous)
}

private func hostCPUPercent(current: HostCPUTicks, previous: HostCPUTicks?) -> Double {
    guard let previous,
          current.total >= previous.total,
          current.busy >= previous.busy else { return 0 }
    let total = current.total - previous.total
    guard total > 0 else { return 0 }
    return Double(current.busy - previous.busy) / Double(total) * 100
}

private func pressureRank(_ level: ResourcePressureLevel) -> Int {
    switch level {
    case .unavailable: return 0
    case .normal: return 1
    case .elevated: return 2
    case .critical: return 3
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
