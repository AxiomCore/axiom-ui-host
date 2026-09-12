#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need python3
for script in "$host_dir"/scripts/*.sh; do bash -n "$script"; done
python3 - "$lock_file" "$host_dir/toolchain/lynx-ui.lock.json" "$host_dir/host-manifest.template.json" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
components = json.load(open(sys.argv[2]))
manifest = json.load(open(sys.argv[3]))
assert lock['format'] == 'axiom-ui-host-engine-lock/v1'
assert components['format'] == 'axiom-lynx-ui-pin/v1'
assert components['package'] == '@lynx-js/lynx-ui'
assert components['version'] == '3.138.0'
assert components['sourceCommit'] == 'b9b3fd7a34d7cde6ef4dddfb2fb95de4f5457d73'
assert components['npmIntegrity'] == 'sha512-7j1au6sOIHY+lHnM1iR5UcevSPxOzwGM7mbB1H8s3cZeTgWcrnbPgCoPToetjc2vJ6jymk/+hlduXcOlrDHL/A=='
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
for required in "$host_dir/web/index.html" "$host_dir/web/host.css" "$host_dir/web/host.js" "$host_dir/scripts/build-web.sh"; do
  [[ -f "$required" ]] || die "missing required web host file: $required"
done
if find "$host_dir" -type d \( -name node_modules -o -path '*/research/lynx/*' \) -print -quit | grep -q .; then
  die "host project must not vendor engine source or node_modules"
fi
printf 'axiom-ui-host checks passed: pinned source, bridge overlays, scripts, and release schema are valid.\n'
