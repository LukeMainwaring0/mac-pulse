import Darwin
import Foundation
import IOKit
import IOKit.ps

enum BatteryFlow: String, Equatable, Sendable {
    case charging
    case discharging
    case charged
    case pluggedIn
}

enum MacThermalState: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    /// macOS already combines the Mac's available temperature sensors and
    /// cooling capacity into this state. Warn only once heat is high enough to
    /// materially reduce performance, rather than reacting to normal warmth.
    var shouldShowWarning: Bool {
        self == .serious || self == .critical
    }

}

struct ThermalSnapshot: Equatable, Sendable {
    static let warningThresholdCelsius = 90.0

    let state: MacThermalState
    let processorTemperatureCelsius: Double?

    /// A real die temperature of 90 C is enough to warn before macOS enters
    /// heavy thermal mitigation. Keep the system thermal state as a fallback
    /// because it accounts for cooling conditions beyond a single sensor.
    var shouldShowWarning: Bool {
        state.shouldShowWarning
            || (processorTemperatureCelsius ?? -.infinity) >= Self.warningThresholdCelsius
    }

    var compactValue: String {
        guard let processorTemperatureCelsius else { return "—" }
        return "\(Int(processorTemperatureCelsius.rounded()))°"
    }

    var detail: String {
        guard let processorTemperatureCelsius else { return "Temperature: —" }
        return "Temperature: \(Int(processorTemperatureCelsius.rounded()))°C"
    }
}

private typealias HIDClient = OpaquePointer
private typealias HIDService = OpaquePointer
private typealias HIDEvent = OpaquePointer

@_silgen_name("IOHIDEventSystemClientCreate")
private func createHIDEventSystemClient(_ allocator: CFAllocator?) -> HIDClient?

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func copyHIDServices(_ client: HIDClient) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func copyHIDServiceProperty(
    _ service: HIDService,
    _ key: CFString
) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func copyHIDServiceEvent(
    _ service: HIDService,
    _ type: Int64,
    _ matching: HIDEvent?,
    _ options: UInt32
) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetFloatValue")
private func hidEventFloatValue(_ event: HIDEvent, _ field: Int32) -> Double

protocol ProcessorTemperatureProviding {
    func hottestDieTemperatureCelsius() -> Double?
}

/// Reads the hottest processor-die sensor exposed by Apple Silicon's PMU HID
/// services. These are the same physical tdie sensors surfaced by system
/// monitoring tools and require neither a helper process nor administrator
/// privileges.
final class AppleSiliconTemperatureProvider: ProcessorTemperatureProviding {
    private let client = createHIDEventSystemClient(kCFAllocatorDefault)
    private let temperatureEventType: Int64 = 15
    private let temperatureLevelField: Int32 = 15 << 16

    func hottestDieTemperatureCelsius() -> Double? {
        guard let client,
              let services = copyHIDServices(client)?.takeRetainedValue()
        else { return nil }

        var hottest: Double?
        for index in 0..<CFArrayGetCount(services) {
            guard let rawService = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = HIDService(rawService)
            guard let product = copyHIDServiceProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String,
                  product.hasPrefix("PMU tdie"),
                  let rawEvent = copyHIDServiceEvent(
                    service,
                    temperatureEventType,
                    nil,
                    0
                  )?.takeRetainedValue()
            else { continue }

            let event = HIDEvent(Unmanaged.passUnretained(rawEvent).toOpaque())
            let value = hidEventFloatValue(event, temperatureLevelField)
            guard value.isFinite, (0...125).contains(value) else { continue }
            hottest = max(hottest ?? value, value)
        }
        return hottest
    }
}

