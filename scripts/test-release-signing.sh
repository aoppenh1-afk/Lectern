#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/release-signing.sh"
security() {
  printf '%s\n' "${TEST_IDENTITIES:-}"
}
export REQUIRE_CODE_SIGN_IDENTITY=1
fingerprint=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
name="Developer ID Application: Example ($LECTERN_RELEASE_TEAM)"
TEST_IDENTITIES="1) $fingerprint \"$name\""
[[ "$(resolve_lectern_signing_identity)" == "$fingerprint" ]]
LECTERN_SIGN_IDENTITY="$name"
[[ "$(resolve_lectern_signing_identity)" == "$fingerprint" ]]
for LECTERN_SIGN_IDENTITY in '-' 'Apple Development: Example' 'DIFFERENT_CERTIFICATE'; do
  if resolve_lectern_signing_identity >/dev/null 2>&1; then
    echo "FAIL: accepted changed identity $LECTERN_SIGN_IDENTITY" >&2
    exit 1
  fi
done
unset LECTERN_SIGN_IDENTITY
TEST_IDENTITIES='1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Lectern Release Signing"'
if resolve_lectern_signing_identity >/dev/null 2>&1; then
  echo 'FAIL: accepted replacement certificate with same name' >&2
  exit 1
fi
TEST_IDENTITIES="1) $fingerprint \"Apple Development: Example ($LECTERN_RELEASE_TEAM)\""
if resolve_lectern_signing_identity >/dev/null 2>&1; then exit 1; fi
TEST_IDENTITIES="1) $fingerprint \"Developer ID Application: Example (OTHERTEAM1)\""
if resolve_lectern_signing_identity >/dev/null 2>&1; then exit 1; fi
TEST_IDENTITIES="1) $fingerprint \"$name\"
2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB \"$name\""
if resolve_lectern_signing_identity >/dev/null 2>&1; then exit 1; fi
LECTERN_SIGN_IDENTITY="$fingerprint"
[[ "$(resolve_lectern_signing_identity)" == "$fingerprint" ]]
unset LECTERN_SIGN_IDENTITY
TEST_IDENTITIES=''
if resolve_lectern_signing_identity >/dev/null 2>&1; then
  echo 'FAIL: accepted missing certificate' >&2
  exit 1
fi
REQUIRE_CODE_SIGN_IDENTITY=0
LECTERN_SIGN_IDENTITY=-
[[ "$(resolve_lectern_signing_identity)" == '-' ]]
echo 'PASS: Developer ID selection, team pin, ambiguous identities, rejected self-signing/development/ad-hoc releases, scratch build'
