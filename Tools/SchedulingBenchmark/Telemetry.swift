import Foundation
import IOKit.ps
import CoreGraphics
import Darwin

@main struct BenchmarkTelemetry {
    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPSBatteryPowerValue
    }
    static func displays() -> [Double] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayCopyDisplayMode($0)?.refreshRate ?? 0 }.sorted()
    }
    static func main() throws {
        let reader = SMCPowerReader(), parent = getppid(), start = ProcessInfo.processInfo.systemUptime
        setbuf(stdout, nil)
        while getppid() == parent && ProcessInfo.processInfo.systemUptime - start < 1800 {
            let battery = onBattery(), reading = reader.read()
            let watts = reading.flatMap { PowerTelemetry.validBatteryWatts($0.batteryWatts, externalConnected: !battery) }
            var sample: [String: Any] = ["time": ProcessInfo.processInfo.systemUptime,
                "wallTime": Date().timeIntervalSince1970, "onBattery": battery,
                "lpm": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                "refreshRates": displays(), "brightness": NSNull(), "source": "SMC_B0AV_B0AC"]
            sample["watts"] = battery && (watts ?? 0) < 0 ? -(watts!) : NSNull()
            let data = try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
            if !battery { break }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
