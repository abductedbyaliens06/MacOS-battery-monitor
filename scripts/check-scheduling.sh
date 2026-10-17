#!/bin/zsh
set -eu
cd "${0:A:h:h}"
check_dir="$(mktemp -d /tmp/battery-scheduling-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
# These binaries change only their own policy or use a mocked policy backend.
# No privileged helper is built, installed or started by this check.
clang -Wall -Wextra -Werror OptimizerHelper/SchedulingLease.c Tests/SchedulingLeaseFaults.c -o "$check_dir/faults"
"$check_dir/faults"
clang -Wall -Wextra -Werror OptimizerHelper/SchedulingLease.c Tests/SchedulingLeaseNative.c -o "$check_dir/native"
"$check_dir/native"
clang -fobjc-arc -Wall -Wextra -Werror -fsyntax-only OptimizerHelper/main.m
swiftc -module-cache-path /tmp/battery-swift-cache \
  'battery stuff/UsageStudyModels.swift' 'battery stuff/LiveProcessPreview.swift' \
  'battery stuff/OptimizerPolicy.swift' 'battery stuff/SchedulingControlPolicy.swift' \
  Tests/SchedulingControlPolicyTests.swift -o "$check_dir/selection"
"$check_dir/selection"
python3 Tests/SchedulingBoundaryAudit.py
