#include "Verification.h"
#include "SchedulingLease.h"
#include <libproc.h>
#include <pwd.h>
#include <grp.h>
#include <unistd.h>
#include <sys/wait.h>
#include <poll.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>

static int readBounded(int fd,void *value,size_t size){
    struct pollfd event={.fd=fd,.events=POLLIN};
    if(poll(&event,1,5000)<=0)return -1;
    ssize_t n=read(fd,value,size);return n==(ssize_t)size?0:-1;
}
int BOVerifyCrossProcess(uid_t uid){
    if(geteuid()!=0||uid<501)return 2;
    struct passwd *user=getpwuid(uid);if(!user)return 2;gid_t gid=user->pw_gid;
    int ready[2],command[2];if(pipe(ready)!=0)return 3;
    if(pipe(command)!=0){close(ready[0]);close(ready[1]);return 3;}
    pid_t child=fork();if(child<0){close(ready[0]);close(ready[1]);close(command[0]);close(command[1]);return 3;}
    if(child==0){
        close(ready[0]);close(command[1]);
        int state=0;
        if(setgroups(0,NULL)!=0||setgid(gid)!=0||setuid(uid)!=0||geteuid()!=uid)state=1;
        BOProcessPolicy original={0};
        if(!state&&BOReadPolicy(mach_task_self(),&original)!=0)state=2;
        if(write(ready[1],&state,sizeof(state))!=sizeof(state))_exit(4);
        close(ready[1]);char byte=0;
        if(readBounded(command[0],&byte,1)!=0)_exit(5);
        BOProcessPolicy final={0};
        if(BOReadPolicy(mach_task_self(),&final)!=0||!BOPolicyEqual(&original,&final))_exit(6);
        close(command[0]);_exit(state?3:0);
    }
    close(ready[1]);close(command[0]);int state=-1,result=1;
    BOSchedulingLease lease={.pid=child};
    if(readBounded(ready[0],&state,sizeof(state))==0&&state==0){
        struct proc_bsdinfo info={0};
        if(proc_pidinfo(child,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)&&info.pbi_uid==uid){
            lease.started=info.pbi_start_tvsec*1000000+info.pbi_start_tvusec;
            int access=task_for_pid(mach_task_self(),child,&lease.port);
            if(access==0){
                pid_t bound=0;struct proc_bsdinfo after={0};
                if(pid_for_task(lease.port,&bound)==0&&bound==child&&
                    proc_pidinfo(child,PROC_PIDTBSDINFO,0,&after,sizeof(after))==sizeof(after)&&after.pbi_uid==uid&&
                    after.pbi_start_tvsec*1000000+after.pbi_start_tvusec==lease.started&&
                    BOReadPolicy(lease.port,&lease.original)==0&&BOMakeEfficientPolicy(&lease.original,&lease.applied)){
                    int apply=BOApplyPolicy(&lease);int restore=BORestorePolicy(&lease);
                    if(apply==0&&restore==0)result=0;
                    else fprintf(stderr,"Disposable worker apply=%d restore=%d. No user work was touched.\n",apply,restore);
                }
            }else fprintf(stderr,"macOS denied disposable worker task access (%d). Live control remains unavailable.\n",access);
        }
    }
    if(lease.pending&&lease.port)BORestorePolicy(&lease);
    if(lease.port)mach_port_deallocate(mach_task_self(),lease.port);
    close(ready[0]);char quit='Q';
    /* The child waits at most five seconds. Ignore a closed pipe if it exited. */
    struct pollfd event={.fd=command[1],.events=POLLOUT};
    if(poll(&event,1,100)>0&&(event.revents&POLLOUT))write(command[1],&quit,1);
    close(command[1]);int status=0;while(waitpid(child,&status,0)<0&&errno==EINTR){}
    if(!WIFEXITED(status)||WEXITSTATUS(status)!=0)result=1;
    if(result==0)puts("PASS: disposable user-owned worker policy applied, read back and restored; child independently verified its original policy. No existing process was changed.");
    return result;
}
