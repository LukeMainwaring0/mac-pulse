import Darwin
import Foundation

/// One tier of CPU cores, such as "Super" or "Performance" on an M5 Max.
struct CPUCoreGroup: Equatable {
    let name: String
    /// Busy fraction (0–1) for each core in the tier.
    let usages: [Double]

    var average: Double {
        usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
    }
}

struct CPUActivity: Equatable {
    /// Ordered fastest tier first.
    let groups: [CPUCoreGroup]

    var total: Double {
        let all = groups.flatMap(\.usages)
        return all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
    }

    /// Exponential smoothing toward `latest`. A few seconds of averaging turns
    /// per-second scheduler noise into a reading a person can follow.
    static let smoothingTimeConstant: TimeInterval = 4

    func smoothed(toward latest: CPUActivity, elapsed: TimeInterval) -> CPUActivity {
        guard latest.groups.map(\.usages.count) == groups.map(\.usages.count),
              latest.groups.map(\.name) == groups.map(\.name) else { return latest }
        let blend = 1 - exp(-max(0, elapsed) / Self.smoothingTimeConstant)
        return CPUActivity(groups: zip(groups, latest.groups).map { old, new in
            CPUCoreGroup(name: new.name, usages: zip(old.usages, new.usages).map { $0 + ($1 - $0) * blend })
        })
    }
}

/// Measures per-core CPU use from Mach tick counters between samples.
final class CPUActivitySampler {
    private struct Ticks { let busy: UInt64; let total: UInt64 }
    private var previous: [Ticks] = []
    private let tiers: [(name: String, count: Int)]

    init(tiers: [(name: String, count: Int)]? = nil) {
        self.tiers = tiers ?? Self.systemTiers()
    }

    /// Returns nil for the first call, which only establishes a baseline.
    func sample() -> CPUActivity? {
        guard let current = Self.readTicks() else { return nil }
        defer { previous = current }
        guard previous.count == current.count else { return nil }
        let usages = zip(previous, current).map { old, new -> Double in
            let total = Double(new.total &- old.total)
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(new.busy &- old.busy) / total))
        }
        return Self.group(usages, tiers: tiers)
    }

    /// Apple Silicon numbers cores slowest tier first, so tier N−1 owns the
    /// lowest indices and perflevel0 (the fastest) the highest. Verified on an
    /// M5 Max against the device tree (cluster M = cpus 0–11, P = 12–17).
    static func group(_ usages: [Double], tiers: [(name: String, count: Int)]) -> CPUActivity {
        guard !tiers.isEmpty, tiers.map(\.count).reduce(0, +) == usages.count else {
            return CPUActivity(groups: [CPUCoreGroup(name: "Cores", usages: usages)])
        }
        var groups: [CPUCoreGroup] = []
        var index = 0
        for tier in tiers.reversed() {
            groups.append(CPUCoreGroup(name: tier.name, usages: Array(usages[index..<(index + tier.count)])))
            index += tier.count
        }
        return CPUActivity(groups: groups.reversed())
    }

    private static func systemTiers() -> [(name: String, count: Int)] {
        let levels = sysctlInt("hw.nperflevels") ?? 0
        return (0..<levels).compactMap { level in
            guard let count = sysctlInt("hw.perflevel\(level).logicalcpu"), count > 0 else { return nil }
            let name = sysctlString("hw.perflevel\(level).name") ?? (level == 0 ? "Performance" : "Efficiency")
            return (name, count)
        }
    }

    private static func readTicks() -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { cpu in
            let base = Int(CPU_STATE_MAX) * cpu
            func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            let busy = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
            return Ticks(busy: busy, total: busy + ticks(CPU_STATE_IDLE))
        }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
