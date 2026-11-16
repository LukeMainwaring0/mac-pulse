import Foundation

struct PanicKernelExtension: Codable, Equatable, Sendable {
    let name: String
    let isApple: Bool
}

struct PanicReport: Codable, Equatable, Sendable {
    let identity: String
    let path: String
    let timestamp: Date
    let incidentID: String?
    let osVersion: String?
    let model: String?
    let panicString: String
    let panickedTask: String?
    let compressorStatus: String?
    let appleKernelExtensions: [PanicKernelExtension]
    let thirdPartyKernelExtensions: [PanicKernelExtension]
    let fingerprint: String
    let signature: String
    let classification: String

    var taskContext: String? {
        panickedTask.map { "\($0) was active when the panic occurred; cause not established" }
    }
}

struct PanicContextSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let sidecarPresent: Bool?
    let displayTopology: [String]
    let windowServerCPUPercent: Double?
    let memoryPressure: String?
    let swap: String?
    let temperatureCelsius: Double?
    let osVersion: String
}

struct PanicHistoryEntry: Codable, Equatable, Sendable {
    let report: PanicReport
    let firstDetectedAt: Date
    let postRebootContext: PanicContextSnapshot?
}

struct PanicScanSnapshot: Equatable, Sendable {
    static let empty = PanicScanSnapshot(recentCount: 0, latest: nil, newlyDetected: nil, fingerprintCount: 0)

    let recentCount: Int
    let latest: PanicHistoryEntry?
    let newlyDetected: PanicHistoryEntry?
    let fingerprintCount: Int
}

protocol PanicReportDiscovering {
    func reportURLs() -> [URL]
}

protocol PanicContextProviding {
    func capture(at date: Date, temperatureCelsius: Double?) -> PanicContextSnapshot?
}

protocol PanicMonitoring {
    func scan(at date: Date, temperatureCelsius: Double?) -> PanicScanSnapshot
}

struct FileSystemPanicReportDiscovery: PanicReportDiscovering {
    let roots: [URL]
    let fileManager: FileManager

    init(
        roots: [URL] = [
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        ],
        fileManager: FileManager = .default
    ) {
        self.roots = roots
        self.fileManager = fileManager
    }

    func reportURLs() -> [URL] {
        roots.flatMap { root in
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [URL]() }
            let urls: [URL] = enumerator.compactMap { item -> URL? in
                guard let url = item as? URL,
                      url.pathExtension.lowercased() == "panic",
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return nil }
                return url
            }
            return urls
        }
        .sorted { $0.path < $1.path }
    }
}

struct PanicReportParser {
    private static let maximumReportBytes = 4 * 1_024 * 1_024

    func parse(url: URL) -> PanicReport? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty,
              data.count <= Self.maximumReportBytes,
              let newline = data.firstIndex(of: 0x0A)
        else { return nil }

        let headerData = data[..<newline]
        let bodyData = data[data.index(after: newline)...]
        guard let header = jsonDictionary(Data(headerData)),
              let body = jsonDictionary(Data(bodyData)),
              let panicString = body["panicString"] as? String,
              !panicString.isEmpty,
              let timestamp = parseDate(header["timestamp"] as? String ?? body["date"] as? String)
        else { return nil }

