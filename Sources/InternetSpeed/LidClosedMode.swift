import AppKit
import Foundation
import IOKit

struct LidClosedModeStatus: Equatable {
    let isEnabled: Bool
    let isLidClosed: Bool

    var menuTitle: String {
        "Clamshell: \(isEnabled ? "On" : "Off")"
    }

    static func fromIORegistryProperties(_ properties: [String: Any]) -> LidClosedModeStatus? {
        guard let isEnabled = booleanValue(properties["SleepDisabled"]),
              let isLidClosed = booleanValue(properties["AppleClamshellState"])
        else { return nil }

        return LidClosedModeStatus(
            isEnabled: isEnabled,
            isLidClosed: isLidClosed
        )
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
    }
}

struct LidClosedModeDisplaySleepSettings: Equatable {
    let batteryMinutes: Int
    let powerMinutes: Int

    var hasRequiredOffTimeouts: Bool {
        batteryMinutes == 10 && powerMinutes == 10
    }
}

enum LidClosedModeError: LocalizedError, Equatable {
    case unavailable
    case cancelled
    case authorizationFailed(String)
    case changeDidNotApply
    case displaySleepDidNotApply

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Your Mac’s lid setting couldn’t be read."
        case .cancelled:
            return "The change was canceled."
        case let .authorizationFailed(message):
            return message
        case .changeDidNotApply:
            return "macOS didn’t apply the change."
        case .displaySleepDidNotApply:
            return "macOS didn’t restore the 10-minute display sleep setting."
        }
    }
}

protocol LidClosedModeProviding {
    func currentStatus() -> LidClosedModeStatus?
    func setEnabled(_ enabled: Bool) throws
}

final class LidClosedModeProvider: LidClosedModeProviding {
    func currentStatus() -> LidClosedModeStatus? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var rawProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &rawProperties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
              let properties = rawProperties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        return LidClosedModeStatus.fromIORegistryProperties(properties)
    }

    func setEnabled(_ enabled: Bool) throws {
        guard let script = NSAppleScript(source: Self.privilegedScript(enabled: enabled)) else {
            throw LidClosedModeError.unavailable
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            if code == -128 {
                throw LidClosedModeError.cancelled
            }
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String
                ?? "macOS could not change the lid-closed setting."
            throw LidClosedModeError.authorizationFailed(message)
        }

        if !enabled {
            guard currentDisplaySleepSettings()?.hasRequiredOffTimeouts == true else {
                throw LidClosedModeError.displaySleepDidNotApply
            }
        }
    }

    static func privilegedScript(enabled: Bool) -> String {
        if enabled {
            return "do shell script \"/usr/bin/pmset -c disablesleep 1\" with administrator privileges"
        }
        return "do shell script \"/usr/bin/pmset -c disablesleep 0 && /usr/bin/pmset -b displaysleep 10 && /usr/bin/pmset -c displaysleep 10\" with administrator privileges"
    }

    func currentDisplaySleepSettings() -> LidClosedModeDisplaySleepSettings? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }
        return Self.parseDisplaySleepSettings(text)
    }

    static func parseDisplaySleepSettings(_ output: String) -> LidClosedModeDisplaySleepSettings? {
        enum PowerMode {
            case battery
            case power
        }

        var mode: PowerMode?
        var batteryMinutes: Int?
        var powerMinutes: Int?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            switch line {
            case "Battery Power:":
                mode = .battery
            case "AC Power:":
                mode = .power
            default:
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2, fields[0] == "displaysleep", let minutes = Int(fields[1]) else {
                    continue
                }
                switch mode {
                case .battery: batteryMinutes = minutes
                case .power: powerMinutes = minutes
                case nil: break
                }
            }
        }

        guard let batteryMinutes, let powerMinutes else { return nil }
        return LidClosedModeDisplaySleepSettings(
            batteryMinutes: batteryMinutes,
            powerMinutes: powerMinutes
        )
    }
}
