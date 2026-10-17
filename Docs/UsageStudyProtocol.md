# Usage study protocol · version 1

The study is observational. It never changes power modes, display settings, scheduling policies, process state, or test-worker counts. Collection begins when the updated app launches; pause/resume is in **Study**. A workload label is explicit user input, not inferred intent.

## Access status of this build

The sandbox is retained. A signed-app integration check on the development Mac found that `proc_listpids` is denied: discovery of other apps is unavailable. The collector falls back to its own counters where permitted and marks affected intervals with `discoveryLimitedSamples`. Battery/activity observations still work, but this is **not yet a complete cross-app baseline**. No model should be trained from it as if other processes were idle.

Enabling ordinary current-user process discovery in a standalone, non-sandboxed distribution is a separate security-boundary change requiring explicit user approval. It has not been applied. An authorized transition must preserve the existing sandbox container's battery history and preferences before changing storage locations.

## Measurements and boundaries

- Every five seconds a utility queue reads resource counters for readable processes belonging to the current user. Other users and kernel/system services are outside the ranking. Sandboxing and OS restrictions can deny counters; denied/exited processes are counted, not recorded as zero. Scans cap enumeration at 8,192 PIDs.
- Identity is PID plus process start time. Parent traversal groups GUI helpers under their app and Python descendants under their oldest visible Python ancestor. Python job identities expire when the root process restarts. Other unattached commands group by executable name; these are families, not individual script identities. Command arguments and executable paths are never read.
- CPU-time differences are measured in seconds. 100% CPU means one core. Group average CPU uses the family's sampled presence, not the whole report duration. Footprint is the peak sum of visible member footprints, not a precise deduplicated physical-memory total. Disk byte counters and background/maintenance QoS CPU time are recorded when process counters are readable.
- Whole-Mac discharge watts reuse the battery sensor pipeline. Only valid, consecutive battery intervals from the same source integrate energy, using a trapezoid. Charging observations are retained as context but never counted as battery draw. Power coverage is measured battery seconds / all observed seconds, including AC time; it is not a sensor accuracy score.
- Foreground app identity, manual workload, LPM state, thermal state, readable display refresh rates and memory-pressure flags accompany observations. Brightness is explicitly unavailable. Zero/variable refresh rates are omitted rather than guessed. The app records input inactivity duration only through the system idle counter; it does not intercept input. Away begins after two minutes; screen-off events are separate. Screen-off is not a claim that the machine is locked.
- First samples, process births/PID reuse, counter resets, gaps over 15 seconds, clock discontinuities, sleep, pause and restart establish new baselines. App/activity/display/power/workload context transitions are excluded because their interval attribution is ambiguous. Processes that start and exit between scans are missed. Context equality deliberately favors reliable attribution over complete coverage.

## Attribution and intent

Process watts are unavailable. “Mac draw during its activity” is the time-weighted whole-Mac discharge during sampled intervals where that family's CPU time exceeded 0.05 seconds. It includes every other workload and the display. These overlapping values cannot be added and do not establish causation.

Importance is Unclassified, Waiting for results, Normal, or Can finish later. Explicit labels are saved by app/family identity. The export retains labels at observation time; the report shows the current label. Candidate messages require a flexible label and at least 30 CPU seconds during away/screen-off intervals; they propose a future experiment and do not predict savings or trigger actions. No model is trained.

## Storage and controls

Minute summaries use local SQLite in the app's Application Support/BatteryMonitor/usage-study-v1.sqlite, alongside battery history. The utility queue writes incremental updates about once a minute; an open report refreshes up to every 30 seconds and can flush sooner. Sleep, normal quit, pause and explicit export flush pending data. An abnormal crash can lose the most recent unsaved interval summaries.

Retention is up to seven days or 20,000 context-minute rows. Each minute/context retains at most 40 process/importance groups ranked by CPU time. The database page limit is approximately 64 MiB plus its bounded write-ahead log. A full or invalid store pauses collection and preserves existing data. Clear removes study rows and importance labels; it leaves battery history untouched. Export streams JSON to the file chosen by the user. Historical app identities and activity patterns are personal data: review before sharing.

No network, analytics, screenshots, URLs, window titles, keystrokes, environment variables, command arguments or document contents are collected. Pause stops new scans; an in-flight scan may finish but is invalidated before UI publication. The prior completed interval is saved. The sandbox remains enabled. The export entitlement grants only files explicitly selected in the save dialog.

## Establishing a useful baseline

Start with a week covering repeated coding, test runs, browsing, playback, editing, foreground interaction and away periods. Explicitly label workloads and job importance. Treat app rankings as incomplete when process counters are restricted or low-ranked groups have been dropped.

The health card reports total Battery Monitor CPU/footprint and scan wall-clock duration. It does not isolate collector energy. Before claiming efficiency, compare matched collector-on and collector-paused sessions, preserving brightness, display mode, LPM, temperature and workload as closely as possible. Check responsiveness and job completion time as well as watt-hours. Repeat and vary run order to reduce cache/thermal confounding.

The current release does not measure input latency, video dropped frames, GPU power per process, or job completion/performance automatically. Those require task integrations and controlled experiments. Passive correlation cannot prove that throttling saves energy. The 8 W / 14 W and 30–40% runtime aspirations are not enforced or claimed by this observational version.
