#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

version="${1:-}"
[[ -n "$version" ]] || die "usage: package-release.sh <version>"
need python3
clean_stage

# Package only artifacts created by a host build. The app workspace is never
# inspected, and renderer source never becomes a release input by accident.
artifacts=()
while IFS= read -r artifact; do artifacts+=("$artifact"); done < <(find "$output_dir" -maxdepth 1 -type f \( -name 'axiom-ui-host-ios-*.zip' -o -name 'axiom-ui-host-android-*.apk' \) -print | sort)
(( ${#artifacts[@]} > 0 )) || die "no host build artifacts in $output_dir; run a platform build first"
rm -rf "$dist_dir"
mkdir -p "$dist_dir"
for artifact in "${artifacts[@]}"; do cp "$artifact" "$dist_dir/"; done

assets_file="$dist_dir/assets.tsv"
: > "$assets_file"
for artifact in "$dist_dir"/*; do
  [[ -f "$artifact" && "$(basename "$artifact")" != assets.tsv ]] || continue
  name="$(basename "$artifact")"
  case "$name" in
    axiom-ui-host-ios-*) target=ios ;;
    axiom-ui-host-android-*) target=android ;;
    *) die "unsupported host artifact name: $name" ;;
  esac
  variant="${name#axiom-ui-host-$target-}"
  variant="${variant%.app.zip}"
  variant="${variant%.apk}"
  printf '%s\t%s\t%s\t%s\n' "$target" "$variant" "$name" "$(sha256 "$artifact")" >> "$assets_file"
done

python3 - "$lock_file" "$assets_file" "$dist_dir/host-manifest.json" "$version" "$(runtime_revision)" <<'PY'
import datetime, json, pathlib, sys
lock, assets, output, version, revision = sys.argv[1:]
engine = json.load(open(lock))['engine']
records = []
for line in pathlib.Path(assets).read_text().splitlines():
    target, variant, file, digest = line.split('\t')
    records.append({'target': target, 'variant': variant, 'file': file, 'sha256': digest})
manifest = {
    'format': 'axiom-ui-host-release/v1', 'version': version,
    'generatedAt': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
    'engine': engine, 'runtime': {'revision': revision}, 'assets': records,
}
pathlib.Path(output).write_text(json.dumps(manifest, indent=2) + '\n')
PY
rm -f "$assets_file"
"$host_dir/scripts/generate-provenance.sh" "$dist_dir"
printf 'Packaged Axiom UI Host %s at %s\n' "$version" "$dist_dir"
