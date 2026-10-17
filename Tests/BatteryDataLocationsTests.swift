import Foundation
@main struct BatteryDataLocationsTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("battery-location-\(UUID().uuidString)")
        let suite = "BatteryLocationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: home); defaults.removePersistentDomain(forName: suite) }
        let current = home.appendingPathComponent("Library/Application Support/BatteryMonitor")
        check(BatteryDataLocations.directory(home: home).standardizedFileURL.path == current.standardizedFileURL.path, "Fresh installs use normal Application Support")
        let legacyLibrary = home.appendingPathComponent("Library/Containers/\(BatteryDataLocations.bundleID)/Data/Library")
        let legacy = legacyLibrary.appendingPathComponent("Application Support/BatteryMonitor")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let bytes = Data("preserve sqlite and WAL in place".utf8)
        try bytes.write(to: legacy.appendingPathComponent("usage-study-v1.sqlite"))
        try bytes.write(to: legacy.appendingPathComponent("usage-study-v1.sqlite-wal"))
        check(BatteryDataLocations.directory(home: home).standardizedFileURL.path == legacy.standardizedFileURL.path, "Existing study must be reused in place")
        check(try Data(contentsOf: legacy.appendingPathComponent("usage-study-v1.sqlite-wal")) == bytes, "WAL remains untouched")
        let preferencesDirectory = legacyLibrary.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        let preferences = preferencesDirectory.appendingPathComponent("\(BatteryDataLocations.bundleID).plist")
        let saved: [String: Any] = ["battery.preferences.v1": Data([1,2,3]), "study.recording.v1": false,
                                    "study.workload.v1": "Coding", "study.labels.v1": Data([4]), "unrelated": "never import"]
        try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0).write(to: preferences)
        BatteryDataLocations.importPreferences(home: home, defaults: defaults)
        check(defaults.data(forKey: "battery.preferences.v1") == Data([1,2,3]), "Battery appearance and alert preferences survive")
        check(defaults.object(forKey: "study.recording.v1") as? Bool == false, "Paused collection stays paused")
        check(defaults.string(forKey: "study.workload.v1") == "Coding", "Workload survives")
        check(defaults.object(forKey: "unrelated") == nil, "Only known application settings are imported")
        defaults.set(true, forKey: "study.recording.v1")
        BatteryDataLocations.importPreferences(home: home, defaults: defaults)
        check(defaults.bool(forKey: "study.recording.v1"), "Later user preferences are never overwritten")
        try Data("broken plist".utf8).write(to: preferences)
        BatteryDataLocations.importPreferences(home: home, defaults: defaults)
        check(defaults.bool(forKey: "study.recording.v1"), "Unreadable legacy preferences do not reset current settings")
        print("Data locations: existing history/WAL, preference migration, opt-outs and fresh install checks passed.")
    }
}
