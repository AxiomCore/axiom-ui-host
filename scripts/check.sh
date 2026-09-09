#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need python3
for script in "$host_dir"/scripts/*.sh; do bash -n "$script"; done
python3 - "$lock_file" "$host_dir/host-manifest.template.json" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
manifest = json.load(open(sys.argv[2]))
assert lock['format'] == 'axiom-ui-host-engine-lock/v1'
assert manifest['format'] == 'axiom-ui-host-release/v1'
assert lock['engine']['commit'] == manifest['engine']['commit']
PY
for required in \
  "$host_dir/ios/bridge/AxiomRuntimeModule.h" \
  "$host_dir/ios/bridge/AxiomRuntimeModule.m" \
  "$host_dir/ios/bridge/host-registration.m" \
  "$host_dir/android/bridge/AxiomRuntimeModule.java" \
  "$host_dir/android/bridge/AxiomRuntimeJni.cpp" \
  "$host_dir/android/bridge/CMakeLists.txt" \
  "$host_dir/android/AxiomUIHost/build.gradle" \
  "$host_dir/android/AxiomUIHost/src/main/AndroidManifest.xml"; do
  [[ -f "$required" ]] || die "missing required bridge file: $required"
done
if find "$host_dir" -type d \( -name node_modules -o -path '*/research/lynx/*' \) -print -quit | grep -q .; then
  die "host project must not vendor engine source or node_modules"
fi
printf 'axiom-ui-host checks passed: pinned source, bridge overlays, scripts, and release schema are valid.\n'
