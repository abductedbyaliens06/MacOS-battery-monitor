import Foundation

nonisolated enum StudyImportance: String, CaseIterable, Codable, Identifiable, Sendable {
    case unclassified = "Unclassified", urgent = "Waiting for results", normal = "Normal", flexible = "Can finish later"
    var id: String { rawValue }
}
nonisolated enum StudyWorkload: String, CaseIterable, Codable, Identifiable, Sendable {
    case unclassified = "Unclassified", coding = "Coding", tests = "Tests / build", browsing = "Browsing", video = "Video", editing = "Editing", other = "Other"
    var id: String { rawValue }
}
nonisolated enum StudyActivity: String, Codable, Sendable {
    case active = "Active", away = "Away", screenOff = "Screen off"
}
nonisolated struct StudyApp: Sendable {
    var key: String
    var name: String
}
nonisolated struct StudyProcess: Sendable {
    var pid: Int32
    var parent: Int32
    var started: UInt64
    var name: String
    var cpuNS: UInt64
    var backgroundNS: UInt64
    var footprint: UInt64
    var readBytes: UInt64
    var writeBytes: UInt64
    var identity: String { "\(pid):\(started)" }
}
nonisolated struct StudyContext: Codable, Equatable, Sendable {
    var activity: StudyActivity
    var foregroundKey: String
    var foregroundName: String
    var workload: StudyWorkload
    var onBattery: Bool
    var lowPowerMode: Bool
    var thermal: Int
    var displayCount: Int
    var refreshRates: [Double]
    // Public brightness telemetry is not available on all displays; never guess it.
    var brightness: Double? = nil
    var memoryPressure: Int? = nil
}
nonisolated struct StudyFrame: Sendable {
    var date: Date
    var uptime: Double
    var context: StudyContext
    var batteryDraw: Double?
    var batterySource: String
    var temperature: Double?
    var processes: [StudyProcess]
    var apps: [Int32: StudyApp]
    var attempted: Int
    var denied: Int
    var scanMS: Double
    var discoveryLimited = false
}
nonisolated struct StudyGroup: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var cpuSeconds: Double = 0
    var backgroundCPUSeconds: Double = 0
    var awayCPUSeconds: Double = 0
    var footprintPeak: UInt64 = 0
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
    var observations: Int = 0
    var activitySeconds: Double = 0
    // Whole-Mac power during overlapping activity, never per-process wattage.
    var coincidentWh: Double = 0
    var coincidentSeconds: Double = 0
    var importance: StudyImportance = .unclassified
    var averageCPU: Double { activitySeconds > 0 ? cpuSeconds / activitySeconds * 100 : 0 }
    var coincidentWatts: Double? { coincidentSeconds > 0 ? coincidentWh * 3600 / coincidentSeconds : nil }
    mutating func merge(_ other: Self) {
        cpuSeconds += other.cpuSeconds; backgroundCPUSeconds += other.backgroundCPUSeconds
        awayCPUSeconds += other.awayCPUSeconds; footprintPeak = max(footprintPeak, other.footprintPeak)
        readBytes += other.readBytes; writeBytes += other.writeBytes
        observations += other.observations; activitySeconds += other.activitySeconds
        coincidentWh += other.coincidentWh; coincidentSeconds += other.coincidentSeconds
    }
}
nonisolated struct StudyMinute: Codable, Identifiable, Sendable {
    var id: String
    var timestamp: Date
    var context: StudyContext
    var observedSeconds: Double = 0
    var batterySeconds: Double = 0
    var energyWh: Double = 0
    var temperatureTotal: Double = 0
    var temperatureCount: Int = 0
    var samples: Int = 0
    var attempted: Int = 0
    var denied: Int = 0
    var newProcesses: Int = 0
    var omittedGroups: Int = 0
    var source: String
    var discoveryLimitedSamples: Int? = nil
    var groups: [StudyGroup] = []
    func validate() throws {
        guard timestamp.timeIntervalSince1970.isFinite, (0...4_500_000_000).contains(timestamp.timeIntervalSince1970),
              observedSeconds.isFinite, (0...180).contains(observedSeconds),
              batterySeconds.isFinite, (0...observedSeconds).contains(batterySeconds),
              energyWh.isFinite, energyWh >= 0, energyWh <= batterySeconds * 300 / 3600 + 0.001,
              temperatureTotal.isFinite, temperatureCount >= 0, temperatureCount <= 200,
              samples >= 0, samples <= 200, attempted >= 0, denied >= 0, newProcesses >= 0,
              groups.count <= 40, id.count < 16_000, source.count < 500,
              groups.allSatisfy({ group in
                  !group.id.isEmpty && group.id.count < 1000 && group.name.count <= 200
                  && group.cpuSeconds.isFinite && group.cpuSeconds >= 0 && group.cpuSeconds <= observedSeconds * 1024
                  && group.backgroundCPUSeconds.isFinite && group.backgroundCPUSeconds >= 0
                  && group.awayCPUSeconds.isFinite && group.awayCPUSeconds >= 0
                  && group.activitySeconds.isFinite && group.activitySeconds >= 0 && group.activitySeconds <= observedSeconds + 0.001
                  && group.coincidentWh.isFinite && group.coincidentWh >= 0
                  && group.coincidentSeconds.isFinite && group.coincidentSeconds >= 0 && group.coincidentSeconds <= batterySeconds + 0.001
              }) else { throw CocoaError(.fileReadCorruptFile) }
    }
}
nonisolated struct StudyReport: Sendable {
    var since = Date()
    var until = Date()
    var intervals = 0
    var seconds: Double = 0
    var batterySeconds: Double = 0
    var energyWh: Double = 0
    var awayCPUSeconds: Double = 0
    var attempted = 0
    var denied = 0
    var newProcesses = 0
    var omittedGroups = 0
    var discoveryLimitedSamples = 0
    var groups: [StudyGroup] = []
    var timeline: [StudyTimelinePoint] = []
    var monitorCPU: Double?
    var monitorFootprint: UInt64?
    var scanMS: Double = 0
    var averageWatts: Double? { batterySeconds > 0 ? energyWh * 3600 / batterySeconds : nil }
}
nonisolated struct StudyTimelinePoint: Identifiable, Sendable {
    var id: Date { date }
    var date: Date
    var watts: Double
    var segment: Int
}

