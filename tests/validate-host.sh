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
grep -q 'GitHub Release.*already exists' "$host_dir/scripts/publish-release.sh"
grep -q 'origin/main does not match HEAD' "$host_dir/scripts/publish-release.sh"
grep -q 'status --porcelain' "$host_dir/scripts/publish-release.sh"
grep -q 'AXIOM_UI_HOST_RELEASE_SECRETS_LOADED' "$host_dir/scripts/publish-release.sh"
grep -q '@interface AxiomAppDelegate' "$host_dir/ios/AxiomUIHost/AxiomAppDelegate.h"
grep -q 'AxiomRuntimeModule' "$host_dir/ios/AxiomUIHost/AxiomHostViewController.m"
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

mkdir -p "$scratch/build/output"
touch "$scratch/build/output/axiom-ui-host-ios-simulator.app.zip"
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

printf 'axiom-ui-host validation passed: the Axiom-owned host and its release manifest install through the CLI cache.\n'
