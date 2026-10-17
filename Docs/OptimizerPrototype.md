# Battery optimizer prototype · v1

Open **Optimize** in the menu bar. The prototype begins in preview mode with its managed queue paused every time the app starts. The usage study continues independently. Study recommendations never change existing applications or processes.

## Scope and safety boundary

The optimizer contains no SMC/IOKit calls, voltage/current controls, charging limits, fan controls, firmware operations, clock changes, `pmset` commands, administrator helper, process-priority changes, core-affinity controls or process signals. Brightness, refresh rate and Low Power Mode remain untouched. It does not adopt, suspend, terminate or throttle existing processes.

The existing battery sensor reader still uses SMC for observation. Its private command interface now accepts only key-information (9) and read-bytes (5), through a closed read-command enum. It has no write-key command. A source-boundary audit and sensor regression suite check this distinction. This is a code boundary, not a claim that standalone user-level applications are generally sandboxed or incapable of modifying a system.

8 W regular use, 14 W demanding use, 90% performance and 30–40% more runtime are **research targets**. This version neither guarantees them nor treats low wattage alone as success. It does not yet measure task responsiveness or train a model.

## Managed queue

1. Choose a Python interpreter, trusted `.py` script and working directory. Native Python executables are accepted, including venv symlinks; shell scripts/shims and arbitrary command strings are rejected. The selected interpreter path is retained so venv behavior is preserved.
2. Give the job a name and importance. Optional arguments are one literal argument per line; they receive no shell expansion. The interpreter receives `-u -- script.py ...`. Standard input is closed, so interactive prompts are unsupported.
3. **Add to paused queue** stores the definition in memory and pauses new dispatch. It never executes the script. Review the queue, then use **Start queue…** and confirm to enable dispatch.
4. **Pause queue** immediately stops new launches. Running jobs finish normally. Importance can be changed or a queued job removed before launch. No running job receives a signal or new scheduling policy.

Only run code you trust. A selected script runs with your ordinary user permissions and can modify files or launch its own processes. The optimizer does not inspect or sandbox script contents. Its hardware-control exclusion applies to the optimizer's code, not arbitrary code a user independently chooses to execute.

The limit is one root job on battery, and one or optionally two on the adapter. It does **not** limit a script's internal workers or CPU threads. Starting fewer jobs is not proof of energy savings. Use the test runner's own worker configuration inside a trusted script when experimenting later.

## Decision rules

- Fresh, enabled study monitoring and a known power source are required for every launch. Sleep and critical/invalid thermal context hold all new launches.
- **Waiting for results** gets the next available slot, including while interacting on battery. This is queue ordering, not an OS priority boost; an already-running job is not preempted.
- **Normal** and **Can finish later** jobs defer while interacting on battery. Away begins after two minutes without input. Returning does not interrupt a running script.
- Optional battery launches also wait for at least 30 seconds of continuous measured draw. The rolling mean covers up to 60 seconds, breaks on missing/stale readings or source changes, and uses time-weighted intervals. When above the research target, optional launches wait. Foreground work is never power-capped.
- Manual Study workload **Tests / build** or **Editing** selects the 14 W reference; other labels use 8 W. These labels do not imply actual workload recognition.
- Serious thermal state holds non-urgent launches and restricts urgent launches to one. macOS remains responsible for thermal management. Optional launches have a 15-second cooldown after completion.
- Any script failure or launch/log-write failure pauses dispatch. Running jobs are left alone.

## Lifecycle and output

Up to 20 pending jobs and 50 finished summaries are retained in memory. Each job's combined output is capped at 32 KiB while excess data continues draining to prevent pipe backpressure. Output remains in memory, is not exported and is lost on relaunch. Completion waits for root exit and stream closure; scripts must join their children and must not leave long-lived descendants holding output streams open.

Normal Quit is blocked while managed executions are running, and the queue is paused. This preserves output connections and avoids implicitly interrupting user work. Let scripts finish before quitting. A crash, forced quit or OS shutdown can interrupt output streams and tracking; this prototype is not a durable job supervisor. There is deliberately no kill/freeze control. Use this prototype for short, bounded, trusted jobs.

Run summaries live in `optimizer-runs-v1.json` beside battery history. They contain user-supplied job names, importance, timestamps, root PID, status and root runtime. They omit interpreter/script paths, arguments and output. Corrupt run logs are preserved; explicit **Clear finished summaries** resets that separate log. No queued definition is persisted, no run resumes automatically, and interrupted runs are marked untracked without touching the old PID. Battery history and study data are not cleared by this control.

## Validation

`./scripts/check.sh` runs telemetry, preferences, history, study, migration and policy checks plus the safety-boundary audit. `./scripts/check-optimizer.sh` compiles the real service/executor and uses only temporary fixture scripts to verify explicit launch, concurrency, pause/failure handling, literal arguments, output bounds/draining, archive privacy, corrupt-log recovery and restart behavior. It renders synthetic light/dark layouts offscreen, uses a prohibited activation policy and opens no windows. Native control interiors may appear as placeholders in ImageRenderer; full UI interaction remains a live-app check.

The checks do not run user scripts, alter existing processes, invoke power controls or stress hardware. Comparative watt-hour, latency and completion-time experiments remain future work; no efficiency improvement is claimed yet.
