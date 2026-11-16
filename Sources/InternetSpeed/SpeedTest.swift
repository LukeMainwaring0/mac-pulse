import Foundation

/// One real download measurement from Apple's built-in speed test.
struct SpeedResult: Equatable, Sendable {
    let downloadMbps: Double
    let measuredAt: Date
    let bytesTransferred: Int64
}

enum SpeedTestError: LocalizedError, Equatable {
    case didNotFinish
    case unreadableResult

    var errorDescription: String? {
        switch self {
        case .didNotFinish: return "The speed test didn’t finish."
        case .unreadableResult: return "The speed test didn’t return a result."
        }
    }
}

protocol SpeedTesting: Sendable {
    func run() async throws -> SpeedResult
}

/// Runs macOS's networkQuality tool, download only, for a few seconds. It
/// opens many connections at once, so it measures the full speed of the line.
struct AppleSpeedTest: SpeedTesting {
    static let maximumSeconds = 4

    func run() async throws -> SpeedResult {
        try await Task.detached(priority: .utility) {
            guard let data = BoundedProcess.output(
                executable: "/usr/bin/networkQuality",
                arguments: ["-u", "-M", String(Self.maximumSeconds), "-c"],
                timeout: 25
            ) else { throw SpeedTestError.didNotFinish }
            return try Self.parse(data, at: Date())
        }.value
    }

    static func parse(_ data: Data, at date: Date) throws -> SpeedResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bitsPerSecond = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              bitsPerSecond.isFinite, bitsPerSecond > 0
        else { throw SpeedTestError.unreadableResult }
        let bytes = (json["dl_bytes_transferred"] as? NSNumber)?.int64Value ?? 0
        return SpeedResult(downloadMbps: bitsPerSecond / 1_000_000, measuredAt: date, bytesTransferred: bytes)
    }
}

protocol ConnectionChecking: Sendable {
    /// Milliseconds until Apple's server starts answering, or nil when unreachable.
    func responseTime() async -> Double?
}

/// Fetches Apple's 68-byte connectivity page. Reused connections keep this
/// to one round trip, so it shows congestion without moving real data.
final class ConnectionCheck: ConnectionChecking, @unchecked Sendable {
    private let url = URL(string: "https://www.apple.com/library/test/success.html")!
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
    }

    func responseTime() async -> Double? {
        let metrics = TransactionMetrics()
        let started = Date()
        guard let (_, response) = try? await session.data(from: url, delegate: metrics),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        // Time from request to first byte leaves out connection setup.
        if let transaction = metrics.last,
           let request = transaction.requestStartDate,
           let firstByte = transaction.responseStartDate {
            return firstByte.timeIntervalSince(request) * 1_000
        }
        return Date().timeIntervalSince(started) * 1_000
    }
}

private final class TransactionMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var last: URLSessionTaskTransactionMetrics?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        last = metrics.transactionMetrics.last
    }
}

enum SpeedTestReason: String, Sendable {
    case launch, wake, networkChange, manual, menuOpened, hourly, connectionWorse
}

/// When a real speed test is worth its data. Every test fully replaces the
/// last result, so there is no estimate that can drift or get stuck.
enum SpeedTestSchedule {
    /// Opening the menu refreshes anything older than this.
    static let menuFreshness: TimeInterval = 15 * 60
    /// The menu bar number is never older than this while online.
    static let backupInterval: TimeInterval = 60 * 60
    /// A slow connection can start at most one test in this window.
    static let slowConnectionCooldown: TimeInterval = 10 * 60
    /// A failed scheduled test waits this long before trying again.
    static let retryDelay: TimeInterval = 2 * 60
    /// Events that arrive together (wake plus network change) test once.
    static let eventDebounce: TimeInterval = 30

    static func shouldTest(
        _ reason: SpeedTestReason,
        lastResultAt: Date?,
        lastAttemptAt: Date?,
        isMeteredNetwork: Bool,
        isOffline: Bool,
        now: Date
    ) -> Bool {
        if reason == .manual { return true }
        // Hotspots and Low Data Mode only test when asked.
        guard !isMeteredNetwork, !isOffline else { return false }
        let age = lastResultAt.map { now.timeIntervalSince($0) } ?? .infinity
        let sinceAttempt = lastAttemptAt.map { now.timeIntervalSince($0) } ?? .infinity
        switch reason {
        case .launch, .wake, .networkChange: return age >= eventDebounce
        case .menuOpened: return age >= menuFreshness && sinceAttempt >= eventDebounce
        case .hourly: return age >= backupInterval && sinceAttempt >= retryDelay
        case .connectionWorse: return sinceAttempt >= slowConnectionCooldown
        case .manual: return true
        }
    }
}

enum SpeedFormatting {
    /// Compact rate for the menu bar. Mbps is the default scale, so its M
    /// suffix is omitted; K and G remain when the value crosses those scales.
    static func compactRate(_ megabitsPerSecond: Double) -> String {
        guard megabitsPerSecond.isFinite, megabitsPerSecond >= 0 else { return "—" }

        if megabitsPerSecond >= 1_000 {
            return String(format: "%.1fG", megabitsPerSecond / 1_000)
        }
        if megabitsPerSecond < 1 {
            return String(format: "%.0fK", megabitsPerSecond * 1_000)
        }
        if megabitsPerSecond < 10 {
            return String(format: "%.1f", megabitsPerSecond)
        }
        return String(format: "%.0f", megabitsPerSecond)
    }

    static func rate(_ megabitsPerSecond: Double) -> String {
        guard megabitsPerSecond.isFinite, megabitsPerSecond >= 0 else { return "— Mbps" }

        if megabitsPerSecond >= 1_000 {
            return String(format: "%.1f Gbps", megabitsPerSecond / 1_000)
        }
        if megabitsPerSecond < 10 {
            return String(format: "%.1f Mbps", megabitsPerSecond)
        }
        return String(format: "%.0f Mbps", megabitsPerSecond)
    }
}
