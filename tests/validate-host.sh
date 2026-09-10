#!/usr/bin/env bash
set -euo pipefail

host_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$host_dir/.." && pwd)"
scratch="$(mktemp -d)"

"$host_dir/scripts/check.sh"
grep -q 'scan-and-mount' "$host_dir/scripts/lib.sh"
grep -q 'scan_and_mount_ios_simulator_runtimes' "$host_dir/scripts/install-ios-simulator-runtime.sh"
grep -q 'scan_and_mount_ios_simulator_runtimes' "$host_dir/scripts/repair-ios-simulator-runtime.sh"
grep -q '^ios-runtime-repair:' "$host_dir/justfile"
grep -q '^release-initial version:' "$host_dir/justfile"
grep -q '^release-update version:' "$host_dir/justfile"
grep -q 'release-build-root' "$host_dir/scripts/publish-release.sh"
grep -q 'configured external release build cache' "$host_dir/scripts/publish-release.sh"
grep -q 'release-build-image' "$host_dir/scripts/publish-release.sh"
grep -q 'zero-filled .so files' "$host_dir/scripts/publish-release.sh"
grep -q 'Sparse bundles are directories' "$host_dir/scripts/publish-release.sh"
grep -q 'let DiskImages create the mount point' "$host_dir/scripts/publish-release.sh"
grep -q 'GitHub Release.*already exists' "$host_dir/scripts/publish-release.sh"
grep -q 'origin/main does not match HEAD' "$host_dir/scripts/publish-release.sh"
grep -q 'status --porcelain' "$host_dir/scripts/publish-release.sh"
grep -q 'AXIOM_UI_HOST_RELEASE_SECRETS_LOADED' "$host_dir/scripts/publish-release.sh"
grep -q '@interface AxiomAppDelegate' "$host_dir/ios/AxiomUIHost/AxiomAppDelegate.h"
grep -q 'AxiomRuntimeModule' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'axiom.app.revision.json' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'axiom.app.ack.json' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'axiom-ui-host-revision/v2' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'axiom-ui-host-ack/v2' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'state_preserving_patch' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'applied_state_reset' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'rejected_last_good' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'safeAreaTop' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'updateGlobalPropsWithDictionary' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'updateViewportWithPreferredLayoutWidth' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'triggerLayout' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
grep -q 'AxiomUIHostProtocolVersion' "$host_dir/ios/AxiomUIHost/Info.plist"
grep -q '<key>AxiomUIHostProtocolVersion</key><integer>2</integer>' "$host_dir/ios/AxiomUIHost/Info.plist"
grep -q 'AxiomRuntimeFacadeProtocolVersion' "$host_dir/ios/AxiomUIHost/Info.plist"
grep -q 'AxiomRuntimeModuleVersion' "$host_dir/ios/AxiomUIHost/Info.plist"
grep -q 'AxiomRuntimeABIVersion' "$host_dir/ios/AxiomUIHost/Info.plist"
grep -q 'axiom_load_contract_locked' "$host_dir/ios/bridge/AxiomRuntimeModule.m"
grep -q '@"runtimeInfo"' "$host_dir/ios/bridge/AxiomRuntimeModule.m"
grep -q '@"dispatch"' "$host_dir/ios/bridge/AxiomRuntimeModule.m"
grep -q '@"close"' "$host_dir/ios/bridge/AxiomRuntimeModule.m"
grep -q 'AXIOM_UI_OPERATION_DENIED' "$host_dir/ios/bridge/AxiomRuntimeModule.m"
grep -q 'AXIOM_UI_RUNTIME_RESTART_REQUIRED' "$host_dir/ios/bridge/AxiomRuntimeModule.m"
grep -q 'protocolVersion' "$host_dir/ios/bridge/AxiomRuntimeModule.m"
grep -q 'UIApplicationMain' "$host_dir/ios/AxiomUIHost/main.m"
grep -q '\-laxiom_runtime' "$host_dir/ios/AxiomUIHost/project.yml"
grep -q 'IPHONEOS_DEPLOYMENT_TARGET=15.0' "$host_dir/scripts/build-ios.sh"
grep -q 'cargo build --quiet --manifest-path' "$host_dir/scripts/build-ios.sh"
grep -q 'runtime_target_dir="$cache_base/rust/$kind-$xcode_arch-ios15"' "$host_dir/scripts/build-ios.sh"
registration_files="$(rg -l '^void AxiomInstallRuntimeModule' "$host_dir/ios/bridge" --glob '*.m' | wc -l | tr -d '[:space:]')"
if [ "$registration_files" != "1" ]; then
  echo 'axiom-ui-host: runtime module registration must have exactly one implementation' >&2
  exit 1
