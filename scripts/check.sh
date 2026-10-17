#!/bin/zsh
set -eu
cd "${0:A:h:h}"
check_dir="$(mktemp -d /tmp/battery-monitor-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/PowerTelemetry.swift' 'battery stuff/SMCPowerReader.swift' Tests/PowerTelemetryTests.swift -o "$check_dir/telemetry"
"$check_dir/telemetry"
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/BatteryPreferences.swift' Tests/BatteryPreferencesTests.swift -o "$check_dir/preferences"
"$check_dir/preferences"
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/BatterySessions.swift' Tests/BatterySessionsTests.swift -o "$check_dir/sessions"
"$check_dir/sessions"
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/BatterySessions.swift' 'battery stuff/BatteryHistory.swift' Tests/BatteryHistoryTests.swift -o "$check_dir/history"
"$check_dir/history"
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/BatterySnapshot.swift' 'battery stuff/BatteryPreferences.swift' \
  'battery stuff/PowerMenuBarLabel.swift' 'battery stuff/BatteryStatusButtonRenderer.swift' \
  Tests/BatteryStatusRenderingTests.swift -o "$check_dir/status-rendering"
python3 - "$check_dir/status-rendering" <<'PY'
import subprocess, sys
subprocess.run([sys.argv[1]], check=True, timeout=20)
PY
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/UsageStudyModels.swift' 'battery stuff/UsageStudyStore.swift' \
  Tests/UsageStudyTests.swift -o "$check_dir/usage-study"
"$check_dir/usage-study"
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/BatteryDataLocations.swift' Tests/BatteryDataLocationsTests.swift -o "$check_dir/data-locations"
"$check_dir/data-locations"
