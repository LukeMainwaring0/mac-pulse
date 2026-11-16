import AppKit
import CoreWLAN
import Darwin
import Foundation
import IOKit
import SystemConfiguration

// MARK: - Model

struct WiFiDetails: Equatable, Sendable {
    var networkName: String?
    var rssi: Int
    var noise: Int
    var transmitRateMbps: Double
    var channel: Int?
    var band: String?

    var signalToNoise: Int { rssi - noise }

    /// 1–4 bars, using the thresholds Apple's Wireless Diagnostics uses.
    var bars: Int {
        if rssi >= -55 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }

    var quality: String {
        switch bars {
        case 4: return "Excellent"
        case 3: return "Good"
        case 2: return "Fair"
        default: return "Weak"
        }
    }
}

struct VolumeDetails: Equatable, Sendable, Identifiable {
    let name: String
    let path: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isStartup: Bool

    var id: String { path }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

struct MemoryBreakdown: Equatable, Sendable {
    let totalBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedBytes: UInt64
    let freeBytes: UInt64
    let swapUsedBytes: UInt64
}

struct AccessoryBattery: Equatable, Sendable, Identifiable {
    let name: String
    let percent: Int
    var id: String { name }

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("keyboard") { return "keyboard.fill" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if lower.contains("mouse") { return "magicmouse.fill" }
        if lower.contains("airpods") { return "airpodspro" }
        if lower.contains("pencil") { return "applepencil" }
        return "dot.radiowaves.left.and.right"
    }
}

struct SystemIdentity: Equatable, Sendable {
    let modelName: String
    let chip: String
    let computerName: String
    let osVersion: String
    let memoryBytes: UInt64
    let bootedAt: Date?

    static let current: SystemIdentity = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = version.patchVersion > 0
            ? "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "macOS \(version.majorVersion).\(version.minorVersion)"
        return SystemIdentity(
            modelName: CommandCenterReaders.productName() ?? CommandCenterReaders.sysctlString("hw.model") ?? "Mac",
            chip: CommandCenterReaders.sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            computerName: (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac",
            osVersion: os,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            bootedAt: CommandCenterReaders.bootTime()
        )
    }()
}

/// Everything the command center shows beyond the menu bar's own readings.
struct CommandCenterSample: Equatable, Sendable {
    var capturedAt = Date()

    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    var receivedSinceBootBytes: UInt64 = 0
    var sentSinceBootBytes: UInt64 = 0
    var interfaceName: String?
    var localAddress: String?
    var wifi: WiFiDetails?
    var downloadHistory: [MetricHistoryPoint] = []
    var uploadHistory: [MetricHistoryPoint] = []

    var diskReadBytesPerSecond: Double = 0
    var diskWriteBytesPerSecond: Double = 0
    var diskReadHistory: [MetricHistoryPoint] = []
    var diskWriteHistory: [MetricHistoryPoint] = []
    var volumes: [VolumeDetails] = []

    var memory: MemoryBreakdown?

    var loadAverages: [Double] = []
    var processCount: Int = 0
    var thermalState: ProcessInfo.ThermalState = .nominal

    var accessories: [AccessoryBattery] = []

    static let historyWindow: TimeInterval = 120
}

// MARK: - Sampler

/// Reads live system detail once a second while the full app is open. Each
/// read is cheap; slower-changing things (volumes, accessories) refresh less
/// often. Not thread-safe: the controller calls it from one task at a time.
final class CommandCenterSampler: @unchecked Sendable {
    private var sample = CommandCenterSample()
    private var previousNetwork: (received: UInt64, sent: UInt64, at: Date)?
    private var previousDisk: (read: UInt64, written: UInt64, at: Date)?
    private var volumesAt: Date?
    private var accessoriesAt: Date?
    private var wifiAt: Date?

