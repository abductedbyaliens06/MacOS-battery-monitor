# Battery scheduling pilot

Run from the repository:

```sh
./scripts/run-scheduling-benchmark.sh
```

This needs **battery power with Low Power Mode already off**, and runs three counterbalanced cycles of four trials each. Every trial has 10 seconds of settling followed by 20 seconds of measurement: approximately six minutes in total. It does not change brightness, refresh rate, LPM or power settings. Keep lighting, brightness, display setup, foreground activity and other workloads stable. Display-rate telemetry can be unavailable; brightness is unmeasured. The default JSON report is a new file under `/tmp`; existing output files are never overwritten.

For a short protocol pilot (cannot establish a benefit):

```sh
./scripts/run-scheduling-benchmark.sh --cycles 1 --seconds 10
```

The runner compiles a disposable CPU workload, a synthetic latency probe and a read-only battery collector. There is no administrator helper, sudo, discovered-process control, user script, persistent service or settings change. The workload applies and restores the scheduling policy **to itself**. EOF triggers normal restoration/exit; all fixture processes have bounded lifetimes. At most one CPU-bound worker plus brief foreground-probe requests are used. This is an experiment that consumes battery, not an optimization mode for ordinary use.

AC power, LPM, missing/stale discharge readings, elevated thermal state or a display-rate change stop the pilot. The initial AC-power preflight runs before launching workload fixtures. Canceled or incomplete experiments remain inconclusive. Whole-Mac energy is integrated from read-only SMC battery readings using actual elapsed intervals, with no missing-value extrapolation or zero-filled power. Native and collector clock origins are not assumed identical. The analysis requires complete coverage before a trial can enter a comparison.

The report includes average power, background completed work per second, whole-Mac energy per unit of work, and synthetic foreground p95 round-trip latency. Treatments alternate ABBA/BAAB across cycles. Confidence intervals use cycle-level ratios, not hundreds of correlated per-second samples treated as independent experiments. Three cycles still provide only exploratory evidence; uncontrolled background activity can confound the result.

Lower watts **cannot pass** if energy per completed background work gets worse. A synthetic latency regression also fails the pilot. Even a promising result is named `promising_synthetic_pilot`: it does not establish real coding/editing/video performance, 90% retained performance, system-wide LPM equivalence or a 30–40% battery-life increase.

`./scripts/check-scheduling.sh` tests integration gaps and clock changes, invalid readings, slowdown disguised as power saving, performance regressions, incomplete/aborted trials and high variation. It also checks the real fixture's self-policy changes and clean EOF restoration. These tests do not run a multi-minute workload or change any existing process.
