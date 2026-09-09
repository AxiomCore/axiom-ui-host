# Android host build troubleshooting

This guide records the Android host failures encountered while bringing up the
development-host APK on macOS/Apple Silicon. It is written for a new machine
or a future renderer/toolchain update. Run commands from `axiom-ui-host`.

The expected successful command is:

```sh
just android-emulator
```

It produces the signed development-host APK at:

```text
~/.cache/axiom-ui-host/output/axiom-ui-host-android-emulator.apk
```

`android-emulator` is intentionally a signed but debuggable development host;
it is not an end-user distribution APK.

## Required toolchain

The pinned Lynx Gradle project is older than the rest of the local Android
toolchain. Do not replace its requirements with globally newer versions.

| Component | Required value | Why |
| --- | --- | --- |
| Java | JDK 11 | Gradle 6.7.1 cannot run reliably with current JDKs. |
| Lynx Gradle NDK | SDK-managed `21.1.6352462` | The pinned renderer declares this exact NDK. |
| CMake | SDK CMake `3.18.1` | All native Android modules must use one compatible CMake version. |
| Rust `cargo-ndk` NDK | r23 or newer (for example 26.3) | `cargo-ndk` no longer supports the renderer's r21 NDK. |
| Rust targets | `aarch64-linux-android`, `x86_64-linux-android` | The emulator host packages arm64 and x86_64. |

Install the renderer requirements:

```sh
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install "ndk;21.1.6352462"
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install "cmake;3.18.1"
brew install openjdk@11
rustup target add aarch64-linux-android x86_64-linux-android
```

On Apple Silicon, configure the host-specific variables:

```sh
export AXIOM_UI_HOST_JAVA_HOME=/opt/homebrew/opt/openjdk@11/libexec/openjdk.jdk/Contents/Home
export AXIOM_UI_HOST_NDK_HOME="$ANDROID_HOME/ndk/21.1.6352462"
export AXIOM_UI_HOST_CARGO_NDK_HOME="$ANDROID_HOME/ndk/26.3.11579264"
```

Keep the modern NDK installed alongside r21. The build uses the modern NDK
only for Rust, then switches to r21 for the pinned Lynx Gradle build.

## Failure signatures and fixes

### `No matching variant ... attribute 'lynx' with value 'dev'`

The host selected a Lynx flavor not implemented by all transitive renderer
modules. In particular, `LynxJSSDK` has `noasan`, `asan`, and `debugMode`, but
not the host's separate `dev` flavor.

The host must remain flavorless and resolve the renderer dimension to
`noasan`:

```groovy
missingDimensionStrategy 'lynx', 'noasan'
```

This is set in `android/AxiomUIHost/build.gradle`. Do not change it to `dev`
when fixing a variant-resolution error.

### `CMake '3.10.2' was not found` or `CMake 3.22.1 or higher is required`

AGP 4.1 defaults an application module to CMake 3.10.2 unless the module
declares its version. The host bridge originally requested 3.22.1, while
renderer modules use the SDK-pinned 3.18.1.

The stable configuration is:

```groovy
externalNativeBuild { cmake { version CMAKE_VERSION } }
```

and this bridge requirement:

```cmake
cmake_minimum_required(VERSION 3.18.1)
```

Install SDK CMake 3.18.1 and do not satisfy this with a Homebrew CMake binary.

### `cannot find symbol androidx.annotation.Keep`

Lynx generates `LynxAutolinkGenerated.java`, which imports `@Keep`, but its
own annotation dependency is compile-only. The application must expose the
annotation JAR to `javac`:

```groovy
implementation 'androidx.annotation:annotation:1.0.0'
```

### `cannot find symbol getContext()` in `AxiomRuntimeModule`

The pinned `LynxModule` API has a protected `mContext` field and no
`getContext()` method. Use:

```java
new File(mContext.getFilesDir(), "axiom-ui-host")
```

Do not copy bridge snippets written for a newer Lynx API without checking the
pinned `LynxModule` source.

### `More than one file was found ... libaxiom_runtime.so`

AGP automatically packages a CMake `IMPORTED` shared library. If that same
Rust library is also copied into `src/main/jniLibs`, `mergeReleaseNativeLibs`
receives it twice.

Stage the Rust output under `src/main/nativeDeps/<abi>` and import it from
there in `android/bridge/CMakeLists.txt`. Do not work around this using
`packagingOptions.pickFirst`; that hides a layout error and makes the selected
binary ambiguous.

### `KeytoolException ... Given final block not properly padded`

The APK was built and only release signing failed. The generated store is
PKCS12. Java PKCS12 uses the store password for the private key, so a random,
different `AXIOM_UI_HOST_ANDROID_KEY_PASSWORD` fails when Gradle calls
`KeyStore.getKey`.

The build now detects PKCS12 and uses the store password for Gradle signing.
For a permanent repair, set this Infisical value equal to the store password:

```text
AXIOM_UI_HOST_ANDROID_KEY_PASSWORD = AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD
```

Use the Infisical UI; do not paste a password into shell history. New values
created with `scripts/provision-release-secrets.sh` already use matching
passwords. The build validates the keystore and alias before starting native
work, so an invalid base64 blob, store password, or alias fails quickly.

### Missing `tools_shared` files or Gradle 6.7.1 archive

An interrupted Habitat sync can leave a partial opaque engine cache. The build
repairs missing Android renderer tools from a matching verified iOS stage when
available, then re-syncs dependencies if required. It also restores the
pinned Gradle archive from the Habitat cache.

Retry once. If the same error persists, keep the source checkout intact and
remove only the explicit Android stage after confirming its path:

```sh
stage_path="$HOME/.cache/axiom-ui-host/stage/android-emulator"
test -d "$stage_path" && mv "$stage_path" "$stage_path.incomplete"
```

Then rerun `just android-emulator`. The renamed stage remains recoverable.

## Non-fatal output

The following messages are noisy but do not by themselves fail the build:

- `kotlin-android-extensions` and `publishNonDefault` deprecation warnings.
- Android SDK repository XML namespace mapping or `extension-level` warnings.
- GN's `disable_base_export ... never appeared in a declare_args()` warning.
- CMake warnings about upstream Lynx projects lacking `project()`.
- Unsupported Linux-only Node package warning on macOS ARM.
- Rust and Java deprecated/unused-code warnings.

Find the first `FAILURE: Build failed` section and use its `What went wrong`
block as the failure authority.

## Before publishing a successful APK

`just release-update <version>` intentionally refuses a dirty host repository.
That check prevents an APK built from local source from being attached to a
release that points at a different Git commit.

Review and commit the intended host changes first:

```sh
git status --short
git add README.md docs/ android/ scripts/ tests/
git commit -m "Fix Android host build pipeline"
git push origin main
just release-update 0.4.1
```

Do not add local build logs such as `logs/log-1.txt`, cached build directories,
or decoded keystores. If unrelated work is present, commit only the reviewed
Android-host files or stash the unrelated changes before publishing.

## Triage order on another machine

1. Run `just check`.
2. Verify the required SDK, NDK, CMake, JDK, and Rust targets above.
3. Run `just android-emulator` and retain the complete log.
4. Address the first fatal `What went wrong` block, not preceding warnings.
5. On success, confirm the APK path printed by the build.
6. Commit the source changes before running a release command.
