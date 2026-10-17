import SwiftUI

struct LiveProcessView: View {
    @ObservedObject var study: UsageStudyService
    @ObservedObject var optimizer: OptimizerService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Surface("Live control · unavailable in this release") {
                Text("Existing processes are discovered automatically. No jobs need to be added for analysis.")
                Text("The tested macOS permissions do not allow exact scheduling-policy read-back for safe restoration. This release applies no scheduling changes, even to candidates.").foregroundStyle(.secondary)
                Text("High CPU usage alone does not mean a task is unimportant or wasting power. Mark flexible work as Can finish later; keep tasks you need now as Waiting for results.").foregroundStyle(.secondary)
            }.font(.system(size: 11))
            if let live = study.live {
                let age = Date().timeIntervalSince(live.date)
                let fresh = study.recording && age >= 0 && age <= 15 && !live.discoveryLimited
                HStack {
                    Text(fresh ? "Current CPU consumers" : "Monitoring paused or stale")
                    Spacer()
                    Text("\(live.readable) readable").foregroundStyle(.secondary)
                }.font(.system(size: 11, weight: .medium))
                Text("One core = 100% CPU. CPU is a scheduling signal, not per-process watts. Updated by the existing five-second study scan. Showing up to 20 families.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if live.unavailable > 0 || live.discoveryLimited {
                    Text("Coverage is incomplete: \(live.unavailable) processes unavailable. Unreadable processes are not treated as idle.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(live.families.prefix(20)) { family in
                    let importance = study.labels[family.id] ?? .unclassified
                    let proposal = LiveProcessPolicy.proposal(family, importance: importance, fresh: fresh)
                    Surface {
                        HStack(alignment: .firstTextBaseline) {
                            Text(family.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                            Spacer()
                            Text(family.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "Collecting")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                        }
                        Picker("Importance", selection: Binding(get: { importance }, set: { study.setImportance($0, for: family.id) })) {
                            ForEach(StudyImportance.allCases) { Text($0.rawValue).tag($0) }
                        }.font(.system(size: 11))
                        Label(proposal.reason, systemImage: proposal.kind == .protected ? "lock.shield" : "info.circle")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        DisclosureGroup("\(family.totalMembers) processes · \(family.busySamples) consecutive busy samples") {
                            ForEach(family.members) { member in
                                HStack {
                                    Text("\(member.process.name) · \(member.process.pid)").lineLimit(1)
                                    Spacer()
                                    Text(member.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if family.totalMembers > family.members.count { Text("Showing the 16 busiest members.").font(.system(size: 10)) }
                        }.font(.system(size: 10))
                        if proposal.kind == .candidate {
                            Button(optimizer.checkingPolicies.contains(family.id) ? "Checking…" : "Check OS support · read only") {
                                optimizer.checkPolicySupport(familyID: family.id)
                            }.font(.system(size: 11)).buttonStyle(.bordered)
                                .disabled(optimizer.checkingPolicies.contains(family.id))
                            if let result = optimizer.policyChecks[family.id] { Text(result).font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                    }
                }
            } else {
                Text(study.recording ? "Waiting for the next study scan. CPU rates need two samples; candidate evaluation needs three consecutive busy intervals." : "Resume recording in Study to discover current processes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
