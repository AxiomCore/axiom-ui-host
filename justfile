set shell := ["bash", "-euo", "pipefail", "-c"]

default:
  @just --list

check:
  ./scripts/check.sh

test:
  ./tests/validate-host.sh

ios-simulator:
    ./scripts/build-ios.sh simulator

ios-runtime:
    ./scripts/install-ios-simulator-runtime.sh

ios-runtime-repair:
    ./scripts/repair-ios-simulator-runtime.sh

ios-device:
  ./scripts/build-ios.sh device

android-debug:
  ./scripts/build-android.sh debug

android-release:
  ./scripts/build-android.sh release

package version:
  ./scripts/package-release.sh "{{version}}"

verify manifest:
  ./scripts/verify-release.sh "{{manifest}}"

release-dry-run version:
  ./scripts/release.sh --dry-run "{{version}}"

release version:
  ./scripts/release.sh "{{version}}"

# First host publication: requires an empty AxiomCore/axiom-ui-host remote and
# a clean initial source commit. Infisical injects the signing key only for the
# release process.
release-initial version:
  infisical run --env=prod -- env AXIOM_UI_HOST_RELEASE_SECRETS_LOADED=true ./scripts/publish-release.sh initial "{{version}}"

# Later immutable host publications from a clean source commit.
release-update version:
  infisical run --env=prod -- env AXIOM_UI_HOST_RELEASE_SECRETS_LOADED=true ./scripts/publish-release.sh update "{{version}}"
