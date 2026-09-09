#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mode="${1:-}"
version="${2:-}"
[[ "$mode" == initial || "$mode" == update ]] || die "usage: publish-release.sh <initial|update> <version>"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || die "version must be a semantic version without a leading v, for example 0.1.0"

# A maintainer may keep the large release build cache on external storage
# without changing normal developer builds or CI. An explicitly exported build
# root always wins. This local configuration is deliberately outside Git.
release_build_root_config="${AXIOM_UI_HOST_RELEASE_BUILD_ROOT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/axiom-ui-host/release-build-root}"
if [[ "$mode" == update && -z "${AXIOM_UI_HOST_BUILD_ROOT:-}" && -f "$release_build_root_config" ]]; then
  release_build_root="$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; {p; q;}' "$release_build_root_config")"
  [[ "$release_build_root" == /* ]] || die "release build-root config must contain one absolute path: $release_build_root_config"
  release_build_root_parent="$(dirname "$release_build_root")"

  # A macOS APFS sparse image can live on a portable ExFAT SSD while retaining
  # the filesystem semantics required by the NDK linker. If configured, mount
  # it automatically before testing the release build root.
  release_build_image_config="${AXIOM_UI_HOST_RELEASE_BUILD_IMAGE_CONFIG:-$(dirname "$release_build_root_config")/release-build-image}"
  if [[ ! -d "$release_build_root_parent" && -f "$release_build_image_config" ]]; then
    release_build_image="$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; {p; q;}' "$release_build_image_config")"
    # Sparse bundles are directories; regular disk images are files.
    [[ -e "$release_build_image" ]] || die "configured release build image does not exist: $release_build_image"
    need hdiutil
    printf '%s\n' "axiom-ui-host: mounting configured APFS release build volume."
    # macOS owns /Volumes, so let DiskImages create the mount point from the
    # APFS image's volume label rather than attempting to create it directly.
    hdiutil attach -nobrowse "$release_build_image" >/dev/null || \
      die "could not mount configured release build image: $release_build_image"
  fi
  [[ -d "$release_build_root_parent" && -w "$release_build_root_parent" ]] || \
    die "configured release build-root is unavailable or not writable: $release_build_root (connect the external volume or set AXIOM_UI_HOST_BUILD_ROOT)"
  release_build_filesystem="$(diskutil info -plist "$release_build_root_parent" 2>/dev/null | plutil -extract FilesystemName raw - 2>/dev/null || true)"
  [[ "$release_build_filesystem" != ExFAT ]] || \
    die "configured release build-root is on ExFAT. Android NDK lld can write zero-filled .so files there; use an APFS-formatted volume or configure an APFS sparse image on the SSD"
  export AXIOM_UI_HOST_BUILD_ROOT="$release_build_root"
  printf '%s\n' "axiom-ui-host: using configured external release build cache: $AXIOM_UI_HOST_BUILD_ROOT"
fi

# Publishing a host is a production operation. Secrets are injected for this
# one process by the just recipes; do not run this script with a copied key.
[[ "${AXIOM_UI_HOST_RELEASE_SECRETS_LOADED:-}" == true ]] || die "release secrets are not loaded; run 'just release-$mode $version' so Infisical supplies them"
for secret_name in AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX; do
  [[ -n "${!secret_name:-}" ]] || die "$secret_name is required for a signed release"
done

need git
need gh

git_root="$(git -C "$host_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[[ "$git_root" == "$host_dir" ]] || die "the host must be its own Git repository before publishing; initialize/push $host_dir to AxiomCore/axiom-ui-host first"
git -C "$host_dir" rev-parse --verify HEAD >/dev/null || die "the host repository has no initial commit"
[[ -z "$(git -C "$host_dir" status --porcelain)" ]] || die "the host source working tree is not clean; commit or stash source changes before releasing"

remote="$(git -C "$host_dir" remote get-url origin 2>/dev/null || true)"
case "$remote" in
  https://github.com/AxiomCore/axiom-ui-host.git|git@github.com:AxiomCore/axiom-ui-host.git|ssh://git@github.com/AxiomCore/axiom-ui-host.git) ;;
  *) die "origin must be AxiomCore/axiom-ui-host (found: ${remote:-missing})" ;;
esac

tag="v$version"
if gh release view "$tag" --repo AxiomCore/axiom-ui-host >/dev/null 2>&1; then
  die "GitHub Release $tag already exists; releases are immutable, choose a new version"
fi

if [[ "$mode" == initial ]]; then
  # Source is normally pushed before the first release so reviewers can audit
  # exactly what an asset came from. Allow that normal sequence, but require
  # the remote source commit to be identical to this clean checkout.
  if git -C "$host_dir" ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
    remote_main="$(git -C "$host_dir" ls-remote --heads origin main | awk '{print $1}')"
    local_head="$(git -C "$host_dir" rev-parse HEAD)"
    [[ "$remote_main" == "$local_head" ]] || die "origin/main does not match HEAD; pull/rebase or push the reviewed source before its first release"
  fi
  existing_release="$(gh release list --repo AxiomCore/axiom-ui-host --limit 1 2>/dev/null || true)"
  [[ -z "$existing_release" ]] || die "a GitHub Release already exists; use 'just release-update $version' for later releases"
else
  git -C "$host_dir" fetch --quiet origin main || die "cannot fetch origin/main; the first source publication must use 'just release-initial <version>'"
fi

printf '%s\n' "axiom-ui-host: validating source and building the iOS and Android development hosts for release $tag."
"$host_dir/scripts/check.sh"
"$host_dir/tests/validate-host.sh"
"$host_dir/scripts/build-ios.sh" simulator
"$host_dir/scripts/build-android.sh" release

# Build output is confined to the opaque host cache. The source tree was
# checked clean before the build, and must still be clean when we publish it.
[[ -z "$(git -C "$host_dir" status --porcelain)" ]] || die "a release build changed tracked source; inspect and commit it before retrying"
if [[ "$mode" == initial ]]; then
  git -C "$host_dir" push -u origin HEAD:main
else
  git -C "$host_dir" push origin HEAD:main
fi

"$host_dir/scripts/release.sh" "$version"
printf '%s\n' "axiom-ui-host: source and signed release $tag are published."