fi
grep -q 'ARCHS="$xcode_arch"' "$host_dir/scripts/build-ios.sh"
grep -q 'xcodebuild -quiet' "$host_dir/scripts/build-ios.sh"
grep -q 'native host build failed' "$host_dir/scripts/build-ios.sh"
grep -q "pod 'Lynx', :path => '../engine'" "$host_dir/ios/AxiomUIHost/Podfile"
grep -q "pod 'LynxBase', :path => '../engine'" "$host_dir/ios/AxiomUIHost/Podfile"
grep -q "pod 'LynxServiceAPI', :path => '../engine'" "$host_dir/ios/AxiomUIHost/Podfile"
if rg -l -i 'lynxexplorer|explorer/' "$host_dir/ios/AxiomUIHost" --glob '*.{h,m,yml}' --glob 'Podfile' >/dev/null; then
  echo 'axiom-ui-host: iOS product host must not include Explorer sources' >&2
  exit 1
fi
grep -q '^android-emulator:' "$host_dir/justfile"
grep -q 'Android host build troubleshooting' "$host_dir/README.md"
grep -q 'More than one file was found' "$host_dir/docs/android-build-troubleshooting.md"
grep -q 'Given final block not properly padded' "$host_dir/docs/android-build-troubleshooting.md"
grep -q 'release-update' "$host_dir/docs/android-build-troubleshooting.md"
grep -q 'release-build-root' "$host_dir/docs/android-build-troubleshooting.md"
grep -q 'liblynxbase.so: unknown file type' "$host_dir/docs/android-build-troubleshooting.md"
grep -q 'build-android.sh" release' "$host_dir/scripts/publish-release.sh"
grep -q 'AXIOM_UI_HOST_ANDROID_KEYSTORE_BASE64' "$host_dir/scripts/build-android.sh"
grep -q 'keytool.*-certreq' "$host_dir/scripts/build-android.sh"
grep -q 'Keystore type: PKCS12' "$host_dir/scripts/build-android.sh"
grep -q 'effective_android_key_password' "$host_dir/scripts/build-android.sh"
grep -q 'keypass="$storepass"' "$host_dir/scripts/provision-release-secrets.sh"
grep -q 'cargo-ndk' "$host_dir/scripts/build-android.sh"
grep -q 'src/main/nativeDeps' "$host_dir/scripts/build-android.sh"
if grep -q 'cargo ndk.*src/main/jniLibs' "$host_dir/scripts/build-android.sh"; then
  echo 'axiom-ui-host: CMake-imported Rust libraries must not also be staged in jniLibs' >&2
  exit 1
