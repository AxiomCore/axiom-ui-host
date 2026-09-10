#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

kind="${1:-}"
[[ "$kind" == debug || "$kind" == release ]] || die "usage: build-android.sh <debug|release>"
need rsync; need cargo; need cargo-ndk; need rustup; need python3; need base64
# The pinned Lynx Gradle project declares this exact side-by-side NDK version.
# Keep it isolated from a developer's default NDK: other Android projects may
# legitimately use a newer version.
required_ndk_version="21.1.6352462"
required_cmake_version="3.18.1"
# cargo-ndk intentionally dropped support for pre-r23 NDKs, whereas the
# pinned renderer Gradle project still requires r21. Preserve the developer's
# modern NDK for Rust compilation; Gradle receives r21 below.
cargo_ndk_home="${AXIOM_UI_HOST_CARGO_NDK_HOME:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
# The pinned Android build uses Gradle 6.7.1, which cannot parse Java 25 class
# files. Keep this compatibility choice scoped to the host build rather than
# changing a developer's global Java selection for unrelated projects.
host_java_home="${AXIOM_UI_HOST_JAVA_HOME:-${JAVA_HOME:-}}"
if [[ -z "$host_java_home" ]]; then
  for candidate in \
    /opt/homebrew/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home \
    /usr/local/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home; do
    if [[ -x "$candidate/bin/java" ]]; then
      host_java_home="$candidate"
      break
    fi
  done
fi
if [[ ! -x "$host_java_home/bin/java" ]]; then
  die "Android host build requires JDK 11. Install it with 'brew install openjdk@11', then set AXIOM_UI_HOST_JAVA_HOME to '<brew-prefix>/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home'"
fi
java_version="$($host_java_home/bin/java -version 2>&1 | sed -n '1p')"
java_major="$(printf '%s\n' "$java_version" | sed -nE 's/.*"([0-9]+)\..*/\1/p')"
if [[ "$java_major" != "11" ]]; then
  die "Android host build requires JDK 11 for pinned Gradle 6.7.1; AXIOM_UI_HOST_JAVA_HOME selects $java_version"
fi
export JAVA_HOME="$host_java_home"
export PATH="$JAVA_HOME/bin:$PATH"

# Decode and inspect the release key before any renderer or Rust work. Java's
# PKCS12 keytool silently ignores a distinct -keypass in some operations, so
# PKCS12 stores must use their store password as Gradle's key password.
keystore=""
effective_android_key_password=""
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

  if ! keystore_info="$(LC_ALL=C "$JAVA_HOME/bin/keytool" -list -keystore "$keystore" \
    -storepass "$AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD" 2>&1)"; then
    die "Android release keystore cannot be opened: verify its base64 value and store password in Infisical"
  fi
  if ! "$JAVA_HOME/bin/keytool" -list -keystore "$keystore" \
    -storepass "$AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD" \
    -alias "$AXIOM_UI_HOST_ANDROID_KEY_ALIAS" >/dev/null 2>&1; then
    die "Android release key alias was not found in the keystore; verify AXIOM_UI_HOST_ANDROID_KEY_ALIAS in Infisical"
  fi

  if printf '%s\n' "$keystore_info" | grep -Fq 'Keystore type: PKCS12'; then
    effective_android_key_password="$AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD"
    if [[ "$AXIOM_UI_HOST_ANDROID_KEY_PASSWORD" != "$AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD" ]]; then
      printf '%s\n' "axiom-ui-host: PKCS12 uses the store password for its private key; update AXIOM_UI_HOST_ANDROID_KEY_PASSWORD in Infisical to match AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD. Continuing with the correct password." >&2
    fi
  else
    effective_android_key_password="$AXIOM_UI_HOST_ANDROID_KEY_PASSWORD"
    if ! "$JAVA_HOME/bin/keytool" -certreq -keystore "$keystore" \
      -storepass "$AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD" \
      -alias "$AXIOM_UI_HOST_ANDROID_KEY_ALIAS" \
      -keypass "$effective_android_key_password" -file /dev/null >/dev/null 2>&1; then
      die "Android release private key cannot be decrypted; verify AXIOM_UI_HOST_ANDROID_KEY_PASSWORD in Infisical"
    fi
  fi
