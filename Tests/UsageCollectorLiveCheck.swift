import Foundation
import Darwin

@main struct UsageCollectorLiveCheck {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let python = CommandLine.arguments[1]
        let code = "import time\nend=time.monotonic()+20\nwhile time.monotonic()<end:\n start=time.monotonic()\n while time.monotonic()-start<0.04: sum(i*i for i in range(2000))\n time.sleep(0.16)"
        let childCode = "import subprocess,sys\nchildren=[subprocess.Popen([sys.executable,'-c'," + String(data: try JSONEncoder().encode(code), encoding: .utf8)! + "]) for _ in range(2)]\n[p.wait() for p in children]"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-c", childCode]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        Thread.sleep(forTimeInterval: 1)
        let first = UsageProcessCollector.scan()
        check(!first.discoveryLimited && first.processes.count > 1, "Current-user process discovery must be available")
        guard let root = first.processes.first(where: { $0.pid == process.processIdentifier }) else { check(false, "Owned Python parent must be readable"); return }
        let children = first.processes.filter { $0.parent == root.pid }
        check(children.count == 2, "Both owned Python workers must be visible")
        Thread.sleep(forTimeInterval: 6)
        let start = ProcessInfo.processInfo.systemUptime
        let second = UsageProcessCollector.scan()
        let scanMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let map = Dictionary(second.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for child in children {
            guard let current = map[child.pid] else { check(false, "Owned worker must still be running"); return }
            check(current.cpuNS > child.cpuNS, "CPU counters must advance during real work")
            let family = StudyAccumulator.group(for: current, processes: map, apps: [:])
            check(family.key == "job:\(root.identity)", "Live workers must group under their actual Python parent")
        }
        process.waitUntilExit()
        print(String(format: "Live collector: %d readable, %d unavailable, %.1f ms scan; owned Python parent and two advancing workers grouped correctly.", second.processes.count, second.denied, scanMS))
    }
}
