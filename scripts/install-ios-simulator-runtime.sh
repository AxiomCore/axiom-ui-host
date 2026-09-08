#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need xcodebuild
need xcrun

if has_ios_simulator_runtime; then
  printf '%s\n' "axiom-ui-host: an iOS Simulator runtime is already available."
  exit 0
fi

printf '%s\n' "axiom-ui-host: checking for a previously downloaded, unmounted iOS Simulator runtime."
if scan_and_mount_ios_simulator_runtimes && has_ios_simulator_runtime; then
  printf '%s\n' "axiom-ui-host: recovered and mounted the available iOS Simulator runtime."
  exit 0
fi

cat >&2 <<'EOF'
axiom-ui-host: no iOS Simulator runtime is installed for the selected Xcode.
Downloading the matching runtime through Xcode. This may take several GB.
EOF
download_failed=false
if ! xcodebuild -downloadPlatform iOS; then
  download_failed=true
fi

if has_ios_simulator_runtime; then
  printf '%s\n' "axiom-ui-host: iOS Simulator runtime is ready."
  exit 0
fi

# A failed Xcode registration is recoverable when the image itself downloaded.
if scan_and_mount_ios_simulator_runtimes && has_ios_simulator_runtime; then
  printf '%s\n' "axiom-ui-host: Xcode downloaded the runtime but did not register it; the host mounted it successfully."
  exit 0
fi

if [[ "$download_failed" == true ]]; then
  die "Xcode could not register an iOS Simulator runtime. Run 'just ios-runtime-repair'; if no runtime appears, restart Xcode/macOS and install it in Xcode > Settings > Components. Do not delete CoreSimulator files manually."
fi

die "Xcode completed without an available iOS Simulator runtime; run 'just ios-runtime-repair', then install it in Xcode > Settings > Components if it is still unavailable"
