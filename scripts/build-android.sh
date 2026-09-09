#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

kind="${1:-}"
[[ "$kind" == debug || "$kind" == release ]] || die "usage: build-android.sh <debug|release>"
need rsync; need cargo; need cargo-ndk; need python3; need java; need base64
engine="$(verify_engine_source)"
clean_stage

# The Android project is staged beside the immutable renderer checkout. It is
# never emitted into an Acore application's workspace and is never derived
# from upstream Explorer application source.
stage_root="$stage_dir/android-emulator"
engine_stage="$stage_root/engine"
engine_marker="$stage_root/.engine-commit"
locked_engine_commit="$(engine_commit)"
if [[ ! -f "$engine_marker" ]] || [[ "$(<"$engine_marker")" != "$locked_engine_commit" ]]; then
  rm -rf "$stage_root"
fi
if [[ ! -d "$engine_stage" ]]; then
  mkdir -p "$engine_stage"
  rsync -a --delete "$engine/" "$engine_stage/"
  printf '%s\n' "$locked_engine_commit" > "$engine_marker"
fi

# A successful iOS bootstrap contains this same pinned commit and its generated
# renderer dependencies. Reuse it only when the commit proves it is safe.
ios_engine="$stage_dir/ios-simulator/engine"
if [[ ! -d "$engine_stage/tools_shared" && -d "$ios_engine/.git" && \
    "$(git -C "$ios_engine" rev-parse HEAD 2>/dev/null || true)" == "$locked_engine_commit" ]]; then
  rsync -a --delete "$ios_engine/" "$engine_stage/"
fi
if [[ ! -x "$engine_stage/explorer/android/gradlew" ]]; then
  die "pinned engine checkout lacks its Android Gradle wrapper; provision the locked renderer source before building"
fi
if [[ ! -d "$engine_stage/tools_shared" ]]; then
  # Resolve upstream's pinned *build* dependencies in the opaque engine copy.
  # PMD is a Java lint download, not an Android renderer input; its historic
  # upstream URL currently returns a non-zip response, so omit it before sync.
  python3 - "$engine_stage/dependencies/DEPS" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
pattern = re.compile(r"^    ['\"]buildtools/pmd['\"]:\s*\{.*?^    \},\n", re.MULTILINE | re.DOTALL)
text, count = pattern.subn('', text, count=1)
if count != 1:
    raise SystemExit('could not remove unrelated buildtools/pmd dependency')
open(path, 'w', encoding='utf-8').write(text)
PY
  synced=false
  for attempt in 1 2 3; do
    if GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1 \
      "$engine_stage/tools/hab" sync "$engine_stage" --force --no-history --disable-cache; then
      synced=true; break
    fi
    [[ "$attempt" == 3 ]] || printf 'axiom-ui-host: Android renderer dependency sync failed; retrying (%s/3)\n' "$attempt" >&2
  done
  [[ "$synced" == true ]] || die "Android renderer dependency sync failed after three attempts; retry just android-emulator"
fi

host_stage="$engine_stage/explorer/android/axiom_ui_host"
rm -rf "$host_stage"
mkdir -p "$host_stage"
rsync -a --delete "$host_dir/android/AxiomUIHost/" "$host_stage/"
mkdir -p "$host_stage/src/main/java/com/axiom/uihost" "$host_stage/src/main/cpp"
cp "$host_dir/android/bridge/AxiomRuntimeModule.java" "$host_stage/src/main/java/com/axiom/uihost/"
cp "$host_dir/android/bridge/AxiomRuntimeJni.cpp" "$host_stage/src/main/cpp/"
cp "$host_dir/android/bridge/CMakeLists.txt" "$host_stage/src/main/cpp/"

# The generated settings file belongs to the opaque copy. The fragment is
# idempotent and contains no upstream app project reference.
settings="$engine_stage/explorer/android/settings.gradle"
if ! grep -q "project(':AxiomUIHost')" "$settings"; then
  printf '\n' >> "$settings"
  cat "$host_dir/android/AxiomUIHost/settings.gradle.fragment" >> "$settings"
fi

runtime_dir="$repo_dir/axiom-runtime"
[[ -f "$runtime_dir/Cargo.toml" && -f "$runtime_dir/include/axiom.h" ]] || die "Axiom runtime sources are missing beside the host repository"
[[ -n "${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}" ]] || die "ANDROID_NDK_HOME is required; install the Android NDK selected by your Android SDK"
[[ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]] || die "ANDROID_HOME is required; point it at the Android SDK"

abis=(arm64-v8a x86_64)
rust_dir="$cache_base/rust/android-emulator"
rm -rf "$rust_dir" "$host_stage/src/main/jniLibs"
mkdir -p "$rust_dir" "$host_stage/src/main/jniLibs"
for abi in "${abis[@]}"; do
  CARGO_TARGET_DIR="$rust_dir" cargo ndk -t "$abi" -o "$host_stage/src/main/jniLibs" \
    build --manifest-path "$runtime_dir/Cargo.toml" --release
done
cp "$runtime_dir/include/axiom.h" "$host_stage/src/main/cpp/axiom.h"

task="assemble$(tr '[:lower:]' '[:upper:]' <<< "${kind:0:1}")${kind:1}"
gradle_args=(":AxiomUIHost:$task" "-PabiList=$(IFS=,; echo "${abis[*]}")")
if [[ "$kind" == release ]]; then
  for secret in AXIOM_UI_HOST_ANDROID_KEYSTORE_BASE64 AXIOM_UI_HOST_ANDROID_KEY_ALIAS AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD AXIOM_UI_HOST_ANDROID_KEY_PASSWORD; do
    [[ -n "${!secret:-}" ]] || die "$secret is required for a signed Android release host"
  done
  signing_dir="$cache_base/signing"
  mkdir -p "$signing_dir"
  keystore="$signing_dir/axiom-ui-host-release.keystore"
  printf '%s' "$AXIOM_UI_HOST_ANDROID_KEYSTORE_BASE64" | base64 --decode > "$keystore" 2>/dev/null || \
    printf '%s' "$AXIOM_UI_HOST_ANDROID_KEYSTORE_BASE64" | base64 -D > "$keystore"
  chmod 600 "$keystore"
  gradle_args+=("-PAXIOM_UI_HOST_ANDROID_KEYSTORE_FILE=$keystore"
    "-PAXIOM_UI_HOST_ANDROID_KEY_ALIAS=$AXIOM_UI_HOST_ANDROID_KEY_ALIAS"
    "-PAXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD=$AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD"
    "-PAXIOM_UI_HOST_ANDROID_KEY_PASSWORD=$AXIOM_UI_HOST_ANDROID_KEY_PASSWORD")
fi

pushd "$engine_stage/explorer/android" >/dev/null
if ! ./gradlew --no-daemon "${gradle_args[@]}"; then
  die "Android host build failed. The staged project is $host_stage; no application workspace files were generated. Confirm Android SDK/NDK compatibility and retry."
fi
popd >/dev/null

apk="$host_stage/build/outputs/apk/$kind/axiom_ui_host-$kind.apk"
[[ -f "$apk" ]] || apk="$(find "$host_stage/build/outputs/apk/$kind" -name '*.apk' -type f -print -quit)"
[[ -n "$apk" && -f "$apk" ]] || die "Gradle reported success but produced no Android host APK"
archive="$output_dir/axiom-ui-host-android-emulator.apk"
cp "$apk" "$archive"
printf '%s\n' "axiom-ui-host: built Android emulator development host"
printf '%s\n' "$archive"
