import Foundation
import IOKit

/// Read-only SMC sensor access. Never sends the write-key command.
final class SMCPowerReader {
    private var connection: io_connect_t = 0
    private var keyInfo: [String: (size: UInt32, type: UInt32)] = [:]

    init() { reconnect() }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func reconnect() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
        keyInfo.removeAll()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS {
            connection = 0
        }
    }

    struct Reading {
        let voltageV: Double
        let currentA: Double
        let adapterWatts: Double?
        var batteryWatts: Double { voltageV * currentA }
    }

    func read() -> Reading? {
        guard let voltage = readSensor("B0AV"), (5...30).contains(voltage),
              let current = readSensor("B0AC"), abs(current) <= 30 else { return nil }
        let input = readSensor("PDTR").flatMap { (0...300).contains($0) ? $0 : nil }
        return Reading(voltageV: voltage, currentA: current, adapterWatts: input)
    }

    private func readSensor(_ key: String) -> Double? {
        guard connection != 0 else { return nil }
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let info: (size: UInt32, type: UInt32)
        if let cached = keyInfo[key] {
            info = cached
        } else {
            guard let response = call(key: code, command: 9), response[40] == 0 else { return nil }
            info = (readUInt32(response, at: 28), readUInt32(response, at: 32))
            guard (1...32).contains(info.size) else { return nil }
            keyInfo[key] = info
        }
        guard let response = call(key: code, command: 5, size: info.size), response[40] == 0 else { return nil }
        let bytes = Array(response[48..<48 + Int(info.size)])
        guard let value = Self.decode(bytes: bytes, type: info.type) else { return nil }
        // Integer battery sensors are mV/mA; floating-point variants are V/A.
        if info.type == 0x75693136 || info.type == 0x73693136 {
            if key == "B0AV" || key == "B0AC" { return value / 1000 }
        }
        return value
    }

    // SMCKeyData's ABI is 80 bytes: keyInfo at 28, command at 42, payload at 48.
    private func call(key: UInt32, command: UInt8, size: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        withUnsafeBytes(of: key) { input.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: size) { input.replaceSubrange(28..<32, with: $0) }
        input[42] = command
        var outputSize = 80
        let result = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                IOConnectCallStructMethod(connection, 2, inputBuffer.baseAddress, 80,
                                          outputBuffer.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, outputSize == 80 else { return nil }
        return output
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].enumerated().reduce(0) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }

    static func decode(bytes: [UInt8], type: UInt32) -> Double? {
        let name = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: type >> $0) }, encoding: .ascii)
        let value: Double
        // Apple Silicon integer payloads are little-endian; Intel uses big-endian.
        #if arch(arm64)
        let integerBytes = Array(bytes.reversed())
        #else
        let integerBytes = bytes
        #endif
        let integer = integerBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        switch name {
        case "flt " where bytes.count == 4:
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            value = Double(Float(bitPattern: bits))
        case "sp78" where bytes.count == 2:
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where bytes.count == 2:
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui16" where bytes.count == 2:
            value = Double(integer)
        case "ui32" where bytes.count == 4:
            value = Double(integer)
        case "si16" where bytes.count == 2:
            value = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: integer)))
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}
