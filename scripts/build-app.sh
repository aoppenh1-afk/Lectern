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

GOOGLE_BUILD_SETTINGS=()
if [[ -f "$ROOT/.build/GoogleOAuth.xcconfig" ]]; then
  GOOGLE_BUILD_SETTINGS+=(-xcconfig "$ROOT/.build/GoogleOAuth.xcconfig")
fi
if [[ -n "${LECTERN_GOOGLE_CLIENT_ID:-}" ]]; then
  GOOGLE_BUILD_SETTINGS+=("LECTERN_GOOGLE_CLIENT_ID=$LECTERN_GOOGLE_CLIENT_ID")
  GOOGLE_BUILD_SETTINGS+=("LECTERN_GOOGLE_CLIENT_SECRET=${LECTERN_GOOGLE_CLIENT_SECRET:-}")
fi
# Dev-channel identity stamped by scripts/release-dev.sh. Empty for stable
# builds; surfaces as LecternDevTag/LecternDevSHA in Info.plist.
if [[ -n "${LECTERN_DEV_TAG:-}" ]]; then
  GOOGLE_BUILD_SETTINGS+=("LECTERN_DEV_TAG=$LECTERN_DEV_TAG")
fi
if [[ -n "${LECTERN_DEV_SHA:-}" ]]; then
  GOOGLE_BUILD_SETTINGS+=("LECTERN_DEV_SHA=$LECTERN_DEV_SHA")
fi

xcodebuild \
  -scheme Lectern \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ${GOOGLE_BUILD_SETTINGS[@]+"${GOOGLE_BUILD_SETTINGS[@]}"} \
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
