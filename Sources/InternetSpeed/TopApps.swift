import Darwin
import Foundation
import IOKit

struct TopCPUApp: Equatable, Identifiable {
    let name: String
    /// Share of the whole processor, 0–1, so it adds up with the CPU total.
    let share: Double
    /// Memory resident across all of the app's processes.
    var memoryBytes: UInt64 = 0
    /// The app bundle, when the app has one, for showing its icon.
    var bundlePath: String?

    var id: String { name }
}

/// Where the CPU is going: the biggest apps, and how much of the processor
/// all readable processes account for. The rest belongs to system processes
/// macOS hides from non-administrator apps.
struct CPUBreakdown: Equatable {
    let apps: [TopCPUApp]
    let readableShare: Double

    /// The three largest parts: apps of at least 1% and a "System" share for
    /// the hidden remainder when it is at least 2%. Three fit on one line.
    func parts(total: Double?) -> [TopCPUApp] {
        var parts = Array(apps.filter { $0.share >= 0.01 }.prefix(3))
        if let total {
            let hidden = total - readableShare
            if hidden >= 0.02 { parts.append(TopCPUApp(name: "System", share: hidden)) }
        }
        return Array(parts.sorted { $0.share > $1.share }.prefix(3))
    }
}

/// Measures CPU per app across every process this user can read. Each process
/// is credited to the app macOS holds responsible for it, so a Python script an
/// app launched counts toward that app; helpers roll up into their bundle.
final class TopCPUSampler {
    private struct Process {
        let pid: Int32
        let parent: Int32
        let start: UInt64
        let name: String
        let path: String
        let cpuNanoseconds: UInt64
        var residentBytes: UInt64 = 0
    }

    private var previous: [ProcessIdentity: UInt64] = [:]
    private var previousAt: Date?
    private var smoothed: [String: Double] = [:]
    private var bundleNames: [String: String] = [:]
    private var bundlePaths: [String: String] = [:]
    private let coreCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    func sample(at now: Date = Date()) -> CPUBreakdown? {
        let processes = Self.readProcesses()
        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var totals: [String: Double] = [:]
        var memory: [String: UInt64] = [:]
        var current: [ProcessIdentity: UInt64] = [:]

        for process in processes {
            let identity = ProcessIdentity(pid: process.pid, startTimeMicroseconds: process.start)
            current[identity] = process.cpuNanoseconds
            let app = appName(for: process, byPID: byPID)
            memory[app, default: 0] &+= process.residentBytes
            guard elapsed > 0, let before = previous[identity], process.cpuNanoseconds >= before else { continue }
            let seconds = Double(process.cpuNanoseconds - before) / 1_000_000_000
            totals[app, default: 0] += seconds / elapsed / coreCount
        }
        previous = current
        previousAt = now
        guard elapsed > 0 else { return nil }

        // Average over a few seconds so the ranking does not flip constantly.
        let blend = 1 - exp(-elapsed / 6)
        for name in Set(smoothed.keys).union(totals.keys) {
            let value = (smoothed[name] ?? 0) + ((totals[name] ?? 0) - (smoothed[name] ?? 0)) * blend
            smoothed[name] = value < 0.0005 ? nil : value
        }
        let names = Set(smoothed.keys).union(memory.filter { $0.value >= 50_000_000 }.keys)
        let apps = names
            .map { TopCPUApp(name: $0, share: min(1, smoothed[$0] ?? 0), memoryBytes: memory[$0] ?? 0,
                             bundlePath: bundlePaths[$0]) }
            .sorted { $0.share > $1.share }
        return CPUBreakdown(apps: apps, readableShare: smoothed.values.reduce(0, +))
    }

