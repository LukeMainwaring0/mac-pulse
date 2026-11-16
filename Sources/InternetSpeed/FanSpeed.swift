import Darwin
import Foundation
import IOKit

protocol FanSpeedProviding {
    func currentFanSpeeds() -> [Double]
}

/// Reads the Apple SMC fan keys without spawning a helper process. Some Apple
/// Silicon models expose the SMC keys endpoint while older Macs expose the
/// legacy AppleSMC service; both are tried and an unavailable sensor is
/// reported as an empty result.
final class AppleSMCFanSpeedProvider: FanSpeedProviding {
    private var connection: io_connect_t = 0

    init() {
        for serviceName in ["AppleSMCKeysEndpoint", "AppleSMCInterface", "AppleSMCPMU", "AppleSMC"] {
            guard let matching = IOServiceMatching(serviceName) else { continue }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != 0 else { continue }
            let openResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
            if openResult == KERN_SUCCESS {
                IOObjectRelease(service)
                break
            }
            IOObjectRelease(service)
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func currentFanSpeeds() -> [Double] {
        guard connection != 0 else { return [] }
        return (0..<4).compactMap { index in
            let key = "F\(index)Ac"
            return readFixedPoint(key: key)
        }
    }

    private func readFixedPoint(key: String) -> Double? {
        guard let keyInfo = readKeyInfo(fourCC(key)) else { return nil }

        var input = SMCKeyData()
        input.key = fourCC(key)
        input.keyInfo = keyInfo
        input.data8 = 5 // kSMCGetKey
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size
        let result = withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    2,
                    UnsafeRawPointer(inputPointer),
                    MemoryLayout<SMCKeyData>.size,
                    UnsafeMutableRawPointer(outputPointer),
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0) }
        switch keyInfo.dataType {
        case fourCC("FPE2"):
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4.0
        case fourCC("SP78"):
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        default:
            return nil
        }
    }

    private func readKeyInfo(_ key: UInt32) -> SMCKeyInfoData? {
        var input = SMCKeyData()
        input.key = key
        input.data8 = 9 // kSMCGetKeyInfo
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size
        let result = withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    2,
                    UnsafeRawPointer(inputPointer),
                    MemoryLayout<SMCKeyData>.size,
                    UnsafeMutableRawPointer(outputPointer),
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return output.keyInfo
    }

    private func fourCC(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
}