fi

android_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -n "$android_home" ]] || die "ANDROID_HOME is required; point it at the Android SDK"
required_cmake="$android_home/cmake/$required_cmake_version/bin/cmake"
if [[ ! -x "$required_cmake" ]]; then
  die "Android host build requires the renderer-pinned CMake $required_cmake_version. Install it with '$android_home/cmdline-tools/latest/bin/sdkmanager --install \"cmake;$required_cmake_version\"' (or Android Studio SDK Manager), then retry"
fi
required_ndk_home="$android_home/ndk/$required_ndk_version"
host_ndk_home="${AXIOM_UI_HOST_NDK_HOME:-$required_ndk_home}"
if [[ "$host_ndk_home" != "$required_ndk_home" ]]; then
  die "AXIOM_UI_HOST_NDK_HOME must be the SDK-managed renderer NDK at $required_ndk_home; Gradle cannot use an NDK outside this Android SDK"
fi
if [[ ! -d "$host_ndk_home" ]]; then
  die "Android host build requires the renderer-pinned Android NDK $required_ndk_version. Install it with '$android_home/cmdline-tools/latest/bin/sdkmanager --install \"ndk;$required_ndk_version\"' (or Android Studio SDK Manager), then retry"
fi
if [[ ! -d "$cargo_ndk_home" ]]; then
  die "cargo-ndk needs a modern Android NDK (r23 or later) for the Rust runtime. Keep ANDROID_NDK_HOME pointed at a modern SDK NDK, such as $android_home/ndk/26.3.11579264, or set AXIOM_UI_HOST_CARGO_NDK_HOME"
fi
# The old AGP used by the renderer discovers its NDK under ANDROID_HOME, while
# cargo-ndk consumes ANDROID_NDK_HOME. Export both views of the same pinned
# SDK installation before either tool is run.
export ANDROID_HOME="$android_home"
export ANDROID_SDK_ROOT="$android_home"
export ANDROID_NDK_HOME="$host_ndk_home"
export ANDROID_NDK_ROOT="$host_ndk_home"
for rust_target in aarch64-linux-android x86_64-linux-android; do
  if ! rustup target list --installed | grep -Fxq "$rust_target"; then
    die "Rust target $rust_target is not installed; run 'rustup target add aarch64-linux-android x86_64-linux-android' and retry"
  fi
done
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
tools_shared_gn_args="$engine_stage/tools_shared/android_tools/write_gn_args.py"
tools_shared_cmake_generator="$engine_stage/tools_shared/android_tools/generate_cmake_scripts_from_gn.py"
# A cancelled Habitat sync can leave the tools_shared directory and its Git
# metadata behind while omitting its files. Check the scripts Gradle executes,
# not merely the directory, before reusing that opaque cache.
if [[ ! -f "$tools_shared_gn_args" && -d "$ios_engine/.git" && \
    "$(git -C "$ios_engine" rev-parse HEAD 2>/dev/null || true)" == "$locked_engine_commit" ]]; then
  rsync -a --delete "$ios_engine/" "$engine_stage/"
  printf '%s\n' "axiom-ui-host: repaired incomplete Android renderer tools from the verified iOS engine cache."
fi
if [[ ! -x "$engine_stage/explorer/android/gradlew" ]]; then
  die "pinned engine checkout lacks its Android Gradle wrapper; provision the locked renderer source before building"
fi
# Lynx's wrapper intentionally points at a pinned local Gradle archive. An
# earlier interrupted Android stage can contain tools_shared while omitting
# that archive, so copy it from the verified iOS stage when possible and force
# Habitat to restore it otherwise.
gradle_wrapper_archive="$engine_stage/explorer/android/gradle/wrapper/gradle-6.7.1-all.zip"
ios_gradle_wrapper_archive="$ios_engine/explorer/android/gradle/wrapper/gradle-6.7.1-all.zip"
if [[ ! -f "$gradle_wrapper_archive" && -f "$ios_gradle_wrapper_archive" ]]; then
  mkdir -p "$(dirname "$gradle_wrapper_archive")"
  cp "$ios_gradle_wrapper_archive" "$gradle_wrapper_archive"
