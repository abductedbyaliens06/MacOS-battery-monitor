import Foundation

@main
struct PowerTelemetryTests {
    static func main() {
        // Regression: IOKit publishes two's-complement negatives as unsigned numbers.
        assert(PowerTelemetry.signedValue(NSNumber(value: UInt64.max - 587)) == -588)
        assert(PowerTelemetry.signedValue(NSNumber(value: UInt32.max - 587)) == -588)
        assert(PowerTelemetry.signedValue(NSNumber(value: -588)) == -588)
        assert(PowerTelemetry.signedValue(NSNumber(value: 2400)) == 2400)

        // Unplug must hide a delayed positive charge sample rather than show charging watts.
        assert(PowerTelemetry.validBatteryWatts(4, externalConnected: false) == nil)
        assert(PowerTelemetry.validBatteryWatts(-20, externalConnected: false) == -20)
        assert(PowerTelemetry.validBatteryWatts(30, externalConnected: true) == 30)
        assert(PowerTelemetry.validBatteryWatts(-5, externalConnected: true) == -5)
        assert(PowerTelemetry.validBatteryWatts(0, externalConnected: true) == 0)
        assert(PowerTelemetry.validBatteryWatts(nil, externalConnected: true) == nil)
        assert(PowerTelemetry.validBatteryWatts(.nan, externalConnected: true) == nil)
        assert(PowerTelemetry.validBatteryWatts(1_000_000, externalConnected: true) == nil)

        // Hardware-specific sensor decoding: integer SMC values on Apple Silicon.
        #if arch(arm64)
        assert(SMCPowerReader.decode(bytes: [0x88, 0x30], type: fourCC("ui16")) == 12424)
        assert(SMCPowerReader.decode(bytes: [0xB4, 0xFD], type: fourCC("si16")) == -588)
        #else
        assert(SMCPowerReader.decode(bytes: [0x30, 0x88], type: fourCC("ui16")) == 12424)
        assert(SMCPowerReader.decode(bytes: [0xFD, 0xB4], type: fourCC("si16")) == -588)
        #endif
        let floatBytes = withUnsafeBytes(of: Float(-2.5)) { Array($0) }
        assert(SMCPowerReader.decode(bytes: floatBytes, type: fourCC("flt ")) == -2.5)
        assert(SMCPowerReader.decode(bytes: [0], type: fourCC("flt ")) == nil)
        assert(SMCPowerReader.decode(bytes: [0, 0], type: fourCC("????")) == nil)
        let nanBytes = withUnsafeBytes(of: Float.nan) { Array($0) }
        assert(SMCPowerReader.decode(bytes: nanBytes, type: fourCC("flt ")) == nil)
        print("Power telemetry regression checks passed.")
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
