#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

output="${1:-$dist_dir}"
mkdir -p "$output"
need python3
python3 - "$lock_file" "$output/host.sbom.json" "$(runtime_revision)" <<'PY'
import datetime, json, pathlib, sys
lock, output, runtime = sys.argv[1:]
data = json.load(open(lock))
document = {
  'bomFormat': 'CycloneDX', 'specVersion': '1.5', 'version': 1,
  'metadata': {'timestamp': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
               'component': {'type': 'application', 'name': 'axiom-ui-host'}},
  'components': [
    {'type': 'application', 'name': 'axiom-ui-host', 'version': runtime},
    {'type': 'library', 'name': data['engine']['name'], 'version': data['engine']['commit'],
     'externalReferences': [{'type': 'vcs', 'url': data['engine']['source'] + '@' + data['engine']['commit']}]},
  ],
}
pathlib.Path(output).write_text(json.dumps(document, indent=2) + '\n')
PY
cp "$host_dir/licenses/UPSTREAM-NOTICES.md" "$output/UPSTREAM-NOTICES.md"