        let incidentID = string(header["incident_id"]) ?? string(body["incident"])
        let osVersion = string(header["os_version"]) ?? string(body["build"])
        let model = string(body["product"])
        let panickedTask = capture(
            #"(?m)^Panicked task[^\n]*?(?:pid\s+\d+:\s*)([^\n]+)$"#,
            in: panicString
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let compressor = capture(#"(?m)^Compressor Info:\s*([^\n]+)$"#, in: panicString)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let extensions = kernelExtensions(in: panicString)
        let fingerprintParts = fingerprintComponents(panicString: panicString, extensions: extensions)
        let fingerprint = fingerprintParts.normalized
        let signature = fingerprintParts.display
        let classification = classification(
            panicString: panicString,
            extensions: extensions,
            rail: fingerprintParts.rail
        )
        let identity = incidentID.map { "incident:\($0.uppercased())" }
            ?? "report:\(stableHash("\(timestamp.timeIntervalSince1970)|\(fingerprint)"))"

        return PanicReport(
            identity: identity,
            path: url.path,
            timestamp: timestamp,
            incidentID: incidentID,
            osVersion: osVersion,
            model: model,
            panicString: panicString,
            panickedTask: panickedTask,
            compressorStatus: compressor,
            appleKernelExtensions: extensions.filter(\.isApple),
            thirdPartyKernelExtensions: extensions.filter { !$0.isApple },
            fingerprint: fingerprint,
            signature: signature,
            classification: classification
        )
    }

    private func jsonDictionary(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private func capture(_ pattern: String, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private func kernelExtensions(in panicString: String) -> [PanicKernelExtension] {
        guard let sectionStart = panicString.range(of: "Kernel Extensions in backtrace:") else { return [] }
        let tail = panicString[sectionStart.upperBound...]
        let sectionEnd = tail.range(of: "\nlast started kext")?.lowerBound ?? tail.endIndex
        let section = String(tail[..<sectionEnd])
        guard let expression = try? NSRegularExpression(
            pattern: #"(?m)^\s+(com\.[A-Za-z0-9_.-]+)\([^\n]*$"#
        ) else { return [] }
        var seen = Set<String>()
        return expression.matches(
            in: section,
            range: NSRange(section.startIndex..., in: section)
        ).compactMap { match in
            guard let range = Range(match.range(at: 1), in: section) else { return nil }
            let name = String(section[range])
            guard seen.insert(name).inserted else { return nil }
            return PanicKernelExtension(name: name, isApple: name.hasPrefix("com.apple."))
        }
    }

    private func fingerprintComponents(
        panicString: String,
        extensions: [PanicKernelExtension]
    ) -> (normalized: String, display: String, rail: String?) {
        let controller = capture(#"\b(PMC\d+)\s+Assert ID"#, in: panicString)
        let assertID = capture(#"Assert ID:\s*(0x[0-9A-Fa-f]+)"#, in: panicString)?.lowercased()
        let rail = capture(#"\brail:\s*([A-Za-z0-9_-]+)"#, in: panicString)
        let source = capture(#"@([A-Za-z0-9_+.-]+\.cpp):\d+"#, in: panicString)
        let primaryName = extensions.first.map { shortKextName($0.name) }

        var normalized: [String] = []
        if let controller { normalized.append("controller=\(controller.lowercased())") }
        if let assertID { normalized.append("assert=\(assertID)") }
        if let rail { normalized.append("rail=\(rail.lowercased())") }
        if let source { normalized.append("source=\(source.lowercased())") }
        normalized.append(contentsOf: extensions.map { "kext=\($0.name.lowercased())" })

        if normalized.isEmpty {
            var headline = panicString.components(separatedBy: .newlines).first ?? panicString
            headline = headline.replacingOccurrences(
                of: #"0x[0-9A-Fa-f]+|\b(?:cpu|pid)\s*\d+\b|[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27,}"#,
                with: "#",
                options: .regularExpression
            )
            headline = headline.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            normalized.append("headline=\(headline.lowercased().trimmingCharacters(in: .whitespaces))")
        }

        let displayParts = [
            [controller, assertID].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
            rail?.uppercased(),
            primaryName
        ].compactMap { $0 }
        let display = displayParts.isEmpty ? "Kernel panic" : displayParts.joined(separator: " · ")
        return (normalized.joined(separator: "|"), display, rail)
    }

    private func shortKextName(_ name: String) -> String {
        for prefix in ["com.apple.driver.", "com.apple.iokit.", "com.apple."] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name.components(separatedBy: ".").last ?? name
    }

    private func classification(
        panicString: String,
        extensions: [PanicKernelExtension],
        rail: String?
    ) -> String {
        let displayPowerEvidence = panicString.localizedCaseInsensitiveContains("AppleSoCErrorHandler")
            && (rail?.caseInsensitiveCompare("DCS") == .orderedSame
                || panicString.localizedCaseInsensitiveContains("display"))
        if displayPowerEvidence { return "Apple SoC display/power panic" }
        if !extensions.isEmpty, extensions.allSatisfy(\.isApple) { return "Apple kernel panic" }
        if extensions.contains(where: { !$0.isApple }) {
            return "Kernel panic involving third-party extensions"
        }
        return "Kernel panic"
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct StoredPanicHistory: Codable {
    var entries: [PanicHistoryEntry]
}

final class PanicMonitor: PanicMonitoring {
    private static let historyKey = "macPulsePanicHistoryV1"
    private static let retentionLimit = 100
    private let discovery: PanicReportDiscovering
    private let parser: PanicReportParser
    private let contextProvider: PanicContextProviding
    private let defaults: PreferencesStore

    init(
        discovery: PanicReportDiscovering = FileSystemPanicReportDiscovery(),
        parser: PanicReportParser = PanicReportParser(),
        contextProvider: PanicContextProviding = SystemPanicContextProvider(),
        defaults: PreferencesStore = UserDefaults.standard
    ) {
        self.discovery = discovery
        self.parser = parser
        self.contextProvider = contextProvider
        self.defaults = defaults
    }

    func scan(at date: Date, temperatureCelsius: Double?) -> PanicScanSnapshot {
        var history = loadHistory()
        let known = Set(history.entries.map(\.report.identity))
        let reports = discovery.reportURLs().compactMap(parser.parse(url:))
        let newReports = reports.filter { !known.contains($0.identity) }.sorted { $0.timestamp < $1.timestamp }
        let context = newReports.isEmpty ? nil : contextProvider.capture(
            at: date,
            temperatureCelsius: temperatureCelsius
        )
        let newEntries = newReports.map {
            PanicHistoryEntry(report: $0, firstDetectedAt: date, postRebootContext: context)
        }
        if !newEntries.isEmpty {
            history.entries.append(contentsOf: newEntries)
            history.entries.sort { $0.report.timestamp < $1.report.timestamp }
            if history.entries.count > Self.retentionLimit {
                history.entries.removeFirst(history.entries.count - Self.retentionLimit)
            }
            saveHistory(history)
        }

        let cutoff = date.addingTimeInterval(-30 * 24 * 60 * 60)
        let recent = history.entries.filter { $0.report.timestamp >= cutoff }
        let latest = recent.max { $0.report.timestamp < $1.report.timestamp }
        let latestNew = newEntries.last
        let fingerprintCount = latest.map { target in
            history.entries.filter { $0.report.fingerprint == target.report.fingerprint }.count
        } ?? 0
        return PanicScanSnapshot(
            recentCount: recent.count,
            latest: latest,
            newlyDetected: latestNew,
            fingerprintCount: fingerprintCount
        )
    }

    private func loadHistory() -> StoredPanicHistory {
        guard let data = defaults.data(forKey: Self.historyKey),
              let value = try? JSONDecoder().decode(StoredPanicHistory.self, from: data)
        else { return StoredPanicHistory(entries: []) }
        return value
    }

    private func saveHistory(_ history: StoredPanicHistory) {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }
}

struct SystemPanicContextProvider: PanicContextProviding {
    func capture(at date: Date, temperatureCelsius: Double?) -> PanicContextSnapshot? {
        let displayOutput = command("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json", "-timeout", "5"])
        let displayTopology = displayOutput.map(displayNames(in:)) ?? []
        let sidecarPresent = displayOutput.map {
            $0.localizedCaseInsensitiveContains("sidecar")
                || $0.localizedCaseInsensitiveContains("ipad")
        }
        let ps = command("/bin/ps", ["-A", "-o", "%cpu=,comm="])
        let windowServerCPU = ps.flatMap(windowServerCPU(in:))
        let pressure = command("/usr/bin/memory_pressure", ["-Q"]).map(firstUsefulLine(in:))
        let swap = command("/usr/sbin/sysctl", ["-n", "vm.swapusage"]).map(firstUsefulLine(in:))
        return PanicContextSnapshot(
            capturedAt: date,
            sidecarPresent: sidecarPresent,
            displayTopology: displayTopology,
            windowServerCPUPercent: windowServerCPU,
            memoryPressure: pressure,
            swap: swap,
            temperatureCelsius: temperatureCelsius,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    private func command(_ executable: String, _ arguments: [String]) -> String? {
        guard let data = BoundedProcess.output(
            executable: executable, arguments: arguments, timeout: 6
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func firstUsefulLine(in output: String) -> String {
        output.split(separator: "\n").last.map(String.init) ?? output
    }

    private func windowServerCPU(in output: String) -> Double? {
        for line in output.split(separator: "\n") where line.localizedCaseInsensitiveContains("WindowServer") {
            if let first = line.split(whereSeparator: \Character.isWhitespace).first,
               let value = Double(first) {
                return value
            }
        }
        return nil
    }

    private func displayNames(in output: String) -> [String] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        var names: [String] = []
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if key.localizedCaseInsensitiveContains("display_name"), let name = child as? String {
                        names.append(name)
                    }
                    walk(child)
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return Array(Set(names)).sorted()
    }
}