enum BatteryFlowResolver {
    /// Battery current is the source of truth when an attached adapter cannot
    /// keep up with the Mac's load. A small threshold avoids treating normal
    /// controller noise as meaningful discharge.
    static func resolve(
        percentage: Int,
        isCharging: Bool,
        isCharged: Bool,
        powerState: String?,
        amperageMa: Double?
    ) -> BatteryFlow {
        if isCharging {
            return .charging
        }
        if powerState == "AC Power", let amperageMa, amperageMa <= -100 {
            return .discharging
        }
        if isCharged || (percentage == 100 && powerState == "AC Power") {
            return .charged
        }
        if powerState == "AC Power" {
            return .pluggedIn
        }
        return .discharging
    }
}

struct MemorySnapshot: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64
}

struct BatterySnapshot: Equatable, Sendable {
    let percentage: Int
    let flow: BatteryFlow
    let estimate: BatteryTimeEstimate
    let amperageMa: Double?
    let voltageMv: Double?
    let temperatureCelsius: Double?
    let systemLoadMw: Double?
    /// Power arriving from the charger, when one is connected.
    let systemPowerInMw: Double?
    /// The connected charger's rated wattage.
    let adapterWatts: Double?

    /// Minutes until empty while discharging or until 80% while charging.
    var timeRemainingMinutes: Int? { estimate.minutes }

    /// Above 80%, power-connected battery information is intentionally hidden
    /// so it stops taking menu-bar space once the useful charging target has
    /// already been reached. A battery that is actually draining remains
    /// visible even when an adapter is attached.
    var shouldShowInStatus: Bool {
        flow == .discharging || percentage <= 80
    }

    init(
        percentage: Int,
        flow: BatteryFlow,
        estimate: BatteryTimeEstimate,
        amperageMa: Double? = nil,
        voltageMv: Double? = nil,
        temperatureCelsius: Double? = nil,
        systemLoadMw: Double? = nil,
        systemPowerInMw: Double? = nil,
        adapterWatts: Double? = nil
    ) {
        self.percentage = percentage
        self.flow = flow
        self.estimate = estimate
        self.amperageMa = amperageMa
        self.voltageMv = voltageMv
        self.temperatureCelsius = temperatureCelsius
        self.systemLoadMw = systemLoadMw
        self.systemPowerInMw = systemPowerInMw
        self.adapterWatts = adapterWatts
    }

    init(percentage: Int, flow: BatteryFlow, timeRemainingMinutes: Int?) {
        self.init(
            percentage: percentage,
            flow: flow,
            estimate: BatteryTimeEstimate(
                minutes: timeRemainingMinutes,
                lowerBoundMinutes: nil,
                upperBoundMinutes: nil,
                confidence: .learning,
                method: "Apple gauge",
                sampleWindowMinutes: 0
            )
        )
    }
}

struct SystemSnapshot: Equatable, Sendable {
    let memory: MemorySnapshot?
    let battery: BatterySnapshot?
    let thermal: ThermalSnapshot
    let capturedAt: Date
}

protocol SystemStatsProviding {
    func currentSnapshot() -> SystemSnapshot
}

final class SystemStatsProvider: SystemStatsProviding {
    private let batteryEstimator: BatteryEstimator
    private let temperatureProvider: ProcessorTemperatureProviding

    init(
        batteryEstimator: BatteryEstimator = BatteryEstimator(),
        temperatureProvider: ProcessorTemperatureProviding = AppleSiliconTemperatureProvider()
    ) {
        self.batteryEstimator = batteryEstimator
        self.temperatureProvider = temperatureProvider
    }

    func currentSnapshot() -> SystemSnapshot {
        let capturedAt = Date()
        return SystemSnapshot(
            memory: currentMemory(),
            battery: currentBattery(capturedAt: capturedAt),
            thermal: ThermalSnapshot(
                state: MacThermalState(ProcessInfo.processInfo.thermalState),
                processorTemperatureCelsius: temperatureProvider.hottestDieTemperatureCelsius()
            ),
            capturedAt: capturedAt
        )
    }

    private func currentMemory() -> MemorySnapshot? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedBytes = MemoryAccounting.activityMonitorUsedBytes(
            totalBytes: totalBytes,
            freePages: UInt64(statistics.free_count),
            fileBackedPages: UInt64(statistics.external_page_count),
            pageSize: UInt64(pageSize)
        )

