#!/usr/bin/env bash
# Builds a Release copy of Lectern.app into dist/ and signs it.
#
#   scripts/build-app.sh            # -> dist/Lectern.app
#
# Uses the original release certificate. Explicit ad-hoc signing is for scratch builds only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
DERIVED="$ROOT/.build/DerivedData"

cd "$ROOT"
source "$ROOT/scripts/release-signing.sh"
SIGN_IDENTITY="$(resolve_lectern_signing_identity)"

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
  | tee "$DIST/build.log"

BUILT="$DERIVED/Build/Products/Release/Lectern.app"
if [[ ! -d "$BUILT" ]]; then
  echo "Build did not produce $BUILT" >&2
  exit 1
fi

ditto "$BUILT" "$DIST/Lectern.app"

echo "Code signing with identity: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$DIST/Lectern.app"
if [[ "$SIGN_IDENTITY" != '-' ]]; then
  verify_lectern_release_signature "$DIST/Lectern.app"
fi

xattr -cr "$DIST/Lectern.app"

VERSION="$(defaults read "$DIST/Lectern.app/Contents/Info.plist" CFBundleShortVersionString)"
echo "Built Lectern $VERSION -> $DIST/Lectern.app"
