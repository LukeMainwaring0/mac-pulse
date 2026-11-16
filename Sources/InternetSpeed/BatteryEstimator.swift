import Foundation

enum BatteryEstimateConfidence: String, Equatable, Sendable {
    case learning
    case low
    case medium
    case high
}

struct BatteryTimeEstimate: Equatable, Sendable {
    let minutes: Int?
    let lowerBoundMinutes: Int?
    let upperBoundMinutes: Int?
    let confidence: BatteryEstimateConfidence
    let method: String
    let sampleWindowMinutes: Double

    static let unavailable = BatteryTimeEstimate(
        minutes: nil,
        lowerBoundMinutes: nil,
        upperBoundMinutes: nil,
        confidence: .learning,
        method: "Learning local trend",
        sampleWindowMinutes: 0
    )
}

struct BatteryTelemetry: Equatable, Sendable {
    let capturedAt: Date
    let percentage: Int
    let flow: BatteryFlow
    let systemEstimateMinutes: Int?
    let currentCapacityMah: Double?
    let maximumCapacityMah: Double?
    let amperageMa: Double?
    let voltageMv: Double?
    let temperatureCelsius: Double?
    /// Current whole-system load reported by the battery controller.
    let systemLoadMw: Double?
}

/// Combines Apple's battery-gauge estimate with instantaneous electrical data
/// and a rolling local capacity trend. No single source is reliable across all
/// workloads, so the estimator reports both a smoothed best estimate and an
/// uncertainty range.
final class BatteryEstimator {
    private static let chargingTargetFraction = 0.80

    private struct Sample {
        let date: Date
        let capacityMah: Double
        let amperageMa: Double?
    }

    private struct Candidate {
        let name: String
        let minutes: Double
        let weight: Double
    }

    private struct PowerSample {
        let date: Date
        let milliwatts: Double
    }

    private var samples: [Sample] = []
    private var powerSamples: [PowerSample] = []
    private var previousFlow: BatteryFlow?
    private var previousEstimate: Double?
    private var previousEstimateDate: Date?
    private var lastUpdateDate: Date?

    func update(with telemetry: BatteryTelemetry) -> BatteryTimeEstimate {
        if isLongGap(at: telemetry.capturedAt) {
            resetAll(for: telemetry.flow)
        } else if previousFlow != telemetry.flow {
            reset(for: telemetry.flow)
        }
        previousFlow = telemetry.flow
        lastUpdateDate = telemetry.capturedAt
        appendPowerSample(telemetry)

        if telemetry.flow == .charged || telemetry.flow == .pluggedIn {
            return chargedRuntimeEstimate(telemetry)
        }
        guard telemetry.flow == .charging || telemetry.flow == .discharging else {
            return .unavailable
        }

        appendSample(telemetry)

        var candidates: [Candidate] = []
        if let appleToFull = validMinutes(telemetry.systemEstimateMinutes.map(Double.init)) {
            if telemetry.flow == .charging {
                if let appleToTarget = chargingTargetEstimate(
                    fromFullEstimate: appleToFull,
                    telemetry: telemetry
                ) {
                    candidates.append(Candidate(name: "Apple gauge", minutes: appleToTarget, weight: 0.58))
                }
            } else {
                candidates.append(Candidate(name: "Apple gauge", minutes: appleToFull, weight: 0.58))
            }
        }
        if let electrical = electricalEstimate(telemetry) {
            candidates.append(Candidate(name: "live current", minutes: electrical, weight: 0.27))
        }
        if let trend = capacityTrendEstimate(telemetry) {
            let window = sampleWindowMinutes
            candidates.append(Candidate(
                name: "local trend",
                minutes: trend,
                weight: window >= 8 ? 0.45 : 0.30
            ))
        }

        guard !candidates.isEmpty else {
            previousEstimate = nil
            previousEstimateDate = telemetry.capturedAt
            return .unavailable
        }

        let activeCandidates = robustCandidates(candidates)
        let rawEstimate = weightedEstimate(activeCandidates)
        let disagreement = relativeDisagreement(candidates)
        let currentVariation = amperageVariation
        let confidence = confidence(
            candidateCount: candidates.count,
            disagreement: disagreement,
            currentVariation: currentVariation
        )
        let smoothed = smooth(rawEstimate, at: telemetry.capturedAt, instability: max(disagreement, currentVariation))
        let rangeFraction: Double
        switch confidence {
        case .high: rangeFraction = 0.12
        case .medium: rangeFraction = 0.22
        case .low: rangeFraction = 0.35
        case .learning: rangeFraction = 0.45
        }
        let modelMinimum = activeCandidates.map(\.minutes).min() ?? smoothed
        let modelMaximum = activeCandidates.map(\.minutes).max() ?? smoothed
        let lower = max(1, min(smoothed * (1 - rangeFraction), modelMinimum * 0.92))
        let upper = min(2_880, max(smoothed * (1 + rangeFraction), modelMaximum * 1.08))
        let names = activeCandidates.map(\.name).joined(separator: " + ")

        return BatteryTimeEstimate(
            minutes: Int(smoothed.rounded()),
            lowerBoundMinutes: Int(lower.rounded(.down)),
            upperBoundMinutes: Int(upper.rounded(.up)),
            confidence: confidence,
            method: confidence == .learning ? "Learning · \(names)" : "Adaptive · \(names)",
            sampleWindowMinutes: sampleWindowMinutes
        )
    }

