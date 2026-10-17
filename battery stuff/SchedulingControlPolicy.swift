import Foundation

nonisolated struct SchedulingTarget: Codable, Equatable, Sendable {
    var pid: Int32
    var started: UInt64
    var identity: String { "\(pid):\(started)" }
}
nonisolated struct SchedulingRequest: Encodable, Sendable {
    var version = 1
    var targets: [SchedulingTarget]
}
nonisolated struct SchedulingReply: Decodable, Sendable {
    struct Blocked: Decodable, Sendable { var pid: Int32; var reason: String }
    var version: Int
    var active: [String]
    var blocked: [Blocked]
    var failed: Bool
    var onBattery: Bool
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32768 else { throw CocoaError(.fileReadTooLarge) }
        let reply = try JSONDecoder().decode(Self.self, from: data)
        guard reply.version == 1, reply.active.count <= 16, reply.blocked.count <= 16,
              Set(reply.active).count == reply.active.count,
              reply.active.allSatisfy({ $0.count <= 50 && $0.split(separator: ":").count == 2 && $0.split(separator: ":").allSatisfy { UInt64($0) != nil } }),
              reply.blocked.allSatisfy({ $0.pid > 1 && $0.reason.count < 300 }) else { throw CocoaError(.fileReadCorruptFile) }
        return reply
    }
}

/// Existing work is selected by explicit importance, never CPU alone. This
/// mechanism has no inherited flags, so worker parents can safely be considered.
nonisolated enum SchedulingControlPolicy {
    static func targets(live: LiveProcessSnapshot?, labels: [String: StudyImportance], enabled: Bool,
                        recording: Bool, power: OptimizerPower, sleeping: Bool, foregroundKey: String,
                        now: Date = Date(), previouslyActive: Set<String> = []) -> [SchedulingTarget] {
        guard enabled, recording, power == .battery, !sleeping, foregroundKey != "unknown",
              let live, !live.discoveryLimited, live.context.onBattery,
              now.timeIntervalSince(live.date) >= 0, now.timeIntervalSince(live.date) <= 12,
              (0...2).contains(live.context.thermal) else { return [] }
        var targets: [SchedulingTarget] = []
        for family in live.families where labels[family.id] == .flexible && !family.containsMonitor && family.id != foregroundKey {
            // A flexible Python job explicitly labeled by the user is separate
            // from the editor/terminal that launched it. Actual GUI app families
            // and unknown/unclassified dependencies remain excluded.
            guard family.busySamples >= 3 || family.members.contains(where: { previouslyActive.contains($0.id) }) else { continue }
            for member in family.members where member.isPython && !member.isApplication && member.process.pid > 1 {
                let alreadyActive = previouslyActive.contains(member.id)
                guard (member.cpuPercent ?? 0) >= 10 || alreadyActive else { continue }
                targets.append(.init(pid: member.process.pid, started: member.process.started))
                if targets.count == 16 { return targets }
            }
        }
        return targets
    }
}
