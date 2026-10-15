import Foundation

nonisolated struct HistoryMean: Codable, Equatable, Sendable {
    private(set) var total: Double = 0
    private(set) var count: Int = 0
    var value: Double? { count > 0 ? total / Double(count) : nil }
    mutating func add(_ value: Double?) { if let value { total += value; count += 1 } }
    mutating func merge(_ other: Self) { total += other.total; count += other.count }
    func valid(in range: ClosedRange<Double>) -> Bool {
        (0...100_000).contains(count) && total.isFinite && (count == 0 ? total == 0 : value.map(range.contains) == true)
    }
}

nonisolated struct BatteryHistoryBucket: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(timestamp.timeIntervalSince1970)-\(segmentID)" }
    var timestamp: Date
    var lastSampleAt: Date
    var segmentID: UUID
    var onBattery: Bool
    var percentage: Int
    var battery = HistoryMean()
    var load = HistoryMean()
    var input = HistoryMean()
    var temperature = HistoryMean()
    mutating func merge(_ other: Self) {
        battery.merge(other.battery); load.merge(other.load); input.merge(other.input); temperature.merge(other.temperature)
        if other.lastSampleAt >= lastSampleAt { lastSampleAt = other.lastSampleAt; percentage = other.percentage }
    }
    var isValid: Bool {
        timestamp.timeIntervalSince1970.isFinite && lastSampleAt.timeIntervalSince1970.isFinite
            && timestamp.timeIntervalSince1970 >= 0 && lastSampleAt >= timestamp
            && (0...100).contains(percentage) && battery.valid(in: -300...300)
            && load.valid(in: 0...300) && input.valid(in: 0...300) && temperature.valid(in: -20...100)
    }
}

nonisolated struct BatteryHistory: Sendable {
    static let retention: TimeInterval = 7 * 24 * 3600
    static let maximumBuckets = 20_160
    private(set) var buckets: [BatteryHistoryBucket] = []
    private var previousDate: Date?
    private var previousShape: String?
    private var segmentID = UUID()
    private var lastPruneMinute: Int?

    init(buckets: [BatteryHistoryBucket] = [], now: Date = Date()) {
        self.buckets = Array(buckets.filter { $0.timestamp >= now.addingTimeInterval(-Self.retention) && $0.timestamp <= now }.suffix(Self.maximumBuckets))
    }
    mutating func breakContinuity() { previousDate = nil; previousShape = nil; segmentID = UUID() }
    mutating func record(at date: Date, onBattery: Bool, percentage: Int, battery: Double?, load: Double?, input: Double?, temperature: Double?) {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0, (0...100).contains(percentage) else { return }
        if let previousDate, date <= previousDate { return }
        func valid(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            value.flatMap { $0.isFinite && range.contains($0) ? $0 : nil }
        }
        let battery = valid(battery, -300...300), load = valid(load, 0...300), input = valid(input, 0...300)
        let temperature = valid(temperature, -20...100)
        let shape = "\(onBattery)-\(battery != nil)-\(load != nil)-\(input != nil)-\(temperature != nil)"
        if previousShape != shape || previousDate.map({ date.timeIntervalSince($0) > 15 }) == true { segmentID = UUID() }
        previousDate = date; previousShape = shape
        let minute = Int(date.timeIntervalSince1970 / 60)
        let timestamp = Date(timeIntervalSince1970: Double(minute) * 60)
        if buckets.last?.timestamp != timestamp || buckets.last?.segmentID != segmentID {
            buckets.append(BatteryHistoryBucket(timestamp: timestamp, lastSampleAt: date, segmentID: segmentID, onBattery: onBattery, percentage: percentage))
        }
        let index = buckets.count - 1
        buckets[index].lastSampleAt = date; buckets[index].percentage = percentage
        buckets[index].battery.add(battery); buckets[index].load.add(load); buckets[index].input.add(input); buckets[index].temperature.add(temperature)
        if lastPruneMinute != minute || buckets.count > Self.maximumBuckets {
            buckets.removeAll { $0.timestamp < date.addingTimeInterval(-Self.retention) || $0.timestamp > date }
            if buckets.count > Self.maximumBuckets { buckets.removeFirst(buckets.count - Self.maximumBuckets) }
            lastPruneMinute = minute
        }
    }
    /// Merge averages using their sample counts, preserving source/sensor/sleep boundaries.
    func chartBuckets(since start: Date, until end: Date, targetCount: Int = 180) -> [BatteryHistoryBucket] {
        let interval = max(60, ceil(end.timeIntervalSince(start) / Double(max(1, targetCount)) / 60) * 60)
        var result: [BatteryHistoryBucket] = []
        for bucket in buckets where bucket.timestamp >= start && bucket.timestamp <= end {
            let bin = Date(timeIntervalSince1970: floor(bucket.timestamp.timeIntervalSince1970 / interval) * interval)
            if let last = result.last, last.timestamp == bin && last.segmentID == bucket.segmentID {
                result[result.count - 1].merge(bucket)
            } else {
                var item = bucket; item.timestamp = bin; result.append(item)
            }
        }
        return result
    }
}

nonisolated struct BatteryArchive: Codable, Sendable {
    var version = 1
    var buckets: [BatteryHistoryBucket]
    var sessions: [BatterySession]
    func validate() throws {
        guard version == 1, buckets.count <= BatteryHistory.maximumBuckets, sessions.count <= 51,
              buckets.allSatisfy(\.isValid), Set(buckets.map(\.id)).count == buckets.count,
              zip(buckets, buckets.dropFirst()).allSatisfy({ $0.timestamp <= $1.timestamp }),
              Set(sessions.map(\.id)).count == sessions.count,
              sessions.allSatisfy({ session in
                  session.startedAt.timeIntervalSince1970.isFinite && session.lastObservedAt.timeIntervalSince1970.isFinite
                    && session.lastObservedAt >= session.startedAt && (0...100).contains(session.startPercentage)
                    && (0...100).contains(session.endPercentage) && session.observedSeconds.isFinite && session.observedSeconds >= 0
                    && session.measuredSeconds.isFinite && session.measuredSeconds >= 0 && session.measuredSeconds <= session.observedSeconds + 0.001
                    && session.observedSeconds <= session.lastObservedAt.timeIntervalSince(session.startedAt) + 0.001
                    && session.energyUsedWh.isFinite && session.energyUsedWh >= 0
                    && session.peakDrawWatts.isFinite && (0...300).contains(session.peakDrawWatts)
              }) else { throw CocoaError(.fileReadCorruptFile) }
    }
}

/// Serial utility queue keeps regular disk work out of the one-second telemetry loop.
/// A synchronous final flush joins earlier writes, so an old snapshot cannot overwrite it.
nonisolated final class BatteryArchiveStore: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "BatteryMonitor.archive", qos: .utility)
    init(url: URL) { self.url = url }
    func load() throws -> BatteryArchive? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let archive = try JSONDecoder().decode(BatteryArchive.self, from: Data(contentsOf: url))
        try archive.validate(); return archive
    }
    func save(_ archive: BatteryArchive, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            do { try write(archive); completion(nil) }
            catch { completion("Could not save local battery history: \(error.localizedDescription)") }
        }
    }
    func flush(_ archive: BatteryArchive) throws { try queue.sync { try write(archive) } }
    private func write(_ archive: BatteryArchive) throws {
        try archive.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }
}
