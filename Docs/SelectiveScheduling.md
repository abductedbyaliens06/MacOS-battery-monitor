# Selective scheduling mechanism · proposed administrator boundary

Status: real scheduling mechanism tested on a temporary test process. Administrator integration is **not approved, built into the app, installed, or active**. The installed v1.3.1 remains a preview. No battery-life improvement is established.

## Intended behavior

The monitoring scan discovers existing Python work. No scripts need to be relaunched or added to a queue. When enabled on battery, explicitly **Can finish later** workers that have sustained CPU activity receive an efficient macOS task scheduling policy. Normal and **Waiting for results** work, GUI applications, the monitor and unknown foreground contexts are excluded. Independent Python jobs deliberately marked flexible may be optimized while their parent editor is focused; the editor remains unrestricted. This resolves the earlier overly broad ancestor protection that would otherwise exclude an editor's background test jobs.

Brightness, display refresh rate, Low Power Mode, charging, voltage, current, fans and firmware have no setters in this mechanism. There is no process suspension, termination, signal-based duty cycling, memory access or arbitrary command execution. Background work can take longer. Protecting foreground responsiveness and measuring energy per completed task are required; reduced instantaneous watts alone is insufficient.

## Mechanism and evidence

`OptimizerHelper/SchedulingLease.c` reads the complete macOS `TASK_SUPPRESSION_POLICY`, rejects unavailable/default/incompatible policy data, and requires a neutral original suppression request. It changes only `active`, `lowpri_cpu`, and the computation `throughput_qos` hint. Dormant timer, disk, socket or other requests are rejected rather than accidentally activated. There is no hard CPU cap. macOS decides actual scheduling and frequencies.

This uses a macOS private policy structure, declared explicitly from [Apple's XNU task policy definition](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/task_policy_private.h). It is not an App Store API and needs validation across OS releases. Its non-inheritance follows [task_policy_create in Apple's source](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task_policy.c) and was independently verified by a real fork in the native check on macOS 27.0.1.

`./scripts/check-scheduling.sh` runs:

- A real change on the check executable itself, read-back, fork while active, exact restoration, and idempotent restoration. Its child does not inherit the suppression setting. No existing user process is changed.
- A mocked backend covering unreadable/default/wrong-sized policies, concurrent changes, a setter that changes state but reports failure, restoration failure and retry, and dormant I/O policy exclusion.
- Pure selection checks for importance, foreground, power, stale/paused monitoring, thermal state, sustained activity and protocol bounds.
- Syntax validation of the proposed guardian and a source-boundary audit. Syntax and source checks do **not** prove privileged runtime behavior or security.

The ordinary app was denied task-policy access to temporary children. A temporary debugger-entitled probe was denied too. Non-interactive sudo is unavailable; no administrator password has been requested or acquired. A root guardian therefore still needs a separate cross-process test before deployment.

## Proposed temporary guardian

`OptimizerHelper/main.m` proposes a 30-minute session launched explicitly from the target user's Terminal with sudo. It does not install a launch daemon, alter login settings or persist a background service. It refuses non-root execution, mismatched SUDO_UID, root/system process targets, non-Python workers, GUI applications and reused PIDs. It pins a local socket connection to the app's UID, PID and start identity; the client accepts only a root peer. The only request is a bounded set of at most 16 PID/start identities. Clients cannot supply commands, executable paths, hardware values or arbitrary policies.

Before each mutation it saves original/applied policies to a root-owned recovery journal under `/var/run`, using no-follow file access, bounded validated JSON and durable writes. A retained Mach task port binds a live lease to the original task rather than a future reused PID. It verifies the applied policy and restores the exact original only if the current policy still matches its own request. Conflicting external changes cause an error and retained recovery state rather than being silently overwritten.

Removing a target, connecting power, missing a heartbeat for 12 seconds, app exit, normal guardian interruption and the 30-minute session limit request restoration. A child begins at ordinary scheduling and can be independently evaluated by the next scan. This avoids the inherited Darwin background flag problem. The guardian checks foreground identity independently and never adjusts an actual foreground GUI app.

A forced guardian kill or crash cannot execute cleanup. Its root-owned journal is intended for recovery on the next authorized launch; until recovery has been verified, the app must show restoration as unconfirmed and permit no new adjustments. A worker may remain at reduced scheduling priority until recovery or its own exit. This is a remaining operational risk, not a hardware voltage/current risk. Recovery, sleep/wake, cross-process rights, IPC authentication and daemon failure paths still need administrator-session integration tests. The helper is a prototype and has not had an independent security review.

The proposed connection/client sources are under `Prototypes/SchedulingControl/`, outside Xcode's compiled source folder. The Xcode build-script sandbox remains enabled. No helper packaging phase or privileged service registration has been added.

## Approval and remaining validation

Automatic approval review rejected a proposed step to embed the root-capable helper and disable Xcode's build-script sandbox, citing an unauthorized privileged process-control boundary and an unnecessary sandbox change. That step did not execute. The sandbox change is withdrawn. Explicit user approval is needed before privileged integration and an administrator session; no bypass is being used.

Following approval, the necessary gates are:

1. Package the helper without disabling the build-script sandbox, authenticate the session, and validate real access and rollback against temporary **user-owned** worker processes first. Do not activate policies for real user work until those checks pass.
2. Test stale-heartbeat, normal quit, app crash, guardian crash/recovery, PID reuse, foreground changes, power connection and sleep/wake. Verify both policy state and child non-inheritance.
3. Wire explicit enable/pause and actual applied/restored/error status into Optimize. Failed rights or recovery leave control disabled; no simulated savings.
4. Run counterbalanced baseline/optimized/baseline/optimized trials **on battery**, with matching brightness, refresh rate, foreground task and background worker counts. Measure whole-Mac Wh, foreground response/completion time, background completed work, thermal state, monitoring overhead and confidence/variation. Current AC power cannot establish battery savings.
5. Require foreground task performance at least 90% of baseline, report total energy per completed work and background delay, and disable an intervention that regresses those measures. The 8 W/14 W and 30–40% runtime objectives remain unproven. Broad browsing/video savings comparable to system LPM may require additional cooperative app-specific controls; slowing Python work alone does not establish that objective.

Do not claim the full optimizer is complete based on successful policy changes or lower CPU usage alone.
