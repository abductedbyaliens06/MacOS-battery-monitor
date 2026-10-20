#!/bin/zsh
set -eu
cd "${0:A:h:h}"
benchmark_dir="$(mktemp -d /tmp/battery-scheduling-pilot.XXXXXX)"
trap 'rm -rf "$benchmark_dir"' EXIT
# No administrator helper is compiled or used. The fixture alters only itself.
clang -O2 -Wall -Wextra -Werror OptimizerHelper/SchedulingLease.c \
  Tools/SchedulingBenchmark/Fixture.c -o "$benchmark_dir/fixture"
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/PowerTelemetry.swift' 'battery stuff/SMCPowerReader.swift' \
  Tools/SchedulingBenchmark/Telemetry.swift -o "$benchmark_dir/telemetry"
python3 Tools/SchedulingBenchmark/run.py "$benchmark_dir/fixture" "$benchmark_dir/telemetry" "$@"
