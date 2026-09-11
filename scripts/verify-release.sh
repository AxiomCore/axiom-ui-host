#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

manifest="${1:-}"
[[ -f "$manifest" ]] || die "usage: verify-release.sh <host-manifest.json>"
need python3
python3 - "$manifest" <<'PY'
import json, pathlib, re, sys
path = pathlib.Path(sys.argv[1]).resolve()
data = json.loads(path.read_text())
assert data.get('format') == 'axiom-ui-host-release/v1', 'wrong manifest format'
assert data.get('version'), 'missing version'
assert re.fullmatch(r'[0-9a-f]{40}', data['engine']['commit']), 'invalid engine commit'
seen = set()
for asset in data.get('assets', []):
    target, variant, name, digest = asset.get('target'), asset.get('variant'), asset.get('file'), asset.get('sha256')
    assert target in ('ios', 'android', 'web'), 'unknown target'
    assert re.fullmatch(r'[a-z0-9][a-z0-9-]*', variant or ''), 'invalid variant'
    assert (target, variant) not in seen, 'duplicate target/variant'; seen.add((target, variant))
    assert name and '/' not in name and '\\' not in name, 'unsafe asset name'
    assert re.fullmatch(r'[0-9a-f]{64}', digest or ''), 'invalid SHA-256'
    file = path.parent / name
    assert file.is_file(), f'missing asset: {file}'
    import hashlib
    actual = hashlib.sha256(file.read_bytes()).hexdigest()
    assert actual == digest, f'checksum mismatch: {name}'
assert seen, 'no assets'
PY
if [[ -n "${AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX:-}" ]]; then
  [[ -f "$manifest.sig" ]] || die "signed verification requested but $manifest.sig is missing"
  cargo run --quiet --manifest-path "$repo_dir/axiom-keygen/Cargo.toml" -- verify \
    "$AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX" "$manifest" "$manifest.sig"
fi
printf 'Verified host release manifest and artifact checksums: %s\n' "$manifest"
