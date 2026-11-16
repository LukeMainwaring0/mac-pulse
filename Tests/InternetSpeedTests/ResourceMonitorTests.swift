import XCTest
@testable import InternetSpeed

final class ResourceMonitorTests: XCTestCase {
    private final class MemoryStore: ResourceHistoryStoring {
        var samples: [ResourceHistorySample] = []
        var pruneCutoff: Date?

        func load() -> [ResourceHistorySample] { samples }
        func append(_ sample: ResourceHistorySample) { samples.append(sample) }
        func prune(before cutoff: Date) { pruneCutoff = cutoff }
    }

    private let gb: UInt64 = 1_024 * 1_024 * 1_024

    private func memory(
        total: UInt64 = 64 * 1_024 * 1_024 * 1_024,
        used: UInt64 = 40 * 1_024 * 1_024 * 1_024,
        wired: UInt64 = 8 * 1_024 * 1_024 * 1_024,
        compressed: UInt64 = 4 * 1_024 * 1_024 * 1_024,
        active: UInt64 = 20 * 1_024 * 1_024 * 1_024
    ) -> ResourceMemoryMetrics {
        ResourceMemoryMetrics(
            totalBytes: total,
            usedBytes: used,
            wiredBytes: wired,
            compressedBytes: compressed,
            compressedLogicalBytes: compressed * 2,
            activeBytes: active,
            inactiveBytes: 8 * gb,
            freeBytes: 4 * gb,
            fileBackedBytes: 20 * gb
        )
    }

    private func raw(
        minute: Int,
        start: Date,
        memory: ResourceMemoryMetrics? = nil,
        uptime: TimeInterval? = nil,
        swapUsed: UInt64 = 3 * 1_024 * 1_024 * 1_024,
        swapIns: UInt64 = 10,
        swapOuts: UInt64 = 20,
        pageOuts: UInt64 = 30,
        cpu: UInt64? = nil,
        load5: Double = 1,
        diskReads: UInt64? = 500,
        diskWrites: UInt64? = 1_000,
        processes: [ProcessResourceMetric] = []
    ) -> ResourceRawSnapshot {
        let tick = cpu ?? UInt64(minute * 100)
        return ResourceRawSnapshot(
            capturedAt: start.addingTimeInterval(TimeInterval(minute * 60)),
            uptimeSeconds: uptime ?? TimeInterval(10_000 + minute * 60),
            pageSize: 4_096,
            memory: memory ?? self.memory(),
            memoryStatusLevel: nil,
            swapUsedBytes: swapUsed,
            swapTotalBytes: 4 * gb,
            swapIns: swapIns,
            swapOuts: swapOuts,
            pageOuts: pageOuts,
            cpuTicks: HostCPUTicks(user: tick, system: tick, idle: tick * 2, nice: 0),
            loadAverages: [load5, load5, load5],
            processorCount: 16,
            diskBytesReadCounter: diskReads,
            diskBytesWrittenCounter: diskWrites,
            thermalState: .nominal,
            processes: processes
        )
    }

    func testDerivedPressureThresholdsAreExplicitlyEstimated() {
        let normal = memory(compressed: 10 * gb, active: 20 * gb)
        let elevated = memory(compressed: 23 * gb, active: 20 * gb)
        let critical = memory(wired: 10 * gb, compressed: 39 * gb, active: 10 * gb)

        XCTAssertEqual(ResourceAnalyzer.derivedPressure(memory: normal), .normal)
        XCTAssertEqual(ResourceAnalyzer.derivedPressure(memory: elevated), .elevated)
        XCTAssertEqual(ResourceAnalyzer.derivedPressure(memory: critical), .critical)

        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let snapshot = analyzer.ingest(raw(minute: 0, start: Date(), memory: elevated))
        XCTAssertEqual(snapshot.performanceTitle, "Performance: Elevated (estimated)")
    }

    func testAllocatedSwapWithoutCounterMovementIsInactiveAndNeverAlerts() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot: ResourceSnapshot!
        for minute in 0...30 {
            snapshot = analyzer.ingest(raw(minute: minute, start: start))
        }

