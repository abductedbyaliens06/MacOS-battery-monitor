import Foundation
@main struct BatteryHistoryTests {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var history = BatteryHistory(now: start)
        for second in 0..<60 {
            history.record(at: start.addingTimeInterval(Double(second)), onBattery: true, percentage: 80, battery: -10, load: 10, input: 0, temperature: 30)
        }
        assert(history.buckets.count == 1 && history.buckets[0].battery.value == -10)
        history.record(at: start.addingTimeInterval(60), onBattery: false, percentage: 80, battery: 20, load: 10, input: 30, temperature: 31)
        assert(history.buckets.count == 2 && history.buckets[0].segmentID != history.buckets[1].segmentID)
        history.record(at: start.addingTimeInterval(61), onBattery: false, percentage: 80, battery: nil, load: nil, input: 30, temperature: nil)
        history.record(at: start.addingTimeInterval(62), onBattery: false, percentage: 80, battery: 30, load: 10, input: 40, temperature: 31)
        assert(history.buckets.count == 4 && history.buckets[2].battery.value == nil)
        assert(history.buckets[1].segmentID != history.buckets[3].segmentID)
        history.record(at: start.addingTimeInterval(3600), onBattery: false, percentage: 82, battery: 25, load: 10, input: 35, temperature: 32)
        assert(history.buckets[3].segmentID != history.buckets[4].segmentID)
        let chart = history.chartBuckets(since: start, until: start.addingTimeInterval(3600), targetCount: 1)
        assert(chart.count == 5) // Downsampling never bridges segment boundaries.
        var weighted = BatteryHistory(now: start)
        for second in 0...120 {
            weighted.record(at: start.addingTimeInterval(Double(second)), onBattery: true, percentage: 80, battery: second < 60 ? -10 : -20, load: 10, input: 0, temperature: 30)
        }
        let points = weighted.chartBuckets(since: start, until: start.addingTimeInterval(120), targetCount: 1)
        assert(points.count == 2)
        assert(abs(points[0].battery.value! - (-15)) < 0.00001)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BatteryArchiveStore(url: folder.appendingPathComponent("history.json"))
        let initial = try store.load(); assert(initial == nil)
        let archive = BatteryArchive(buckets: history.buckets, sessions: [])
        store.save(BatteryArchive(buckets: [], sessions: [])) { _ in }
        try store.flush(archive)
        let loaded = try store.load()!; assert(loaded.buckets == archive.buckets)
        var restored = BatteryHistory(buckets: try store.load()!.buckets, now: start.addingTimeInterval(3600))
        restored.record(at: start.addingTimeInterval(3601), onBattery: false, percentage: 82, battery: 25, load: 10, input: 35, temperature: 32)
        assert(restored.buckets.last!.segmentID != history.buckets.last!.segmentID)
        let expired = BatteryHistory(buckets: history.buckets, now: start.addingTimeInterval(8 * 86400))
        assert(expired.buckets.isEmpty)
        var corrupt = archive; corrupt.version = 99
        do { try corrupt.validate(); fatalError("Invalid version accepted") } catch { }
        corrupt = archive; corrupt.buckets[0].percentage = 101
        do { try corrupt.validate(); fatalError("Invalid bucket accepted") } catch { }
        try Data("corrupt".utf8).write(to: store.url)
        do { _ = try store.load(); fatalError("Corrupt JSON accepted") } catch { }
        var bounded = BatteryHistory(now: start)
        for second in 0...(BatteryHistory.maximumBuckets + 2) {
            bounded.record(at: start.addingTimeInterval(Double(second)), onBattery: second.isMultiple(of: 2), percentage: 80,
                           battery: -10, load: 10, input: 0, temperature: 30)
        }
        assert(bounded.buckets.count == BatteryHistory.maximumBuckets)
        bounded.record(at: start.addingTimeInterval(8 * 86400), onBattery: true, percentage: 70, battery: -10, load: 10, input: 0, temperature: 30)
        assert(bounded.buckets.count == 1)
        print("Battery history aggregation, gaps, weighted charts, retention, restart, atomic write ordering, and corruption checks passed.")
    }
}
