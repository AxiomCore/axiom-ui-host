#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

variant="${1:-}"
[[ "$variant" == debug || "$variant" == release ]] || die "usage: build-android.sh <debug|release>"

# The old fixture copied and patched the upstream Explorer app. That would
# make Axiom's shipped host dependent on an app it does not own, so this entry
# point deliberately stops until ios/AxiomUIHost's equivalent Android product
# host and typed JNI bridge exist. It must never fall back to Explorer.
die "Android product host is not implemented yet; this command intentionally will not derive an Axiom host from upstream Explorer"
