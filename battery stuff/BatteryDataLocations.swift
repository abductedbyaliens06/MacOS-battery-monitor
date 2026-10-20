import Foundation

/// The standalone build reuses existing container data in place, including SQLite
/// WAL files. Never copy an active database or silently start a second history.
nonisolated enum BatteryDataLocations {
    static let bundleID = "devplaceholder.J4K1HORZ.battery-stuff"
    static var directory: URL { directory(home: FileManager.default.homeDirectoryForCurrentUser) }
    static func directory(home: URL) -> URL {
        let legacy = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/BatteryMonitor")
        let current = home.appendingPathComponent("Library/Application Support/BatteryMonitor")
        let files = ["history-v1.json", "usage-study-v1.sqlite"]
        if files.contains(where: { FileManager.default.fileExists(atPath: legacy.appendingPathComponent($0).path) }) {
            return legacy
        }
        return current
    }
    static func importPreferences(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  defaults: UserDefaults = .standard) {
        let url = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
        guard let data = try? Data(contentsOf: url), data.count <= 2_000_000,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for key in ["battery.preferences.v1", "study.recording.v1", "study.workload.v1", "study.labels.v1"] where defaults.object(forKey: key) == nil {
            if let value = plist[key] { defaults.set(value, forKey: key) }
        }
    }
}
