import Foundation
@main struct BatteryPreferencesTests {
    static func main() throws {
        let suite = "BatteryMonitor.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BatteryPreferencesStore(defaults: defaults)
        assert(store.load() == BatteryPreferences())
        let preferences = BatteryPreferences(labelStyle: .percentAndTemp, alertsEnabled: false, screenGlowEnabled: false, lowBatteryThreshold: 15, highChargeLimitThreshold: 90)
        store.save(preferences)
        assert(BatteryPreferencesStore(defaults: UserDefaults(suiteName: suite)!).load() == preferences)
        store.save(BatteryPreferences(lowBatteryThreshold: -.infinity, highChargeLimitThreshold: 200))
        assert(store.load().lowBatteryThreshold == 20 && store.load().highChargeLimitThreshold == 100)
        defaults.set(Data("invalid".utf8), forKey: "battery.preferences.v1")
        assert(store.load() == BatteryPreferences())
        print("Battery preference persistence, bounds, and corrupt-data checks passed.")
    }
}
