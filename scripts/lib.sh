#!/usr/bin/env bash
set -euo pipefail

host_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_dir="$(cd "$host_dir/.." && pwd)"
lock_file="$host_dir/toolchain/engine-source.lock.json"

cache_base="${AXIOM_UI_HOST_BUILD_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/axiom-ui-host}"
stage_dir="$cache_base/stage"
output_dir="$cache_base/output"
dist_dir="${AXIOM_UI_HOST_DIST_ROOT:-$host_dir/dist}"

die() { printf 'axiom-ui-host: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

engine_commit() { python3 - "$lock_file" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['engine']['commit'])
PY
}

engine_source() {
  if [[ -n "${AXIOM_UI_HOST_ENGINE_SOURCE:-}" ]]; then printf '%s\n' "$AXIOM_UI_HOST_ENGINE_SOURCE"; return; fi
  printf '%s\n' "$repo_dir/research/lynx"
}

verify_engine_source() {
  local source expected actual
  source="$(engine_source)"
  [[ -d "$source/.git" ]] || die "engine source not found at $source; set AXIOM_UI_HOST_ENGINE_SOURCE"
  expected="$(engine_commit)"
  actual="$(git -C "$source" rev-parse HEAD)"
  [[ "$actual" == "$expected" ]] || die "engine revision $actual does not match locked revision $expected"
  printf '%s\n' "$source"
}

runtime_revision() {
  git -C "$repo_dir" rev-parse HEAD 2>/dev/null || \
    git -C "$repo_dir/axiom-runtime" rev-parse HEAD 2>/dev/null || \
    printf 'workspace-uncommitted\n'
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else sha256sum "$1" | awk '{print $1}'; fi
}

clean_stage() {
  mkdir -p "$stage_dir" "$output_dir" "$dist_dir"
}

has_ios_simulator_runtime() {
  xcrun simctl list runtimes --json 2>/dev/null | python3 -c '
import json, sys
try:
    runtimes = json.load(sys.stdin).get("runtimes", [])
except (json.JSONDecodeError, BrokenPipeError):
    raise SystemExit(1)
raise SystemExit(0 if any(runtime.get("identifier", "").startswith(
    "com.apple.CoreSimulator.SimRuntime.iOS-"
) and runtime.get("isAvailable", True) for runtime in runtimes) else 1)
'
}

# Xcode downloads simulator images into managed storage first. A download can
# finish while CoreSimulator has not mounted the image yet. This only discovers
# and mounts those images; it never removes simulator data.
scan_and_mount_ios_simulator_runtimes() {
  xcrun simctl runtime scan-and-mount
}
