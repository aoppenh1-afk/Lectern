#!/usr/bin/env bash
# Builds a Release copy of Lectern.app into dist/ and signs it.
#
#   scripts/build-app.sh            # -> dist/Lectern.app
#
# Signing identity priority:
#   1. $LECTERN_SIGN_IDENTITY (explicit environment variable override)
#   2. "Lectern Release Signing" (permanent self-signed certificate via scripts/setup-signing-cert.sh)
#   3. "Developer ID Application: ..." or "Apple Development: ..." (if present in Keychain)
#   4. Fallback to ad-hoc (-) with warning (only allowed for local scratch builds)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
DERIVED="$ROOT/.build/DerivedData"

cd "$ROOT"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
fi

rm -rf "$DIST/Lectern.app"
mkdir -p "$DIST"

xcodebuild \
  -scheme Lectern \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build \
  | grep -E "error:|warning: .*deprecated|\*\* BUILD" || true

BUILT="$DERIVED/Build/Products/Release/Lectern.app"
if [[ ! -d "$BUILT" ]]; then
  echo "Build did not produce $BUILT" >&2
  exit 1
fi

ditto "$BUILT" "$DIST/Lectern.app"

# Resolve signing identity
SIGN_IDENTITY="${LECTERN_SIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-identity -p codesigning -v | grep -q "\"Lectern Release Signing\""; then
    SIGN_IDENTITY="Lectern Release Signing"
  elif security find-identity -p codesigning -v | grep -q "\"Developer ID Application:"; then
    SIGN_IDENTITY="$(security find-identity -p codesigning -v | grep "\"Developer ID Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
  elif security find-identity -p codesigning -v | grep -q "\"Apple Development:"; then
    SIGN_IDENTITY="$(security find-identity -p codesigning -v | grep "\"Apple Development:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
  fi
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Code signing with identity: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$DIST/Lectern.app"
elif [[ "${REQUIRE_CODE_SIGN_IDENTITY:-0}" == "1" ]]; then
  echo "Error: No valid code signing certificate found in Keychain, and REQUIRE_CODE_SIGN_IDENTITY=1." >&2
  echo "Ad-hoc signing is rejected for releases because it breaks Keychain authorization on updates." >&2
  echo "Run 'scripts/setup-signing-cert.sh' to create a permanent 'Lectern Release Signing' certificate." >&2
  exit 1
else
  echo "Warning: No code signing certificate found; falling back to ad-hoc signing (-)." >&2
  echo "macOS Keychain items will not persist across updates without re-authorization." >&2
  echo "Run 'scripts/setup-signing-cert.sh' to install a permanent certificate." >&2
  codesign --force --deep --sign - "$DIST/Lectern.app"
fi

xattr -cr "$DIST/Lectern.app"

VERSION="$(defaults read "$DIST/Lectern.app/Contents/Info.plist" CFBundleShortVersionString)"
echo "Built Lectern $VERSION -> $DIST/Lectern.app"