    private func appName(for process: Process, byPID: [Int32: Process]) -> String {
        // The app macOS holds responsible (the one that launched it) comes first.
        if let responsible = Self.responsiblePID(for: process.pid), responsible != process.pid,
           let owner = byPID[responsible] ?? Self.lightweightProcess(pid: responsible) {
            if let family = ProcessFamilyAggregator.family(name: owner.name, path: owner.path) {
                rememberBundle(for: family.displayName, path: owner.path)
                return family.displayName
            }
            if let bundle = Self.outermostAppBundle(in: owner.path) {
                return bundleName(bundle)
            }
        }
        var candidate: Process? = process
        var visited: Set<Int32> = []
        while let current = candidate, visited.insert(current.pid).inserted {
            if let family = ProcessFamilyAggregator.family(name: current.name, path: current.path) {
                rememberBundle(for: family.displayName, path: current.path)
                return family.displayName
            }
            candidate = byPID[current.parent]
        }
        if let bundle = Self.outermostAppBundle(in: process.path) {
            return bundleName(bundle)
        }
        return process.name
    }

    /// Grouped families ("Safari + WebKit") show the icon of the app at their head.
    private func rememberBundle(for name: String, path: String) {
        guard bundlePaths[name] == nil, let bundle = Self.outermostAppBundle(in: path) else { return }
        bundlePaths[name] = bundle
    }

    private func bundleName(_ bundle: String) -> String {
        if let cached = bundleNames[bundle] { return cached }
        let info = Bundle(path: bundle)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
        bundleNames[bundle] = name
        if bundlePaths[name] == nil { bundlePaths[name] = bundle }
        return name
    }

    private typealias ResponsibilityFunction = @convention(c) (
        pid_t, UnsafeMutablePointer<pid_t>?, UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<CChar>?
    ) -> pid_t

    /// macOS records which app is responsible for each process (the same record
    /// it uses to attribute privacy permissions). The function is not in the
    /// public headers, so it is looked up at run time and skipped if missing.
    private static let responsibilityFunction: ResponsibilityFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    static func responsiblePID(for pid: Int32) -> Int32? {
        guard let function = responsibilityFunction else { return nil }
        let responsible = function(pid, nil, nil, nil)
        return responsible > 0 ? responsible : nil
    }

    private static func lightweightProcess(pid: Int32) -> Process? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return nil }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let name = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 ? String(cString: nameBuffer) : ""
        return Process(pid: pid, parent: 0, start: 0, name: name, path: String(cString: pathBuffer), cpuNanoseconds: 0)
    }

    static func outermostAppBundle(in path: String) -> String? {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    /// proc_taskinfo CPU times are Mach ticks on Apple Silicon, not nanoseconds.
    static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }()

    private static func readProcesses() -> [Process] {
        let capacity = max(256, proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0) / Int32(MemoryLayout<Int32>.size) + 64)
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).compactMap { pid in
            guard pid > 0 else { return nil }
            var all = proc_taskallinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, Int32(MemoryLayout<proc_taskallinfo>.size))
                    == MemoryLayout<proc_taskallinfo>.size else { return nil }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let name = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 ? String(cString: nameBuffer) : "pid \(pid)"
            var pathBuffer = [CChar](repeating: 0, count: 4_096)
            let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
            let ticks = all.ptinfo.pti_total_user &+ all.ptinfo.pti_total_system
            return Process(
                pid: pid,
                parent: Int32(all.pbsd.pbi_ppid),
                start: all.pbsd.pbi_start_tvsec * 1_000_000 + all.pbsd.pbi_start_tvusec,
                name: name,
                path: path,
                cpuNanoseconds: UInt64(Double(ticks) * nanosecondsPerTick),
                residentBytes: all.ptinfo.pti_resident_size
            )
        }
    }
}

/// Reads GPU utilization the graphics driver publishes; no permissions needed.
enum GPUActivityReader {
    static func utilization() -> Double? {
        guard let properties = acceleratorProperties(),
              let statistics = properties["PerformanceStatistics"] as? [String: Any],
              let percent = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
        else { return nil }
        return min(1, max(0, percent / 100))
    }

    static func coreCount() -> Int? {
        (acceleratorProperties()?["gpu-core-count"] as? NSNumber)?.intValue
    }

    private static func acceleratorProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }
}