        return MemorySnapshot(usedBytes: usedBytes, totalBytes: totalBytes)
    }

    private func currentBattery(capturedAt: Date) -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery",
                  description["Is Present"] as? Bool != false
            else { continue }

            let currentCapacity = description["Current Capacity"] as? Int ?? 0
            let maximumCapacity = max(1, description["Max Capacity"] as? Int ?? 100)
            let percentage = min(100, max(0, Int(
                (Double(currentCapacity) / Double(maximumCapacity) * 100).rounded()
            )))
            let isCharging = description["Is Charging"] as? Bool ?? false
            let isCharged = description["Is Charged"] as? Bool ?? false
            let powerState = description["Power Source State"] as? String
            let registry = smartBatteryProperties()
            let amperage = number(registry, keys: ["InstantAmperage", "Amperage"])

            let flow = BatteryFlowResolver.resolve(
                percentage: percentage,
                isCharging: isCharging,
                isCharged: isCharged,
                powerState: powerState,
                amperageMa: amperage
            )
            let rawMinutes: Int?
            switch flow {
            case .charged, .pluggedIn:
                rawMinutes = nil
            case .charging:
                rawMinutes = description["Time to Full Charge"] as? Int
            case .discharging:
                rawMinutes = description["Time to Empty"] as? Int
            }

            let minutes = rawMinutes.flatMap { value in
                // IOKit uses negative and very large sentinel values while it
                // is still calculating an estimate.
                (1...(48 * 60)).contains(value) ? value : nil
            }
            let rawCurrent = number(registry, keys: ["AppleRawCurrentCapacity", "CurrentCapacity"])
            let rawMaximum = number(registry, keys: ["AppleRawMaxCapacity", "NominalChargeCapacity"])
            let voltage = number(registry, keys: ["AppleRawBatteryVoltage", "Voltage"])
            let rawTemperature = number(registry, keys: ["Temperature"])
            let powerTelemetry = registry["PowerTelemetryData"] as? [String: Any] ?? [:]
            let systemLoad = number(powerTelemetry, keys: ["SystemLoad"])
            let powerIn = number(powerTelemetry, keys: ["SystemPowerIn"])
            let adapter = registry["AdapterDetails"] as? [String: Any] ?? [:]
            let adapterWatts = number(adapter, keys: ["Watts"])
            let telemetry = BatteryTelemetry(
                capturedAt: capturedAt,
                percentage: percentage,
                flow: flow,
                systemEstimateMinutes: minutes,
                currentCapacityMah: positive(rawCurrent),
                maximumCapacityMah: positive(rawMaximum),
                amperageMa: amperage,
                voltageMv: positive(voltage),
                temperatureCelsius: rawTemperature.map { $0 / 100 },
                systemLoadMw: positive(systemLoad)
            )
            let estimate = batteryEstimator.update(with: telemetry)
            return BatterySnapshot(
                percentage: percentage,
                flow: flow,
                estimate: estimate,
                amperageMa: amperage,
                voltageMv: positive(voltage),
                temperatureCelsius: rawTemperature.map { $0 / 100 },
                systemLoadMw: positive(systemLoad),
                systemPowerInMw: positive(powerIn),
                adapterWatts: positive(adapterWatts)
            )
        }

        return nil
    }

    private func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dictionary
    }

    private func number(_ properties: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = properties[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = properties[key] as? Double { return value }
            if let value = properties[key] as? Int { return Double(value) }
        }
        return nil
    }

    private func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

