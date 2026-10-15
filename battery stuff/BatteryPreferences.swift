import Foundation

enum MenuBarLabelStyle: String, CaseIterable, Identifiable, Codable {
    case percentAndWatts = "Percentage + Battery Watts"
    case wattsOnly = "Battery Watts (Default)"
    case inputWatts = "Charger Input Watts"
    case systemWatts = "System Load Watts"
    case percentAndSysLoad = "91% • Sys 8.3W"
    case percentAndTemp = "91% • 31.2°C"
    case percentOnly = "91% (Compact)"
    var id: String { rawValue }
}

struct BatteryPreferences: Codable, Equatable {
    var labelStyle: MenuBarLabelStyle = .wattsOnly
    var alertsEnabled = true
    var screenGlowEnabled = true
    var lowBatteryThreshold: Double = 20
    var highChargeLimitThreshold: Double = 80

    var validated: Self {
        var result = self
        result.lowBatteryThreshold = lowBatteryThreshold.isFinite ? min(45, max(5, lowBatteryThreshold)) : 20
        result.highChargeLimitThreshold = highChargeLimitThreshold.isFinite ? min(100, max(50, highChargeLimitThreshold)) : 80
        return result
    }
}

struct BatteryPreferencesStore {
    let defaults: UserDefaults
    private let key = "battery.preferences.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> BatteryPreferences {
        guard let data = defaults.data(forKey: key), let preferences = try? JSONDecoder().decode(BatteryPreferences.self, from: data) else {
            return BatteryPreferences()
        }
        return preferences.validated
    }
    func save(_ preferences: BatteryPreferences) {
        guard let data = try? JSONEncoder().encode(preferences.validated) else { return }
        defaults.set(data, forKey: key)
    }
}