        XCTAssertTrue(snapshot.swapDetail.contains("3.0 GB allocated · inactive"))
        XCTAssertTrue(snapshot.alerts.isEmpty)
        XCTAssertEqual(snapshot.sample.swapInBytes, 0)
        XCTAssertEqual(snapshot.sample.swapOutBytes, 0)
    }

    func testInactiveSwapDoesNotOverclaimObservationWindow() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)

        _ = analyzer.ingest(raw(minute: 0, start: start))
        let shortSnapshot = analyzer.ingest(raw(minute: 1, start: start))
        XCTAssertTrue(shortSnapshot.swapDetail.contains("inactive in latest sample"))
        XCTAssertFalse(shortSnapshot.swapDetail.contains("15m"))

        var coveredSnapshot = shortSnapshot
        for minute in 2...15 {
            coveredSnapshot = analyzer.ingest(raw(minute: minute, start: start))
        }
        XCTAssertTrue(coveredSnapshot.swapDetail.contains("no churn in 15m"))
    }

    func testElevatedPressureAlertsAtThirtyMinutesNotBefore() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let elevated = memory(compressed: 23 * gb, active: 20 * gb)
        var snapshot: ResourceSnapshot!
        for minute in 0..<30 {
            snapshot = analyzer.ingest(raw(minute: minute, start: start, memory: elevated))
        }
        XCTAssertFalse(snapshot.alerts.contains { $0.id == "pressure-elevated" })

        snapshot = analyzer.ingest(raw(minute: 30, start: start, memory: elevated))
        XCTAssertEqual(snapshot.alerts.first(where: { $0.id == "pressure-elevated" })?.cause,
                       "Estimated memory pressure has stayed elevated for 30 min")
    }

    func testCriticalPressureAlertsOnFirstSample() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let critical = memory(wired: 10 * gb, compressed: 39 * gb, active: 10 * gb)
        let snapshot = analyzer.ingest(raw(minute: 0, start: Date(), memory: critical))

        XCTAssertEqual(snapshot.statusAlert?.severity, .critical)
        XCTAssertEqual(snapshot.statusAlert?.id, "pressure-critical")
    }

    func testCounterDecreaseAndUptimeResetProduceZeroDeltas() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        _ = analyzer.ingest(raw(
            minute: 0,
            start: start,
            uptime: 10_000,
            swapIns: 1_000,
            swapOuts: 2_000,
            pageOuts: 3_000,
            diskWrites: 10_000
        ))
        let snapshot = analyzer.ingest(raw(
            minute: 1,
            start: start,
            uptime: 10,
            swapIns: 1,
            swapOuts: 2,
            pageOuts: 3,
            diskWrites: 100
        ))

        XCTAssertEqual(snapshot.sample.swapInBytes, 0)
        XCTAssertEqual(snapshot.sample.swapOutBytes, 0)
        XCTAssertEqual(snapshot.sample.pageOutBytes, 0)
        XCTAssertEqual(snapshot.sample.diskWriteBytes, 0)
        XCTAssertFalse(snapshot.alerts.contains { $0.id == "swap-growth" || $0.id == "disk-writes" })
    }

    func testProcessAggregationPropagatesFamilyToDescendantsWithoutDoubleCounting() {
        let root = ProcessResourceMetric(
            pid: 10,
            parentPID: 1,
            startTimeMicroseconds: 100,
            name: "Codex",
            path: "/Applications/Codex.app/Contents/MacOS/Codex",
            residentBytes: 2 * gb,
            cpuTimeNanoseconds: 2_000_000_000
        )
        let helper = ProcessResourceMetric(
            pid: 11,
            parentPID: 10,
            startTimeMicroseconds: 110,
            name: "node",
            path: "/usr/local/bin/node",
            residentBytes: gb,
            cpuTimeNanoseconds: 1_000_000_000
        )
        let previous = [
            ProcessIdentity(pid: 10, startTimeMicroseconds: 100): UInt64(1_000_000_000),
            ProcessIdentity(pid: 11, startTimeMicroseconds: 110): UInt64(500_000_000)
        ]
        let aggregate = ProcessFamilyAggregator.aggregate(
            processes: [root, helper],
            previous: previous,
            elapsed: 10
        )

        XCTAssertEqual(aggregate, [AppFamilyMetric(
            family: .codex,
            residentBytes: 3 * gb,
            processCount: 2,
            cpuPercent: 15
        )])
    }

    func testPIDReuseDoesNotCreateCPUCounterSpike() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let old = ProcessResourceMetric(
            pid: 42, parentPID: 1, startTimeMicroseconds: 1, name: "Codex", path: "",
            residentBytes: gb, cpuTimeNanoseconds: 10_000_000_000
        )
        let reused = ProcessResourceMetric(
            pid: 42, parentPID: 1, startTimeMicroseconds: 2, name: "Codex", path: "",
            residentBytes: gb, cpuTimeNanoseconds: 100_000_000
        )
        _ = analyzer.ingest(raw(minute: 0, start: start, processes: [old]))
        let snapshot = analyzer.ingest(raw(minute: 1, start: start, processes: [reused]))

        XCTAssertEqual(snapshot.sample.families.first?.cpuPercent, 0)
    }

    func testRetentionHasExactBoundAndStoreIsPruned() {
        let store = MemoryStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let analyzer = ResourceAnalyzer(store: store, maxSamples: 3, now: start)
        for minute in 0..<5 {
            _ = analyzer.ingest(raw(minute: minute, start: start))
        }

        XCTAssertEqual(analyzer.history.count, 3)
        XCTAssertEqual(analyzer.history.first?.capturedAt, start.addingTimeInterval(2 * 60))
        XCTAssertNotNil(store.pruneCutoff)
    }

    func testHighCPUWithoutQueuedLoadDoesNotAlert() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot: ResourceSnapshot!
        for minute in 0...35 {
            // Busy rises by 190 ticks and idle by 10: 95% host CPU, but load
            // remains far below 1.15 per active processor.
            let ticks = UInt64(minute * 95)
            let rawSample = ResourceRawSnapshot(
                capturedAt: start.addingTimeInterval(Double(minute * 60)),
                uptimeSeconds: Double(10_000 + minute * 60),
                pageSize: 4_096,
                memory: memory(),
                memoryStatusLevel: nil,
                swapUsedBytes: 0,
                swapTotalBytes: 0,
                swapIns: 0,
                swapOuts: 0,
                pageOuts: 0,
                cpuTicks: HostCPUTicks(user: ticks, system: ticks, idle: UInt64(minute * 10), nice: 0),
                loadAverages: [2, 2, 2],
                processorCount: 16,
                diskBytesReadCounter: 0,
                diskBytesWrittenCounter: 0,
                thermalState: .nominal,
                processes: []
            )
            snapshot = analyzer.ingest(rawSample)
        }
        XCTAssertFalse(snapshot.alerts.contains { $0.id == "cpu-saturation" })
    }

    func testSustainedSwapGrowthAlertsButOneBurstDoesNot() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let pageDelta = UInt64(80 * 1_024 * 1_024 / 4_096)
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        var snapshot: ResourceSnapshot!
        for minute in 0...15 {
            snapshot = analyzer.ingest(raw(
                minute: minute,
                start: start,
                swapUsed: 2 * gb + UInt64(minute) * 80 * 1_024 * 1_024,
                swapOuts: 20 + UInt64(minute) * pageDelta
            ))
        }
        XCTAssertEqual(snapshot.alerts.first(where: { $0.id == "swap-growth" })?.severity, .attention)
        XCTAssertTrue(snapshot.swapDetail.contains("active"))

        let burstAnalyzer = ResourceAnalyzer(store: MemoryStore())
        for minute in 0...15 {
            let growth = minute == 8 ? gb : 0
            snapshot = burstAnalyzer.ingest(raw(
                minute: minute,
                start: start,
                swapUsed: 2 * gb + growth,
                swapOuts: minute >= 8 ? 20 + pageDelta : 20
            ))
        }
        XCTAssertFalse(snapshot.alerts.contains { $0.id == "swap-growth" })
    }

    func testStableCountLeakLikeGrowthQualifiesAfterTwoHours() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot: ResourceSnapshot!
        for minute in 0...120 {
            let process = ProcessResourceMetric(
                pid: 10,
                parentPID: 1,
                startTimeMicroseconds: 100,
                name: "Codex",
                path: "",
                residentBytes: 4 * gb + UInt64(minute) * 26 * 1_024 * 1_024,
                cpuTimeNanoseconds: UInt64(minute) * 1_000_000
            )
            snapshot = analyzer.ingest(raw(minute: minute, start: start, processes: [process]))
        }
        XCTAssertEqual(snapshot.alerts.first(where: { $0.id == "leak-Codex" })?.severity, .attention)
        XCTAssertTrue(snapshot.alerts.first(where: { $0.id == "leak-Codex" })?.cause.contains("2 hr") == true)
    }

    func testExcessiveSSDHostWritesRequireCoveredSixHourWindow() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let perMinute = UInt64(360 * 1_024 * 1_024)
        var snapshot: ResourceSnapshot!
        for minute in 0..<360 {
            snapshot = analyzer.ingest(raw(
                minute: minute,
                start: start,
                diskWrites: UInt64(minute) * perMinute
            ))
        }
        XCTAssertFalse(snapshot.alerts.contains { $0.id == "disk-writes" })
        snapshot = analyzer.ingest(raw(minute: 360, start: start, diskWrites: 360 * perMinute))
        XCTAssertTrue(snapshot.alerts.contains { $0.id == "disk-writes" })
    }

    func testCPUAndQueuedLoadMustBothPersistForThirtyMinutes() {
        let analyzer = ResourceAnalyzer(store: MemoryStore())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot: ResourceSnapshot!
        for minute in 0...31 {
            let busy = UInt64(minute * 95)
            snapshot = analyzer.ingest(ResourceRawSnapshot(
                capturedAt: start.addingTimeInterval(Double(minute * 60)),
                uptimeSeconds: Double(10_000 + minute * 60),
                pageSize: 4_096,
                memory: memory(),
                memoryStatusLevel: nil,
                swapUsedBytes: 0,
                swapTotalBytes: 0,
                swapIns: 0,
                swapOuts: 0,
                pageOuts: 0,
                cpuTicks: HostCPUTicks(user: busy, system: busy, idle: UInt64(minute * 10), nice: 0),
                loadAverages: [20, 20, 20],
                processorCount: 16,
                diskBytesReadCounter: 0,
                diskBytesWrittenCounter: 0,
                thermalState: .nominal,
                processes: []
            ))
        }
        XCTAssertEqual(snapshot.alerts.first(where: { $0.id == "cpu-saturation" })?.cause,
                       "CPU saturation and queued load have persisted for 30 min")
    }

    func testAnalyzerHasNoProcessControlSurface() {
        let methodNames = Set(Mirror(reflecting: ResourceAnalyzer(store: MemoryStore())).children.compactMap(\.label))
        XCTAssertFalse(methodNames.contains("processController"))
        XCTAssertFalse(methodNames.contains("actionProvider"))
    }
}
