import Foundation

nonisolated struct BatterySession: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var startedAt: Date
    var lastObservedAt: Date
    var startedAtUnplug: Bool
    var startPercentage: Int
    var endPercentage: Int
    var observedSeconds: Double = 0
    var measuredSeconds: Double = 0
    var energyUsedWh: Double = 0
    var peakDrawWatts: Double = 0
    var percentagePointsUsed: Int { max(0, startPercentage - endPercentage) }
    var averageDrawWatts: Double? { measuredSeconds >= 1 ? energyUsedWh * 3600 / measuredSeconds : nil }
    var coverage: Double { observedSeconds > 0 ? min(1, measuredSeconds / observedSeconds) : 0 }
}

nonisolated struct BatterySessionTracker: Sendable {
    private(set) var current: BatterySession?
    private(set) var completed: [BatterySession] = []
    private var previous: Observation?
    private struct Observation: Sendable {
        var date: Date
        var onBattery: Bool
        var percentage: Int
        var watts: Double?
    }
    mutating func observe(at date: Date, onBattery: Bool, percentage: Int, watts: Double?) {
        guard date.timeIntervalSince1970.isFinite, (0...100).contains(percentage) else { return }
        if let previous, date <= previous.date { return }
        let validWatts = watts.flatMap { $0.isFinite && (-300...0).contains($0) ? $0 : nil }
        let observation = Observation(date: date, onBattery: onBattery, percentage: percentage, watts: validWatts)
        defer { previous = observation }
        guard onBattery else { finish(); return }
        let interval = previous.map { date.timeIntervalSince($0.date) } ?? 0
        // Never integrate across sleep, a stopped process, or an unobserved power-source change.
        if current != nil && interval > 15 { finish() }
        if current == nil {
            current = BatterySession(startedAt: date, lastObservedAt: date,
                                     startedAtUnplug: previous.map { !$0.onBattery && interval <= 15 } ?? false,
                                     startPercentage: percentage, endPercentage: percentage)
        }
        guard var session = current else { return }
        session.lastObservedAt = date; session.endPercentage = percentage
        if let watts = validWatts { session.peakDrawWatts = max(session.peakDrawWatts, -watts) }
        if let previous, previous.onBattery, interval > 0, interval <= 15, session.startedAt < date {
            session.observedSeconds += interval
            if let first = previous.watts, let second = validWatts {
                session.energyUsedWh += -(first + second) / 2 * interval / 3600
                session.measuredSeconds += interval
            }
        }
        current = session
    }
    mutating func breakContinuity() { finish(); previous = nil }
    private mutating func finish() {
        if let current { completed.insert(current, at: 0) }
        completed = Array(completed.prefix(50)); current = nil
    }
    /// Recovered sessions remain completed; an app restart cannot prove continued discharging.
    mutating func restore(_ sessions: [BatterySession]) {
        completed = Array(sessions.sorted { $0.lastObservedAt > $1.lastObservedAt }.prefix(50))
        current = nil; previous = nil
    }
    var allSessions: [BatterySession] { (current.map { [$0] } ?? []) + completed }
}
