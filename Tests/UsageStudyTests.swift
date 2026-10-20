import Foundation

@main struct UsageStudyTests {
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    static func context(_ activity: StudyActivity = .active, onBattery: Bool = true) -> StudyContext {
        StudyContext(activity: activity, foregroundKey: "app.editor", foregroundName: "Editor", workload: .coding,
                     onBattery: onBattery, lowPowerMode: false, thermal: 0, displayCount: 1, refreshRates: [120])
    }
    static func process(_ cpu: UInt64, pid: Int32 = 20, parent: Int32 = 10, start: UInt64 = 1, name: String = "python3") -> StudyProcess {
        StudyProcess(pid: pid, parent: parent, started: start, name: name, cpuNS: cpu,
                     backgroundNS: cpu / 2, footprint: 1000, readBytes: cpu / 1000, writeBytes: cpu / 2000)
    }
    static func frame(_ seconds: Double, watts: Double? = 10, processes: [StudyProcess]? = nil,
                      context: StudyContext = context(), source: String = "SMC") -> StudyFrame {
        StudyFrame(date: origin.addingTimeInterval(seconds), uptime: 100 + seconds, context: context,
                   batteryDraw: watts, batterySource: source, temperature: 35,
                   processes: processes ?? [process(UInt64(seconds + 1) * 1_000_000_000)],
                   apps: [10: StudyApp(key: "app.terminal", name: "Terminal")], attempted: 1, denied: 0, scanMS: 1)
    }
    static func check(_ test: Bool, _ message: String) {
        guard test else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    static func main() throws {
        var accumulator = StudyAccumulator()
        accumulator.record(frame(0, watts: 8), labels: [:])
        check(accumulator.pending.isEmpty, "First sample only establishes baselines")
        accumulator.record(frame(5, watts: 12), labels: [:])
        accumulator.record(frame(10, watts: 12), labels: [:])
        check(accumulator.pending.count == 1, "Stable contexts must aggregate under a deterministic minute key")
        let minute = accumulator.pending.values.first!
        check(near(minute.observedSeconds, 10) && near(minute.energyWh, 110 / 3600), "Trapezoid energy and intervals")
        check(minute.groups.count == 1 && near(minute.groups[0].cpuSeconds, 10), "CPU deltas accumulate, not lifetime counters")
        check(minute.groups[0].importance == .unclassified, "Importance is never guessed")

        var gap = StudyAccumulator()
        gap.record(frame(0), labels: [:]); gap.record(frame(30), labels: [:])
        check(gap.pending.isEmpty, "Long gaps are not integrated")
        gap.record(frame(35, context: context(.away)), labels: [:])
        check(gap.pending.isEmpty, "Context transitions are not attributed")
        gap.record(frame(40, context: context(.away)), labels: ["job:20:1": .flexible])
        check(near(gap.pending.values.first!.groups[0].awayCPUSeconds, 5), "Away CPU is measured")
        check(gap.pending.values.first!.groups[0].importance == .flexible, "Explicit intent is recorded")
        gap.breakContinuity(); gap.record(frame(45), labels: [:])
        check(near(gap.pending.values.first!.observedSeconds, 5), "Sleep/pause boundaries reset baselines")

        for pair in [(Optional<Double>.none, Optional(10.0)), (Optional(Double.nan), Optional(10.0)), (Optional(-1.0), Optional(10.0))] {
            var a = StudyAccumulator(); a.record(frame(0, watts: pair.0), labels: [:]); a.record(frame(5, watts: pair.1), labels: [:])
            check(a.pending.values.first!.batterySeconds == 0 && a.pending.values.first!.energyWh == 0, "Unavailable power is not zero power")
        }
        var charging = StudyAccumulator(); charging.record(frame(0, context: context(onBattery: false)), labels: [:])
        charging.record(frame(5, context: context(onBattery: false)), labels: [:])
        check(charging.pending.values.first!.batterySeconds == 0, "Charging measurements never count as battery draw")
        var changedSource = StudyAccumulator(); changedSource.record(frame(0), labels: [:]); changedSource.record(frame(5, source: "Registry"), labels: [:])
        check(changedSource.pending.values.first!.energyWh == 0, "Different power sources do not bridge")
        var clock = StudyAccumulator(); clock.record(frame(0), labels: [:])
        var jumped = frame(5); jumped.date = origin.addingTimeInterval(500)
        clock.record(jumped, labels: [:]); check(clock.pending.isEmpty, "Wall-clock jumps do not manufacture intervals")

        var reused = StudyAccumulator(); reused.record(frame(0), labels: [:])
        reused.record(frame(5, processes: [process(100_000_000_000, start: 2)]), labels: [:])
        check(reused.pending.values.first!.groups.isEmpty && reused.pending.values.first!.newProcesses == 1, "PID reuse must reset CPU baseline")
        let root = process(0), child = process(0, pid: 21, parent: 20)
        let tree = [root.pid: root, child.pid: child]
        let family = StudyAccumulator.group(for: child, processes: tree, apps: [10: StudyApp(key: "terminal", name: "Terminal")])
        check(family.key == "job:20:1", "Python children stay in their job instead of merging with the terminal")
        let launcher = process(0, pid: 10, parent: 9, name: "TestLauncher")
        let unrelatedPython = process(0, pid: 9, parent: 1)
        check(StudyAccumulator.group(for: child, processes: [21: child, 20: root, 10: launcher, 9: unrelatedPython], apps: [:]).key == "job:20:1", "A non-Python launcher separates independent job families")
        let browser = process(0, pid: 30, parent: 1, name: "Browser")
        let helper = process(0, pid: 31, parent: 30, name: "Renderer")
        check(StudyAccumulator.group(for: helper, processes: [30: browser, 31: helper], apps: [30: StudyApp(key: "browser", name: "Browser")]).key == "browser", "App helpers group with their parent app")
        var cycle = child; cycle.parent = cycle.pid
        _ = StudyAccumulator.group(for: cycle, processes: [cycle.pid: cycle], apps: [:])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-study-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.sqlite")
        do {
            let store = try UsageStudyStore(url: url)
            try store.save(accumulator.pending, now: origin.addingTimeInterval(10))
            accumulator.didSave()
            accumulator.record(frame(15), labels: [:])
            try store.save(accumulator.pending, now: origin.addingTimeInterval(15))
            let report = try store.report(since: origin.addingTimeInterval(-60), now: origin.addingTimeInterval(15), labels: ["job:20:1": .urgent])
            check(near(report.seconds, 15) && near(report.energyWh, 165 / 3600), "Incremental writes merge; they must not overwrite earlier intervals")
            check(report.groups[0].importance == .urgent, "Report uses the latest explicit label")
            check(near(report.groups[0].cpuSeconds, 15), "Report totals CPU correctly")
            let exported = directory.appendingPathComponent("export.json")
            try store.export(to: exported, labels: [:], now: origin)
            let data = try Data(contentsOf: exported)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            check((json["minutes"] as? [Any])?.count == 1, "Streaming export is valid JSON with minute records")
            check(String(decoding: data, as: UTF8.self).contains("Whole-Mac"), "Export identifies attribution limitations")
            try store.export(to: exported, labels: [:], now: origin)
        }
        do {
            let restarted = try UsageStudyStore(url: url)
            let report = try restarted.report(since: origin.addingTimeInterval(-60), now: origin, labels: [:])
            check(near(report.seconds, 15), "Archive survives restart")
            try restarted.save([:], now: origin.addingTimeInterval(8 * 86400))
            check(try restarted.report(since: origin.addingTimeInterval(-60), now: origin, labels: [:]).intervals == 0, "Seven-day retention prunes records")
            try restarted.save([minute.id: minute], now: origin)
            try restarted.clear()
            check(try restarted.report(since: origin.addingTimeInterval(-60), now: origin, labels: [:]).intervals == 0, "Clear removes all observations")
        }
        var limited = StudyAccumulator()
        var firstLimited = frame(0); firstLimited.discoveryLimited = true
        var nextLimited = frame(5); nextLimited.discoveryLimited = true
        limited.record(firstLimited, labels: [:]); limited.record(nextLimited, labels: [:])
        check(limited.pending.values.first!.discoveryLimitedSamples == 1, "Restricted discovery is recorded as missing coverage")
        var invalid = minute; invalid.observedSeconds = 1e308
        do { try invalid.validate(); check(false, "Unsafe archive totals must fail validation") } catch {}
        let corrupt = directory.appendingPathComponent("corrupt.sqlite")
        let original = Data("corrupt data".utf8); try original.write(to: corrupt)
        do { _ = try UsageStudyStore(url: corrupt); check(false, "Corrupt database must fail") } catch {}
        check(try Data(contentsOf: corrupt) == original, "Corrupt storage is not silently replaced")
        try UsageStudyStore.erase(at: corrupt)
        let recovered = try UsageStudyStore(url: corrupt)
        check(try recovered.report(since: origin, now: origin, labels: [:]).intervals == 0, "Explicit clear can recover a corrupt store")
        print("Usage study: counters, energy, identity, grouping, intent, gaps, persistence, retention, export and corruption checks passed.")
    }
}
