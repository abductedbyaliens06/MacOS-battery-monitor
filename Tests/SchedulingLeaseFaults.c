#include "../OptimizerHelper/SchedulingLease.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(v,msg) do{if(!(v)){fprintf(stderr,"FAIL: %s\n",msg);exit(1);}}while(0)
static BOProcessPolicy policy;
static int readFailure=0,setFailure=0,setCount=0,wrongCount=0,readDefault=0,applyThenFail=0;
kern_return_t task_policy_get(task_policy_get_t task,task_policy_flavor_t flavor,task_policy_t out,mach_msg_type_number_t *count,boolean_t *defaults){
    (void)task;CHECK(flavor==TASK_SUPPRESSION_POLICY,"Only suppression getter allowed");
    if(readFailure)return KERN_FAILURE;
    memcpy(out,&policy,sizeof(policy));*count=wrongCount?1:BO_POLICY_COUNT;*defaults=readDefault;return 0;
}
kern_return_t task_policy_set(task_policy_set_t task,task_policy_flavor_t flavor,task_policy_t input,mach_msg_type_number_t count){
    (void)task;CHECK(flavor==TASK_SUPPRESSION_POLICY&&count==BO_POLICY_COUNT,"Only suppression setter allowed");
    BOProcessPolicy *p=(BOProcessPolicy*)input;CHECK(p->suspend==0&&p->cpu_limit==0,"Cannot freeze or impose a hard cap");
    setCount++;if(setFailure)return KERN_FAILURE;
    policy=*p;return applyThenFail?KERN_FAILURE:0;
}
static BOSchedulingLease setup(void){
    memset(&policy,0,sizeof(policy));readFailure=setFailure=setCount=wrongCount=readDefault=applyThenFail=0;
    BOSchedulingLease l={.port=42};CHECK(BOReadPolicy(l.port,&l.original)==0,"Baseline readable");
    CHECK(BOMakeEfficientPolicy(&l.original,&l.applied),"Baseline supported");return l;
}
int main(void){
    BOSchedulingLease l=setup();readFailure=1;
    CHECK(BOApplyPolicy(&l)!=0&&setCount==0&&!l.pending,"No mutation without baseline read-back");
    l=setup();wrongCount=1;CHECK(BOApplyPolicy(&l)!=0&&setCount==0,"Reject unsupported ABI count");
    l=setup();readDefault=1;CHECK(BOApplyPolicy(&l)!=0&&setCount==0,"Defaults cannot stand in for actual policy");
    l=setup();policy.active=1;CHECK(BOApplyPolicy(&l)!=0&&setCount==0,"Concurrent policy change must abort application");
    l=setup();setFailure=1;CHECK(BOApplyPolicy(&l)!=0&&l.pending,"Unknown setter outcomes remain pending");
    setFailure=0;CHECK(BORestorePolicy(&l)==0&&!l.pending,"Failed no-op setter resolves safely");
    l=setup();applyThenFail=1;CHECK(BOApplyPolicy(&l)!=0&&l.pending,"Even setter error may have changed state");
    applyThenFail=0;CHECK(BORestorePolicy(&l)==0&&!l.pending&&BOPolicyEqual(&policy,&l.original),"Uncertain application restores original");
    l=setup();CHECK(BOApplyPolicy(&l)==0,"Apply works");policy.lowpri_cpu=0;
    CHECK(BORestorePolicy(&l)==KERN_ABORTED&&l.pending&&setCount==1,"Do not overwrite another policy actor; preserve recovery state");
    l=setup();CHECK(BOApplyPolicy(&l)==0,"Apply before failed restore");setFailure=1;
    CHECK(BORestorePolicy(&l)!=0&&l.pending,"Failed restoration remains pending");setFailure=0;
    CHECK(BORestorePolicy(&l)==0&&!l.pending,"Restoration may be retried");
    BOProcessPolicy original={.disk_throttle=1},applied;
    CHECK(!BOMakeEfficientPolicy(&original,&applied),"Do not activate dormant disk policy");original=(BOProcessPolicy){.background_sockets=1};
    CHECK(!BOMakeEfficientPolicy(&original,&applied),"Do not activate dormant network policy");
    puts("Scheduling lease fault checks: missing/invalid read-back, concurrent policy changes, uncertain setters, restoration failure/retry and dormant policy exclusion passed.");
}
