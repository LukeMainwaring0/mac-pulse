import Darwin
import Foundation
import OSLog

/// For short, trusted diagnostic commands. Call from a background worker.
enum BoundedProcess {
    private static let logger = Logger(subsystem: "com.lukemainwaring.internetspeed", category: "Health")

    static func output(executable: String, arguments: [String], timeout: TimeInterval = 3) -> Data? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-pulse-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("stdout")
            guard FileManager.default.createFile(
                atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else { return nil }
            let output = try FileHandle(forUpdating: file)
            defer { try? output.close() }

            // A file cannot fill a pipe and deadlock the child while we wait.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            guard exited.wait(timeout: .now() + max(0, timeout)) == .success else {
                logger.error("Diagnostic timed out: \(executable, privacy: .public)")
                if process.isRunning { process.terminate() }
                if exited.wait(timeout: .now() + 0.2) == .timedOut {
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    // Even cleanup must be bounded if an OS service is stuck.
                    _ = exited.wait(timeout: .now() + 0.2)
                }
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            try output.seek(toOffset: 0)
            let limit = 1_048_576
            guard let data = try output.read(upToCount: limit + 1), data.count <= limit else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