fi
# Habitat keeps completed HTTP objects in this content-addressed cache. Reuse
# the exact archive it already fetched for the pinned engine instead of making
# a new full dependency sync solely because an interrupted stage omitted the
# stage-local copy.
habitat_cache_root="${HABITAT_CACHE_ROOT:-$HOME/.habitat_cache}"
cached_gradle_wrapper_archive="$habitat_cache_root/objects/services.gradle.org/distributions/gradle-6.7.1-all.zip"
if [[ ! -f "$gradle_wrapper_archive" && -f "$cached_gradle_wrapper_archive" ]]; then
  mkdir -p "$(dirname "$gradle_wrapper_archive")"
  cp "$cached_gradle_wrapper_archive" "$gradle_wrapper_archive"
  printf '%s\n' "axiom-ui-host: restored the pinned Android Gradle archive from the existing Habitat cache."
fi
if [[ ! -f "$tools_shared_gn_args" || ! -f "$tools_shared_cmake_generator" || ! -f "$gradle_wrapper_archive" ]]; then
  # Resolve upstream's pinned *build* dependencies in the opaque engine copy.
  # PMD is a Java lint download, not an Android renderer input; its historic
  # upstream URL currently returns a non-zip response, so omit it before sync.
  printf '%s\n' "axiom-ui-host: syncing pinned Android renderer dependencies in the opaque cache. A first or repaired cache can take several minutes before Habitat prints further progress."
  python3 - "$engine_stage/dependencies/DEPS" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
entry = re.search(r"(?m)^\s*['\"]buildtools/pmd['\"]\s*:\s*\{", text)
if entry:
    # Remove one complete top-level dependency object. The upstream DEPS file
    # has changed formatting over time, so counting matching braces is safer
    # than relying on a fixed indentation or closing-comma layout.
    start = text.rfind('\n', 0, entry.start()) + 1
    brace = text.find('{', entry.start())
    depth = 0
    end = None
    for index in range(brace, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                end = index + 1
                break
    if end is None:
        raise SystemExit('could not find the end of optional buildtools/pmd dependency')
    while end < len(text) and text[end] in ' \t,\r\n':
        end += 1
    text = text[:start] + text[end:]
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
[[ -f "$gradle_wrapper_archive" ]] || die "pinned Android Gradle archive is missing after dependency sync; retry just android-emulator"
[[ -f "$tools_shared_gn_args" && -f "$tools_shared_cmake_generator" ]] || \
  die "Android renderer tools are incomplete after dependency sync; retry just android-emulator"

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

abis=(arm64-v8a x86_64)
rust_dir="$cache_base/rust/android-emulator"
# Cargo owns invalidation for its target directory. Preserve it across Gradle
# retries; only the staged APK inputs must be refreshed for every build.
# The Rust runtime is linked into the JNI bridge as a static archive. Keeping
# one Android shared object avoids relying on AGP to discover and package a
# transitive IMPORTED shared library (AGP 4.1 omitted it from released APKs).
rm -rf "$host_stage/src/main/jniLibs" "$host_stage/src/main/nativeDeps"
mkdir -p "$rust_dir" "$host_stage/src/main/nativeDeps"
# cargo-ndk obtains workspace metadata before it forwards arguments to Cargo.
# Invoking it from the host repository therefore fails even when a later
# `--manifest-path` names the real runtime crate. Build from that crate so the
# toolchain never depends on a Cargo.toml being present in axiom-ui-host.
pushd "$runtime_dir" >/dev/null
for abi in "${abis[@]}"; do
  case "$abi" in
    arm64-v8a) rust_target="aarch64-linux-android" ;;
    x86_64) rust_target="x86_64-linux-android" ;;
    *) die "unsupported Android runtime ABI: $abi" ;;
  esac
  # cargo-ndk rejects the renderer's r21 NDK. Limit the newer NDK to this
  # child process; the Gradle environment below remains pinned to r21.
  ANDROID_NDK_HOME="$cargo_ndk_home" ANDROID_NDK_ROOT="$cargo_ndk_home" \
    CARGO_TARGET_DIR="$rust_dir" cargo ndk -t "$abi" build --release
  runtime_archive="$rust_dir/$rust_target/release/libaxiom_runtime.a"
  [[ -f "$runtime_archive" ]] || die "Axiom runtime static archive was not produced for $abi"
  mkdir -p "$host_stage/src/main/nativeDeps/$abi"
  cp "$runtime_archive" "$host_stage/src/main/nativeDeps/$abi/libaxiom_runtime.a"
