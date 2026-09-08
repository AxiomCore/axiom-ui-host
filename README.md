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
just package version=0.1.0
just verify manifest=dist/host-manifest.json
just release-dry-run version=0.1.0
just release-initial 0.1.0
just release-update 0.1.1
```

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
`android-debug` is intentionally gated until Axiom's own Android application
and typed request/response JNI bridge are implemented. It never derives an
application from an upstream sample host. Build products are written under
`AXIOM_UI_HOST_BUILD_ROOT` (or the user cache); no command writes generated
source into an Acore app or this repository.

To install the latest published release through the Axiom CLI:

```sh
axiom ui host install --target ios
axiom ui host status --target ios
axiom run app/main.acore --target ios
```

The normal `axiom run` flow asks to install a missing **UI Host**, downloads the
latest Axiom-owned release automatically, verifies its signed manifest and
artifact checksum, then installs only the matching target asset. CI can use
`--non-interactive`; `--release-manifest` remains available for an explicitly
supplied local release.

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

Release signing is intentionally a separate CI responsibility. The CI workflow
must sign both the manifest and every platform archive with an Axiom-controlled
key, attach the public-key identifier and signature files to the same GitHub
release, and publish only after `just verify` succeeds. The CLI verifies the
manifest signature and archive hash before recording the host in its opaque
cache.

### Publishing source and release assets

`dist/` is a release attachment directory, never a Git input. Initialize this
directory as the separate `AxiomCore/axiom-ui-host` repository and push a clean
`main` commit before its first publication. `release-initial` accepts that
already-pushed source commit as long as no GitHub Release exists yet. Then run:

```sh
just release-initial 0.1.0
```

It loads the signing key only through `infisical run --env=prod`, validates and
builds the iOS Simulator host, pushes the source commit to `main`, and creates
the signed immutable GitHub Release `v0.1.0`. Later releases use a new version:

```sh
just release-update 0.1.1
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

The iOS simulator host is the first release channel. It remains a development
host until a device/simulator launch smoke test and the Axiom UI bundle-delivery
adapter are enabled. Android is not releasable yet: the command deliberately
does not emit an APK until its callback bridge is completed and tested.