    func sample(at now: Date = Date()) -> CommandCenterSample {
        sample.capturedAt = now

        // Network throughput across Wi-Fi and Ethernet.
        let interfaces = CommandCenterReaders.interfaceCounters()
        let received = interfaces.reduce(UInt64(0)) { $0 &+ $1.received }
        let sent = interfaces.reduce(UInt64(0)) { $0 &+ $1.sent }
        if let previous = previousNetwork, received >= previous.received, sent >= previous.sent {
            let elapsed = max(0.2, now.timeIntervalSince(previous.at))
            sample.downloadBytesPerSecond = smooth(sample.downloadBytesPerSecond, Double(received - previous.received) / elapsed, elapsed)
            sample.uploadBytesPerSecond = smooth(sample.uploadBytesPerSecond, Double(sent - previous.sent) / elapsed, elapsed)
            append(&sample.downloadHistory, sample.downloadBytesPerSecond, now)
            append(&sample.uploadHistory, sample.uploadBytesPerSecond, now)
        }
        previousNetwork = (received, sent, now)
        sample.receivedSinceBootBytes = received
        sample.sentSinceBootBytes = sent
        let addresses = CommandCenterReaders.ipv4Addresses()
        let primary = interfaces
            .filter { addresses[$0.name] != nil }
            .max { $0.received &+ $0.sent < $1.received &+ $1.sent }
        sample.interfaceName = primary?.name
        sample.localAddress = primary.flatMap { addresses[$0.name] }

        if wifiAt.map({ now.timeIntervalSince($0) >= 2 }) ?? true {
            wifiAt = now
            sample.wifi = CommandCenterReaders.wifi()
        }

        // Disk throughput.
        if let disk = CommandCenterReaders.diskCounters() {
            if let previous = previousDisk, disk.read >= previous.read, disk.written >= previous.written {
                let elapsed = max(0.2, now.timeIntervalSince(previous.at))
                sample.diskReadBytesPerSecond = smooth(sample.diskReadBytesPerSecond, Double(disk.read - previous.read) / elapsed, elapsed)
                sample.diskWriteBytesPerSecond = smooth(sample.diskWriteBytesPerSecond, Double(disk.written - previous.written) / elapsed, elapsed)
                append(&sample.diskReadHistory, sample.diskReadBytesPerSecond, now)
                append(&sample.diskWriteHistory, sample.diskWriteBytesPerSecond, now)
            }
            previousDisk = (disk.read, disk.written, now)
        }
        if volumesAt.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
            volumesAt = now
            sample.volumes = CommandCenterReaders.volumes()
        }

        sample.memory = CommandCenterReaders.memory()
        var loads = [Double](repeating: 0, count: 3)
        sample.loadAverages = getloadavg(&loads, 3) == 3 ? loads : []
        sample.processCount = Int(proc_listallpids(nil, 0))
        sample.thermalState = ProcessInfo.processInfo.thermalState

        if accessoriesAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true {
            accessoriesAt = now
            sample.accessories = CommandCenterReaders.accessories()
        }
        return sample
    }

    /// A short average keeps rates readable without hiding real changes.
    private func smooth(_ previous: Double, _ latest: Double, _ elapsed: TimeInterval) -> Double {
        previous + (latest - previous) * (1 - exp(-elapsed / 2))
    }

    private func append(_ history: inout [MetricHistoryPoint], _ value: Double, _ now: Date) {
        history.append(MetricHistoryPoint(capturedAt: now, value: value))
        let cutoff = now.addingTimeInterval(-CommandCenterSample.historyWindow - 5)
        if let first = history.firstIndex(where: { $0.capturedAt >= cutoff }), first > 0 {
            history.removeFirst(first)
        }
    }
}

// MARK: - Readers

enum CommandCenterReaders {
    struct InterfaceCounter { let name: String; let received: UInt64; let sent: UInt64 }