enum MemoryAccounting {
    /// Matches Activity Monitor's headline "Memory Used" value. Its total is
    /// physical memory less free and file-backed pages. Purgeable pages remain
    /// counted here, even though Activity Monitor also includes them in its
    /// separate Cached Files figure.
    static func activityMonitorUsedBytes(
        totalBytes: UInt64,
        freePages: UInt64,
        fileBackedPages: UInt64,
        pageSize: UInt64
    ) -> UInt64 {
        let reclaimablePages = freePages.addingReportingOverflow(fileBackedPages)
        guard !reclaimablePages.overflow else { return 0 }
        let reclaimableBytes = reclaimablePages.partialValue.multipliedReportingOverflow(by: pageSize)
        guard !reclaimableBytes.overflow else { return 0 }
        return totalBytes - min(totalBytes, reclaimableBytes.partialValue)
    }
}

enum SystemStatsFormatting {
    /// Menu bar form. "GB" is gigabytes; "Gb" would mean gigabits.
    static func compactMemory(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / Double(1 << 30)
        if gigabytes < 10 {
            return String(format: "%.1fGB", gigabytes)
        }
        return String(format: "%.0fGB", gigabytes)
    }

    /// Popover form, spaced the way macOS writes sizes ("105 GB").
    static func memoryValue(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / Double(1 << 30)
        return gigabytes < 10
            ? String(format: "%.1f GB", gigabytes)
            : String(format: "%.0f GB", gigabytes)
    }

    static func detailedMemory(_ memory: MemorySnapshot) -> String {
        let used = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: memory.usedBytes),
            countStyle: .memory
        )
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: memory.totalBytes),
            countStyle: .memory
        )
        return "\(used) used of \(total)"
    }

    static func compactBattery(_ battery: BatterySnapshot) -> String {
        switch battery.flow {
        case .charged:
            return "B\(compactDuration(battery.timeRemainingMinutes))"
        case .pluggedIn:
            return "B↯"
        case .charging:
            return "B↑\(compactDuration(battery.timeRemainingMinutes))"
        case .discharging:
            return "B↓\(compactDuration(battery.timeRemainingMinutes))"
        }
    }

    static func batteryDetail(_ battery: BatterySnapshot) -> String {
        let prefix = "\(battery.percentage)%"
        switch battery.flow {
        case .charged:
            guard let minutes = battery.timeRemainingMinutes else {
                return "\(prefix) · Estimating battery time"
            }
            return "\(prefix) · \(detailedDuration(minutes)) of battery"
        case .pluggedIn:
            guard let minutes = battery.timeRemainingMinutes else {
                return "\(prefix) · Estimating battery time"
            }
            return "\(prefix) · \(detailedDuration(minutes)) of battery"
        case .charging:
            if battery.percentage >= 80 {
                return prefix
            }
            guard let minutes = battery.timeRemainingMinutes else {
                return "\(prefix) · Estimating time to 80%"
            }
            return "\(prefix) · \(detailedDuration(minutes)) to 80%"
        case .discharging:
            guard let minutes = battery.timeRemainingMinutes else {
                return "\(prefix) · Estimating time remaining"
            }
            return "\(prefix) · \(detailedDuration(minutes)) remaining"
        }
    }

    static func batteryRangeDetail(_ battery: BatterySnapshot) -> String? {
        guard let lower = battery.estimate.lowerBoundMinutes,
              let upper = battery.estimate.upperBoundMinutes,
              lower < upper
        else { return nil }
        return "Likely range: \(detailedDuration(lower))–\(detailedDuration(upper))"
    }

    static func batteryConfidenceDetail(_ battery: BatterySnapshot) -> String {
        let confidence: String
        switch battery.estimate.confidence {
        case .learning: confidence = "Learning"
        case .low: confidence = "Low"
        case .medium: confidence = "Medium"
        case .high: confidence = "High"
        }
        let window = battery.estimate.sampleWindowMinutes
        let sample: String
        if window < 1 {
            sample = "just started"
        } else {
            sample = "\(Int(window.rounded())) min local history"
        }
        return "Confidence: \(confidence) · \(sample)"
    }

    static func compactDuration(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "…" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        if hours >= 10 || remainder == 0 { return "\(hours)h" }
        return "\(hours)h\(remainder)"
    }

    static func detailedDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }
}
