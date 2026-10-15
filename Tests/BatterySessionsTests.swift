import Foundation
@main struct BatterySessionsTests {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var tracker = BatterySessionTracker()
        tracker.observe(at: start, onBattery: false, percentage: 80, watts: 20)
        tracker.observe(at: start.addingTimeInterval(1), onBattery: true, percentage: 80, watts: -10)
        assert(tracker.current!.startedAtUnplug)
        for second in 2...361 { tracker.observe(at: start.addingTimeInterval(Double(second)), onBattery: true, percentage: 75, watts: -10) }
        assert(abs(tracker.current!.energyUsedWh - 1) < 0.00001)
        assert(abs(tracker.current!.averageDrawWatts! - 10) < 0.00001)
        assert(tracker.current!.percentagePointsUsed == 5 && tracker.current!.observedSeconds == 360)
        tracker.observe(at: start.addingTimeInterval(362), onBattery: true, percentage: 75, watts: nil)
        tracker.observe(at: start.addingTimeInterval(363), onBattery: true, percentage: 75, watts: -20)
        assert(tracker.current!.measuredSeconds == 360 && tracker.current!.observedSeconds == 362)
        tracker.observe(at: start.addingTimeInterval(364), onBattery: true, percentage: 75, watts: -10)
        assert(abs(tracker.current!.energyUsedWh - (1 + 15.0 / 3600)) < 0.00001)
        let id = tracker.current!.id
        tracker.observe(at: start.addingTimeInterval(3600), onBattery: true, percentage: 65, watts: -5)
        assert(tracker.completed.count == 1 && tracker.current!.id != id)
        assert(!tracker.current!.startedAtUnplug && tracker.current!.observedSeconds == 0)
        tracker.observe(at: start.addingTimeInterval(3601), onBattery: false, percentage: 65, watts: 25)
        assert(tracker.current == nil && tracker.completed.count == 2)
        tracker.breakContinuity()
        tracker.observe(at: start.addingTimeInterval(3602), onBattery: true, percentage: 65, watts: .nan)
        assert(!tracker.current!.startedAtUnplug && tracker.current!.averageDrawWatts == nil)
        let all = tracker.allSessions
        let data = try JSONEncoder().encode(all)
        var restored = BatterySessionTracker()
        restored.restore(try JSONDecoder().decode([BatterySession].self, from: data))
        assert(restored.current == nil && restored.completed.count == 3)
        restored.observe(at: start.addingTimeInterval(4000), onBattery: true, percentage: 64, watts: -10)
        assert(restored.current!.energyUsedWh == 0 && !restored.current!.startedAtUnplug)
        print("Battery session integration, transitions, missing samples, sleep gaps, and restart checks passed.")
    }
}
