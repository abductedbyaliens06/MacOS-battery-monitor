import Foundation
@main struct SchedulingControlPolicyTests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() throws {
        let now = Date()
        let context = StudyContext(activity: .active, foregroundKey: "app.editor", foregroundName: "Editor", workload: .coding, onBattery: true, lowPowerMode: false, thermal: 0, displayCount: 1, refreshRates: [120])
        let p = StudyProcess(pid: 100, parent: 20, started: 123, name: "python3", cpuNS: 0, backgroundNS: 0, footprint: 0, readBytes: 0, writeBytes: 0)
        let worker = LiveProcessMember(process: p, cpuPercent: 100, hasChildren: true, isApplication: false)
        var family = LiveProcessFamily(id: "job:100:123", name: "Python", cpuPercent: 100, busySamples: 3, foregroundRelated: true, containsMonitor: false, members: [worker], totalMembers: 1)
        var snapshot = LiveProcessSnapshot(date: now, context: context, families: [family], readable: 1, unavailable: 0, discoveryLimited: false)
        var label: StudyImportance = .flexible, enabled = true, recording = true, power = OptimizerPower.battery, sleeping = false, foreground = "app.editor"
        var active: Set<String> = []
        func targets() -> [SchedulingTarget] {
            SchedulingControlPolicy.targets(live: snapshot, labels: [family.id: label], enabled: enabled, recording: recording, power: power, sleeping: sleeping, foregroundKey: foreground, now: now, previouslyActive: active)
        }
        check(targets().count == 1, "Explicitly flexible independent Python work can be optimized while its editor is focused")
        for value in [StudyImportance.urgent,.normal,.unclassified] { label = value; check(targets().isEmpty, "Other importance classes are protected") }; label = .flexible
        enabled = false; check(targets().isEmpty,"Pause restores"); enabled = true
        recording = false; check(targets().isEmpty,"Study pause restores"); recording = true
        power = .adapter; check(targets().isEmpty,"Adapter restores"); power = .battery
        sleeping = true; check(targets().isEmpty,"Sleep restores"); sleeping = false
        foreground = family.id; check(targets().isEmpty,"Foreground family protected"); foreground = "unknown"; check(targets().isEmpty,"Unknown foreground holds changes"); foreground = "app.editor"
        snapshot.date = now.addingTimeInterval(-13); check(targets().isEmpty,"Stale observations restore"); snapshot.date = now
        snapshot.discoveryLimited = true; check(targets().isEmpty,"Restricted coverage restores"); snapshot.discoveryLimited = false
        snapshot.context.thermal = 3; check(targets().isEmpty,"Critical thermal state restores"); snapshot.context.thermal = 0
        family.containsMonitor = true; snapshot.families = [family]; check(targets().isEmpty,"Monitor family excluded"); family.containsMonitor = false
        family.members[0].isApplication = true; snapshot.families = [family]; check(targets().isEmpty,"GUI applications excluded"); family.members[0].isApplication = false
        family.busySamples = 1; snapshot.families = [family]; check(targets().isEmpty,"Require sustained work"); active = [p.identity]
        family.members[0].cpuPercent = 0; snapshot.families = [family]; check(targets().count == 1,"Avoid oscillation when efficient scheduling lowers worker CPU"); active = []
        let request = try JSONEncoder().encode(SchedulingRequest(targets: [.init(pid: 100, started: 123)]))
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        check(Set(object.keys) == ["version", "targets"], "Protocol has no commands, paths or arbitrary policy settings")
        let good = Data(#"{"version":1,"active":["100:123"],"blocked":[],"failed":false,"onBattery":true}"#.utf8)
        check(try SchedulingReply.decode(good).active == ["100:123"],"Bounded reply decodes")
        do { _ = try SchedulingReply.decode(Data(#"{"version":99,"active":[],"blocked":[],"failed":false,"onBattery":true}"#.utf8)); check(false,"Unknown protocol must fail") } catch {}
        var acknowledgement = SchedulingAcknowledgement()
        acknowledgement.sending(nonempty: true)
        check(acknowledgement.mayHaveApplied, "Lost first reply must not claim no changes")
        acknowledgement.sending(nonempty: false)
        check(acknowledgement.mayHaveApplied, "Sending Pause alone does not prove restoration")
        let failedEmpty = try SchedulingReply.decode(Data(#"{"version":1,"active":[],"blocked":[],"failed":true,"onBattery":true}"#.utf8))
        acknowledgement.received(failedEmpty)
        check(acknowledgement.mayHaveApplied, "A failed empty reply cannot clear recovery uncertainty")
        let restored = try SchedulingReply.decode(Data(#"{"version":1,"active":[],"blocked":[],"failed":false,"onBattery":true}"#.utf8))
        acknowledgement.received(restored)
        check(!acknowledgement.mayHaveApplied, "Only verified empty success clears pending restoration")
        acknowledgement.received(try SchedulingReply.decode(good))
        check(acknowledgement.mayHaveApplied, "Applied acknowledgement remains recoverable on later disconnect")
        print("Scheduling selection: intent, foreground, power, freshness, pause, thermal, continuity and bounded protocol checks passed.")
    }
}
