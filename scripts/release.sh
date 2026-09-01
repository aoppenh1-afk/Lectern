#!/usr/bin/env bash
# Cuts a release: bumps the version, builds, zips, tags, pushes, and publishes
# a GitHub release that the in-app updater can find.
#
#   scripts/release.sh 1.2.0 [--notes "What changed"]
#
# Requirements: clean git tree on main, `gh` signed in with access to the repo,
# xcodegen on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "usage: scripts/release.sh <major.minor[.patch]> [--notes TEXT]" >&2
  exit 1
fi
shift
NOTES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean. Commit or stash first." >&2
  exit 1
fi

REPO="$(grep -E '^[[:space:]]*LecternUpdateRepository:' project.yml | sed -E 's/.*:[[:space:]]*//')"
if [[ -z "$REPO" ]]; then
  echo "LecternUpdateRepository is not set in project.yml" >&2
  exit 1
fi

CURRENT_BUILD="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')"
NEXT_BUILD=$((CURRENT_BUILD + 1))

sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:).*/\1 \"$VERSION\"/" project.yml
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 \"$NEXT_BUILD\"/" project.yml
xcodegen generate >/dev/null

"$ROOT/scripts/build-app.sh"

ZIP="dist/Lectern-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent dist/Lectern.app "$ZIP"
shasum -a 256 "$ZIP" | sed -E "s#dist/##" > "$ZIP.sha256"

git add project.yml Lectern.xcodeproj/project.pbxproj Support/Info.plist
git commit -m "Release $VERSION"
git tag -a "v$VERSION" -m "Lectern $VERSION"
git push origin HEAD
git push origin "v$VERSION"

if [[ -z "$NOTES" ]]; then
  NOTES="Lectern $VERSION"
fi
gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" \
  --repo "$REPO" \
  --title "Lectern $VERSION" \
  --notes "$NOTES"

echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
