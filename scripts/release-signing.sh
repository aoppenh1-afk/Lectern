#!/usr/bin/env bash
# Public team identifier verified from the maintainer's Apple certificate.
# Self-signed apps use a per-build cdhash Keychain partition even with a stable DR.
LECTERN_RELEASE_TEAM=ZRU5DU22H4
LECTERN_RELEASE_REQUIREMENT='identifier "com.lectern.Lectern" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "ZRU5DU22H4"'

resolve_lectern_signing_identity() {
  local requested="${LECTERN_SIGN_IDENTITY:-}"
  if [[ "$requested" == '-' && "${REQUIRE_CODE_SIGN_IDENTITY:-0}" != 1 ]]; then
    printf '%s\n' '-'
    return
  fi
  local identities candidates fingerprint name selected='' count=0
  identities="$(security find-identity -p codesigning -v)" || return
  candidates="$(printf '%s\n' "$identities" | sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-Fa-f]{40}) "(Developer ID Application:.*)"$/\1|\2/p')"
  while IFS='|' read -r fingerprint name; do
    [[ -n "$fingerprint" && "$name" == *"($LECTERN_RELEASE_TEAM)" ]] || continue
    [[ -z "$requested" || "$requested" == "$fingerprint" || "$requested" == "$name" ]] || continue
    selected="$fingerprint"
    count=$((count + 1))
  done <<< "$candidates"
  if [[ "$count" != 1 ]]; then
    echo "Error: Install a Developer ID Application certificate with its private key for team $LECTERN_RELEASE_TEAM. If several are installed, select one with LECTERN_SIGN_IDENTITY." >&2
    echo 'Self-signed certificates reset the Keychain partition on rebuild. Apple Development certificates are not release distribution identities.' >&2
    return 1
  fi
  printf '%s\n' "$selected"
}

verify_lectern_release_signature() {
  codesign --verify --deep --strict -R "=$LECTERN_RELEASE_REQUIREMENT" "$1"
}
