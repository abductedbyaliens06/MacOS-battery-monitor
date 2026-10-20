#import <AppKit/AppKit.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <libproc.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ucred.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <strings.h>
#include "SchedulingLease.h"
#include "Verification.h"

/* Temporary, explicitly launched root guardian, not a persistent install.
 * No shell, exec, file-path request, memory access, process signal or hardware
 * setter exists in this server. The only writable task policy is in Lease.c.
 */
static volatile sig_atomic_t stopping=0;
static void stop(int signalNumber){ (void)signalNumber;stopping=1; }
static uint64_t startOf(struct proc_bsdinfo *p){return p->pbi_start_tvsec*1000000+p->pbi_start_tvusec;}
static BOOL identity(pid_t pid,uid_t uid,uint64_t started,struct proc_bsdinfo *out){
    return pid>1&&proc_pidinfo(pid,PROC_PIDTBSDINFO,0,out,sizeof(*out))==sizeof(*out)&&out->pbi_uid==uid&&startOf(out)==started;
}
static BOOL python(struct proc_bsdinfo *p){return strncasecmp(p->pbi_comm,"python",6)==0||strncasecmp(p->pbi_comm,"pytest",6)==0;}
static BOOL onBattery(void){
    CFTypeRef info=IOPSCopyPowerSourcesInfo();if(!info)return NO;
    CFStringRef source=IOPSGetProvidingPowerSourceType(info);
    BOOL result=source&&CFEqual(source,CFSTR(kIOPSBatteryPowerValue));CFRelease(info);return result;
}
static BOOL bindTask(pid_t pid,uid_t uid,uint64_t started,mach_port_t *port){
    struct proc_bsdinfo p={0};if(!identity(pid,uid,started,&p))return NO;
    if(task_for_pid(mach_task_self(),pid,port)!=KERN_SUCCESS)return NO;
    pid_t bound=0;
    if(!identity(pid,uid,started,&p)||pid_for_task(*port,&bound)!=KERN_SUCCESS||bound!=pid){mach_port_deallocate(mach_task_self(),*port);*port=0;return NO;}
    return YES;
}
static BOOL durableWrite(NSString *path,NSData *data){
    NSString *template=[path stringByAppendingString:@".XXXXXX"];
    char name[PATH_MAX];if(![template getFileSystemRepresentation:name maxLength:sizeof(name)])return NO;
    int fd=mkstemp(name);if(fd<0)return NO;BOOL ok=fchmod(fd,0600)==0;
    const char *bytes=data.bytes;size_t left=data.length;
    while(ok&&left){ssize_t n=write(fd,bytes,left);if(n<0&&errno==EINTR)continue;if(n<=0){ok=NO;break;}bytes+=n;left-=n;}
    if(ok)ok=fsync(fd)==0;close(fd);
    if(ok)ok=rename(name,path.fileSystemRepresentation)==0;
    if(!ok)unlink(name);
    int dir=open("/var/run",O_RDONLY);if(dir>=0){if(fsync(dir)!=0)ok=NO;close(dir);}
    return ok;
}
static BOOL journal(NSString *path,BOSchedulingLease *leases,uid_t uid){
    NSMutableArray *rows=[NSMutableArray array];
    for(int i=0;i<16;i++)if(leases[i].pending){
        BOSchedulingLease *l=&leases[i];
        [rows addObject:@{@"pid":@(l->pid),@"started":@(l->started),@"uid":@(uid),
            @"original":[[NSData dataWithBytes:&l->original length:sizeof(l->original)] base64EncodedStringWithOptions:0],
            @"applied":[[NSData dataWithBytes:&l->applied length:sizeof(l->applied)] base64EncodedStringWithOptions:0]}];
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];return data&&durableWrite(path,data);
}
static BOOL recover(NSString *path,uid_t uid){
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(fd<0)return errno==ENOENT;
    struct stat st;BOOL safe=fstat(fd,&st)==0&&st.st_uid==0&&S_ISREG(st.st_mode)&&st.st_nlink==1&&st.st_size<=65536;close(fd);if(!safe)return NO;
    NSData *data=[NSData dataWithContentsOfFile:path];id rows=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![rows isKindOfClass:NSArray.class]||[rows count]>16)return NO;
    for(id row in rows){
        if(![row isKindOfClass:NSDictionary.class]||![row[@"pid"] isKindOfClass:NSNumber.class]||![row[@"started"] isKindOfClass:NSNumber.class]||![row[@"uid"] isKindOfClass:NSNumber.class]||[row[@"uid"] unsignedIntValue]!=uid||![row[@"original"] isKindOfClass:NSString.class]||![row[@"applied"] isKindOfClass:NSString.class])return NO;
        NSData *a=[[NSData alloc]initWithBase64EncodedString:row[@"original"] options:0],*b=[[NSData alloc]initWithBase64EncodedString:row[@"applied"] options:0];
        if(a.length!=64||b.length!=64)return NO;
        BOSchedulingLease l={.pid=[row[@"pid"] intValue],.started=[row[@"started"] unsignedLongLongValue],.pending=true};
        memcpy(&l.original,a.bytes,64);memcpy(&l.applied,b.bytes,64);
        BOProcessPolicy expected;if(!BOMakeEfficientPolicy(&l.original,&expected)||!BOPolicyEqual(&expected,&l.applied))return NO;
        struct proc_bsdinfo p={0};if(!identity(l.pid,uid,l.started,&p))continue;
        if(!bindTask(l.pid,uid,l.started,&l.port))return NO;
        int r=BORestorePolicy(&l);mach_port_deallocate(mach_task_self(),l.port);if(r!=0)return NO;
    }
    return durableWrite(path,[NSData dataWithBytes:"[]" length:2]);
}
static int recoverOnly(uid_t uid){
    NSString *base=[NSString stringWithFormat:@"/var/run/battery-optimizer-%u",uid];
    int lock=open([base stringByAppendingString:@".lock"].fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    struct stat st;
    if(lock<0||fstat(lock,&st)!=0||st.st_uid!=0||!S_ISREG(st.st_mode)||st.st_nlink!=1||flock(lock,LOCK_EX|LOCK_NB)!=0){
        if(lock>=0)close(lock);fprintf(stderr,"Stop the live guardian before recovery.\n");return 3;
    }
    BOOL ok=recover([base stringByAppendingString:@".json"],uid);close(lock);
    if(ok)puts("Recorded original scheduling policies restored. No new adjustments applied.");
    else fprintf(stderr,"Recovery could not be verified. Journal preserved; no new adjustments applied.\n");
    return ok?0:3;
}
static BOOL restoreAll(BOSchedulingLease *leases,NSString *path,uid_t uid){
    BOOL ok=YES, changed=NO;
    for(int i=0;i<16;i++)if(leases[i].port){
        changed=YES;
        BOSchedulingLease *l=&leases[i];
        int r=BORestorePolicy(l);
        if(r==KERN_SUCCESS||r==KERN_TERMINATED||r==MACH_SEND_INVALID_DEST){l->pending=false;mach_port_deallocate(mach_task_self(),l->port);memset(l,0,sizeof(*l));}
        else ok=NO;
    }
    return (!changed||journal(path,leases,uid))&&ok;
}
static BOOL protectedByForeground(pid_t pid,pid_t foreground,uid_t uid){
    if(foreground<=1)return YES;
    /* Explicit flexible Python jobs may be descendants of an editor; protect
     * actual foreground membership, not every independent job it launched. */
    if(pid==foreground)return YES;
    struct proc_bsdinfo p={0};
    if(proc_pidinfo(foreground,PROC_PIDTBSDINFO,0,&p,sizeof(p))!=sizeof(p)||p.pbi_uid!=uid)return YES;
    return NO;
}
static int serve(uid_t uid,pid_t app){
    struct proc_bsdinfo appInfo={0};
    if(proc_pidinfo(app,PROC_PIDTBSDINFO,0,&appInfo,sizeof(appInfo))!=sizeof(appInfo)||appInfo.pbi_uid!=uid)return 2;
    uint64_t appStart=startOf(&appInfo);
    char executable[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(proc_pidpath(app,executable,sizeof(executable))<=0||![[NSString stringWithUTF8String:executable] hasSuffix:@"/battery stuff.app/Contents/MacOS/battery stuff"]){fprintf(stderr,"Expected the running Battery Monitor app.\n");return 2;}
    NSString *base=[NSString stringWithFormat:@"/var/run/battery-optimizer-%u",uid];
    NSString *lockPath=[base stringByAppendingString:@".lock"],*journalPath=[base stringByAppendingString:@".json"];
    int lock=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    struct stat ls;if(lock<0||fstat(lock,&ls)!=0||ls.st_uid!=0||!S_ISREG(ls.st_mode)||ls.st_nlink!=1||flock(lock,LOCK_EX|LOCK_NB)!=0){fprintf(stderr,"Another guardian is running, or lock is unsafe.\n");return 2;}
    if(!recover(journalPath,uid)){fprintf(stderr,"Recovery requires review; refusing new changes.\n");close(lock);return 3;}
    NSString *socketPath=[NSString stringWithFormat:@"%@-%d.sock",base,app];
    struct sockaddr_un address={.sun_family=AF_UNIX};strlcpy(address.sun_path,socketPath.fileSystemRepresentation,sizeof(address.sun_path));address.sun_len=sizeof(address);
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    if(listener<0||bind(listener,(struct sockaddr*)&address,sizeof(address))!=0){fprintf(stderr,"Cannot bind private session socket.\n");close(lock);return 2;}
    if(chown(address.sun_path,uid,-1)!=0||chmod(address.sun_path,0600)!=0||listen(listener,1)!=0){unlink(address.sun_path);close(listener);close(lock);return 2;}
    signal(SIGINT,stop);signal(SIGTERM,stop);signal(SIGHUP,stop);signal(SIGPIPE,SIG_IGN);
    BOSchedulingLease leases[16]={0};int client=-1;NSMutableData *input=[NSMutableData data];
    double last=NSProcessInfo.processInfo.systemUptime,begin=last;BOOL failed=NO;
    fprintf(stderr,"Guardian ready for app %d. No changes until explicitly enabled on battery. Ctrl-C restores and exits.\n",app);
    while(!stopping&&!failed){@autoreleasepool{
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate date]];
        struct proc_bsdinfo currentApp={0};double now=NSProcessInfo.processInfo.systemUptime;
        if(!identity(app,uid,appStart,&currentApp)||now-begin>1800)break;
        pid_t foreground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        BOOL battery=onBattery();
        if(now-last>12||!battery){if(!restoreAll(leases,journalPath,uid)){failed=YES;break;}}
        for(int i=0;i<16;i++)if(leases[i].pending){
            BOProcessPolicy actual;int readback=BOReadPolicy(leases[i].port,&actual);
            if(readback==KERN_TERMINATED||readback==MACH_SEND_INVALID_DEST){
                leases[i].pending=false;mach_port_deallocate(mach_task_self(),leases[i].port);memset(&leases[i],0,sizeof(leases[i]));
                if(!journal(journalPath,leases,uid)){failed=YES;break;}
            }else if(readback!=0||!BOPolicyEqual(&actual,&leases[i].applied)){failed=YES;break;}
        }
        if(failed)break;
        for(int i=0;i<16;i++)if(leases[i].pending&&protectedByForeground(leases[i].pid,foreground,uid)){
            int r=BORestorePolicy(&leases[i]);if(r!=0){failed=YES;break;}mach_port_deallocate(mach_task_self(),leases[i].port);memset(&leases[i],0,sizeof(leases[i]));
            if(!journal(journalPath,leases,uid)){failed=YES;break;}
        }
        struct pollfd pollFD={.fd=client<0?listener:client,.events=POLLIN};int ready=poll(&pollFD,1,500);
        if(ready<0){if(errno==EINTR)continue;break;}
        if(!ready)continue;
        if(client<0){
            client=accept(listener,NULL,NULL);if(client<0)continue;
            uid_t peerUID;gid_t peerGID;pid_t peerPID=0;socklen_t length=sizeof(peerPID);
            if(getpeereid(client,&peerUID,&peerGID)!=0||peerUID!=uid||getsockopt(client,SOL_LOCAL,LOCAL_PEERPID,&peerPID,&length)!=0||peerPID!=app){close(client);client=-1;continue;}
            int flags=fcntl(client,F_GETFL,0);fcntl(client,F_SETFL,flags|O_NONBLOCK);last=now;continue;
        }
        char chunk[4096];ssize_t n=read(client,chunk,sizeof(chunk));
        if(n<0&&(errno==EINTR||errno==EAGAIN))continue;
        if(n<=0)break;
        [input appendBytes:chunk length:n];if(input.length>32768)break;
        const unsigned char *bytes=input.bytes;NSUInteger newline=NSNotFound;
        for(NSUInteger i=0;i<input.length;i++)if(bytes[i]=='\n'){newline=i;break;}
        if(newline==NSNotFound)continue;
        NSData *line=[input subdataWithRange:NSMakeRange(0,newline)];[input replaceBytesInRange:NSMakeRange(0,newline+1) withBytes:NULL length:0];
        /* Exactly one outstanding request; no pipelined privileged operations. */
        if(input.length)break;
        id request=[NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if(![request isKindOfClass:NSDictionary.class]||![request[@"version"] isEqual:@1]||![request[@"targets"] isKindOfClass:NSArray.class]||[request[@"targets"] count]>16)break;
        NSArray *targets=request[@"targets"];NSMutableSet *desired=[NSMutableSet set];BOOL valid=YES;
        for(id target in targets){if(![target isKindOfClass:NSDictionary.class]||![target[@"pid"] isKindOfClass:NSNumber.class]||![target[@"started"] isKindOfClass:NSNumber.class]){valid=NO;break;}[desired addObject:[NSString stringWithFormat:@"%d:%llu",[target[@"pid"] intValue],[target[@"started"] unsignedLongLongValue]]];}
        if(!valid||desired.count!=targets.count)break;
        last=now;NSMutableArray *blocked=[NSMutableArray array];BOOL changed=NO;
        for(int i=0;i<16;i++)if(leases[i].port){
            BOSchedulingLease *l=&leases[i];NSString *key=[NSString stringWithFormat:@"%d:%llu",l->pid,l->started];
            struct proc_bsdinfo p={0};
            if(![desired containsObject:key]||!battery||!identity(l->pid,uid,l->started,&p)){
                int r=BORestorePolicy(l);
                if(r!=0&&r!=KERN_TERMINATED&&r!=MACH_SEND_INVALID_DEST){failed=YES;break;}
                changed=YES;
                l->pending=false;mach_port_deallocate(mach_task_self(),l->port);memset(l,0,sizeof(*l));
            }
        }
        if(changed&&!journal(journalPath,leases,uid))failed=YES;
        if(!failed&&battery)for(NSDictionary *target in targets){
            pid_t pid=[target[@"pid"] intValue];uint64_t started=[target[@"started"] unsignedLongLongValue];
            BOOL exists=NO;int slot=-1;for(int i=0;i<16;i++){if(leases[i].pid==pid&&leases[i].started==started)exists=YES;if(!leases[i].port&&slot<0)slot=i;}
            if(exists)continue;
            struct proc_bsdinfo p={0};NSString *reason=nil;
            if(slot<0||pid==app||pid==getpid()||!identity(pid,uid,started,&p)||!python(&p)||(p.pbi_flags&PROC_FLAG_APPLICATION)||protectedByForeground(pid,foreground,uid))reason=@"Protected, exited, wrong identity or unsupported worker";
            BOSchedulingLease l={.pid=pid,.started=started};
            if(!reason&&!bindTask(pid,uid,started,&l.port))reason=@"macOS denied task access";
            if(!reason&&(BOReadPolicy(l.port,&l.original)!=0||!BOMakeEfficientPolicy(&l.original,&l.applied)))reason=@"Original policy unavailable or already managed";
            if(reason){if(l.port)mach_port_deallocate(mach_task_self(),l.port);[blocked addObject:@{@"pid":@(pid),@"reason":reason}];continue;}
            l.pending=true;leases[slot]=l;
            if(!journal(journalPath,leases,uid)){failed=YES;break;}
            struct proc_bsdinfo latest={0};
            BOOL stillEligible=identity(pid,uid,started,&latest)&&python(&latest)&&!(latest.pbi_flags&PROC_FLAG_APPLICATION)&&
                !protectedByForeground(pid,NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier,uid);
            int r=stillEligible?BOApplyPolicy(&leases[slot]):KERN_ABORTED;
            if(r!=0){[blocked addObject:@{@"pid":@(pid),@"reason":[NSString stringWithFormat:@"Apply/read-back failed (%d)",r]}];if(BORestorePolicy(&leases[slot])!=0){failed=YES;break;}mach_port_deallocate(mach_task_self(),leases[slot].port);memset(&leases[slot],0,sizeof(leases[slot]));}
            if(!journal(journalPath,leases,uid)){failed=YES;break;}
        }
        NSMutableArray *active=[NSMutableArray array];for(int i=0;i<16;i++)if(leases[i].pending)[active addObject:[NSString stringWithFormat:@"%d:%llu",leases[i].pid,leases[i].started]];
        NSData *reply=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"active":active,@"blocked":blocked,@"failed":@(failed),@"onBattery":@(battery)} options:0 error:nil];
        NSMutableData *packet=[reply mutableCopy];[packet appendBytes:"\n" length:1];
        ssize_t sent=write(client,packet.bytes,packet.length);if(sent!=(ssize_t)packet.length)break;
    }}
    BOOL restored=restoreAll(leases,journalPath,uid);
    if(client>=0)close(client);close(listener);unlink(address.sun_path);close(lock);
    if(!restored)fprintf(stderr,"Restoration incomplete. Root-owned recovery journal preserved; restart this helper before further use.\n");
    else fprintf(stderr,"All live scheduling leases restored. Guardian stopped.\n");
    return restored&&!failed?0:3;
}
int main(int argc,const char **argv){@autoreleasepool{
    BOOL verifyOnly=argc==3&&strcmp(argv[1],"--verify")==0;
    BOOL recoveryOnly=argc==3&&strcmp(argv[1],"--recover")==0;
    BOOL serving=argc==4&&strcmp(argv[1],"--serve")==0;
    if(!verifyOnly&&!recoveryOnly&&!serving){fprintf(stderr,"Usage: BatteryOptimizerHelper --verify/--recover <user-uid> OR --serve <user-uid> <app-pid>\n");return 2;}
    char *end=NULL;unsigned long uid=strtoul(argv[2],&end,10);if(!*argv[2]||*end||uid<501||uid>UINT_MAX)return 2;
    if(geteuid()!=0){fprintf(stderr,"Administrator authorization is required. No changes made.\n");return 2;}
    struct stat console;
    if(stat("/dev/console",&console)!=0||console.st_uid!=uid){fprintf(stderr,"The target must be the current console user.\n");return 2;}
    const char *sudoUID=getenv("SUDO_UID");if(sudoUID&&strtoul(sudoUID,NULL,10)!=uid)return 2;
    signal(SIGPIPE,SIG_IGN);
    if(recoveryOnly)return recoverOnly((uid_t)uid);
    if(verifyOnly)return BOVerifyCrossProcess((uid_t)uid);
    long app=strtol(argv[3],&end,10);if(!*argv[3]||*end||app<=1||app>INT_MAX)return 2;
    if(BOVerifyCrossProcess((uid_t)uid)!=0){fprintf(stderr,"Disposable-worker safety gate failed. Server will not start.\n");return 3;}
    [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyProhibited];
    return serve((uid_t)uid,(pid_t)app);
}}
