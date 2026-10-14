import Foundation
import AppKit
import IOKit
import IOKit.ps
import UserNotifications
import Combine

enum PowerState: String {
    case charging = "Charging"
    case discharging = "On Battery"
    case pluggedInHolding = "AC (Charge Held)"
    case fullyCharged = "Fully Charged"
    case desktopAC = "Desktop Mac (AC)"
    case unknown = "Unknown"
}

enum MenuBarLabelStyle: String, CaseIterable, Identifiable {
    case percentAndWatts = "91% +11.7W (Default)"
    case wattsOnly = "+11.7W (Watts Only)"
    case percentAndSysLoad = "91% • Sys 8.3W"
    case percentAndTemp = "91% • 31.2°C"
    case percentOnly = "91% (Compact)"
    
    var id: String { rawValue }
}

struct PowerSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let batteryWatts: Double
    let systemLoadWatts: Double
    let wallWatts: Double
    let temperatureC: Double
    let percentage: Int
}

struct BatterySnapshot {
    var hasBattery: Bool = false
    var percentage: Int = 0
    var rawStateOfCharge: Double = 0.0
    
    // 3-Way Power Routing (Watts)
    var voltageMV: Int = 0
    var amperageMA: Int = 0
    var liveWatts: Double = 0.0              // + charging, - discharging
    var systemLoadWatts: Double = 0.0        // CPU/GPU/Display consumption
    var wallInputWatts: Double = 0.0         // Power pulled from charger
    var adapterLossWatts: Double = 0.0       // Adapter heat loss
    var chargeRatePercentPerHour: Double = 0.0
    
    // USB-C PD / MagSafe Handshake
    var adapterWatts: Int = 0
    var adapterVoltageV: Double = 0.0
    var adapterCurrentA: Double = 0.0
    var adapterName: String = "Disconnected"
    var adapterManufacturer: String = "—"
    var adapterSerial: String = "—"
    
    // Dual Health & Capacity (mAh & Wh)
    var currentCapacityMAH: Int = 0
    var rawMaxCapacityMAH: Int = 0           // Unsmoothed gauge capacity
    var nominalMaxCapacityMAH: Int = 0       // Smoothed capacity (System Settings)
    var designCapacityMAH: Int = 0           // Factory design capacity
    var rawHealthPercentage: Double = 0.0
    var nominalHealthPercentage: Double = 0.0
    var currentEnergyWH: Double = 0.0
    var maxEnergyWH: Double = 0.0
    var designEnergyWH: Double = 0.0
    
    // Cycles & Condition
    var cycleCount: Int = 0
    var designCycleCount: Int = 1000
    var conditionText: String = "Normal"
    
    // Thermal & Per-Cell Telemetry
    var temperatureCelsius: Double = 0.0
    var isThermalWarning: Bool = false
    var cellVoltagesMV: [Int] = []
    var cellDeltaMV: Int = 0
    
    // BMS Lifetime Black-Box Diary
    var lifetimeMaxTempC: Double? = nil
    var lifetimeMinTempC: Double? = nil
    var totalOperatingHours: Int? = nil
    var highSocHours: Int? = nil
    var peakChargeCurrentMA: Int? = nil
    var peakDischargeCurrentMA: Int? = nil
    
    // Hardware Identity
    var deviceName: String = "—"
    var serialNumber: String = "—"
    var firmwareVersion: String = "—"
    
    // State & Time
    var powerState: PowerState = .unknown
    var timeRemainingMinutes: Int? = nil
}

@MainActor
final class BatteryService: ObservableObject {
    @Published var snapshot = BatterySnapshot()
    @Published var history: [PowerSample] = []
    @Published var rawRegistryPairs: [(key: String, value: String)] = []
    
    // Menu Bar Appearance
    @Published var labelStyle: MenuBarLabelStyle = .percentAndWatts
    
    // Session Statistics
    @Published var sessionPeakDrawWatts: Double = 0.0
    @Published var sessionPeakChargeWatts: Double = 0.0
    
    // Custom Alerts & Screen Glow
    @Published var alertsEnabled: Bool = true
    @Published var screenGlowEnabled: Bool = true
    @Published var lowBatteryThreshold: Double = 20.0
    @Published var highChargeLimitThreshold: Double = 80.0
    
