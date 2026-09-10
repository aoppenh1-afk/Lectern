#!/usr/bin/env bash
# Publishes a dev-channel prerelease for the current commit on main.
#
#   scripts/release-dev.sh
#
# Unlike scripts/release.sh this never bumps MARKETING_VERSION /
# CURRENT_PROJECT_VERSION and never commits: it stamps the dev tag and
# commit SHA into the build (LecternDevTag / LecternDevSHA), builds the app,
# tags v<MARKETING>-dev.<UTC-timestamp>-<short-sha>, and publishes a GitHub
# prerelease that only the dev update channel sees (`/releases/latest`,
# which stable follows, ignores prereleases). Old dev prereleases are
# pruned to the most recent KEEP_DEV_RELEASES.
#
# Requirements: clean git tree, `gh` signed in with access to the repo,
# xcodegen on PATH. Code signing uses the persistent release certificate
# when available and falls back to ad-hoc signing otherwise (dev only;
# ad-hoc builds may re-prompt for Keychain access).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEEP_DEV_RELEASES="${KEEP_DEV_RELEASES:-20}"

if [[ -n "$(git status --porcelain)" ]]; then
  # xcodegen regenerates Lectern.xcodeproj/ and Support/Info.plist from
  # project.yml, so drift there is allowed (build-app.sh regenerates them
  # again before building). Anything else must be committed so the dev tag
  # points at exactly the code that was built.
  DIRTY="$(git status --porcelain | grep -v ' Lectern.xcodeproj/' | grep -v ' Support/Info.plist' || true)"
  if [[ -n "$DIRTY" ]]; then
    echo "Working tree has uncommitted source changes. Commit or stash first:" >&2
    echo "$DIRTY" >&2
    exit 1
  fi
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" && -z "${LECTERN_DEV_ALLOW_BRANCH:-}" ]]; then
  echo "Dev releases are cut from main (on $BRANCH). Set LECTERN_DEV_ALLOW_BRANCH=1 to override." >&2
  exit 1
fi

source "$ROOT/scripts/release-signing.sh"
if [[ -z "${LECTERN_SIGN_IDENTITY:-}" ]] && ! security find-identity -p codesigning -v 2>/dev/null | grep -Fq "$LECTERN_RELEASE_CERTIFICATE"; then
  export LECTERN_SIGN_IDENTITY="-"
  echo "Release certificate not found; dev build will be ad-hoc signed." >&2
fi

REPO="$(grep -E '^[[:space:]]*LecternUpdateRepository:' project.yml | sed -E 's/.*:[[:space:]]*//')"
if [[ -z "$REPO" ]]; then
  echo "LecternUpdateRepository is not set in project.yml" >&2
  exit 1
fi

MARKETING="$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
FULL_SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short=7 HEAD)"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TAG="v${MARKETING}-dev.${STAMP}-${SHORT_SHA}"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists." >&2
  exit 1
fi

export LECTERN_DEV_TAG="$TAG"
export LECTERN_DEV_SHA="$FULL_SHA"

"$ROOT/scripts/build-app.sh"

if [[ "${LECTERN_SIGN_IDENTITY:-}" != "-" ]]; then
  verify_lectern_release_signature "$ROOT/dist/Lectern.app"
fi

ZIP="dist/Lectern-$TAG.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent dist/Lectern.app "$ZIP"
shasum -a 256 "$ZIP" | sed -E "s#dist/##" > "$ZIP.sha256"

PREV_DEV_TAG="$(git tag --list 'v*-dev.*' --sort=-creatordate | head -n 1 || true)"
if [[ -n "$PREV_DEV_TAG" ]]; then
  COMMITS="$(git log --oneline "${PREV_DEV_TAG}..HEAD" -- || true)"
else
  COMMITS="$(git log --oneline -20 -- || true)"
fi
if [[ -z "$COMMITS" ]]; then
  COMMITS="(no new commits listed)"
fi
NOTES="Dev build from main @ ${FULL_SHA} (${STAMP} UTC), on top of Lectern ${MARKETING}.

${COMMITS}"

git tag -a "$TAG" -m "Lectern dev $TAG"
git push origin "$TAG"

gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
  --repo "$REPO" \
  --title "Lectern Dev ${STAMP} (${SHORT_SHA})" \
  --notes "$NOTES" \
  --prerelease

# Prune older dev prereleases so every-commit publishing does not flood
# the Releases page. Keeps the newest KEEP_DEV_RELEASES.
OLD_TAGS="$(gh release list --repo "$REPO" --limit 100 \
  --json tagName,isPrerelease \
  --jq "[.[] | select(.isPrerelease and (.tagName | contains(\"-dev.\"))) | .tagName][$KEEP_DEV_RELEASES:][] // empty" || true)"
if [[ -n "$OLD_TAGS" ]]; then
  echo "$OLD_TAGS" | while IFS= read -r old; do
    [[ -z "$old" ]] && continue
    echo "Pruning old dev release $old"
    gh release delete "$old" --cleanup-tag --yes --repo "$REPO"
  done
fi

echo "Published dev https://github.com/$REPO/releases/tag/$TAG"
