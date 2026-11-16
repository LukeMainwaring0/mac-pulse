import Foundation

struct MetricHistoryPoint: Equatable {
    let capturedAt: Date
    let value: Double
}

struct RecentMetricHistory {
    static let retention: TimeInterval = 10 * 60
    /// Speed tests run every 15 to 60 minutes, so download keeps a day.
    static let downloadRetention: TimeInterval = 24 * 60 * 60
    static let maximumPointsPerMetric = 620
    static let maximumRenderedPoints = 90

    private(set) var download: [MetricHistoryPoint] = []
    private(set) var memory: [MetricHistoryPoint] = []
    private(set) var temperature: [MetricHistoryPoint] = []
    /// Smoothed total CPU use, 0–100.
    private(set) var cpu: [MetricHistoryPoint] = []
    /// Smoothed GPU use, 0–100.
    private(set) var gpu: [MetricHistoryPoint] = []
    /// Smoothed system power use, in watts.
    private(set) var power: [MetricHistoryPoint] = []

    mutating func recordDownload(megabitsPerSecond: Double, at date: Date) {
        guard megabitsPerSecond.isFinite, megabitsPerSecond >= 0 else { return }
        Self.append(
            MetricHistoryPoint(capturedAt: date, value: megabitsPerSecond),
            to: &download,
            now: date,
            retention: Self.downloadRetention
        )
    }

    mutating func recordSystem(memoryUsedBytes: UInt64?, temperatureCelsius: Double?, at date: Date) {
        if let memoryUsedBytes {
            Self.append(
                MetricHistoryPoint(
                    capturedAt: date,
                    value: Double(memoryUsedBytes) / Double(1 << 30)
                ),
                to: &memory,
                now: date
            )
        }
        if let temperatureCelsius,
           temperatureCelsius.isFinite,
           temperatureCelsius > 0 {
            Self.append(
                MetricHistoryPoint(capturedAt: date, value: temperatureCelsius),
                to: &temperature,
                now: date
            )
        }
    }

    mutating func recordCPU(percent: Double, at date: Date) {
        guard percent.isFinite else { return }
        Self.append(MetricHistoryPoint(capturedAt: date, value: min(100, max(0, percent))), to: &cpu, now: date)
    }

    mutating func recordGPU(percent: Double, at date: Date) {
        guard percent.isFinite else { return }
        Self.append(MetricHistoryPoint(capturedAt: date, value: min(100, max(0, percent))), to: &gpu, now: date)
    }

    mutating func recordPower(watts: Double, at date: Date) {
        guard watts.isFinite, watts >= 0 else { return }
        Self.append(MetricHistoryPoint(capturedAt: date, value: watts), to: &power, now: date)
    }

    var downloadValues: [Double] {
        renderedValues(download)
    }

    var memoryValues: [Double] {
        renderedValues(memory)
    }

    var temperatureValues: [Double] {
        renderedValues(temperature)
    }

    private static func append(
        _ point: MetricHistoryPoint,
        to points: inout [MetricHistoryPoint],
        now: Date,
        retention: TimeInterval = Self.retention
    ) {
        points.append(point)
        points.removeAll {
            $0.capturedAt < now.addingTimeInterval(-retention)
        }
        if points.count > Self.maximumPointsPerMetric {
            points.removeFirst(points.count - Self.maximumPointsPerMetric)
        }
    }

    private func renderedValues(_ points: [MetricHistoryPoint]) -> [Double] {
        guard points.count > Self.maximumRenderedPoints else {
            return points.map(\.value)
        }

        let lastIndex = points.count - 1
        let denominator = Self.maximumRenderedPoints - 1
        return (0..<Self.maximumRenderedPoints).map { outputIndex in
            let sourceIndex = Int(
                (Double(outputIndex) * Double(lastIndex) / Double(denominator)).rounded()
            )
            return points[sourceIndex].value
        }
    }
}
