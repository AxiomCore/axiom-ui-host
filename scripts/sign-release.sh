#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
manifest="${1:-$dist_dir/host-manifest.json}"
[[ -f "$manifest" ]] || die "manifest is missing: $manifest"
[[ -n "${AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX:-}" ]] || die "AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX is required"
signature="$manifest.sig"
cargo run --quiet --manifest-path "$repo_dir/axiom-keygen/Cargo.toml" -- sign "$AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX" "$manifest" > "$signature"
printf 'Signed %s\n' "$manifest"
