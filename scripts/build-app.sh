#!/usr/bin/env bash
# Builds a Release copy of Lectern.app into dist/ and ad-hoc signs it.
#
#   scripts/build-app.sh            # -> dist/Lectern.app
#
# There is no Apple Developer account behind this project, so the bundle is
# ad-hoc signed. Gatekeeper will ask the first person who opens a downloaded
# copy to approve it once (see README).
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
codesign --force --deep --sign - "$DIST/Lectern.app"
xattr -cr "$DIST/Lectern.app"

VERSION="$(defaults read "$DIST/Lectern.app/Contents/Info.plist" CFBundleShortVersionString)"
echo "Built Lectern $VERSION -> $DIST/Lectern.app"
