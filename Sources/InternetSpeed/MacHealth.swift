import Foundation
import IOKit

enum MacHealthLevel: String, Equatable, Sendable {
    case good = "Good"
    case attention = "Attention"
}

struct BatteryHealthSnapshot: Equatable, Sendable {
    let maximumCapacityPercent: Int?
    let cycleCount: Int?
    let condition: String?
    let temperatureCelsius: Double?
}

struct StorageHealthSnapshot: Equatable, Sendable {
    let smartStatus: String?
    let usedPercent: Int?
    let bytesWrittenCounter: UInt64?
    let readErrors: UInt64?
    let writeErrors: UInt64?
}

struct HealthHardwareSnapshot: Equatable, Sendable {
    let battery: BatteryHealthSnapshot?
    let storage: StorageHealthSnapshot?
}

protocol HealthHardwareProviding {
    func currentHealthHardware(at date: Date) -> HealthHardwareSnapshot
}

struct DailyHealthHistory: Codable, Equatable, Sendable {
    var dayStart: Date
    var lastSampleAt: Date?
    var temperatureSampleSeconds: TimeInterval
    var temperatureDegreeSeconds: Double
    var peakTemperatureCelsius: Double?
    var hotSeconds: TimeInterval
    var throttledSeconds: TimeInterval
    var lastStorageBytesWritten: UInt64?
    var storageBytesWritten: UInt64

    static func empty(at date: Date, calendar: Calendar) -> DailyHealthHistory {
        DailyHealthHistory(
            dayStart: calendar.startOfDay(for: date),
            lastSampleAt: nil,
            temperatureSampleSeconds: 0,
            temperatureDegreeSeconds: 0,
            peakTemperatureCelsius: nil,
            hotSeconds: 0,
            throttledSeconds: 0,
            lastStorageBytesWritten: nil,
            storageBytesWritten: 0
        )
    }

    var averageTemperatureCelsius: Double? {
        guard temperatureSampleSeconds > 0 else { return nil }
        return temperatureDegreeSeconds / temperatureSampleSeconds
    }

    mutating func record(
        thermal: ThermalSnapshot,
        storageBytesWrittenCounter: UInt64?,
        at date: Date,
        calendar: Calendar
    ) {
        if !calendar.isDate(dayStart, inSameDayAs: date) {
            self = Self.empty(at: date, calendar: calendar)
        }

        if let temperature = thermal.processorTemperatureCelsius {
            peakTemperatureCelsius = max(peakTemperatureCelsius ?? temperature, temperature)
            if let lastSampleAt {
                // Sleeping or a stalled process must not be counted as hours of
                // heat. Normal polling is every five seconds; fifteen seconds
                // keeps small scheduling delays honest without filling gaps.
                let elapsed = min(15, max(0, date.timeIntervalSince(lastSampleAt)))
                temperatureSampleSeconds += elapsed
                temperatureDegreeSeconds += temperature * elapsed
                if temperature >= ThermalSnapshot.warningThresholdCelsius {
                    hotSeconds += elapsed
                }
                if thermal.state.shouldShowWarning {
                    throttledSeconds += elapsed
                }
            }
        }
        lastSampleAt = date

        if let counter = storageBytesWrittenCounter {
            if let previous = lastStorageBytesWritten, counter >= previous {
                storageBytesWritten &+= counter - previous
            }
            // A lower counter means the controller reset, normally at reboot.
            lastStorageBytesWritten = counter
        }
    }
}

struct MacHealthSnapshot: Equatable, Sendable {
    let level: MacHealthLevel
    let batteryDetail: String
    let storageDetail: String
    let heatDetail: String
    let reliabilityDetail: String
    let panic: PanicHealthPresentation?
    let issues: [String]
    let shouldShowStatusAlert: Bool

    var title: String { "Mac Health: \(level.rawValue)" }
    var alertDetail: String { issues.first ?? "Mac health needs attention" }
}

struct PanicHealthPresentation: Equatable, Sendable {
    let signature: String
    let classification: String
    let occurrenceCount: Int
    let incidentID: String?
    let reportPath: String
    let taskContext: String?
    let compressorStatus: String?
    let postRebootContext: PanicContextSnapshot?
    let isNew: Bool
}

final class MacHealthMonitor {
    private enum Keys {
        static let history = "macHealthDailyHistoryV1"
    }

    private let hardwareProvider: HealthHardwareProviding
    private let panicMonitor: PanicMonitoring
    private let defaults: PreferencesStore
    private let calendar: Calendar
    private let hardwareRefreshInterval: TimeInterval
    private var hardware: HealthHardwareSnapshot?
    private var panicSnapshot = PanicScanSnapshot.empty
    private var lastHardwareRefreshAt: Date?
    private var lastPersistedAt: Date?
    private var history: DailyHealthHistory

