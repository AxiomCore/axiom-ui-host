#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
output="${1:-$PWD/axiom-ui-host-release-secrets.env}"
[[ ! -e "$output" ]] || die "refusing to overwrite $output"
need openssl; need keytool; need cargo
work="$(mktemp -d)"
# Generate values once, then make the keystore with those exact values.
storepass="$(openssl rand -hex 24)"; keypass="$(openssl rand -hex 24)"; alias="axiom-ui-host-$(openssl rand -hex 6)"
keytool -genkeypair -keystore "$work/android.keystore" -storetype PKCS12 -storepass "$storepass" -keypass "$keypass" -alias "$alias" -keyalg RSA -keysize 4096 -validity 3650 -dname 'CN=Axiom UI Host, O=AxiomCore, C=US' >/dev/null
keys="$(cargo run --quiet --manifest-path "$repo_dir/axiom-keygen/Cargo.toml" -- generate)"
private="$(printf '%s\n' "$keys" | sed -n 's/^AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX=//p')"
public="$(printf '%s\n' "$keys" | sed -n 's/^AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX=//p')"
umask 077
{
  printf 'AXIOM_UI_HOST_SIGNING_PRIVATE_KEY_HEX=%s\n' "$private"
  printf 'AXIOM_UI_HOST_SIGNING_PUBLIC_KEY_HEX=%s\n' "$public"
  printf '# Release repository is public metadata fixed as AxiomCore/axiom-ui-host.\n'
  printf 'AXIOM_UI_HOST_ANDROID_KEYSTORE_BASE64=%s\n' "$(base64 < "$work/android.keystore" | tr -d '\n')"
  printf 'AXIOM_UI_HOST_ANDROID_KEY_ALIAS=%s\n' "$alias"
  printf 'AXIOM_UI_HOST_ANDROID_KEYSTORE_PASSWORD=%s\n' "$storepass"
  printf 'AXIOM_UI_HOST_ANDROID_KEY_PASSWORD=%s\n' "$keypass"
  printf '# Add Apple certificate/profile values after exporting them from Apple Developer.\n'
  printf '# AXIOM_UI_HOST_APPLE_CERTIFICATE_BASE64=\n# AXIOM_UI_HOST_APPLE_CERTIFICATE_PASSWORD=\n# AXIOM_UI_HOST_APPLE_PROVISIONING_PROFILE_BASE64=\n'
} > "$output"
chmod 600 "$output"
printf 'Created %s (mode 0600). Import its variables into Infisical; do not commit it.\n' "$output"
