import Foundation
import SQLite3

/// All access is serialized by UsageStudyWorker. Each write contains only new intervals.
nonisolated final class UsageStudyStore {
    static let retention: Double = 7 * 86400
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw CocoaError(.fileReadUnknown)
        }
        do {
            try execute("PRAGMA busy_timeout=2000; PRAGMA auto_vacuum=INCREMENTAL; PRAGMA max_page_count=16384; PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=32;")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT OR IGNORE INTO metadata VALUES ('version', '1');")
            var version: String?
            try rows("SELECT value FROM metadata WHERE key='version'") { statement in version = String(cString: sqlite3_column_text(statement, 0)) }
            guard version == "1" else { throw CocoaError(.fileReadCorruptFile) }
            try execute("CREATE TABLE IF NOT EXISTS minutes (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS minutes_time ON minutes(timestamp);")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { throw CocoaError(.fileReadCorruptFile) }
        return query
    }
    private func rows(_ sql: String, since: Date? = nil, _ body: (OpaquePointer) throws -> Void) throws {
        let query = try statement(sql); defer { sqlite3_finalize(query) }
        if let since { sqlite3_bind_double(query, 1, since.timeIntervalSince1970) }
        var step = sqlite3_step(query)
        while step == SQLITE_ROW { try body(query); step = sqlite3_step(query) }
        guard step == SQLITE_DONE else { throw CocoaError(.fileReadCorruptFile) }
    }
    private func payload(_ query: OpaquePointer, column: Int32 = 0) throws -> Data {
        let size = Int(sqlite3_column_bytes(query, column))
        guard size > 0, size < 256_000, let bytes = sqlite3_column_blob(query, column) else { throw CocoaError(.fileReadCorruptFile) }
        return Data(bytes: bytes, count: size)
    }
    func save(_ updates: [String: StudyMinute], now: Date) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for update in updates.values {
                var minute = update
                let select = try statement("SELECT payload FROM minutes WHERE id=?")
                sqlite3_bind_text(select, 1, update.id, -1, transient)
                let step = sqlite3_step(select)
                if step == SQLITE_ROW {
                    do {
                        var existing = try decoder.decode(StudyMinute.self, from: payload(select))
                        existing.observedSeconds += update.observedSeconds; existing.batterySeconds += update.batterySeconds
                        existing.energyWh += update.energyWh; existing.samples += update.samples
                        existing.temperatureTotal += update.temperatureTotal; existing.temperatureCount += update.temperatureCount
                        existing.attempted += update.attempted; existing.denied += update.denied
                        existing.newProcesses += update.newProcesses; existing.omittedGroups += update.omittedGroups
                        existing.discoveryLimitedSamples = (existing.discoveryLimitedSamples ?? 0) + (update.discoveryLimitedSamples ?? 0)
                        var groups = Dictionary(existing.groups.map { ($0.id + "|" + $0.importance.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
                        for group in update.groups {
                            let key = group.id + "|" + group.importance.rawValue
                            if var old = groups[key] { old.merge(group); groups[key] = old } else { groups[key] = group }
                        }
                        existing.omittedGroups += max(0, groups.count - 40)
                        existing.groups = Array(groups.values.sorted { $0.cpuSeconds > $1.cpuSeconds }.prefix(40))
                        if existing.source != update.source { existing.source = "Mixed sources" }
                        minute = existing
                    } catch { sqlite3_finalize(select); throw error }
                } else if step != SQLITE_DONE { sqlite3_finalize(select); throw CocoaError(.fileReadCorruptFile) }
                sqlite3_finalize(select)
                try minute.validate()
                let data = try encoder.encode(minute)
                let insert = try statement("INSERT OR REPLACE INTO minutes VALUES (?, ?, ?)")
                defer { sqlite3_finalize(insert) }
                sqlite3_bind_text(insert, 1, minute.id, -1, transient)
                sqlite3_bind_double(insert, 2, minute.timestamp.timeIntervalSince1970)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(insert, 3, $0.baseAddress, Int32($0.count), transient) }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
            }
            let prune = try statement("DELETE FROM minutes WHERE timestamp < ?")
            sqlite3_bind_double(prune, 1, now.addingTimeInterval(-Self.retention).timeIntervalSince1970)
            guard sqlite3_step(prune) == SQLITE_DONE else { sqlite3_finalize(prune); throw CocoaError(.fileWriteUnknown) }
            sqlite3_finalize(prune)
            try execute("DELETE FROM minutes WHERE id IN (SELECT id FROM minutes ORDER BY timestamp DESC LIMIT -1 OFFSET 20000); COMMIT;")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    static func erase(at url: URL) throws {
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
    func clear() throws { try execute("DELETE FROM minutes; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;") }

    func report(since: Date, now: Date, labels: [String: StudyImportance]) throws -> StudyReport {
        var report = StudyReport(since: since, until: now)
        var groups: [String: StudyGroup] = [:]
        var points: [Int: (wh: Double, seconds: Double)] = [:]
        try rows("SELECT payload FROM minutes WHERE timestamp >= ? ORDER BY timestamp", since: since) { query in
            let minute = try decoder.decode(StudyMinute.self, from: payload(query))
            try minute.validate()
            report.intervals += minute.samples; report.seconds += minute.observedSeconds
            report.batterySeconds += minute.batterySeconds; report.energyWh += minute.energyWh
            report.attempted += minute.attempted; report.denied += minute.denied
            report.newProcesses += minute.newProcesses; report.omittedGroups += minute.omittedGroups
            report.discoveryLimitedSamples += minute.discoveryLimitedSamples ?? 0
            // Ten-minute bins bound chart marks even for a seven-day study.
            let slot = Int(minute.timestamp.timeIntervalSince1970 / 600)
            var point = points[slot] ?? (0, 0)
            point.wh += minute.energyWh; point.seconds += minute.batterySeconds; points[slot] = point
            for var group in minute.groups {
                report.awayCPUSeconds += group.awayCPUSeconds
                group.importance = labels[group.id] ?? .unclassified
                if var old = groups[group.id] { old.merge(group); groups[group.id] = old }
                else if groups.count < 5000 { groups[group.id] = group }
                else { report.omittedGroups += 1 }
            }
        }
        report.groups = groups.values.sorted { $0.cpuSeconds == $1.cpuSeconds ? $0.id < $1.id : $0.cpuSeconds > $1.cpuSeconds }
        var previousSlot: Int?
        var segment = 0
        for slot in points.keys.sorted() {
            let point = points[slot]!
            guard point.seconds > 0 else { continue }
            if let previousSlot, slot - previousSlot > 1 { segment += 1 }
            report.timeline.append(StudyTimelinePoint(date: Date(timeIntervalSince1970: Double(slot) * 600), watts: point.wh * 3600 / point.seconds, segment: segment))
            previousSlot = slot
        }
        return report
    }

    /// Streaming export avoids loading the entire study into RAM.
    func export(to destination: URL, labels: [String: StudyImportance], now: Date) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".study-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        do {
            try file.write(contentsOf: Data("{\"version\":1,\"powerAttribution\":\"Whole-Mac battery draw only; process watts unavailable\",\"labels\":".utf8))
            try file.write(contentsOf: encoder.encode(labels))
            try file.write(contentsOf: Data(",\"minutes\":[".utf8))
            var first = true
            try rows("SELECT payload FROM minutes WHERE timestamp >= ? ORDER BY timestamp", since: now.addingTimeInterval(-Self.retention)) { query in
                if !first { try file.write(contentsOf: Data(",".utf8)) }; first = false
                try file.write(contentsOf: payload(query))
            }
            try file.write(contentsOf: Data("]}".utf8)); try file.synchronize(); try file.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch { try? file.close(); throw error }
    }
}
