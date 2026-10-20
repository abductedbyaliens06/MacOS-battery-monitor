import Foundation

nonisolated struct LiveProcessMember: Identifiable, Sendable {
    var id: String { process.identity }
    var process: StudyProcess
    var cpuPercent: Double?
    var hasChildren: Bool
    var isApplication: Bool
    var isPython: Bool {
        process.name.lowercased().hasPrefix("python") || process.name.lowercased().hasPrefix("pytest")
    }
}
nonisolated struct LiveProcessFamily: Identifiable, Sendable {
    var id: String
    var name: String
    var cpuPercent: Double?
    var busySamples: Int
    var foregroundRelated: Bool
    var containsMonitor: Bool
    var members: [LiveProcessMember]
    var totalMembers: Int
}
nonisolated struct LiveProcessSnapshot: Sendable {
    var date: Date
    var context: StudyContext
    var families: [LiveProcessFamily]
    var readable: Int
    var unavailable: Int
    var discoveryLimited: Bool
}
nonisolated struct LiveProcessProposal: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case protected, labelNeeded, observing, unsupported, candidate }
    var kind: Kind
    var reason: String
    var targetIdentity: String?
}
nonisolated enum LiveProcessPolicy {
    static func proposal(_ family: LiveProcessFamily, importance: StudyImportance, fresh: Bool) -> LiveProcessProposal {
        func hold(_ kind: LiveProcessProposal.Kind, _ text: String) -> LiveProcessProposal { .init(kind: kind, reason: text) }
        guard fresh else { return hold(.observing, "Monitoring is paused, incomplete or stale. No proposal is eligible.") }
        if family.containsMonitor { return hold(.protected, "Battery Monitor is always excluded from its own optimizer.") }
        if importance == .urgent { return hold(.protected, "You are waiting for results. Preserve this family's progress.") }
        if family.foregroundRelated && importance != .flexible { return hold(.protected, "This family belongs to the foreground app. Protect its work and dependencies.") }
        guard importance == .flexible else {
            return hold(importance == .unclassified ? .labelNeeded : .protected,
                        importance == .unclassified ? "Importance unknown. Classify it before considering changes." : "Normal importance: observe without changes.")
        }
        guard family.busySamples >= 3, let cpu = family.cpuPercent, cpu >= 10 else {
            return hold(.observing, "Collecting sustained CPU activity: at least three consecutive busy samples are needed.")
        }
        guard let worker = family.members.filter({ $0.isPython && !$0.isApplication && ($0.cpuPercent ?? 0) >= 10 })
            .max(by: { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }) else {
            return hold(.unsupported, "This mechanism supports Python workers, not GUI applications.")
        }
        return .init(kind: .candidate, reason: "Eligible for efficient scheduling when the verified administrator helper is connected and optimization is enabled on battery.", targetIdentity: worker.id)
    }
}

/// Reuses the study's existing five-second scan; no second process polling loop.
nonisolated struct LiveProcessAnalyzer {
    private var previous: StudyFrame?
    private var busy: [String: Int] = [:]
    mutating func reset() { previous = nil; busy = [:] }
    mutating func observe(_ frame: StudyFrame, monitorPID: Int32) -> LiveProcessSnapshot {
        let dt = previous.map { frame.uptime - $0.uptime } ?? 0
        let continuous = dt > 0 && dt <= 15 && previous.map { abs(frame.date.timeIntervalSince($0.date) - dt) < 2 } == true
        let old = continuous ? Dictionary((previous?.processes ?? []).map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        let processes = Dictionary(frame.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let parents = Set(frame.processes.map(\.parent))
        var families: [String: LiveProcessFamily] = [:]
        for process in frame.processes {
            let group = StudyAccumulator.group(for: process, processes: processes, apps: frame.apps)
            var family = families[group.key] ?? .init(id: group.key, name: group.name, busySamples: 0,
                                                       foregroundRelated: false, containsMonitor: false, members: [], totalMembers: 0)
            var cpu: Double?
            if let prior = old[process.identity], process.cpuNS >= prior.cpuNS {
                cpu = Double(process.cpuNS - prior.cpuNS) / 1e9 / dt * 100
            }
            if let cpu { family.cpuPercent = (family.cpuPercent ?? 0) + cpu }
            family.containsMonitor = family.containsMonitor || process.pid == monitorPID
            var cursor: StudyProcess? = process, visited: Set<Int32> = []
            for _ in 0..<64 {
                guard let current = cursor, visited.insert(current.pid).inserted else { break }
                if frame.apps[current.pid]?.key == frame.context.foregroundKey || frame.apps[current.parent]?.key == frame.context.foregroundKey { family.foregroundRelated = true }
                cursor = processes[current.parent]
            }
            family.members.append(.init(process: process, cpuPercent: cpu, hasChildren: parents.contains(process.pid), isApplication: frame.apps[process.pid] != nil))
            family.totalMembers += 1; families[group.key] = family
        }
        var nextBusy: [String: Int] = [:]
        for key in Array(families.keys) {
            guard var family = families[key] else { continue }
            let count = continuous && (family.cpuPercent ?? 0) >= 10 ? min(1000, (busy[key] ?? 0) + 1) : 0
            family.busySamples = count; nextBusy[key] = count
            family.members = Array(family.members.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(16))
            families[key] = family
        }
        previous = frame; busy = nextBusy
        return .init(date: frame.date, context: frame.context,
                     families: Array(families.values.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }.prefix(100)),
                     readable: frame.processes.count, unavailable: frame.denied, discoveryLimited: frame.discoveryLimited)
    }
}
