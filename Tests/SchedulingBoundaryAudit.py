"""Source guard for the proposed helper; this does not replace runtime review."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
helper = root / 'OptimizerHelper'
for path in helper.glob('*'):
    source = path.read_text()
    for pattern in [r'\b(setpriority|kill|ptrace|task_suspend\w*|task_resume\w*|mach_vm_\w*|vm_write|system|popen|exec\w*|posix_spawn\w*)\s*\(', r'IORegistryEntrySet', r'IOConnectCall', r'/usr/bin/pmset']:
        assert not re.search(pattern, source), (path.name, pattern)
core = (helper / 'SchedulingLease.c').read_text()
assert len(re.findall(r'\btask_policy_set\s*\(', core)) == 1
assert 'task_policy_set(port, TASK_SUPPRESSION_POLICY' in core
assert 'policy->cpu_limit || policy->suspend' in core
assert 'original->disk_throttle' in core and 'original->background_sockets' in core
server = (helper / 'main.m').read_text()
assert len(re.findall(r'\btask_for_pid\s*\(', server)) == 1
assert 'LOCAL_PEERPID' in server and 'peerPID!=app' in server
assert 'peerUID!=uid' in server and 'pbi_uid==uid' in server
assert 'O_NOFOLLOW' in server and 'fsync(fd)' in server
assert 'now-last>12' in server and 'now-begin>1800' in server
project = (root / 'battery stuff.xcodeproj/project.pbxproj').read_text()
assert 'ENABLE_USER_SCRIPT_SANDBOXING = NO' not in project
assert 'com.apple.product-type.tool' in project and 'BatteryOptimizerHelper' in project
assert 'PBXShellScriptBuildPhase' not in project, 'Helper must use native build/copy phases'
verify = (helper / 'Verification.c').read_text()
assert 'setgroups(0,NULL)' in verify and 'setuid(uid)' in verify
assert 'task_for_pid(mach_task_self(),child' in verify
assert 'BOVerifyCrossProcess((uid_t)uid)!=0' in server
print('Approved scheduling boundary: one policy setter, no hardware/memory/signal/command APIs; identity/peer checks, recovery and timeouts present. Native packaging preserves script sandbox; disposable-worker gate precedes server startup.')
