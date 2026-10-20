import Foundation
import Darwin

/// Read-only capability check. Deliberately does not request a debugger/control
/// port or set any scheduling policy when exact rollback cannot be verified.
nonisolated enum ProcessPolicyReadback {
    static func check(_ expected: StudyProcess) -> String {
        guard expected.pid > 1, expected.pid != getpid() else { return "Protected process. No changes made." }
        var identity = proc_bsdinfo()
        guard proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &identity, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              identity.pbi_uid == getuid(), identity.pbi_start_tvsec * 1_000_000 + identity.pbi_start_tvusec == expected.started else {
            return "Process exited, changed identity or is not owned by this user. No changes made."
        }
        var port: mach_port_name_t = 0
        let bind = task_name_for_pid(mach_task_self_, expected.pid, &port)
        guard bind == KERN_SUCCESS else { return "macOS denied task-name access (\(bind)). No changes made." }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var policy = task_qos_policy()
        var count = mach_msg_type_number_t(MemoryLayout<task_qos_policy>.size / MemoryLayout<integer_t>.size)
        var defaults: boolean_t = 0
        let result = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_policy_get(port, task_policy_flavor_t(TASK_OVERRIDE_QOS_POLICY), $0, &count, &defaults)
            }
        }
        guard result == KERN_SUCCESS, defaults == 0 else {
            return "Live adjustment unavailable: macOS denied exact policy read-back (\(result)). Rollback cannot be verified, so nothing was changed."
        }
        return "Policy is readable, but live changes remain disabled in this preview release. No changes made."
    }
}
