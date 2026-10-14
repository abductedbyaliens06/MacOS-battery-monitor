import Foundation

/// IOKit uses both unsigned two's-complement and signed NSNumber values.
enum PowerTelemetry {
    static func validBatteryWatts(_ watts: Double?, externalConnected: Bool) -> Double? {
        guard let watts, watts.isFinite, abs(watts) <= 300,
              externalConnected || watts <= 0 else { return nil }
        return watts
    }

    static func signedValue(_ number: NSNumber) -> Int {
        let bits = number.uint64Value
        if bits <= UInt64(UInt32.max), bits > UInt64(Int32.max) {
            return Int(Int32(bitPattern: UInt32(bits)))
        }
        return Int(Int64(bitPattern: bits))
    }
}