fi
grep -q 'required_cmake_version="3.18.1"' "$host_dir/scripts/build-android.sh"
grep -q 'axiom-ui-host-android-emulator.apk' "$host_dir/scripts/build-android.sh"
grep -q "project(':AxiomUIHost')" "$host_dir/android/AxiomUIHost/settings.gradle.fragment"
grep -q 'version CMAKE_VERSION' "$host_dir/android/AxiomUIHost/build.gradle"
grep -q "implementation 'androidx.annotation:annotation:1.0.0'" "$host_dir/android/AxiomUIHost/build.gradle"
grep -q '^cmake_minimum_required(VERSION 3\.18\.1)$' "$host_dir/android/bridge/CMakeLists.txt"
grep -Fq '../nativeDeps/${ANDROID_ABI}/libaxiom_runtime.so' "$host_dir/android/bridge/CMakeLists.txt"
grep -q 'dev.axiomcore.uihost' "$host_dir/android/AxiomUIHost/src/main/AndroidManifest.xml"
grep -q 'android:name="com.axiom.uihost.AxiomHostApplication"' "$host_dir/android/AxiomUIHost/src/main/AndroidManifest.xml"
grep -q 'android:name="com.axiom.uihost.AxiomHostActivity"' "$host_dir/android/AxiomUIHost/src/main/AndroidManifest.xml"
grep -q '^package com\.axiom\.uihost;' "$host_dir/android/AxiomUIHost/src/main/java/com/axiom/uihost/AxiomHostApplication.java"
grep -q '^package com\.axiom\.uihost;' "$host_dir/android/AxiomUIHost/src/main/java/com/axiom/uihost/AxiomHostActivity.java"
grep -q 'AxiomUIHostProtocolVersion' "$host_dir/android/AxiomUIHost/src/main/AndroidManifest.xml"
grep -q 'axiom.app.revision.json' "$host_dir/android/AxiomUIHost/src/main/java/com/axiom/uihost/AxiomHostActivity.java"
grep -q 'axiom-ui-host-revision/v2' "$host_dir/android/AxiomUIHost/src/main/java/com/axiom/uihost/AxiomHostActivity.java"
grep -q 'axiom-ui-host-ack/v2' "$host_dir/android/AxiomUIHost/src/main/java/com/axiom/uihost/AxiomHostActivity.java"
grep -q 'applied_state_reset' "$host_dir/android/AxiomUIHost/src/main/java/com/axiom/uihost/AxiomHostActivity.java"
grep -q 'System.loadLibrary("axiom_runtime_jni")' "$host_dir/android/bridge/AxiomRuntimeModule.java"
grep -q 'mContext.getFilesDir()' "$host_dir/android/bridge/AxiomRuntimeModule.java"
grep -q 'axiom_clear_callback' "$host_dir/android/bridge/AxiomRuntimeJni.cpp"
if rg -l -i 'com\.lynx\.explorer|ExplorerApplication|LynxExplorer' "$host_dir/android/AxiomUIHost" "$host_dir/android/bridge" --glob '*.{java,cpp,gradle}' >/dev/null; then
  echo 'axiom-ui-host: Android product host must not include Explorer sources' >&2
  exit 1
fi

mkdir -p "$scratch/build/output"
touch "$scratch/build/output/axiom-ui-host-ios-simulator.app.zip"
touch "$scratch/build/output/axiom-ui-host-android-emulator.apk"
AXIOM_UI_HOST_BUILD_ROOT="$scratch/build" AXIOM_UI_HOST_DIST_ROOT="$scratch/dist" "$host_dir/scripts/package-release.sh" 0.0.0-validation
keys="$(cargo run --quiet --manifest-path "$repo_dir/axiom-keygen/Cargo.toml" -- generate)"
private="$(printf '%s\n' "$keys" | sed -n 's/^AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX=//p')"
public="$(printf '%s\n' "$keys" | sed -n 's/^AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX=//p')"
AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX="$private" "$host_dir/scripts/sign-release.sh" "$scratch/dist/host-manifest.json"
AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX="$public" AXIOM_UI_HOST_DIST_ROOT="$scratch/dist" "$host_dir/scripts/verify-release.sh" "$scratch/dist/host-manifest.json"

AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX="$public" XDG_CACHE_HOME="$scratch/cache" cargo run --quiet --manifest-path "$repo_dir/AxiomCore/cli/Cargo.toml" -- \
  ui host install --target ios --variant simulator --non-interactive --release-manifest "$scratch/dist/host-manifest.json" >/dev/null
status="$(XDG_CACHE_HOME="$scratch/cache" cargo run --quiet --manifest-path "$repo_dir/AxiomCore/cli/Cargo.toml" -- \
  ui host status --target ios)"
[[ "$status" == *'UI Host for ios is set up'* ]]
AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX="$public" XDG_CACHE_HOME="$scratch/cache" cargo run --quiet --manifest-path "$repo_dir/AxiomCore/cli/Cargo.toml" -- \
  ui host install --target android --variant emulator --non-interactive --release-manifest "$scratch/dist/host-manifest.json" >/dev/null
status="$(XDG_CACHE_HOME="$scratch/cache" cargo run --quiet --manifest-path "$repo_dir/AxiomCore/cli/Cargo.toml" -- \
  ui host status --target android)"
[[ "$status" == *'Installed release: 0.0.0-validation (emulator)'* ]]

printf 'axiom-ui-host validation passed: the Axiom-owned host and its release manifest install through the CLI cache.\n'