done
popd >/dev/null
cp "$runtime_dir/include/axiom.h" "$host_stage/src/main/cpp/axiom.h"

task="assemble$(tr '[:lower:]' '[:upper:]' <<< "${kind:0:1}")${kind:1}"
gradle_args=(":AxiomUIHost:$task" "-PabiList=$(IFS=,; echo "${abis[*]}")")
if [[ "$kind" == release ]]; then
  gradle_args+=("-PAXIOM_UI_HOST_ANDROID_KEYSTORE_FILE=$keystore"
    "-PAXIOM_UI_HOST_ANDROID_KEY_ALIAS=$AXIOM_UI_HOST_ANDROID_KEY_ALIAS"
    "-PAXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD=$AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD"
    "-PAXIOM_UI_HOST_ANDROID_KEY_PASSWORD=$effective_android_key_password")
fi

pushd "$engine_stage/explorer/android" >/dev/null
if ! ./gradlew --no-daemon "${gradle_args[@]}"; then
  die "Android host build failed. The staged project is $host_stage; no application workspace files were generated. Confirm Android SDK/NDK compatibility and retry."
fi
popd >/dev/null

llvm_readelf="$(find "$host_ndk_home/toolchains/llvm/prebuilt" -path '*/bin/llvm-readelf' -type f -print -quit)"
[[ -x "$llvm_readelf" ]] || die "renderer NDK does not provide llvm-readelf for Android runtime verification"
for abi in "${abis[@]}"; do
  built_bridge="$host_stage/build/intermediates/cmake/$kind/obj/$abi/libaxiom_runtime_jni.so"
  [[ -f "$built_bridge" ]] || die "Android build did not produce the Axiom runtime bridge for $abi"
  dynamic_section="$("$llvm_readelf" -d "$built_bridge")"
  if grep -Fq 'Shared library: [libaxiom_runtime.so]' <<< "$dynamic_section"; then
    die "Android $abi bridge still loads libaxiom_runtime.so dynamically; the Rust runtime must be embedded into libaxiom_runtime_jni.so"
  fi
done

apk="$host_stage/build/outputs/apk/$kind/axiom_ui_host-$kind.apk"
[[ -f "$apk" ]] || apk="$(find "$host_stage/build/outputs/apk/$kind" -name '*.apk' -type f -print -quit)"
[[ -n "$apk" && -f "$apk" ]] || die "Gradle reported success but produced no Android host APK"
python3 - "$apk" "${abis[@]}" <<'PY'
import sys, zipfile

apk, *abis = sys.argv[1:]
with zipfile.ZipFile(apk) as archive:
    names = set(archive.namelist())
missing = [f"lib/{abi}/libaxiom_runtime_jni.so" for abi in abis
           if f"lib/{abi}/libaxiom_runtime_jni.so" not in names]
if missing:
    raise SystemExit("Android APK is missing embedded Axiom runtime bridge: " + ", ".join(missing))
separate_runtime = sorted(name for name in names if name.endswith("/libaxiom_runtime.so"))
if separate_runtime:
    raise SystemExit("Android APK unexpectedly depends on a separately packaged Axiom runtime: " + ", ".join(separate_runtime))
PY
archive="$output_dir/axiom-ui-host-android-emulator.apk"
cp "$apk" "$archive"
printf '%s\n' "axiom-ui-host: built Android emulator development host"
printf '%s\n' "$archive"