    /// 64-bit byte counters for physical network interfaces (Wi-Fi, Ethernet).
    static func interfaceCounters() -> [InterfaceCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, 6 /* NET_RT_IFLIST2 */, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [] }
        var results: [String: InterfaceCounter] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if header.ifm_type == 0x12 /* RTM_IFINFO2 */,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        if name.hasPrefix("en") {
                            results[name] = InterfaceCounter(name: name, received: message.ifm_data.ifi_ibytes,
                                                             sent: message.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return Array(results.values)
    }

    static func ipv4Addresses() -> [String: String] {
        var addresses: [String: String] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses[name] = String(cString: host)
            }
        }
        return addresses
    }

    static func wifi() -> WiFiDetails? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              interface.rssiValue() != 0 else { return nil }
        let band: String?
        switch interface.wlanChannel()?.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = nil
        }
        return WiFiDetails(
            networkName: interface.ssid(),
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            transmitRateMbps: interface.transmitRate(),
            channel: interface.wlanChannel()?.channelNumber,
            band: band
        )
    }

    /// Bytes read from and written to the internal SSD since boot.
    static func diskCounters() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        var found = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let statistics = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            found = true
        }
        return found ? (read, written) : nil
    }

    static func volumes() -> [VolumeDetails] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                      .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> VolumeDetails? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 1_000_000_000 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            return VolumeDetails(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                totalBytes: Int64(total),
                availableBytes: available,
                isInternal: values.volumeIsInternal ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isStartup: values.volumeIsRootFileSystem ?? (url.path == "/")
            )
        }
        .sorted { ($0.isStartup ? 0 : 1, $0.name) < ($1.isStartup ? 0 : 1, $1.name) }
    }

    static func memory() -> MemoryBreakdown? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        // Activity Monitor's categories: app memory is anonymous memory that
        // isn't purgeable; cached files can be dropped at any time.
        let anonymous = UInt64(statistics.internal_page_count) * page
        let purgeable = UInt64(statistics.purgeable_count) * page
        let wired = UInt64(statistics.wire_count) * page
        let compressed = UInt64(statistics.compressor_page_count) * page
        let cached = (UInt64(statistics.external_page_count) + UInt64(statistics.purgeable_count)) * page
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        let accounted = app + wired + compressed + cached
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed: UInt64 = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : 0
        return MemoryBreakdown(totalBytes: total, appBytes: app, wiredBytes: wired, compressedBytes: compressed,
                               cachedBytes: cached, freeBytes: total > accounted ? total - accounted : 0,
                               swapUsedBytes: swapUsed)
    }

    /// Battery levels of connected Bluetooth keyboards, mice, trackpads and more.
    static func accessories() -> [AccessoryBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var seen: [String: AccessoryBattery] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = (property("BatteryPercent") as? NSNumber)?.intValue,
                  let name = property("Product") as? String else { continue }
            seen[name] = AccessoryBattery(name: name, percent: percent)
        }
        return seen.values.sorted { $0.name < $1.name }
    }

    static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}

enum CommandCenterFormatting {
    /// Network rates in bits, like speed tests: "12.4 Mbps", "830 Kbps".
    static func bitRate(_ bytesPerSecond: Double) -> String {
        let bits = bytesPerSecond * 8
        switch bits {
        case 1_000_000_000...: return String(format: "%.2f Gbps", bits / 1_000_000_000)
        case 10_000_000...: return String(format: "%.0f Mbps", bits / 1_000_000)
        case 1_000_000...: return String(format: "%.1f Mbps", bits / 1_000_000)
        case 1_000...: return String(format: "%.0f Kbps", bits / 1_000)
        default: return "0 Kbps"
        }
    }

    /// Disk rates in bytes: "1.2 GB/s", "340 MB/s".
    static func byteRate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case 1_000_000_000...: return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        case 10_000_000...: return String(format: "%.0f MB/s", bytesPerSecond / 1_000_000)
        case 1_000_000...: return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        case 1_000...: return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        default: return "0 KB/s"
        }
    }

    static func uptime(since boot: Date?, now: Date = Date()) -> String {
        guard let boot else { return "—" }
        let minutes = Int(now.timeIntervalSince(boot) / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days) d \(hours) hr" }
        if hours > 0 { return "\(hours) hr \(mins) min" }
        return "\(mins) min"
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> (text: String, level: TileStatus.Level) {
        switch state {
        case .nominal: return ("Nominal", .good)
        case .fair: return ("Fair", .fair)
        case .serious: return ("Serious", .poor)
        case .critical: return ("Critical", .bad)
        @unknown default: return ("Unknown", .fair)
        }
    }
}
