#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

need python3
need wasm-pack
runtime_dir="$repo_dir/axiom-runtime"
[[ -f "$runtime_dir/Cargo.toml" ]] || die "Axiom Runtime source is missing at $runtime_dir"
web_stage="$cache_base/web/browser"
wasm_stage="$cache_base/web/wasm"
web_target_dir="$cache_base/rust/web-wasm32"
web_build_log="$output_dir/web-wasm-build.log"
rm -rf "$web_stage" "$wasm_stage"
mkdir -p "$web_stage" "$wasm_stage" "$web_target_dir" "$output_dir"

printf '%s\n' 'axiom-ui-host: compiling the embedded browser runtime WASM.'
# Rust panic locations can otherwise retain the maintainer's checkout and
# Cargo-cache paths inside the release binary. Keep the artifact relocatable
# and reproducible without leaking build-machine absolute paths.
runtime_rustflags="${RUSTFLAGS:-} --remap-path-prefix=$repo_dir=axiom-source --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=cargo-registry"
run_wasm_build() {
  local jobs="$1"
  set +e
  CARGO_TARGET_DIR="$web_target_dir" \
    CARGO_BUILD_JOBS="$jobs" \
    RUSTFLAGS="$runtime_rustflags" \
    wasm-pack build "$runtime_dir" --target no-modules --out-dir "$wasm_stage" --release --locked \
    2>&1 | tee "$web_build_log"
  local status="${PIPESTATUS[0]}"
  set -e
  return "$status"
}

# Keep web host/proc-macro artifacts out of axiom-runtime/target and away from
# the target directories used by the native host builds. Apple Clang can also
# occasionally terminate while linking a host-side proc macro. Retry only that
# toolchain failure, using one job and a fresh, platform-scoped cache; ordinary
# Rust/WASM compilation errors must fail immediately with their original log.
if ! run_wasm_build "${AXIOM_UI_HOST_WEB_CARGO_JOBS:-2}"; then
  if grep -Eq 'unable to execute command: (Segmentation fault|Bus error)|linker command failed due to signal' "$web_build_log"; then
    printf '%s\n' 'axiom-ui-host: Apple linker crashed while compiling a WASM build dependency; retrying once with a fresh single-job cache.' >&2
    rm -rf "$web_target_dir"
    mkdir -p "$web_target_dir"
    run_wasm_build 1 || die "browser runtime WASM compilation failed after the Apple linker retry (full log: $web_build_log)"
  else
    die "browser runtime WASM compilation failed (full log: $web_build_log)"
  fi
fi
cp "$host_dir/web/index.html" "$host_dir/web/host.css" "$host_dir/web/host.js" "$web_stage/"
cp "$wasm_stage/axiom_runtime.js" "$wasm_stage/axiom_runtime_bg.wasm" "$web_stage/"
# These are raw C ABI exports on the WebAssembly instance returned by
# wasm-bindgen initialization. Newer wasm-bindgen releases intentionally do
# not repeat their names in the generated JavaScript glue, so inspect the WASM
# artifact that actually owns the exports.
for runtime_export in \
  axiom_wasm_initialize \
  axiom_wasm_load_contract \
  axiom_wasm_call \
  axiom_wasm_cancel \
  axiom_wasm_reset_session; do
  LC_ALL=C grep -a -q "$runtime_export" "$web_stage/axiom_runtime_bg.wasm" || \
    die "browser runtime is missing required WASM export: $runtime_export"
done
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
