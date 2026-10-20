#include "../OptimizerHelper/SchedulingLease.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#define CHECK(v,msg) do{if(!(v)){fprintf(stderr,"FAIL: %s\n",msg);exit(1);}}while(0)
int main(void) {
    BOSchedulingLease lease={.pid=getpid(),.port=mach_task_self()};
    CHECK(BOReadPolicy(lease.port,&lease.original)==KERN_SUCCESS,"Read exact own policy");
    CHECK(BOMakeEfficientPolicy(&lease.original,&lease.applied),"Build limited scheduling intervention");
    CHECK(!lease.applied.suspend&&!lease.applied.cpu_limit&&!lease.applied.disk_throttle&&!lease.applied.background_sockets,"No freeze, hard cap, disk or network intervention");
    kern_return_t apply=BOApplyPolicy(&lease);
    if(apply!=KERN_SUCCESS){BORestorePolicy(&lease);fprintf(stderr,"apply=%d\n",apply);return 1;}
    /* A real fork while the change is live verifies the non-inherited property. */
    pid_t child=fork();
    if(child==0){BOProcessPolicy p;int r=BOReadPolicy(mach_task_self(),&p);_exit(r==0&&p.active==0&&p.lowpri_cpu==0?0:3);}
    int status=0;waitpid(child,&status,0);
    kern_return_t restore=BORestorePolicy(&lease);
    CHECK(restore==KERN_SUCCESS&&!lease.pending,"Restore exact original policy");
    CHECK(WIFEXITED(status)&&WEXITSTATUS(status)==0,"Forked children do not inherit suppression policy");
    CHECK(BORestorePolicy(&lease)==KERN_SUCCESS,"Restore is idempotent");
    puts("Native scheduling lease: real apply/read-back, fork non-inheritance, exact restoration and idempotence passed. Only the test process was changed.");
}
