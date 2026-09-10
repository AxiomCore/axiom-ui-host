#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

kind="${1:-}"
[[ "$kind" == simulator || "$kind" == device ]] || die "usage: build-ios.sh <simulator|device>"
need rsync; need cargo; need xcodebuild; need xcrun; need pod; need python3; need xcodegen
if [[ "$kind" == simulator ]] && ! has_ios_simulator_runtime; then
  die "no iOS Simulator runtime is available; run 'just ios-runtime' to install the runtime selected by Xcode"
fi
engine="$(verify_engine_source)"
clean_stage
stage_root="$stage_dir/ios-$kind"
# The upstream Podfile follows paths back to the engine root. Keep the entire
# pinned checkout, generated Podspecs, and renderer dependency graph in an
# opaque cache. Recreating it on every run would repeat a large source sync;
# the commit marker invalidates the cache whenever the engine lock changes.
engine_stage="$stage_root/engine"
engine_marker="$stage_root/.engine-commit"
locked_engine_commit="$(engine_commit)"
if [[ ! -f "$engine_marker" ]] && [[ -d "$engine_stage/.git" ]] && \
  [[ "$(git -C "$engine_stage" rev-parse HEAD 2>/dev/null || true)" == "$locked_engine_commit" ]]; then
  # Adopt a cache staged by an earlier version of this script only when its
  # checked-out engine commit proves it is the currently locked source.
  printf '%s\n' "$locked_engine_commit" > "$engine_marker"
fi
if [[ ! -f "$engine_marker" ]] || [[ "$(<"$engine_marker")" != "$locked_engine_commit" ]]; then
  rm -rf "$stage_root"
fi
if [[ ! -d "$engine_stage" ]]; then
  mkdir -p "$engine_stage"
  rsync -a --delete "$engine/" "$engine_stage/"
  printf '%s\n' "$locked_engine_commit" > "$engine_marker"
fi
host_stage="$stage_root/AxiomUIHost"
rsync -a --delete "$host_dir/ios/AxiomUIHost/" "$host_stage/"
if [[ ! -f "$engine_stage/Lynx.podspec" ]]; then
  # The pinned checkout intentionally excludes generated podspecs and the
  # renderer's source dependencies. GN resolves the complete native renderer
  # graph, so synchronize that graph into the opaque cache copy before asking
  # it to produce podspecs. Remove upstream Explorer and Android-wrapper-only
  # downloads first: Axiom ships neither and the product host never uses them.
  # Habitat executes a few pinned source generators during synchronization.
  # Give those generators the same private PyYAML environment used later for
  # podspec generation instead of relying on the developer's system Python.
  python_env="$cache_base/python"
  if [[ ! -x "$python_env/bin/python" ]]; then
    python3 -m venv "$python_env"
    "$python_env/bin/python" -m pip install --disable-pip-version-check --quiet PyYAML
  fi
  export PATH="$python_env/bin:$PATH"
  python3 - "$engine_stage/dependencies/DEPS" <<'PY'
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
excluded = (
    "platform/android/gradle/wrapper/gradle-6.7.1-all.zip",
    "explorer/android/gradle/wrapper/gradle-6.7.1-all.zip",
    "explorer/darwin/ios/lynx_explorer/xctestrunner",
    # This is a Java lint tool, unrelated to building the iOS renderer. Its
    # historic upstream release URL currently serves a non-zip response.
    "buildtools/pmd",
)
for name in excluded:
    pattern = re.compile(
        rf"^    ['\"]{re.escape(name)}['\"]:\s*\{{.*?^    \}},\n",
        re.MULTILINE | re.DOTALL,
    )
    text, count = pattern.subn("", text, count=1)
    if count != 1:
        raise SystemExit(f"could not remove excluded upstream dependency: {name}")
open(path, "w", encoding="utf-8").write(text)
PY
  # Force HTTP/1.1 only for the synchronizer process. This avoids a known
  # intermittent HTTP/2 cancellation from large GitHub repository fetches;
  # it does not modify the developer's global Git configuration.
  synced=false
  for attempt in 1 2 3; do
    if GIT_EDITOR=true GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1 \
      GIT_CONFIG_KEY_1=tag.gpgSign GIT_CONFIG_VALUE_1=false \
      "$engine_stage/tools/hab" sync "$engine_stage" --force --no-history --disable-cache; then
      synced=true
      break
    fi
    [[ "$attempt" == 3 ]] || printf 'axiom-ui-host: native renderer dependency sync failed; retrying (%s/3)\n' "$attempt" >&2
  done
  [[ "$synced" == true ]] || die "native renderer dependency sync failed after three attempts; retry just ios-simulator"

  # Habitat may replace this dependency directory while synchronizing. Pin it
  # explicitly below before invoking its podspec helper.
  tools_commit="$(python3 - "$engine_stage/dependencies/DEPS.tools_shared" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r"tools-shared\.git.*?['\"]commit['\"]\s*:\s*['\"]([0-9a-f]{40})", text, re.S)
