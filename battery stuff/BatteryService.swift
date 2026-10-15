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

struct PowerSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let batteryWatts: Double
    let systemLoadWatts: Double
    let wallWatts: Double
    let temperatureC: Double?
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
    var temperatureCelsius: Double? = nil
    var temperatureReadingSource = "Unavailable"
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
    var powerReadingAvailable: Bool = false
    var inputReadingAvailable: Bool = false
    var powerReadingSource: String = "Unavailable"
    var usesLiveSensors: Bool = false
}

@MainActor
final class BatteryService: ObservableObject {
    @Published var snapshot = BatterySnapshot()
    @Published var history: [PowerSample] = []
    @Published private(set) var sessions = BatterySessionTracker()
    @Published var rawRegistryPairs: [(key: String, value: String)] = []
    
    // Menu Bar Appearance
    @Published var labelStyle: MenuBarLabelStyle = .wattsOnly { didSet { savePreferences() } }
    
    // Session Statistics
    @Published var sessionPeakDrawWatts: Double = 0.0
    @Published var sessionPeakChargeWatts: Double = 0.0
    
    // Custom Alerts & Screen Glow
    @Published var alertsEnabled: Bool = true { didSet { savePreferences() } }
    @Published var screenGlowEnabled: Bool = true { didSet { savePreferences() } }
    @Published var lowBatteryThreshold: Double = 20.0 { didSet { savePreferences() } }
    @Published var highChargeLimitThreshold: Double = 80.0 { didSet { savePreferences() } }
    
    private let preferencesStore = BatteryPreferencesStore()
    private let smc = SMCPowerReader()
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var lastRegistryToken: String?
    private var lastRegistryChange = Date()
    private var monitoringTask: Task<Void, Never>?
    private var lastAlertKey: String = ""
    private var glowWindow: NSWindow?
    
    init() {
        let preferences = preferencesStore.load()
        labelStyle = preferences.labelStyle
        alertsEnabled = preferences.alertsEnabled
        screenGlowEnabled = preferences.screenGlowEnabled
        lowBatteryThreshold = preferences.lowBatteryThreshold
        highChargeLimitThreshold = preferences.highChargeLimitThreshold
        requestNotificationPermissions()
        refresh()
        startMonitoring(interval: 1.0)
        installPowerNotifications()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }
    
    deinit {
        monitoringTask?.cancel()
        if let source = powerSourceRunLoopSource {
            CFRunLoopSourceInvalidate(source)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func savePreferences() {
        preferencesStore.save(BatteryPreferences(labelStyle: labelStyle, alertsEnabled: alertsEnabled,
                                                screenGlowEnabled: screenGlowEnabled, lowBatteryThreshold: lowBatteryThreshold,
                                                highChargeLimitThreshold: highChargeLimitThreshold))
    }

    private func installPowerNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSourceRunLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // This source is scheduled exclusively on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, context)?.takeRetainedValue()
        if let source = powerSourceRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    @objc private func willSleep(_ notification: Notification) { sessions.breakContinuity() }

    @objc private func didWake(_ notification: Notification) {
        sessions.breakContinuity()
        smc.reconnect()
        lastRegistryToken = nil
        history.removeAll()
        refresh()
    }

    private func systemPowerSource() -> [String: Any] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [:] }
        for source in list {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return description
            }
        }
        return [:]
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
            sessions.breakContinuity()
            snapshot = BatterySnapshot(hasBattery: false, powerState: .desktopAC)
            history.removeAll()
            rawRegistryPairs.removeAll()
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
        let rawAdapterDetails = mergedProps["AdapterDetails"] as? [String: Any] ?? [:]
        
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
        
        let source = systemPowerSource()
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
        
        // 5. Live sensors first; registry figures are a slower hardware fallback.
        let externalConnected = (source[kIOPSPowerSourceStateKey] as? String).map { $0 == kIOPSACPowerValue }
            ?? (mergedProps["ExternalConnected"] as? Bool) ?? false
        let isCharging = (source[kIOPSIsChargingKey] as? Bool)
            ?? (mergedProps["IsCharging"] as? Bool) ?? false
        let fullyCharged = (source[kIOPSIsChargedKey] as? Bool)
            ?? (mergedProps["FullyCharged"] as? Bool) ?? false
        if let current = source[kIOPSCurrentCapacityKey] as? NSNumber,
           let maximum = source[kIOPSMaxCapacityKey] as? NSNumber, maximum.doubleValue > 0 {
            next.percentage = min(100, max(0, Int((current.doubleValue / maximum.doubleValue * 100).rounded())))
        }

