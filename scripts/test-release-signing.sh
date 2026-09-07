#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/release-signing.sh"
security() {
  printf '%s\n' "${TEST_IDENTITIES:-}"
}
export REQUIRE_CODE_SIGN_IDENTITY=1
TEST_IDENTITIES="1) $LECTERN_RELEASE_CERTIFICATE \"Lectern Release Signing\""
[[ "$(resolve_lectern_signing_identity)" == "$LECTERN_RELEASE_CERTIFICATE" ]]
LECTERN_SIGN_IDENTITY='Lectern Release Signing'
[[ "$(resolve_lectern_signing_identity)" == "$LECTERN_RELEASE_CERTIFICATE" ]]
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
TEST_IDENTITIES=''
if resolve_lectern_signing_identity >/dev/null 2>&1; then
  echo 'FAIL: accepted missing certificate' >&2
  exit 1
fi
REQUIRE_CODE_SIGN_IDENTITY=0
LECTERN_SIGN_IDENTITY=-
[[ "$(resolve_lectern_signing_identity)" == '-' ]]
echo 'PASS: pinned identity, changed identity, ad-hoc release, replacement certificate, missing certificate, scratch build'
