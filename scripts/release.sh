#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

dry_run=false
if [[ "${1:-}" == --dry-run ]]; then dry_run=true; shift; fi
version="${1:-}"
[[ -n "$version" ]] || die "usage: release.sh [--dry-run] <version>"
"$host_dir/scripts/package-release.sh" "$version"
"$host_dir/scripts/sign-release.sh" "$dist_dir/host-manifest.json"
"$host_dir/scripts/verify-release.sh" "$dist_dir/host-manifest.json"
if "$dry_run"; then
  printf 'Release dry run passed. CI may now sign the manifest and publish Axiom-owned assets.\n'
  exit 0
fi
need gh
# Public routing metadata is intentionally fixed in source. It is not a
# credential and therefore does not belong in Infisical or release commands.
github_repository="AxiomCore/axiom-ui-host"
gh release create "v$version" "$dist_dir"/* --repo "$github_repository" --title "Axiom UI Host $version" --generate-notes
printf 'Published Axiom-owned UI Host release v%s.\n' "$version"