    private func reset(for flow: BatteryFlow) {
        samples.removeAll(keepingCapacity: true)
        previousFlow = flow
        previousEstimate = nil
        previousEstimateDate = nil
    }

    private func resetAll(for flow: BatteryFlow) {
        reset(for: flow)
        powerSamples.removeAll(keepingCapacity: true)
    }

    private func isLongGap(at date: Date) -> Bool {
        guard let last = lastUpdateDate else { return false }
        return date.timeIntervalSince(last) > 5 * 60 || date < last
    }

    private func appendPowerSample(_ telemetry: BatteryTelemetry) {
        guard let milliwatts = telemetry.systemLoadMw,
              milliwatts.isFinite,
              (1_000...200_000).contains(milliwatts)
        else { return }
        powerSamples.append(PowerSample(date: telemetry.capturedAt, milliwatts: milliwatts))
        let cutoff = telemetry.capturedAt.addingTimeInterval(-10 * 60)
        powerSamples.removeAll { $0.date < cutoff }
    }

    private func appendSample(_ telemetry: BatteryTelemetry) {
        guard let capacity = telemetry.currentCapacityMah, capacity > 0 else { return }
        samples.append(Sample(date: telemetry.capturedAt, capacityMah: capacity, amperageMa: telemetry.amperageMa))
        let cutoff = telemetry.capturedAt.addingTimeInterval(-30 * 60)
        samples.removeAll { $0.date < cutoff }
    }

    private var sampleWindowMinutes: Double {
        guard let first = samples.first?.date, let last = samples.last?.date else { return 0 }
        return max(0, last.timeIntervalSince(first) / 60)
    }

    private var powerSampleWindowMinutes: Double {
        guard let first = powerSamples.first?.date, let last = powerSamples.last?.date else { return 0 }
        return max(0, last.timeIntervalSince(first) / 60)
    }

