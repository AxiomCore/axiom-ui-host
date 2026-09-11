#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need python3
need wasm-pack
runtime_dir="$repo_dir/axiom-runtime"
[[ -f "$runtime_dir/Cargo.toml" ]] || die "Axiom Runtime source is missing at $runtime_dir"
web_stage="$cache_base/web/browser"
wasm_stage="$cache_base/web/wasm"
rm -rf "$web_stage" "$wasm_stage"
mkdir -p "$web_stage" "$wasm_stage" "$output_dir"

printf '%s\n' 'axiom-ui-host: compiling the embedded browser runtime WASM.'
# Rust panic locations can otherwise retain the maintainer's checkout and
# Cargo-cache paths inside the release binary. Keep the artifact relocatable
# and reproducible without leaking build-machine absolute paths.
runtime_rustflags="${RUSTFLAGS:-} --remap-path-prefix=$repo_dir=axiom-source --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=cargo-registry"
RUSTFLAGS="$runtime_rustflags" wasm-pack build "$runtime_dir" --target no-modules --out-dir "$wasm_stage" --release
cp "$host_dir/web/index.html" "$host_dir/web/host.css" "$host_dir/web/host.js" "$web_stage/"
cp "$wasm_stage/axiom_runtime.js" "$wasm_stage/axiom_runtime_bg.wasm" "$web_stage/"
# no-modules emits a global lexical binding. Publish it deliberately for the
# host module, matching the proven axiom-sdk browser integration.
printf '\nwindow.wasm_bindgen = wasm_bindgen;\n' >> "$web_stage/axiom_runtime.js"
python3 - "$web_stage" "$output_dir/axiom-ui-host-web-browser.zip" <<'PY'
import pathlib, sys, zipfile
root, output = map(pathlib.Path, sys.argv[1:])
with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.iterdir()):
        info = zipfile.ZipInfo(path.name, (1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        archive.writestr(info, path.read_bytes())
PY
printf 'Built web UI Host: %s\n' "$output_dir/axiom-ui-host-web-browser.zip"
