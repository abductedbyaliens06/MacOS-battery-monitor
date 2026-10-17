Run all regression checks from the project directory:

```sh
./scripts/check.sh
```

The seven executable suites cover:

- Telemetry: unsigned signed-current decoding, delayed charging samples after unplugging, missing/invalid telemetry, temperature units and SMC payload decoding.
- Preferences: persistence across store instances, safe defaults for corrupt data, and threshold bounds. Tests use a disposable UserDefaults suite.
- Sessions: time-weighted energy, charging transitions, invalid readings, measurement coverage, sleep gaps, and restart boundaries.
- History: minute aggregation, sample-weighted downsampling, chart gaps, retention, archive validation, atomic write ordering, and corrupt JSON handling. Tests use temporary files.

- Status rendering: eager bitmap images, recursive appearance callbacks, 10,000 redundant presentations, theme and display-scale changes. The executable uses a prohibited activation policy and a 20-second timeout, with no visible test windows.
- Usage study: counter integration, missing power, context/gap/clock boundaries, PID reuse, Python/app grouping, explicit importance, incremental SQLite writes, restart, seven-day retention, clear, streaming export and corrupt-store preservation. All files are temporary.

- Data locations: reuse of container history and SQLite/WAL files, migration of known preferences, preservation of opt-outs and newer settings, and fresh-install paths. Fixtures use temporary directories and defaults.

Tests do not change charging state or write SMC keys. Validate physical plug/unplug and sleep/wake behavior with the app running. Model-dependent SMC access must also be checked in the signed app. Command-line access may be restricted.

Render the study UI with synthetic data in light and dark mode:

```sh
./scripts/check-study-ui.sh
```

This uses temporary storage, disables collection, applies a prohibited activation policy, and opens no windows. Images are written to `/tmp/battery-study-ui-preview/`. The compiler step has a three-minute timeout; the rendering process is limited to twenty seconds. Live cross-app discovery must be checked in the signed app; unit tests alone do not prove OS counter availability.

Run the standalone collector integration check with temporary, low-duty Python workers:

```sh
./scripts/check-study-live.sh
```

It verifies current-user discovery, advancing CPU counters, and grouping of an owned Python parent and two workers. Workers exit after twenty seconds; the test process is bounded to thirty seconds and changes no existing processes or priorities.
