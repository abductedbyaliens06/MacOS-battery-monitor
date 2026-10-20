import Foundation

nonisolated enum OptimizerPower: String, Sendable { case battery, adapter, unknown }
nonisolated enum ManagedJobPriority: String, CaseIterable, Identifiable, Codable, Sendable {
    case urgent = "Waiting for results", normal = "Normal", flexible = "Can finish later"
    var id: String { rawValue }
    var rank: Int { switch self { case .urgent: return 0; case .normal: return 1; case .flexible: return 2 } }
}
nonisolated enum ManagedJobState: String, Codable, Sendable {
    case queued = "Queued", running = "Running", completed = "Completed", failed = "Failed", removed = "Removed", untracked = "Continues outside app"
}
nonisolated struct OptimizerContext: Equatable, Sendable {
    var power: OptimizerPower = .unknown
    var away = false
    var fresh = false
    var sleeping = false
    var thermal = 0
    var sustainedWatts: Double?
    var demanding = false
    var targetWatts: Double { demanding ? 14 : 8 }
}
nonisolated struct OptimizerDecision: Equatable, Sendable {
    var mayStart: Bool
    var reason: String
}
nonisolated enum OptimizerPolicy {
    static func decision(priority: ManagedJobPriority, context: OptimizerContext, enabled: Bool,
                         running: Int, configuredLimit: Int, coolingDown: Bool) -> OptimizerDecision {
        func hold(_ reason: String) -> OptimizerDecision { .init(mayStart: false, reason: reason) }
        guard enabled else { return hold("Queue paused. Recommendations only.") }
        guard !context.sleeping else { return hold("Mac is sleeping; no new launches.") }
        guard context.fresh, context.power != .unknown else { return hold("Waiting for fresh monitoring and a known power source.") }
        guard (0...3).contains(context.thermal), context.sustainedWatts.map({ $0.isFinite && (0...300).contains($0) }) ?? true else { return hold("Invalid monitoring context; holding new launches.") }
        guard context.thermal < 3 else { return hold("Critical thermal state; holding new jobs for macOS to manage cooling.") }
        let limit = context.power == .battery || context.thermal >= 2 ? 1 : min(2, max(1, configuredLimit))
        guard running < limit else { return hold("Concurrency limit reached; running jobs continue unchanged.") }
        if priority == .urgent { return .init(mayStart: true, reason: "You are waiting for results; start the selected job.") }
        guard context.thermal < 2 else { return hold("Elevated thermal state; deferring non-urgent launches.") }
        guard !coolingDown else { return hold("Brief cooldown between non-urgent jobs.") }
        if context.power == .battery {
            guard context.away else { return hold("Protecting active use on battery; waiting until you are away or charging.") }
            guard let watts = context.sustainedWatts else { return hold("Collecting 30 seconds of continuous battery draw before an optional launch.") }
            if watts > context.targetWatts {
                return hold("Measured draw is above the target; defer this optional launch, without capping foreground performance.")
            }
        }
        return .init(mayStart: true, reason: context.power == .adapter ? "Power adapter connected; a queue slot is available." : "You are away; a queue slot is available.")
    }
}

/// Time-weighted battery draw. Missing values, source transitions and long gaps
/// break continuity instead of manufacturing low-power evidence.
nonisolated struct OptimizerPowerWindow {
    private struct Interval { var start: Double; var end: Double; var watts: Double }
    private var intervals: [Interval] = []
    private var previous: (time: Double, watts: Double, source: String)?
    mutating func observe(time: Double, watts: Double?, source: String) {
        guard time.isFinite, let watts, watts.isFinite, (0...300).contains(watts) else {
            previous = nil; intervals = []; return
        }
        if let old = previous {
            let dt = time - old.time
            if dt > 0, dt <= 15, old.source == source {
                intervals.append(.init(start: old.time, end: time, watts: (old.watts + watts) / 2))
            } else { intervals = [] }
        }
        previous = (time, watts, source)
        intervals.removeAll { $0.end <= time - 60 }
    }
    func average(at time: Double) -> Double? {
        guard let previous, time - previous.time >= 0, time - previous.time <= 10 else { return nil }
        var seconds = 0.0, wattSeconds = 0.0
        for interval in intervals {
            let dt = max(0, interval.end - max(interval.start, time - 60))
            seconds += dt; wattSeconds += interval.watts * dt
        }
        return seconds >= 30 ? wattSeconds / seconds : nil
    }
}
nonisolated struct ManagedJobRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var label: String
    var priority: ManagedJobPriority
    var state: ManagedJobState = .queued
    var added = Date()
    var started: Date?
    var finished: Date?
    var duration: Double?
    var pid: Int32?
    var exitCode: Int32?
    var reason = "Queue paused."
}
