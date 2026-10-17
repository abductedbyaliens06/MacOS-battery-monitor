#pragma once
#include <mach/mach.h>
#include <mach/task_policy.h>
#include <stdint.h>
#include <stdbool.h>

/* macOS TASK_SUPPRESSION_POLICY ABI: XNU mach/task_policy_private.h.
 * No internal bitfield decoding. Validate count and round-trip before use.
 * Only active, lowpri_cpu and throughput_qos differ from the original.
 * suspend, cpu_limit, disk policy, timers and sockets are never enabled.
 */
typedef struct {
    integer_t active, lowpri_cpu, timer_throttle, disk_throttle;
    integer_t cpu_limit, suspend, throughput_qos, suppressed_cpu;
    integer_t background_sockets, reserved[7];
} BOProcessPolicy;
#define BO_POLICY_COUNT ((mach_msg_type_number_t)(sizeof(BOProcessPolicy)/sizeof(integer_t)))
_Static_assert(sizeof(BOProcessPolicy) == 64, "Unexpected policy ABI");

typedef struct {
    int32_t pid;
    uint64_t started;
    mach_port_t port;
    BOProcessPolicy original, applied;
    bool pending;
} BOSchedulingLease;

/* Core is also used by an unprivileged self-test. Server alone acquires ports. */
kern_return_t BOReadPolicy(mach_port_t port, BOProcessPolicy *policy);
bool BOPolicyEqual(const BOProcessPolicy *a, const BOProcessPolicy *b);
bool BOMakeEfficientPolicy(const BOProcessPolicy *original, BOProcessPolicy *applied);
kern_return_t BOApplyPolicy(BOSchedulingLease *lease);
kern_return_t BORestorePolicy(BOSchedulingLease *lease);