    private func chargedRuntimeEstimate(_ telemetry: BatteryTelemetry) -> BatteryTimeEstimate {
        guard let currentCapacity = telemetry.currentCapacityMah,
              let maximumCapacity = telemetry.maximumCapacityMah,
              let voltageMv = telemetry.voltageMv,
              currentCapacity > 0,
              maximumCapacity > 0,
              voltageMv > 0,
              !powerSamples.isEmpty
        else { return .unavailable }

        let usableCapacityMah = min(currentCapacity, maximumCapacity) * 0.97
        // Infer the pack's series-cell count from its near-full voltage, then
        // use the cells' nominal (not peak) voltage for honest stored energy.
        let cellCount = min(6, max(1, Int((voltageMv / 4_400).rounded())))
        let nominalVoltage = Double(cellCount) * 3.85
        let usableEnergyMwh = usableCapacityMah * nominalVoltage

        let now = telemetry.capturedAt
        var weightedPower = 0.0
        var totalWeight = 0.0
        for sample in powerSamples {
            let age = max(0, now.timeIntervalSince(sample.date))
            let weight = exp(-age / 90)
            weightedPower += sample.milliwatts * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return .unavailable }
        let averagePower = weightedPower / totalWeight
        guard let minutes = validMinutes(usableEnergyMwh / averagePower * 60) else {
            return .unavailable
        }

        let powers = powerSamples.map(\.milliwatts).sorted()
        let lowPower = percentile(powers, fraction: 0.20)
        let highPower = percentile(powers, fraction: 0.80)
        let optimistic = min(2_880, usableEnergyMwh / max(1, lowPower) * 60)
        let pessimistic = max(1, usableEnergyMwh / max(1, highPower) * 60)
        let mean = powers.reduce(0, +) / Double(powers.count)
        let variance = powers.reduce(0) { $0 + pow($1 - mean, 2) } / Double(powers.count)
        let variation = mean > 0 ? min(1, sqrt(variance) / mean) : 1

        let confidence: BatteryEstimateConfidence
        let fallbackRange: Double
        switch (powerSampleWindowMinutes, variation) {
        case (8..., ..<0.15):
            confidence = .high
            fallbackRange = 0.12
        case (3..., ..<0.35):
            confidence = .medium
            fallbackRange = 0.22
        case (1..., _):
            confidence = .low
            fallbackRange = 0.35
        default:
            confidence = .learning
            fallbackRange = 0.45
        }

        let smoothed = smooth(minutes, at: now, instability: variation)
        let lower = min(pessimistic, smoothed * (1 - fallbackRange))
        let upper = max(optimistic, smoothed * (1 + fallbackRange))
        let energyWh = usableEnergyMwh / 1_000
        let powerW = averagePower / 1_000
        return BatteryTimeEstimate(
            minutes: Int(smoothed.rounded()),
            lowerBoundMinutes: Int(max(1, lower).rounded(.down)),
            upperBoundMinutes: Int(min(2_880, upper).rounded(.up)),
            confidence: confidence,
            method: String(format: "Energy forecast · %.0f Wh ÷ %.0f W current use", energyWh, powerW),
            sampleWindowMinutes: powerSampleWindowMinutes
        )
    }