    init(
        hardwareProvider: HealthHardwareProviding = MacHealthHardwareProvider(),
        panicMonitor: PanicMonitoring? = nil,
        defaults: PreferencesStore = UserDefaults.standard,
        calendar: Calendar = .current,
        hardwareRefreshInterval: TimeInterval = 300,
        now: Date = Date()
    ) {
        self.hardwareProvider = hardwareProvider
        self.panicMonitor = panicMonitor ?? PanicMonitor(defaults: defaults)
        self.defaults = defaults
        self.calendar = calendar
        self.hardwareRefreshInterval = hardwareRefreshInterval
        if let data = defaults.data(forKey: Keys.history),
           let stored = try? JSONDecoder().decode(DailyHealthHistory.self, from: data) {
            self.history = stored
        } else {
            self.history = .empty(at: now, calendar: calendar)
        }
    }

    func update(thermal: ThermalSnapshot, at date: Date = Date()) -> MacHealthSnapshot {
        if hardware == nil
            || lastHardwareRefreshAt.map({ date.timeIntervalSince($0) >= hardwareRefreshInterval }) == true {
            hardware = hardwareProvider.currentHealthHardware(at: date)
            panicSnapshot = panicMonitor.scan(
                at: date,
                temperatureCelsius: thermal.processorTemperatureCelsius
            )
            lastHardwareRefreshAt = date
        }

        history.record(
            thermal: thermal,
            storageBytesWrittenCounter: hardware?.storage?.bytesWrittenCounter,
            at: date,
            calendar: calendar
        )
        if lastPersistedAt == nil
            || lastPersistedAt.map({ date.timeIntervalSince($0) >= 60 }) == true {
            persistHistory(at: date)
        }

        return presentation(thermal: thermal, hardware: hardware, panic: panicSnapshot)
    }

    private func persistHistory(at date: Date) {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Keys.history)
            lastPersistedAt = date
        }
    }

    private func presentation(
        thermal: ThermalSnapshot,
        hardware: HealthHardwareSnapshot?,
        panic: PanicScanSnapshot
    ) -> MacHealthSnapshot {
        var issues: [String] = []
        var needsIndependentStatusAlert = false

        if thermal.shouldShowWarning {
            issues.append("Processor temperature is high")
            // The existing red live-temperature display is already the alert.
        }
        if history.hotSeconds >= 30 * 60 {
            issues.append("Sustained high temperature today")
            needsIndependentStatusAlert = !thermal.shouldShowWarning
        }
        if history.throttledSeconds >= 5 * 60 {
            issues.append("Sustained thermal throttling today")
            needsIndependentStatusAlert = !thermal.shouldShowWarning
        }

        let batteryDetail: String
        if let battery = hardware?.battery {
            let capacity = battery.maximumCapacityPercent.map { "\($0)%" } ?? "—"
            let cycles = battery.cycleCount.map { "\($0) cycles" } ?? "cycles —"
            batteryDetail = "Battery Health: \(capacity) · \(cycles)"
            if battery.condition == "Service Recommended"
                || (battery.maximumCapacityPercent ?? 100) < 80 {
                issues.append("Battery service is recommended")
                needsIndependentStatusAlert = true
            }
            if (battery.cycleCount ?? 0) >= 1_000 {
                issues.append("Battery has reached its rated cycle count")
                needsIndependentStatusAlert = true
            }
            if let temperature = battery.temperatureCelsius, temperature >= 40 {
                issues.append("Battery temperature is high")
                needsIndependentStatusAlert = true
            }
        } else {
            batteryDetail = "Battery Health: —"
        }

        let storageDetail: String
        if let storage = hardware?.storage {
            let smart = storage.smartStatus ?? "Unknown"
            let used = storage.usedPercent.map { "\($0)% used" } ?? "usage —"
            let written = history.storageBytesWritten == 0
                ? "0 B"
                : ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: history.storageBytesWritten),
                    countStyle: .file
                )
            storageDetail = "Storage: \(smart) · \(used) · \(written) written today"
            if let status = storage.smartStatus, status != "Verified" {
                issues.append("Storage health is \(status.lowercased())")
                needsIndependentStatusAlert = true
            }
            if (storage.usedPercent ?? 0) >= 90 {
                issues.append("Storage is nearly full")
                needsIndependentStatusAlert = true
            }
            if (storage.readErrors ?? 0) > 0 || (storage.writeErrors ?? 0) > 0 {
                issues.append("Storage controller errors were detected")
                needsIndependentStatusAlert = true
            }
        } else {
            storageDetail = "Storage: —"
        }

        let average = history.averageTemperatureCelsius
            ?? thermal.processorTemperatureCelsius
        let peak = history.peakTemperatureCelsius
            ?? thermal.processorTemperatureCelsius
        let averageText = average.map { "\(Int($0.rounded()))° avg" } ?? "avg —"
        let peakText = peak.map { "\(Int($0.rounded()))° peak" } ?? "peak —"
        let hotMinutes = Int(history.hotSeconds / 60)
        var heatDetail = "Heat Today: \(averageText) · \(peakText) · \(hotMinutes)m ≥90°"
        let throttledMinutes = Int(history.throttledSeconds / 60)
        if throttledMinutes > 0 {
            heatDetail += " · \(throttledMinutes)m thermal pressure"
        }

        let panicCount = panic.recentCount
        let latestPanic = panic.latest
        let reliabilityDetail = panicCount == 0
            ? "Reliability: No panics in 30 days"
            : "Reliability: \(panicCount) panic\(panicCount == 1 ? "" : "s") in 30 days"
                + (latestPanic.map { " · \($0.report.signature)" } ?? "")
        if panicCount > 0 {
            if let report = latestPanic?.report {
                issues.append("\(report.classification): \(report.signature)")
            } else {
                issues.append("A recent kernel panic was detected")
            }
            needsIndependentStatusAlert = true
        }

        let panicPresentation = latestPanic.map { entry in
            PanicHealthPresentation(
                signature: entry.report.signature,
                classification: entry.report.classification,
                occurrenceCount: panic.fingerprintCount,
                incidentID: entry.report.incidentID,
                reportPath: entry.report.path,
                taskContext: entry.report.taskContext,
                compressorStatus: entry.report.compressorStatus,
                postRebootContext: entry.postRebootContext,
                isNew: panic.newlyDetected?.report.identity == entry.report.identity
            )
        }

        return MacHealthSnapshot(
            level: issues.isEmpty ? .good : .attention,
            batteryDetail: batteryDetail,
            storageDetail: storageDetail,
            heatDetail: heatDetail,
            reliabilityDetail: reliabilityDetail,
            panic: panicPresentation,
            issues: issues,
            shouldShowStatusAlert: needsIndependentStatusAlert
        )
    }
}