    private var monitoringTask: Task<Void, Never>?
    private var lastAlertKey: String = ""
    private var glowWindow: NSWindow?
    
    init() {
        requestNotificationPermissions()
        refresh()
        startMonitoring(interval: 2.0)
    }
    
    func startMonitoring(interval: TimeInterval) {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                self.refresh()
            }
        }
    }
    
    func refresh() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            snapshot = BatterySnapshot(hasBattery: false, powerState: .desktopAC)
            return
        }
        defer { IOObjectRelease(service) }
        
        // 1. Merge AppleSmartBattery + AppleSmartBatteryPack + Child Registry Entries
        var mergedProps = extractProperties(from: service)
        
        let packService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        if packService != 0 {
            let packProps = extractProperties(from: packService)
            for (k, v) in packProps where mergedProps[k] == nil {
                mergedProps[k] = v
            }
            IOObjectRelease(packService)
        }
        
        var childIterator: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator) == KERN_SUCCESS {
            defer { IOObjectRelease(childIterator) }
            var child = IOIteratorNext(childIterator)
            while child != 0 {
                let childProps = extractProperties(from: child)
                for (k, v) in childProps where mergedProps[k] == nil {
                    mergedProps[k] = v
                }
                IOObjectRelease(child)
                child = IOIteratorNext(childIterator)
            }
        }
        
        let batteryData = mergedProps["BatteryData"] as? [String: Any] ?? [:]
        let lifetimeData = batteryData["LifetimeData"] as? [String: Any]
            ?? mergedProps["LifetimeData"] as? [String: Any] ?? [:]
        let powerTelemetry = mergedProps["PowerTelemetryData"] as? [String: Any]
            ?? batteryData["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapterDetails = mergedProps["AdapterDetails"] as? [String: Any] ?? [:]
        
        func readInt(_ keys: [String], minValid: Int? = nil) -> Int? {
            for key in keys {
                if let val = (mergedProps[key] as? NSNumber)?.intValue,
                   minValid == nil || val >= minValid! {
                    return val
                }
                if let val = (batteryData[key] as? NSNumber)?.intValue,
                   minValid == nil || val >= minValid! {
                    return val
                }
            }
            return nil
        }
        
        var next = BatterySnapshot(hasBattery: true)
        
        // 2. Capacities (mAh) — Ignore MaxCapacity=100 percentage flag
        let designMAH = readInt(["DesignCapacity", "FedDesignCapacity"], minValid: 500) ?? 0
        let nominalMAH = readInt(["NominalChargeCapacity", "FCCComp1"], minValid: 500) ?? 0
        let rawMaxMAH = readInt(["AppleRawMaxCapacity", "FullChargeCapacity"], minValid: 500)
            ?? (nominalMAH > 0 ? nominalMAH : (readInt(["MaxCapacity"], minValid: 500) ?? 0))
        let effectiveMaxMAH = rawMaxMAH > 0 ? rawMaxMAH : nominalMAH
        
        let rawCurrMAH = readInt(["AppleRawCurrentCapacity"], minValid: 101)
            ?? (effectiveMaxMAH > 0 && (readInt(["CurrentCapacity"]) ?? 0) <= 100
                ? Int(round(Double(effectiveMaxMAH) * Double(readInt(["CurrentCapacity"]) ?? 0) / 100.0))
                : (readInt(["CurrentCapacity"]) ?? 0))
        
        next.designCapacityMAH = designMAH
        next.rawMaxCapacityMAH = effectiveMaxMAH
        next.nominalMaxCapacityMAH = nominalMAH > 0 ? nominalMAH : effectiveMaxMAH
        next.currentCapacityMAH = rawCurrMAH
        
        // 3. Displayed & Raw Percentage
        if let topCurr = (mergedProps["CurrentCapacity"] as? NSNumber)?.intValue,
           let topMax = (mergedProps["MaxCapacity"] as? NSNumber)?.intValue,
           topMax == 100 {
            next.percentage = topCurr
        } else if effectiveMaxMAH > 0 {
            next.percentage = Int(round((Double(rawCurrMAH) / Double(effectiveMaxMAH)) * 100.0))
        }
        
        if let soc = (batteryData["StateOfCharge"] as? NSNumber)?.doubleValue {
            next.rawStateOfCharge = soc
        } else if effectiveMaxMAH > 0 {
            next.rawStateOfCharge = min(100.0, (Double(rawCurrMAH) / Double(effectiveMaxMAH)) * 100.0)
        } else {
            next.rawStateOfCharge = Double(next.percentage)
        }
        
        // 4. Dual Health Percentages (Nominal vs Raw)
        if designMAH > 0 {
            if effectiveMaxMAH > 0 {
                next.rawHealthPercentage = (Double(effectiveMaxMAH) / Double(designMAH)) * 100.0
            }
            if next.nominalMaxCapacityMAH > 0 {
                next.nominalHealthPercentage = (Double(next.nominalMaxCapacityMAH) / Double(designMAH)) * 100.0
            } else {
                next.nominalHealthPercentage = next.rawHealthPercentage
            }
        }
        
        // 5. Voltage, Signed Amperage & 3-Way Power Routing
        let voltage = readInt(["AppleRawBatteryVoltage", "Voltage"], minValid: 1000) ?? 11400
        let amperage = Int((mergedProps["InstantAmperage"] as? NSNumber)?.int64Value
            ?? (mergedProps["Amperage"] as? NSNumber)?.int64Value
            ?? (batteryData["InstantAmperage"] as? NSNumber)?.int64Value ?? 0)
        
        next.voltageMV = voltage
        next.amperageMA = amperage
        next.liveWatts = (Double(voltage) * Double(amperage)) / 1_000_000.0
        
        let nominalVolts = voltage > 5000 ? (Double(voltage) / 1000.0) : 11.4
        next.currentEnergyWH = (Double(rawCurrMAH) * nominalVolts) / 1000.0
        next.maxEnergyWH = (Double(effectiveMaxMAH) * nominalVolts) / 1000.0
        next.designEnergyWH = (Double(designMAH) * 11.4) / 1000.0
        
        if effectiveMaxMAH > 0 {
            next.chargeRatePercentPerHour = (Double(amperage) / Double(effectiveMaxMAH)) * 100.0
        }
        
        let sysPowerInMW = (powerTelemetry["SystemPowerIn"] as? NSNumber)?.int64Value ?? 0
        let sysLoadMW = (powerTelemetry["SystemLoad"] as? NSNumber)?.int64Value ?? 0
        let adapterLossMW = (powerTelemetry["AdapterEfficiencyLoss"] as? NSNumber)?.int64Value ?? 0
        
        let externalConnected = (mergedProps["ExternalConnected"] as? Bool) ?? false
        let isCharging = (mergedProps["IsCharging"] as? Bool) ?? false
        let fullyCharged = (mergedProps["FullyCharged"] as? Bool) ?? false
        
        if sysPowerInMW > 0 {
            next.wallInputWatts = Double(sysPowerInMW) / 1000.0
        } else if externalConnected {
            next.wallInputWatts = max(0.0, next.liveWatts)
        }
        
        if adapterLossMW > 0 {
            next.adapterLossWatts = Double(adapterLossMW) / 1000.0
        }
        
        if !externalConnected {
            next.systemLoadWatts = abs(min(0.0, next.liveWatts))
        } else if sysLoadMW > 0 && Double(sysLoadMW) / 1000.0 < 180.0 {
            next.systemLoadWatts = Double(sysLoadMW) / 1000.0
        } else if next.wallInputWatts > 0 {
            next.systemLoadWatts = max(0.0, next.wallInputWatts - max(0.0, next.liveWatts))
        }
        
        // 6. Temperature (VirtualTemperature in 0.01°C vs Temperature in 0.1K)
        if let virtualTemp = (mergedProps["VirtualTemperature"] as? NSNumber)?.doubleValue
            ?? (batteryData["VirtualTemperature"] as? NSNumber)?.doubleValue,
           virtualTemp > 0 {
            next.temperatureCelsius = virtualTemp / 100.0
        } else if let rawTemp = (mergedProps["Temperature"] as? NSNumber)?.doubleValue
            ?? (batteryData["Temperature"] as? NSNumber)?.doubleValue,
                  rawTemp > 0 {
            if rawTemp > 2400 && rawTemp < 3500 {
                next.temperatureCelsius = (rawTemp / 10.0) - 273.15
            } else {
                next.temperatureCelsius = rawTemp / 100.0
            }
        }
        next.isThermalWarning = next.temperatureCelsius >= 40.0
        
        // 7. Per-Cell Voltages (3S Pack)
        if let cells = batteryData["CellVoltage"] as? [NSNumber] {
            let validCells = cells.map { $0.intValue }.filter { $0 > 2500 }
            next.cellVoltagesMV = validCells
            if let minC = validCells.min(), let maxC = validCells.max() {
                next.cellDeltaMV = maxC - minC
            }
        }
        
        // 8. Cycles & Condition
        next.cycleCount = readInt(["CycleCount"]) ?? 0
        next.designCycleCount = readInt(["DesignCycleCount9C"], minValid: 100) ?? 1000
        let permFailure = readInt(["PermanentFailureStatus"]) ?? 0
        if permFailure != 0 {
            next.conditionText = "Service Required"
        } else if next.nominalHealthPercentage > 0 && next.nominalHealthPercentage < 80.0 {
            next.conditionText = "Service (<80%)"
        } else {
            next.conditionText = "Normal"
        }
        
        // 9. Adapter / USB-C PD Handshake
        next.adapterWatts = (adapterDetails["Watts"] as? NSNumber)?.intValue ?? 0
        if let v = (adapterDetails["AdapterVoltage"] as? NSNumber)?.doubleValue
            ?? (adapterDetails["Voltage"] as? NSNumber)?.doubleValue {
            next.adapterVoltageV = v > 100 ? (v / 1000.0) : v
        }
        if let c = (adapterDetails["Current"] as? NSNumber)?.doubleValue
            ?? (adapterDetails["Amperage"] as? NSNumber)?.doubleValue {
            next.adapterCurrentA = c / 1000.0
        }
        next.adapterName = (adapterDetails["Description"] as? String)
            ?? (adapterDetails["Name"] as? String)
            ?? (externalConnected ? "AC Power Adapter" : "Disconnected")
        next.adapterManufacturer = (adapterDetails["Manufacturer"] as? String) ?? "Apple / USB-PD"
        next.adapterSerial = (adapterDetails["SerialString"] as? String) ?? "—"
        
        // 10. BMS Lifetime Black-Box Data
        if let maxT = (lifetimeData["MaximumTemperature"] as? NSNumber)?.doubleValue {
            next.lifetimeMaxTempC = maxT > 200 ? (maxT / 10.0) : maxT
        }
        if let minT = (lifetimeData["MinimumTemperature"] as? NSNumber)?.doubleValue {
            next.lifetimeMinTempC = minT > 200 ? (minT / 10.0) : minT
        }
        if let opTime = (lifetimeData["TotalOperatingTime"] as? NSNumber)?.intValue {
            next.totalOperatingHours = opTime
        }
        if let highSoc = (lifetimeData["TimeAtHighSoc"] as? NSNumber)?.intValue {
            next.highSocHours = highSoc
        }
        if let peakChg = (lifetimeData["MaximumChargeCurrent"] as? NSNumber)?.intValue {
            next.peakChargeCurrentMA = peakChg
        }
        if let peakDis = (lifetimeData["MaximumDischargeCurrent"] as? NSNumber)?.intValue {
            next.peakDischargeCurrentMA = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: peakDis)))
        }
        
        // 11. Hardware Identity
        next.deviceName = (mergedProps["DeviceName"] as? String)
            ?? (batteryData["DeviceName"] as? String) ?? "AppleSmartBattery"
        next.serialNumber = (mergedProps["Serial"] as? String)
            ?? (batteryData["Serial"] as? String) ?? "—"
        if let fw = mergedProps["GasGaugeFirmwareVersion"] {
            next.firmwareVersion = "\(fw)"
        }
        
        // 12. Power State & Time Remaining
        if externalConnected {
            if isCharging {
                next.powerState = .charging
            } else if fullyCharged || next.percentage >= 99 {
                next.powerState = .fullyCharged
            } else {
                next.powerState = .pluggedInHolding
            }
        } else {
            next.powerState = .discharging
        }
        
        let timeRem = readInt(["TimeRemaining", "AvgTimeToFull", "AvgTimeToEmpty"])
        if let t = timeRem, t > 0 && t < 6000 {
            next.timeRemainingMinutes = t
        }
        
        if next.liveWatts < 0 {
            sessionPeakDrawWatts = max(sessionPeakDrawWatts, abs(next.liveWatts))
        } else if next.liveWatts > 0 {
            sessionPeakChargeWatts = max(sessionPeakChargeWatts, next.liveWatts)
        }
        
        let sample = PowerSample(
            timestamp: Date(),
            batteryWatts: next.liveWatts,
            systemLoadWatts: next.systemLoadWatts,
            wallWatts: next.wallInputWatts,
            temperatureC: next.temperatureCelsius,
            percentage: next.percentage
        )
        history.append(sample)
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
        
        buildRawInspectorList(top: mergedProps, batteryData: batteryData, power: powerTelemetry, lifetime: lifetimeData)
        
        self.snapshot = next
        evaluateCustomAlerts(for: next)
    }
    
    private func extractProperties(from entry: io_registry_entry_t) -> [String: Any] {
        var propsPtr: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsPtr, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsPtr?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return props
    }
    
    private func buildRawInspectorList(top: [String: Any], batteryData: [String: Any], power: [String: Any], lifetime: [String: Any]) {
        var pairs: [(String, String)] = []
        for (k, v) in top where !(v is [String: Any]) && !(v is Data) {
            pairs.append(("Top.\(k)", "\(v)"))
        }
        for (k, v) in batteryData where !(v is [String: Any]) && !(v is Data) {
            pairs.append(("BatteryData.\(k)", "\(v)"))
        }
        for (k, v) in power {
            pairs.append(("PowerTelemetry.\(k)", "\(v)"))
        }
        for (k, v) in lifetime where !(v is Data) {
            pairs.append(("Lifetime.\(k)", "\(v)"))
        }
        rawRegistryPairs = pairs.sorted { $0.0 < $1.0 }
    }
    
    // MARK: - Alerts & Juicy-Style Full-Screen Neon Edge Glow
    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    private func evaluateCustomAlerts(for data: BatterySnapshot) {
        guard alertsEnabled, data.hasBattery else { return }
        
        if data.powerState == .discharging && Double(data.percentage) <= lowBatteryThreshold {
            let key = "low_\(Int(lowBatteryThreshold))"
            if lastAlertKey != key {
                lastAlertKey = key
                sendNotification(
                    title: "Low Battery (\(data.percentage)%)",
                    body: "Discharging at \(String(format: "%.1fW", abs(data.liveWatts))). Connect power soon."
                )
                if screenGlowEnabled { triggerScreenEdgeGlow(color: .systemOrange) }
            }
        } else if data.powerState == .charging && Double(data.percentage) >= highChargeLimitThreshold {
            let key = "high_\(Int(highChargeLimitThreshold))"
            if lastAlertKey != key {
                lastAlertKey = key
                sendNotification(
                    title: "Charge Target Reached (\(data.percentage)%)",
                    body: "Charging at \(String(format: "+%.1fW", data.liveWatts)). Unplug or hold charge to reduce cell wear."
                )
                if screenGlowEnabled { triggerScreenEdgeGlow(color: .systemGreen) }
            }
        } else if data.percentage > Int(lowBatteryThreshold) + 2 && data.percentage < Int(highChargeLimitThreshold) - 2 {
            lastAlertKey = ""
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
    
    func triggerScreenEdgeGlow(color: NSColor) {
        guard let screen = NSScreen.main else { return }
        glowWindow?.orderOut(nil)
        
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let box = NSView(frame: screen.frame)
        box.wantsLayer = true
        box.layer?.borderWidth = 10
        box.layer?.borderColor = color.withAlphaComponent(0.85).cgColor
        box.layer?.cornerRadius = 18
        box.layer?.shadowColor = color.cgColor
        box.layer?.shadowRadius = 28
        box.layer?.shadowOpacity = 1.0
        panel.contentView = box
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        self.glowWindow = panel
        
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1.0
        }, completionHandler: {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.2))
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.6
                    panel.animator().alphaValue = 0.0
                }, completionHandler: {
                    Task { @MainActor in
                        panel.orderOut(nil)
                    }
                })
            }
        })
    }
}
