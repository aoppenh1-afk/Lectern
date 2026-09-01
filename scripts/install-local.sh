#!/usr/bin/env bash
# Builds Lectern and replaces the copy in /Applications, then relaunches it.
#
#   scripts/install-local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${LECTERN_INSTALL_DIR:-/Applications}/Lectern.app"

"$ROOT/scripts/build-app.sh"

if pgrep -x Lectern >/dev/null 2>&1; then
  echo "Quitting running Lectern…"
  osascript -e 'tell application "Lectern" to quit' >/dev/null 2>&1 || pkill -x Lectern || true
  for _ in $(seq 1 25); do
    pgrep -x Lectern >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

rm -rf "$TARGET"
ditto "$ROOT/dist/Lectern.app" "$TARGET"
echo "Installed $(defaults read "$TARGET/Contents/Info.plist" CFBundleShortVersionString) at $TARGET"
open -n "$TARGET"
