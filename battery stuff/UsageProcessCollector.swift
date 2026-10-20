import Foundation
import Darwin

/// Read-only counters. Never reads argv, environment, paths or process contents.
nonisolated enum UsageProcessCollector {
    static func scan() -> (processes: [StudyProcess], attempted: Int, denied: Int, truncated: Bool, discoveryLimited: Bool) {
        let countBytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard countBytes > 0 else { return restrictedScan() }
        let capacity = min(8192, Int(countBytes) / MemoryLayout<Int32>.size + 128)
        var pids = [Int32](repeating: 0, count: capacity)
        let returned = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count)) }
        guard returned > 0 else { return restrictedScan() }
        let count = min(capacity, Int(returned) / MemoryLayout<Int32>.size)
        let valid = pids.prefix(count).filter { $0 > 0 }
        let result = valid.compactMap { read($0) }
        return (result, valid.count, valid.count - result.count, count == capacity, false)
    }
    private static func restrictedScan() -> (processes: [StudyProcess], attempted: Int, denied: Int, truncated: Bool, discoveryLimited: Bool) {
        let own = read(getpid()).map { [$0] } ?? []
        return (own, 1, own.isEmpty ? 1 : 0, false, true)
    }
    private static func read(_ pid: Int32) -> StudyProcess? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        var usage = rusage_info_v3()
        let success = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V3, $0) }
        }
        guard success == 0 else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let fallback = withUnsafeBytes(of: info.pbi_comm) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let cpu = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        guard !cpu.overflow else { return nil }
        return StudyProcess(pid: pid, parent: Int32(info.pbi_ppid),
                                   started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                                   name: String((name.isEmpty ? fallback : name).prefix(80)), cpuNS: cpu.partialValue,
                                   backgroundNS: usage.ri_cpu_time_qos_background + usage.ri_cpu_time_qos_maintenance,
                                   footprint: usage.ri_phys_footprint, readBytes: usage.ri_diskio_bytesread,
                                   writeBytes: usage.ri_diskio_byteswritten)
    }
}
