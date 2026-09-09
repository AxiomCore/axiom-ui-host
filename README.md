# Axiom UI Host

`axiom-ui-host` is Axiom-owned source and release automation for the native
applications that receive an Axiom UI bundle. It is deliberately separate from
an Acore application: an application contains authored `.acore` files only;
the host is built, signed, released, installed, and verified as a platform
toolchain input.

The host is built from pinned renderer source, but users install only Axiom
release assets. A release never downloads or trusts a third-party prebuilt
renderer binary. Axiom CI builds the renderer source and Axiom bridge itself,
then publishes the resulting host archive, checksum, provenance manifest,
SBOM, notices, and signature from Axiom's GitHub release.

## Commands

Install [just](https://github.com/casey/just), then run from this directory:

```sh
just check
just ios-runtime
just ios-simulator
just android-debug
just android-emulator
just package version=0.3.0
just verify manifest=dist/host-manifest.json
just release-dry-run version=0.3.0
just release-update 0.3.0
```

For Android environment setup, known failure signatures, safe cache recovery,
and release-publishing checks, see [Android host build troubleshooting](docs/android-build-troubleshooting.md).

`ios-simulator` needs Xcode, CocoaPods, XcodeGen, Rust iOS targets, an iOS
Simulator runtime, and a pinned source checkout. Run `just ios-runtime` once
per Xcode version to install Xcode's matching simulator runtime; it may
download several GB. If Xcode reports a duplicate simulator-image UUID after
a download, run `just ios-runtime-repair`. It safely asks CoreSimulator to
scan and mount already-downloaded images; it never deletes simulator data.
The build automatically bootstraps the pinned GN graph
and its Python-only build dependency, then generates `Lynx.podspec` inside the
opaque host cache. `Lynx`, `LynxBase`, and `LynxServiceAPI` resolve from that
staged source tree, not the CocoaPods registry. The current pinned engine
still declares PrimJS as an upstream source pod; mirroring and locking that
source is a remaining release-hardening item.
`android-emulator` builds the signed Axiom-owned **development host** APK used
by `axiom run --target android`; `android-debug` is the unsigned local build.
Both require Android SDK, `cargo-ndk`, Java, and the pinned engine source.
The renderer currently requires the SDK-managed side-by-side NDK
**`21.1.6352462`**. Install it without removing other NDKs:

```sh
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install "ndk;21.1.6352462"
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install "cmake;3.18.1"
```

Set `ANDROID_HOME` (or `ANDROID_SDK_ROOT`) to the Android SDK. The host build
automatically selects and exports that exact NDK for both Gradle and Cargo, so
your global `ANDROID_NDK_HOME` may continue to point at another project’s NDK.
`AXIOM_UI_HOST_NDK_HOME` can explicitly name that SDK-side-by-side directory;
it must be `$ANDROID_HOME/ndk/21.1.6352462`.
The Rust runtime is compiled with `cargo-ndk`, which requires NDK r23 or later.
Leave `ANDROID_NDK_HOME` set to a modern installed NDK (for example 26.3), or
set `AXIOM_UI_HOST_CARGO_NDK_HOME` to one. The build deliberately uses that
modern NDK only for Cargo and switches back to r21 for the Lynx Gradle build.
The host resolves Lynx’s Android `lynx` flavor dimension to `noasan`, the
normal unsanitized variant shared by all transitive Lynx modules. Axiom’s
development delivery protocol is implemented by the host itself; this keeps
the Axiom artifact task stable as `assembleRelease`.
All native Gradle modules use the renderer-pinned SDK CMake **3.18.1**; the
build checks for it before compiling the Rust runtime.
The pinned Android Gradle build requires JDK 11. On Apple Silicon, install it
with `brew install openjdk@11` and set
`AXIOM_UI_HOST_JAVA_HOME=/opt/homebrew/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home`
before running an Android host build. This variable is intentionally
host-specific and does not require changing the Java version used by other
projects.
The release build takes the Android keystore only from the four
`AXIOM_UI_HOST_ANDROID_*` variables and decodes it only into the opaque host
cache. It never derives an application from an upstream sample host. Build
products are written under `AXIOM_UI_HOST_BUILD_ROOT` (or the user cache); no
command writes generated source into an Acore app or this repository.

For a maintainer who releases from external storage, `just release-update`
can load a local, untracked cache location from
`~/.config/axiom-ui-host/release-build-root`. Put one absolute path in that
file. The Android NDK linker cannot build on ExFAT: use an APFS-formatted
volume, or an APFS sparse image stored on the external SSD. A companion
`release-build-image` file can name that image and it will be mounted on demand.
This affects only release updates on that machine; an explicitly set
`AXIOM_UI_HOST_BUILD_ROOT` still takes precedence.

To install the latest published release through the Axiom CLI:

```sh
axiom ui host install --target ios
axiom ui host status --target ios
axiom ui host recover --target ios
axiom run app/main.acore --target ios
axiom ui host install --target android
axiom ui host status --target android
axiom run app/main.acore --target android
```

The normal `axiom run` flow asks to install a missing **UI Host**, downloads the
latest Axiom-owned release automatically, verifies its signed manifest and
artifact checksum, then installs only the matching target asset. CI can use
`--non-interactive`; `--release-manifest` remains available for an explicitly
supplied local release.

Release `0.3.0` introduces delivery protocol v2. A compatible Acore edit may
request state-preserving patch delivery, but the host must acknowledge the
result explicitly. The current pinned renderer transport safely returns an
explained state-reset fallback while it reloads the template inside the
existing app process; it does not claim that page state was retained. Run
`axiom ui host recover --target ios` only when a development acknowledgement is
stuck: it restarts the host and clears its two disposable control records, not
verified archives, last-good bundle, or application source.

Android has the same fixed `bundle` / `revision` / `ack` v2 protocol under the
host's app-private `files/axiom-ui-host` directory. The CLI selects a running
Android Emulator, installs the verified APK when needed, and transfers those
fixed files with `adb run-as`; it does not open the host sandbox to a source
path or network URL. Set `AXIOM_UI_ANDROID_DEVICE_SERIAL` to select a specific
authorized development device. The current Android host stays open but
truthfully reports a full-template state reset. Its renderer callback is
single-use, so streaming/event-channel parity and physical-device evidence are
still explicit Phase 5E gates. `axiom ui host recover --target android` clears
only its stale control records and relaunches that development host.

The GitHub repository and release assets used by normal CLI users must be
publicly downloadable. A private GitHub release works only for an authenticated
maintainer and cannot distribute to end users; never embed a GitHub token in the
CLI. If the host must remain private, publish its signed assets through an
Axiom-controlled public distribution endpoint instead.

## Release contract

The machine-readable manifest is `axiom-ui-host-release/v1`. The CLI verifies
the selected asset's SHA-256 before recording it in its opaque host cache.
The manifest records the Axiom host version, platform, artifact name, hash,
pinned engine revision, Axiom runtime revision, and provenance. A manifest is
an input to installation, not an application build input.

Before publishing, run `scripts/provision-release-secrets.sh` locally and put
its generated values in Infisical. It creates a new Ed25519 host-release key
and Android keystore. Apple signing material cannot be safely fabricated: it
must be exported from an Apple Developer certificate and provisioning profile.
The generated Android keystore is PKCS12, so its private-key password and store
password intentionally match. The Android build validates both the alias and
private-key password before starting the expensive native build.

Release signing is intentionally a separate CI responsibility. The CI workflow
must sign both the manifest and every platform archive with an Axiom-controlled
key, attach the public-key identifier and signature files to the same GitHub
release, and publish only after `just verify` succeeds. The CLI verifies the
manifest signature and archive hash before recording the host in its opaque
cache.

For GitHub Actions, synchronize the existing Infisical production values to
repository secrets (or replace that source with an approved Infisical CI
identity): `AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX`,
`AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX`, and all four
`AXIOM_UI_HOST_ANDROID_*` keystore values. The workflow never prints them or
uploads the decoded keystore. Its runtime revision is an explicit reviewed pin
in `.github/workflows/release.yml`; update it only with matching ABI evidence.

### Publishing source and release assets

`dist/` is a release attachment directory, never a Git input. Initialize this
directory as the separate `AxiomCore/axiom-ui-host` repository and push a clean
`main` commit before its first publication. `release-initial` accepts that
already-pushed source commit as long as no GitHub Release exists yet. Then run:

```sh
just release-initial 0.1.0
```

It loads signing material only through `infisical run --env=prod`, validates and
builds the iOS Simulator and signed Android Emulator development hosts, pushes the source commit to `main`, and creates
the signed immutable GitHub Release `v0.1.0`. Later releases use a new version:

```sh
just release-update 0.3.0
```

Both commands reject a dirty source tree, an incorrect remote, or an existing
release tag. They never create commits or upload build caches.

## Repository boundaries

- `toolchain/` pins sources and target assumptions.
- `ios/` and `android/` hold Axiom bridge overlays and host-specific setup.
- `scripts/` stages a source host only inside the opaque cache and packages
  only the resulting Axiom artifacts.
- `dist/` is disposable local release output and is gitignored.

The host contains a renderer runtime because native rendering requires one.
What Axiom owns is the build, bridge, artifact, release identity, verification,
and lifecycle; users do not install or depend on a renderer vendor's binary
distribution.

The release repository is fixed as `AxiomCore/axiom-ui-host`. This is public
routing metadata, so the scripts do not load it from Infisical.

## Current release gate

The iOS Simulator and Android Emulator artifacts are development-host release
channels, never end-user application packages. Both are retrieved only from an
Axiom-signed GitHub release. The Android artifact is intentionally debuggable
so `adb run-as` can preserve the app-private delivery boundary; do not ship it
to users or treat it as a production Android app. Android contract-dispatch
event parity, emulator E2E, and physical-device smoke evidence remain open and
are tracked in the Phase 5E document.
