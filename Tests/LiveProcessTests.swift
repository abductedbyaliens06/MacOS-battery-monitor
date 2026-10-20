import Foundation

@main struct LiveProcessTests {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
    }
    static func process(_ seconds: UInt64, pid: Int32 = 20, parent: Int32 = 10, start: UInt64 = 1, name: String = "python3") -> StudyProcess {
        .init(pid: pid, parent: parent, started: start, name: name, cpuNS: seconds * 1_000_000_000,
              backgroundNS: 0, footprint: 100, readBytes: 0, writeBytes: 0)
    }
    static func frame(_ seconds: Double, processes: [StudyProcess]? = nil, foreground: String = "editor") -> StudyFrame {
        .init(date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), uptime: 100 + seconds,
              context: .init(activity: .active, foregroundKey: foreground, foregroundName: foreground,
                             workload: .coding, onBattery: true, lowPowerMode: false, thermal: 0, displayCount: 1, refreshRates: [120]),
              batteryDraw: 10, batterySource: "fixture", temperature: 35,
              processes: processes ?? [process(UInt64(seconds))], apps: [10: .init(key: "terminal", name: "Terminal")], attempted: 1, denied: 0, scanMS: 1)
    }
    static func main() {
        var analyzer = LiveProcessAnalyzer()
        let baseline = analyzer.observe(frame(0), monitorPID: 999)
        check(baseline.families[0].cpuPercent == nil, "First sample must not fabricate a CPU rate")
        let next = analyzer.observe(frame(5), monitorPID: 999).families[0]
        check(next.cpuPercent == 100 && next.busySamples == 1, "CPU deltas use elapsed time")
        _ = analyzer.observe(frame(10), monitorPID: 999)
        var family = analyzer.observe(frame(15), monitorPID: 999).families[0]
        func proposal(_ importance: StudyImportance = .flexible, fresh: Bool = true) -> LiveProcessProposal {
            LiveProcessPolicy.proposal(family, importance: importance, fresh: fresh)
        }
        check(proposal().kind == .candidate && proposal().targetIdentity == "20:1", "Sustained flexible Python leaf is a preview candidate")
        check(proposal(.urgent).kind == .protected, "Urgent work is protected")
        check(proposal(.normal).kind == .protected, "Normal work is observe only")
        check(proposal(.unclassified).kind == .labelNeeded, "High CPU does not imply low importance")
        check(proposal(fresh: false).kind == .observing, "Stale data cannot produce an eligible proposal")
        family.foregroundRelated = true
        check(proposal(.normal).kind == .protected, "Normal foreground dependencies are protected")
        check(proposal().kind == .candidate, "Explicitly flexible Python jobs are independent of the foreground editor")
        family.foregroundRelated = false; family.containsMonitor = true
        check(proposal().kind == .protected, "Monitor cannot target itself")
        family.containsMonitor = false; family.members[0].hasChildren = true
        check(proposal().kind == .candidate, "Non-inherited policy permits individually evaluated Python parents")
        family.members[0].hasChildren = false; family.members[0].isApplication = true
        check(proposal().kind == .unsupported, "GUI apps are excluded")
        let gap = analyzer.observe(frame(40), monitorPID: 999).families[0]
        check(gap.cpuPercent == nil && gap.busySamples == 0, "Gaps reset evidence")
        let reused = analyzer.observe(frame(45, processes: [process(100, start: 2)]), monitorPID: 999).families[0]
        check(reused.cpuPercent == nil && reused.busySamples == 0, "PID reuse resets CPU baseline")
        analyzer.reset()
        let child = process(0, pid: 21, parent: 20)
        let tree = analyzer.observe(frame(0, processes: [process(0), child], foreground: "terminal"), monitorPID: 20).families[0]
        check(tree.foregroundRelated && tree.containsMonitor, "Ancestor apps and monitor membership protect whole family")
        check(tree.members.first { $0.process.pid == 20 }?.hasChildren == true, "Parents are identified from the existing scan")
        print("Live process preview: CPU continuity, identity, intent, foreground dependencies and candidate exclusions passed.")
    }
}