if not match: raise SystemExit('cannot resolve pinned tools_shared revision')
print(match.group(1))
PY
)"
  if [[ ! -d "$engine_stage/tools_shared/.git" ]]; then
    git clone --quiet https://github.com/lynx-family/tools-shared.git "$engine_stage/tools_shared"
  fi
  # An interrupted clone may have a valid .git directory but not the pinned
  # object. Fetch that exact immutable commit before every checkout.
  git -C "$engine_stage/tools_shared" fetch --quiet --depth=1 origin "$tools_commit"
  git -C "$engine_stage/tools_shared" checkout --quiet --detach "$tools_commit"
  # GN's project configuration is supplied by Lynx's separately pinned
  # buildroot repository. It is a build dependency, not an Axiom product-host
  # dependency, and is staged only beside the immutable engine checkout.
  read -r build_url build_commit < <(python3 - "$engine_stage/dependencies/DEPS" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
entry = re.search(r"['\"]build['\"]\s*:\s*\{(.*?)\n\s*\},", text, re.S)
if not entry:
    raise SystemExit('cannot resolve pinned buildroot declaration')
url = re.search(r"['\"]url['\"]\s*:\s*['\"]([^'\"]+)", entry.group(1))
commit = re.search(r"['\"]commit['\"]\s*:\s*['\"]([0-9a-f]{40})", entry.group(1))
if not url or not commit:
    raise SystemExit('cannot resolve pinned buildroot URL and revision')
print(url.group(1), commit.group(1))
PY
)
  if [[ ! -d "$engine_stage/build/.git" ]]; then
    git init --quiet "$engine_stage/build"
    git -C "$engine_stage/build" remote add origin "$build_url"
  fi
  build_cache_root="$HOME/.habitat_cache/git/buildroot.git"
  build_cache=""
  if [[ -d "$build_cache_root" ]]; then
    for candidate in "$build_cache_root"/*; do
      if [[ -d "$candidate" ]] && git -C "$candidate" cat-file -e "$build_commit^{commit}" 2>/dev/null; then
        build_cache="$candidate"
        break
      fi
    done
  fi
  if [[ -n "$build_cache" ]]; then
    git -C "$engine_stage/build" fetch --quiet --depth=1 "$build_cache" "$build_commit"
  else
    git -C "$engine_stage/build" fetch --quiet --depth=1 origin "$build_commit"
  fi
  git -C "$engine_stage/build" checkout --quiet --detach "$build_commit"
  if [[ ! -x "$engine_stage/buildtools/gn/gn" ]]; then
    mkdir -p "$engine_stage/buildtools/gn"
    # Habitat may already have fetched this immutable archive during an
    # earlier attempt. Reuse it when present so a transient GitHub/CDN failure
    # does not restart or hang the bootstrap. An explicit archive path is
    # useful for hermetic CI; the fallback still downloads the pinned URL.
    gn_archive="${AXIOM_UI_HOST_GN_ARCHIVE:-$HOME/.habitat_cache/objects/github.com/lynx-family/buildtools/releases/download/gn-cc28efe6/buildtools-gn-darwin-arm64.tar.gz}"
    if [[ ! -f "$gn_archive" ]]; then
      gn_archive="$cache_base/downloads/buildtools-gn-darwin-arm64.tar.gz"
      mkdir -p "$(dirname "$gn_archive")"
      curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 --silent --show-error \
        -o "$gn_archive" \
        "https://github.com/lynx-family/buildtools/releases/download/gn-cc28efe6/buildtools-gn-darwin-arm64.tar.gz"
    fi
    tar -xzf "$gn_archive" -C "$engine_stage/buildtools/gn"
    [[ -x "$engine_stage/buildtools/gn/gn" ]] || die "GN bootstrap archive did not contain an executable gn binary: $gn_archive"
  fi
  # Upstream's podspec generator accepts --root for its output paths but the
  # GN wrapper itself discovers .gn from its inherited working directory.
  # Run it from the staged engine root; never from the host repository.
  pushd "$engine_stage" >/dev/null
  "$python_env/bin/python" tools/ios_tools/generate_podspec_scripts_by_gn.py \
    --root "$engine_stage" --enable-autosync-version
  popd >/dev/null
fi
for required_podspec in Lynx.podspec LynxService.podspec; do
  if [[ ! -f "$engine_stage/$required_podspec" ]]; then
    die "upstream source bootstrap completed without $required_podspec; inspect $engine_stage for the generator failure"
  fi
done

runtime_dir="$repo_dir/axiom-runtime"
[[ -f "$runtime_dir/Cargo.toml" ]] || die "Axiom runtime not found at $runtime_dir"
if [[ "$kind" == simulator ]]; then
  sdk="iphonesimulator"
  case "$(uname -m)" in
    arm64) rust_target="aarch64-apple-ios-sim"; xcode_arch="arm64" ;;
    x86_64) rust_target="x86_64-apple-ios"; xcode_arch="x86_64" ;;
    *) die "unsupported simulator build architecture: $(uname -m)" ;;
  esac
else
  rust_target="aarch64-apple-ios"; xcode_arch="arm64"; sdk="iphoneos"
fi
# Keep Rust/C dependencies' deployment metadata compatible with the iOS host
# target instead of inheriting the selected SDK's current version. Its target
# directory is owned by the opaque host cache, so artifacts created with a
# different SDK or deployment target can never be silently reused.
runtime_target_dir="$cache_base/rust/$kind-$xcode_arch-ios15"
CARGO_TARGET_DIR="$runtime_target_dir" IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  cargo build --quiet --manifest-path "$runtime_dir/Cargo.toml" --target "$rust_target" --release
runtime_lib="$runtime_target_dir/$rust_target/release/libaxiom_runtime.a"
[[ -f "$runtime_lib" ]] || die "runtime build did not produce $runtime_lib"

bridge_dir="$host_stage/AxiomRuntime"
mkdir -p "$bridge_dir"
cp "$host_dir/ios/bridge/AxiomRuntimeModule.h" "$host_dir/ios/bridge/AxiomRuntimeModule.m" "$host_dir/ios/bridge/host-registration.m" "$bridge_dir/"
cp "$runtime_dir/include/axiom.h" "$bridge_dir/axiom.h"
cp "$runtime_lib" "$bridge_dir/libaxiom_runtime.a"
xcodegen generate --spec "$host_stage/project.yml" --project "$host_stage"
pushd "$host_stage" >/dev/null
pod install
popd >/dev/null
scheme="AxiomUIHost"
derived="$output_dir/ios-$kind-derived"
rm -rf "$derived"
destination_args=()
if [[ "$kind" == simulator ]]; then
  # A generic simulator destination is sufficient to compile/archive the host;
  # it does not require a particular device to have been created in Simulator.
  destination_args=(-destination 'generic/platform=iOS Simulator')
fi
# The FFI archive is built for this host architecture. Explicitly align
# Xcode's app target with it instead of asking it to also link an unavailable
# simulator slice (for example x86_64 on Apple Silicon).
build_log="$output_dir/ios-$kind-xcodebuild.log"
if ! xcodebuild -quiet -workspace "$host_stage/AxiomUIHost.xcworkspace" -scheme "$scheme" -configuration Release -sdk "$sdk" "${destination_args[@]}" -derivedDataPath "$derived" ARCHS="$xcode_arch" build >"$build_log" 2>&1; then
  printf '%s\n' "axiom-ui-host: native host build failed; the final diagnostics follow (full log: $build_log)" >&2
  tail -n 120 "$build_log" >&2
  exit 1
fi
app_path="$(find "$derived/Build/Products" -type d -name '*.app' -print -quit)"
[[ -n "$app_path" ]] || die "xcodebuild did not produce an app"
archive="$output_dir/axiom-ui-host-ios-$kind.app.zip"
rm -f "$archive"
(cd "$(dirname "$app_path")" && ditto -c -k --sequesterRsrc --keepParent "$(basename "$app_path")" "$archive")
printf '%s\n' "axiom-ui-host: built iOS $kind host (full Xcode log: $build_log)"
printf '%s\n' "$archive"
