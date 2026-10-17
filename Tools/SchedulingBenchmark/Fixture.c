/* Disposable workload only. Never obtains another task's port or changes an
 * existing process. Commands select fixed modes, not executable code. */
#include "../../OptimizerHelper/SchedulingLease.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
static volatile uint64_t sink=1;
static uint64_t work(unsigned count){uint64_t value=sink;for(unsigned i=0;i<count;i++)value=(value^(value>>13))*6364136223846793005ULL+1;sink=value;return value;}
static double seconds(void){struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return ts.tv_sec+ts.tv_nsec/1e9;}
int main(int argc,char **argv){
    if(argc!=2||(strcmp(argv[1],"--worker")&&strcmp(argv[1],"--probe")))return 2;
    int worker=!strcmp(argv[1],"--worker");
    BOSchedulingLease lease={.pid=getpid(),.port=mach_task_self()};
    if(worker&&(BOReadPolicy(lease.port,&lease.original)!=0||!BOMakeEfficientPolicy(&lease.original,&lease.applied)))return 3;
    if(worker){int flags=fcntl(STDIN_FILENO,F_GETFL,0);if(fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK)<0)return 3;}
    setvbuf(stdout,NULL,_IOLBF,0);
    double begin=seconds();uint64_t chunks=0;int result=0;
    while(seconds()-begin<1800){
        char command=0;ssize_t n=read(STDIN_FILENO,&command,1);
        if(n==0)break;
        if(n<0&&errno!=EAGAIN&&errno!=EINTR){result=4;break;}
        if(n>0){
            if(worker){BOProcessPolicy current;if(BOReadPolicy(lease.port,&current)!=0||
                !BOPolicyEqual(&current,lease.pending?&lease.applied:&lease.original)){result=5;break;}}
            if(command=='Q')break;
            if(worker&&(command=='B'||command=='E')){
                int r=command=='B'?BORestorePolicy(&lease):(lease.pending?0:BOApplyPolicy(&lease));
                if(r){result=5;break;}
                printf("{\"mode\":\"%s\",\"chunks\":%llu,\"time\":%.9f}\n",lease.pending?"efficient":"baseline",chunks,seconds());
            }else if(worker&&command=='S'){
                printf("{\"mode\":\"%s\",\"chunks\":%llu,\"time\":%.9f}\n",lease.pending?"efficient":"baseline",chunks,seconds());
            }else if(!worker&&command=='P'){
                double start=seconds();work(50000);
                printf("{\"computeSeconds\":%.9f,\"checksum\":%llu}\n",seconds()-start,sink);
            }else{result=6;break;}
        }
        if(worker){work(250000);chunks++;}
    }
    if(worker&&BORestorePolicy(&lease)!=0)result=7;
    return result;
}