/// Counter baselines live only in RAM. Restart, sleep, pause and gaps never bridge energy.
nonisolated struct StudyAccumulator {
    private var previous: StudyFrame?
    private(set) var pending: [String: StudyMinute] = [:]
    mutating func breakContinuity() { previous = nil }
    mutating func reset() { previous = nil; pending = [:] }
    mutating func didSave() { pending = [:] }

    static func group(for process: StudyProcess, processes: [Int32: StudyProcess], apps: [Int32: StudyApp]) -> StudyApp {
        // Keep Python jobs distinct even when launched inside Terminal or an IDE.
        func python(_ p: StudyProcess) -> Bool { p.name.lowercased().hasPrefix("python") || p.name.lowercased().hasPrefix("pytest") }
        var cursor = process
        var pythonRoot: StudyProcess? = python(process) ? process : nil
        var visited: Set<Int32> = []
        var app: StudyApp?
        for _ in 0..<64 {
            guard visited.insert(cursor.pid).inserted else { break }
            if app == nil { app = apps[cursor.pid] }
            guard let parent = processes[cursor.parent] else { break }
            if python(parent) { pythonRoot = parent }
            cursor = parent
        }
        if let root = pythonRoot { return StudyApp(key: "job:\(root.identity)", name: "\(root.name) · PID \(root.pid)") }
        return app ?? StudyApp(key: "process:\(process.name)", name: process.name)
    }

    mutating func record(_ frame: StudyFrame, labels: [String: StudyImportance]) {
        defer { previous = frame }
        guard let old = previous else { return }
        let dt = frame.uptime - old.uptime
        let wallDT = frame.date.timeIntervalSince(old.date)
        guard dt > 0, dt <= 15, abs(wallDT - dt) < 2 else { return }
        // An activity/app/power transition has no reliable interval-level attribution.
        guard frame.context == old.context else { return }
        let timestamp = Date(timeIntervalSince1970: floor(frame.date.timeIntervalSince1970 / 60) * 60)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encodedContext = (try? encoder.encode(frame.context)) ?? Data()
        let id = "\(Int(timestamp.timeIntervalSince1970))|\(encodedContext.base64EncodedString())"
        var minute = pending[id] ?? StudyMinute(id: id, timestamp: timestamp, context: frame.context, source: frame.batterySource)
        minute.observedSeconds += dt; minute.samples += 1
        minute.attempted += frame.attempted; minute.denied += frame.denied
        minute.discoveryLimitedSamples = (minute.discoveryLimitedSamples ?? 0) + (frame.discoveryLimited ? 1 : 0)
        var energy: Double?
        if frame.context.onBattery, old.batterySource == frame.batterySource,
           let before = old.batteryDraw, let after = frame.batteryDraw,
           before.isFinite, after.isFinite, (0...300).contains(before), (0...300).contains(after) {
            energy = (before + after) / 2 * dt / 3600
            minute.energyWh += energy!; minute.batterySeconds += dt
        }
        if let temp = frame.temperature, temp.isFinite, (-20...120).contains(temp) {
            minute.temperatureTotal += temp; minute.temperatureCount += 1
        }
        let previousProcesses = Dictionary(old.processes.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        let processes = Dictionary(frame.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var grouped: [String: StudyGroup] = [:]
        for process in frame.processes {
            guard let prior = previousProcesses[process.identity], process.cpuNS >= prior.cpuNS else {
                minute.newProcesses += 1; continue
            }
            let app = Self.group(for: process, processes: processes, apps: frame.apps)
            var group = grouped[app.key] ?? StudyGroup(id: app.key, name: app.name, importance: labels[app.key] ?? .unclassified)
            let cpu = Double(process.cpuNS - prior.cpuNS) / 1e9
            group.cpuSeconds += cpu
            group.backgroundCPUSeconds += process.backgroundNS >= prior.backgroundNS ? Double(process.backgroundNS - prior.backgroundNS) / 1e9 : 0
            if frame.context.activity != .active { group.awayCPUSeconds += cpu }
            group.footprintPeak += process.footprint
            group.readBytes += process.readBytes >= prior.readBytes ? process.readBytes - prior.readBytes : 0
            group.writeBytes += process.writeBytes >= prior.writeBytes ? process.writeBytes - prior.writeBytes : 0
            grouped[app.key] = group
        }
        var merged = Dictionary(minute.groups.map { ($0.id + "|" + $0.importance.rawValue, $0) }, uniquingKeysWith: { a, b in var g = a; g.merge(b); return g })
        for var group in grouped.values {
            group.activitySeconds = dt; group.observations = 1
            if group.cpuSeconds > 0.05, let energy {
                group.coincidentWh = energy; group.coincidentSeconds = dt
            }
            let key = group.id + "|" + group.importance.rawValue
            if var existing = merged[key] { existing.merge(group); merged[key] = existing }
            else { merged[key] = group }
        }
        let sorted = merged.values.sorted { $0.cpuSeconds == $1.cpuSeconds ? $0.id < $1.id : $0.cpuSeconds > $1.cpuSeconds }
        minute.omittedGroups += max(0, sorted.count - 40)
        minute.groups = Array(sorted.prefix(40))
        pending[id] = minute
    }
}