    private func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let index = Int((Double(sortedValues.count - 1) * fraction).rounded())
        return sortedValues[min(sortedValues.count - 1, max(0, index))]
    }

    private var amperageVariation: Double {
        let values = samples.suffix(60).compactMap { $0.amperageMa.map(abs) }.filter { $0 >= 50 }
        guard values.count >= 3 else { return 0.35 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 1 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return min(1, sqrt(variance) / mean)
    }

    private func electricalEstimate(_ telemetry: BatteryTelemetry) -> Double? {
        guard let current = telemetry.currentCapacityMah,
              let maximum = telemetry.maximumCapacityMah,
              let amperage = telemetry.amperageMa.map(abs),
              maximum > 0, current >= 0, amperage >= 50
        else { return nil }

        let minutes: Double
        switch telemetry.flow {
        case .discharging:
            minutes = current / amperage * 60
        case .charging:
            minutes = taperedChargeMinutes(
                currentCapacity: current,
                maximumCapacity: maximum,
                currentAmperage: amperage
            )
        case .charged, .pluggedIn:
            return nil
        }
        return validMinutes(minutes)
    }

    /// Converts Apple's time-to-full gauge into time-to-80%. The conversion
    /// accounts for the slower charging bands above 80% instead of scaling by
    /// percentage alone.
    private func chargingTargetEstimate(
        fromFullEstimate fullMinutes: Double,
        telemetry: BatteryTelemetry
    ) -> Double? {
        let start: Double
        if let current = telemetry.currentCapacityMah,
           let maximum = telemetry.maximumCapacityMah,
           maximum > 0 {
            start = current / maximum
        } else {
            start = Double(telemetry.percentage) / 100
        }

        let targetWork = chargeWork(
            from: start,
            to: Self.chargingTargetFraction
        )
        let fullWork = chargeWork(from: start, to: 1)
        guard targetWork > 0, fullWork > 0 else { return nil }
        return validMinutes(fullMinutes * targetWork / fullWork)
    }

    /// Integrates the current charging rate only as far as the 80% target.
    private func taperedChargeMinutes(
        currentCapacity: Double,
        maximumCapacity: Double,
        currentAmperage: Double
    ) -> Double {
        let start = min(1, max(0, currentCapacity / maximumCapacity))
        let work = chargeWork(
            from: start,
            to: Self.chargingTargetFraction
        )
        return work * maximumCapacity / currentAmperage * 60
    }

    /// Relative charging work across the battery controller's four broad
    /// charging bands. A lower rate means more time per percentage point.
    private func chargeWork(from start: Double, to target: Double) -> Double {
        let bands: [(end: Double, rate: Double)] = [
            (0.80, 1.00),
            (0.90, 0.82),
            (0.95, 0.55),
            (1.00, 0.30)
        ]
        var cursor = min(1, max(0, start))
        let clampedTarget = min(1, max(cursor, target))
        var work = 0.0
        for band in bands {
            let bandEnd = min(band.end, clampedTarget)
            if cursor < bandEnd {
                work += (bandEnd - cursor) / band.rate
                cursor = bandEnd
            }
            if cursor >= clampedTarget { break }
        }
        return work
    }

    private func capacityTrendEstimate(_ telemetry: BatteryTelemetry) -> Double? {
        guard samples.count >= 4,
              sampleWindowMinutes >= 2,
              let firstDate = samples.first?.date,
              let current = telemetry.currentCapacityMah,
              let maximum = telemetry.maximumCapacityMah,
              maximum > 0
        else { return nil }

        let points = samples.map { (x: $0.date.timeIntervalSince(firstDate) / 3_600, y: $0.capacityMah) }
        let meanX = points.map(\.x).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
        let denominator = points.reduce(0) { $0 + pow($1.x - meanX, 2) }
        guard denominator > 0 else { return nil }
        let slope = points.reduce(0) { $0 + (($1.x - meanX) * ($1.y - meanY)) } / denominator
        guard abs(slope) >= max(20, maximum * 0.003) else { return nil }

        let minutes: Double
        switch telemetry.flow {
        case .discharging where slope < 0:
            minutes = current / abs(slope) * 60
        case .charging where slope > 0:
            minutes = taperedChargeMinutes(
                currentCapacity: current,
                maximumCapacity: maximum,
                currentAmperage: slope
            )
        default:
            return nil
        }
        return validMinutes(minutes)
    }

    private func robustCandidates(_ candidates: [Candidate]) -> [Candidate] {
        let median = candidates.map(\.minutes).sorted()[candidates.count / 2]
        let filtered = candidates.filter { candidate in
            candidates.count < 3 || abs(candidate.minutes - median) / max(1, median) <= 0.75
        }
        return filtered.isEmpty ? candidates : filtered
    }

    private func weightedEstimate(_ candidates: [Candidate]) -> Double {
        let weight = candidates.reduce(0) { $0 + $1.weight }
        return candidates.reduce(0) { $0 + ($1.minutes * $1.weight) } / weight
    }

    private func relativeDisagreement(_ candidates: [Candidate]) -> Double {
        guard candidates.count > 1 else { return 0.5 }
        let values = candidates.map(\.minutes)
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 1 }
        return min(1, ((values.max() ?? mean) - (values.min() ?? mean)) / mean)
    }

    private func confidence(
        candidateCount: Int,
        disagreement: Double,
        currentVariation: Double
    ) -> BatteryEstimateConfidence {
        guard sampleWindowMinutes >= 2 else { return .learning }
        if candidateCount >= 3, sampleWindowMinutes >= 8, disagreement < 0.20, currentVariation < 0.25 {
            return .high
        }
        if candidateCount >= 2, disagreement < 0.45, currentVariation < 0.55 {
            return .medium
        }
        return .low
    }

    private func smooth(_ target: Double, at date: Date, instability: Double) -> Double {
        defer {
            previousEstimateDate = date
        }
        guard let previousEstimate, let previousDate = previousEstimateDate else {
            self.previousEstimate = target
            return target
        }
        let elapsedMinutes = max(0, date.timeIntervalSince(previousDate) / 60)
        let naturallyAdvanced: Double
        if previousFlow == .charging || previousFlow == .discharging {
            naturallyAdvanced = max(1, previousEstimate - elapsedMinutes)
        } else {
            // A battery held on AC does not discharge, so this forecast changes
            // only when stored energy or observed system load changes.
            naturallyAdvanced = previousEstimate
        }
        let relativeChange = abs(target - naturallyAdvanced) / max(1, naturallyAdvanced)
        let alpha: Double
        if instability > 0.55 || relativeChange > 0.40 {
            alpha = 0.48
        } else if instability > 0.25 || relativeChange > 0.20 {
            alpha = 0.30
        } else {
            alpha = 0.16
        }
        let result = naturallyAdvanced + alpha * (target - naturallyAdvanced)
        self.previousEstimate = result
        return result
    }

    private func validMinutes(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (1...2_880).contains(value) else { return nil }
        return value
    }
}
