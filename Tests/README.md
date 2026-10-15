Run all regression checks from the project directory:

```sh
./scripts/check.sh
```

The four executable suites cover:

- Telemetry: unsigned signed-current decoding, delayed charging samples after unplugging, missing/invalid telemetry, temperature units and SMC payload decoding.
- Preferences: persistence across store instances, safe defaults for corrupt data, and threshold bounds. Tests use a disposable UserDefaults suite.
- Sessions: time-weighted energy, charging transitions, invalid readings, measurement coverage, sleep gaps, and restart boundaries.
- History: minute aggregation, sample-weighted downsampling, chart gaps, retention, archive validation, atomic write ordering, and corrupt JSON handling. Tests use temporary files.

Tests do not change charging state or write SMC keys. Validate physical plug/unplug and sleep/wake behavior with the app running. Model-dependent SMC access must also be checked in the signed, sandboxed app. Command-line access may be restricted.
