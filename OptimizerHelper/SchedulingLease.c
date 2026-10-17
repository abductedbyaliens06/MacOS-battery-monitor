#include "SchedulingLease.h"
#include <string.h>

kern_return_t BOReadPolicy(mach_port_t port, BOProcessPolicy *policy) {
    memset(policy, 0, sizeof(*policy));
    mach_msg_type_number_t count = BO_POLICY_COUNT;
    boolean_t defaults = FALSE;
    kern_return_t result = task_policy_get(port, TASK_SUPPRESSION_POLICY, (task_policy_t)policy, &count, &defaults);
    if (result != KERN_SUCCESS) return result;
    if (defaults || count != BO_POLICY_COUNT) return KERN_NOT_SUPPORTED;
    /* Unsupported values must not be silently normalized during restoration. */
    if (policy->cpu_limit || policy->suspend) return KERN_NOT_SUPPORTED;
    for (int i=0;i<7;i++) if(policy->reserved[i]) return KERN_NOT_SUPPORTED;
    return KERN_SUCCESS;
}
bool BOPolicyEqual(const BOProcessPolicy *a, const BOProcessPolicy *b) { return memcmp(a,b,sizeof(*a))==0; }
bool BOMakeEfficientPolicy(const BOProcessPolicy *original, BOProcessPolicy *applied) {
    if (original->active || original->lowpri_cpu || original->timer_throttle || original->disk_throttle ||
        original->cpu_limit || original->suspend || original->throughput_qos || original->suppressed_cpu ||
        original->background_sockets) return false;
    for(int i=0;i<7;i++)if(original->reserved[i])return false;
    *applied = *original;
    applied->active = 1;
    applied->lowpri_cpu = 1;
    applied->throughput_qos = THROUGHPUT_QOS_TIER_3;
    return true;
}
static kern_return_t BOSetPolicy(mach_port_t port, const BOProcessPolicy *policy) {
    /* No external Darwin background flags: these suppression requests are not
     * copied to forked children by XNU task_policy_create. No suspend/hard cap. */
    if (policy->cpu_limit || policy->suspend) return KERN_INVALID_ARGUMENT;
    return task_policy_set(port, TASK_SUPPRESSION_POLICY, (task_policy_t)policy, BO_POLICY_COUNT);
}
kern_return_t BOApplyPolicy(BOSchedulingLease *lease) {
    BOProcessPolicy before;
    kern_return_t r=BOReadPolicy(lease->port,&before);
    if(r!=KERN_SUCCESS)return r;
    if(!BOPolicyEqual(&before,&lease->original))return KERN_ABORTED;
    /* Pending is set BEFORE the setter. An uncertain setter outcome still
     * requires restoration; callers persist original+applied first. */
    lease->pending=true;
    r=BOSetPolicy(lease->port,&lease->applied);
    if(r!=KERN_SUCCESS)return r;
    BOProcessPolicy after;
    r=BOReadPolicy(lease->port,&after);
    if(r!=KERN_SUCCESS)return r;
    return BOPolicyEqual(&after,&lease->applied)?KERN_SUCCESS:KERN_FAILURE;
}
kern_return_t BORestorePolicy(BOSchedulingLease *lease) {
    if(!lease->pending)return KERN_SUCCESS;
    BOProcessPolicy current;
    kern_return_t r=BOReadPolicy(lease->port,&current);
    if(r!=KERN_SUCCESS)return r;
    if(BOPolicyEqual(&current,&lease->original)){lease->pending=false;return KERN_SUCCESS;}
    /* Another actor changed the suppression policy: do not overwrite it. */
    if(!BOPolicyEqual(&current,&lease->applied))return KERN_ABORTED;
    r=BOSetPolicy(lease->port,&lease->original);
    if(r!=KERN_SUCCESS)return r;
    BOProcessPolicy after;
    r=BOReadPolicy(lease->port,&after);
    if(r==KERN_SUCCESS && !BOPolicyEqual(&after,&lease->original))r=KERN_FAILURE;
    if(r==KERN_SUCCESS)lease->pending=false;
    return r;
}
