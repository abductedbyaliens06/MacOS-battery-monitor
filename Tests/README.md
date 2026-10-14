Run the telemetry regression checks from the project directory:

```sh
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/PowerTelemetry.swift' \
  'battery stuff/SMCPowerReader.swift' \
  Tests/PowerTelemetryTests.swift \
  -o /tmp/battery-telemetry-tests
/tmp/battery-telemetry-tests
```

Checks cover unsigned signed-current decoding, delayed charging samples after unplugging,
missing and invalid telemetry, and integer/float SMC payload formats.

Live hardware validation requires running the app: the command-line tool sandbox blocks
SMC access. The app retains its sandbox with an IOKit client exception for the read-only
SMC reader. Health data falls back to AppleSmartBattery; unsupported live sensors use
slower registry power data, labeled in the popover footer.
