#!/usr/bin/env bash
# Shared signing policy. This fingerprint is public certificate metadata, not a secret.
# Keep it stable: replacing the certificate changes Keychain authorization.
LECTERN_RELEASE_CERTIFICATE=3037A18F1050717B4C7916457A8C22F4AB6D5BA9
LECTERN_RELEASE_REQUIREMENT='identifier "com.lectern.Lectern" and certificate root = H"3037a18f1050717b4c7916457a8c22f4ab6d5ba9"'

resolve_lectern_signing_identity() {
  local requested="${LECTERN_SIGN_IDENTITY:-$LECTERN_RELEASE_CERTIFICATE}"
  if [[ "$requested" == '-' && "${REQUIRE_CODE_SIGN_IDENTITY:-0}" != 1 ]]; then
    printf '%s\n' '-'
    return
  fi
  local identities
  identities="$(security find-identity -p codesigning -v)" || return
  if ! printf '%s\n' "$identities" | grep -F "$LECTERN_RELEASE_CERTIFICATE" | grep -Fq '"Lectern Release Signing"'; then
    echo 'Error: The original Lectern release certificate is unavailable. Import its .p12 backup; do not generate a replacement.' >&2
    return 1
  fi
  if [[ "$requested" != "$LECTERN_RELEASE_CERTIFICATE" && "$requested" != 'Lectern Release Signing' ]]; then
    echo 'Error: Changing the release signing identity would reset Keychain authorization.' >&2
    return 1
  fi
  printf '%s\n' "$LECTERN_RELEASE_CERTIFICATE"
}

verify_lectern_release_signature() {
  codesign --verify --deep --strict -R "=$LECTERN_RELEASE_REQUIREMENT" "$1"
}
