import Foundation

/// IOKit uses both unsigned two's-complement and signed NSNumber values.
enum PowerTelemetry {
    static func validBatteryWatts(_ watts: Double?, externalConnected: Bool) -> Double? {
        guard let watts, watts.isFinite, abs(watts) <= 300,
              externalConnected || watts <= 0 else { return nil }
        return watts
    }

    static func validTemperature(_ value: Double) -> Double? {
        guard value.isFinite, (-20...100).contains(value), value != 0 else { return nil }
        return value
    }

    static func registryTemperature(virtual: Double?, raw: Double?) -> Double? {
        if let virtual, let value = validTemperature(virtual / 100) { return value }
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        // SmartBattery Temperature uses tenths of Kelvin; some drivers use centi-Celsius.
        return validTemperature((2400...3732).contains(raw) ? raw / 10 - 273.15 : raw / 100)
    }

    static func signedValue(_ number: NSNumber) -> Int {
        let bits = number.uint64Value
        if bits <= UInt64(UInt32.max), bits > UInt64(Int32.max) {
            return Int(Int32(bitPattern: UInt32(bits)))
        }
        return Int(Int64(bitPattern: bits))
    }
}
