#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

output="${1:-$dist_dir}"
mkdir -p "$output"
need python3
phase2_profile="$repo_dir/axiom-ui/registry/generated/release-provenance.json"
phase2_generator="$repo_dir/research/axiom-lynx-integration/phase-2-profile/generate-phase-2l-artifacts.py"
[[ -f "$phase2_profile" ]] || die "Phase 2 release provenance is missing: $phase2_profile"
python3 "$phase2_generator" --check
python3 - "$lock_file" "$output/host.sbom.json" "$(runtime_revision)" "$repo_dir/axiom-ui-host/toolchain/lynx-ui.lock.json" <<'PY'
import datetime, json, pathlib, sys
lock, output, runtime, component_lock = sys.argv[1:]
data = json.load(open(lock))
component = json.load(open(component_lock))
document = {
  'bomFormat': 'CycloneDX', 'specVersion': '1.5', 'version': 1,
  'metadata': {'timestamp': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
               'component': {'type': 'application', 'name': 'axiom-ui-host'}},
  'components': [
    {'type': 'application', 'name': 'axiom-ui-host', 'version': runtime},
    {'type': 'library', 'name': data['engine']['name'], 'version': data['engine']['commit'],
     'externalReferences': [{'type': 'vcs', 'url': data['engine']['source'] + '@' + data['engine']['commit']}]},
    {'type': 'library', 'name': component['package'], 'version': component['version'],
     'properties': [
       {'name': 'axiom:sourceCommit', 'value': component['sourceCommit']},
       {'name': 'axiom:npmIntegrity', 'value': component['npmIntegrity']},
     ]},
  ],
}
pathlib.Path(output).write_text(json.dumps(document, indent=2) + '\n')
PY
cp "$phase2_profile" "$output/frontend-profile.json"
cp "$host_dir/licenses/UPSTREAM-NOTICES.md" "$output/UPSTREAM-NOTICES.md"
