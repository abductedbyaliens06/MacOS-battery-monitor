import Foundation
@main struct OptimizerPolicyTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let good = OptimizerContext(power: .adapter, fresh: true)
        func allows(_ c: OptimizerContext, _ p: ManagedJobPriority = .normal, enabled: Bool = true, running: Int = 0, limit: Int = 2, cooldown: Bool = false) -> Bool {
            OptimizerPolicy.decision(priority: p, context: c, enabled: enabled, running: running, configuredLimit: limit, coolingDown: cooldown).mayStart
        }
        for priority in ManagedJobPriority.allCases {
            check(!allows(good, priority, enabled: false), "Preview must never dispatch")
            var context = good; context.fresh = false
            check(!allows(context, priority), "Stale data must fail closed")
            context = good; context.power = .unknown
            check(!allows(context, priority), "Unknown power must fail closed")
            context = good; context.sleeping = true
            check(!allows(context, priority), "No new launches while sleeping")
            context = good; context.thermal = 3
            check(!allows(context, priority), "Critical thermal state holds all launches")
            check(!allows(good, priority, running: 2, limit: 99), "Absolute concurrency maximum is two")
            context = good; context.power = .battery
            check(!allows(context, priority, running: 1), "Battery concurrency maximum is one")
        }
        var invalid = good; invalid.thermal = -1
        check(!allows(invalid, .urgent), "Invalid thermal input fails closed")
        invalid = good; invalid.sustainedWatts = .nan
        check(!allows(invalid, .urgent), "Non-finite power input fails closed")
        var battery = good; battery.power = .battery
        check(allows(battery, .urgent), "Explicit urgent jobs may start during interaction")
        check(!allows(battery, .normal) && !allows(battery, .flexible), "Non-urgent battery jobs defer during interaction")
        battery.away = true
        check(!allows(battery), "Optional battery launches require a measured baseline")
        battery.sustainedWatts = 7
        check(allows(battery), "Away context and a measured baseline permit queued work")
        battery.sustainedWatts = 10
        check(!allows(battery), "Regular-use target defers optional launches")
        battery.demanding = true
        check(allows(battery), "Demanding target is fourteen watts")
        check(allows(battery, .urgent, cooldown: true), "Urgent work bypasses optional cooldown")
        check(!allows(good, cooldown: true), "Cooldown holds optional launches")
        var warm = good; warm.thermal = 2
        check(!allows(warm) && allows(warm, .urgent), "Serious thermal state permits only urgent work, one at a time")
        check(!allows(warm, .urgent, running: 1), "Warm concurrency is one")
        var window = OptimizerPowerWindow()
        for time in stride(from: 0.0, through: 25, by: 5) { window.observe(time: time, watts: 8, source: "SMC") }
        check(window.average(at: 25) == nil, "Insufficient observation cannot claim sustained power")
        window.observe(time: 30, watts: 8, source: "SMC")
        check(window.average(at: 30) == 8, "Time-weighted rolling draw")
        check(window.average(at: 45) == nil, "Stale power is unavailable")
        window.observe(time: 35, watts: nil, source: "SMC")
        check(window.average(at: 35) == nil, "Missing power resets continuity")
        for time in stride(from: 40.0, through: 70, by: 5) { window.observe(time: time, watts: 12, source: "SMC") }
        window.observe(time: 75, watts: 12, source: "Registry")
        check(window.average(at: 75) == nil, "Sensor source changes reset continuity")
        window.observe(time: 100, watts: 12, source: "Registry")
        check(window.average(at: 100) == nil, "Long gaps reset continuity")
        window.observe(time: 105, watts: .nan, source: "Registry")
        check(window.average(at: 105) == nil, "Non-finite readings are rejected")
        print("Optimizer policy: preview, freshness, interaction, thermal, concurrency, cooldown and power-window checks passed.")
    }
}