        let voltage = readInt(["AppleRawBatteryVoltage", "Voltage"], minValid: 1000) ?? 0
        let currentNumber = (mergedProps["InstantAmperage"] as? NSNumber)
            ?? (batteryData["InstantAmperage"] as? NSNumber)
            ?? (mergedProps["Amperage"] as? NSNumber)
            ?? (batteryData["Amperage"] as? NSNumber)
        // Some drivers expose negative current as an unsigned 32- or 64-bit integer.
        let amperage = currentNumber.map { PowerTelemetry.signedValue($0) } ?? 0
        next.voltageMV = voltage
        next.amperageMA = amperage
        let gaugeWatts: Double? = currentNumber != nil && voltage > 0
            ? Double(voltage) * Double(amperage) / 1_000_000 : nil
        let telemetryWatts = (powerTelemetry["BatteryPower"] as? NSNumber).map {
            Double(PowerTelemetry.signedValue($0)) / 1000
        }
        let registryWatts = telemetryWatts.flatMap { abs($0) <= 300 ? $0 : nil } ?? gaugeWatts
        let tokenKeys = ["BatteryPowerAccumulatorCount", "SystemLoadAccumulatorCount", "SystemPowerInAccumulatorCount"]
        let counters = tokenKeys.compactMap { powerTelemetry[$0].map { String(describing: $0) } }
        let token = counters.isEmpty ? String(describing: mergedProps["UpdateTime"] ?? "") : counters.joined(separator: ":")
        if lastRegistryToken != token {
            lastRegistryToken = token
            lastRegistryChange = Date()
        }
        let registryFresh = Date().timeIntervalSince(lastRegistryChange) < 90
        let live = smc.read()
        let watts = live?.batteryWatts ?? (registryFresh ? registryWatts : nil)
        // Suppress a positive reading left behind by the gauge after unplugging.
        let validWatts = PowerTelemetry.validBatteryWatts(watts, externalConnected: externalConnected)
        next.powerReadingAvailable = validWatts != nil
        next.liveWatts = validWatts ?? 0
        next.usesLiveSensors = live != nil
        next.powerReadingSource = live != nil ? "Live SMC · 1 s" : (next.powerReadingAvailable ? "Registry · slower updates" : "Waiting for power telemetry")
        if let live {
            next.voltageMV = Int((live.voltageV * 1000).rounded())
            next.amperageMA = Int((live.currentA * 1000).rounded())
        }

        let nominalVolts = next.voltageMV > 5000 ? Double(next.voltageMV) / 1000 : 11.4
        next.currentEnergyWH = Double(rawCurrMAH) * nominalVolts / 1000
        next.maxEnergyWH = Double(effectiveMaxMAH) * nominalVolts / 1000
        next.designEnergyWH = Double(designMAH) * 11.4 / 1000
        if effectiveMaxMAH > 0 && next.powerReadingAvailable {
            next.chargeRatePercentPerHour = Double(next.amperageMA) / Double(effectiveMaxMAH) * 100
        }

        let registryInput = (powerTelemetry["SystemPowerIn"] as? NSNumber)?.doubleValue
        let input = live?.adapterWatts ?? (registryFresh ? registryInput.map { $0 / 1000 } : nil)
        next.inputReadingAvailable = !externalConnected || input.map { (0...300).contains($0) } == true
        next.wallInputWatts = externalConnected && next.inputReadingAvailable ? (input ?? 0) : 0
        let sysLoadMW = (powerTelemetry["SystemLoad"] as? NSNumber)?.doubleValue ?? 0
        if !externalConnected {
            next.systemLoadWatts = abs(min(0, next.liveWatts))
        } else if live?.adapterWatts != nil && next.powerReadingAvailable {
            next.systemLoadWatts = max(0, next.wallInputWatts - next.liveWatts)
        } else if registryFresh && sysLoadMW > 0 && sysLoadMW < 300_000 {
            next.systemLoadWatts = sysLoadMW / 1000
        } else if next.inputReadingAvailable && next.powerReadingAvailable {
            next.systemLoadWatts = max(0, next.wallInputWatts - next.liveWatts)
        }
        if externalConnected && registryFresh {
            next.adapterLossWatts = max(0, (powerTelemetry["AdapterEfficiencyLoss"] as? NSNumber)?.doubleValue ?? 0) / 1000
        }

        // 6. Some macOS versions omit temperature from AppleSmartBattery entirely.
        let registryTemperature = PowerTelemetry.registryTemperature(
            virtual: (mergedProps["VirtualTemperature"] as? NSNumber)?.doubleValue ?? (batteryData["VirtualTemperature"] as? NSNumber)?.doubleValue,
            raw: (mergedProps["Temperature"] as? NSNumber)?.doubleValue ?? (batteryData["Temperature"] as? NSNumber)?.doubleValue)
        let sensorTemperature = smc.readBatteryTemperature()
        next.temperatureCelsius = sensorTemperature ?? registryTemperature
        next.temperatureReadingSource = sensorTemperature != nil ? "Live SMC" : (registryTemperature != nil ? "Battery registry" : "Unavailable")
        next.isThermalWarning = next.temperatureCelsius.map { $0 >= 40 } ?? false

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
        let adapterDetails = externalConnected ? rawAdapterDetails : [:]
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
        next.adapterManufacturer = (adapterDetails["Manufacturer"] as? String) ?? (externalConnected ? "Apple / USB-PD" : "—")
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
        
        let timeRem: Int?
        if next.powerState == .charging {
            timeRem = (source[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue ?? readInt(["AvgTimeToFull", "TimeRemaining"])
        } else if next.powerState == .discharging {
            timeRem = (source[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue ?? readInt(["AvgTimeToEmpty", "TimeRemaining"])
        } else {
            timeRem = nil
        }
        if let t = timeRem, t > 0 && t < 6000 {
            next.timeRemainingMinutes = t
        }
        
        if next.liveWatts < 0 {
            sessionPeakDrawWatts = max(sessionPeakDrawWatts, abs(next.liveWatts))
        } else if next.liveWatts > 0 {
            sessionPeakChargeWatts = max(sessionPeakChargeWatts, next.liveWatts)
        }
        
        sessions.observe(at: Date(), onBattery: !externalConnected, percentage: next.percentage,
                         watts: next.powerReadingAvailable ? next.liveWatts : nil)

        let sample = PowerSample(
            timestamp: Date(),
            batteryWatts: next.liveWatts,
            systemLoadWatts: next.systemLoadWatts,
            wallWatts: next.wallInputWatts,
            temperatureC: next.temperatureCelsius,
            percentage: next.percentage
        )
        if next.powerReadingAvailable,
           history.last.map({ sample.timestamp.timeIntervalSince($0.timestamp) >= 0.8 }) ?? true {
            history.append(sample)
        }
        history.removeAll { Date().timeIntervalSince($0.timestamp) > 120 }
        
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
