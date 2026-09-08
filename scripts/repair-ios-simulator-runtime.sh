#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need xcrun

if has_ios_simulator_runtime; then
  printf '%s\n' "axiom-ui-host: an iOS Simulator runtime is already available; no repair is needed."
  exit 0
fi

printf '%s\n' "axiom-ui-host: scanning managed CoreSimulator storage for downloaded but unmounted runtimes."
scan_and_mount_ios_simulator_runtimes

if has_ios_simulator_runtime; then
  printf '%s\n' "axiom-ui-host: recovered and mounted the iOS Simulator runtime."
  exit 0
fi

die "no downloaded iOS Simulator runtime could be mounted; install one with 'just ios-runtime' or Xcode > Settings > Components"
