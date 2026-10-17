import Foundation

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
    let systemLoadWatts: Double?
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
    var systemLoadReadingAvailable = false
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