final class MacHealthHardwareProvider: HealthHardwareProviding {
    func currentHealthHardware(at date: Date) -> HealthHardwareSnapshot {
        HealthHardwareSnapshot(
            battery: batteryHealth(),
            storage: storageHealth()
        )
    }

    private func batteryHealth() -> BatteryHealthSnapshot? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let properties = properties(for: service) else { return nil }

        let maximumCapacity: Int?
        if let percentage = number(properties["MaxCapacity"]), (0...100).contains(percentage) {
            maximumCapacity = Int(percentage.rounded())
        } else if let current = number(properties["AppleRawMaxCapacity"]),
                  let design = number(properties["DesignCapacity"]),
                  design > 0 {
            maximumCapacity = min(100, Int((current / design * 100).rounded()))
        } else {
            maximumCapacity = nil
        }
        let permanentFailure = number(properties["PermanentFailureStatus"]) ?? 0
        let condition = permanentFailure != 0 || (maximumCapacity ?? 100) < 80
            ? "Service Recommended"
            : "Good"
        return BatteryHealthSnapshot(
            maximumCapacityPercent: maximumCapacity,
            cycleCount: number(properties["CycleCount"]).map { Int($0.rounded()) },
            condition: condition,
            temperatureCelsius: number(properties["Temperature"]).map { $0 / 100 }
        )
    }

    private func storageHealth() -> StorageHealthSnapshot? {
        let disk = diskInfo()
        let controller = storageControllerStatistics()
        let volumeURL = URL(fileURLWithPath: "/System/Volumes/Data")
        let values = try? volumeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let usedPercent: Int?
        if let total = values?.volumeTotalCapacity,
           let available = values?.volumeAvailableCapacity.map(Int64.init)
                ?? values?.volumeAvailableCapacityForImportantUsage,
           total > 0 {
            usedPercent = min(100, max(0, Int(
                ((1 - Double(available) / Double(total)) * 100).rounded()
            )))
        } else {
            usedPercent = nil
        }

        guard disk != nil || controller != nil || usedPercent != nil else { return nil }
        return StorageHealthSnapshot(
            smartStatus: disk?["SMARTStatus"] as? String,
            usedPercent: usedPercent,
            bytesWrittenCounter: controller?.bytesWritten,
            readErrors: controller?.readErrors,
            writeErrors: controller?.writeErrors
        )
    }

    private func diskInfo() -> [String: Any]? {
        guard let data = BoundedProcess.output(
            executable: "/usr/sbin/diskutil",
            arguments: ["info", "-plist", "disk0"]
        ) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
    }

    private func storageControllerStatistics() -> (
        bytesWritten: UInt64,
        readErrors: UInt64,
        writeErrors: UInt64
    )? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleNVMeController")
        )
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

        var best: (UInt64, UInt64, UInt64)?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let properties = properties(for: entry),
                  let statistics = properties["Statistics"] as? [String: Any],
                  let bytesWritten = unsignedNumber(statistics["Bytes (Write)"])
            else { continue }
            let candidate = (
                bytesWritten,
                unsignedNumber(statistics["Errors (Read)"]) ?? 0,
                unsignedNumber(statistics["Errors (Write)"]) ?? 0
            )
            if best == nil || candidate.0 > best!.0 { best = candidate }
        }
        return best
    }

    private func properties(for service: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private func unsignedNumber(_ value: Any?) -> UInt64? {
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }
}
