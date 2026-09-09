#!/usr/bin/env bash
# Package an existing signed app; does not rebuild, resign, or publish it.
# Usage: scripts/package-dmg.sh /path/to/Lectern.app /path/to/Lectern-version.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Supply the path to Lectern.app}"
OUTPUT="${2:?Supply the output DMG path}"
[[ -d "$APP/Contents" && "$(basename "$APP")" == Lectern.app ]] || { echo 'Expected a Lectern.app bundle' >&2; exit 1; }
[[ ! -e "$OUTPUT" ]] || { echo "Output already exists: $OUTPUT" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
TOOLS="$ROOT/dist/.dmg-tools"
if [[ ! -x "$TOOLS/bin/python3" ]]; then
  python3 -m venv "$TOOLS"
fi
"$TOOLS/bin/python3" -m pip install --disable-pip-version-check -r "$ROOT/scripts/dmg-requirements.txt"
mkdir -p "$(dirname "$OUTPUT")"
"$TOOLS/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D "app=$APP" 'Install Lectern' "$OUTPUT"
hdiutil verify "$OUTPUT"
shasum -a 256 "$OUTPUT" | sed "s#  .*#  $(basename "$OUTPUT")#" > "$OUTPUT.sha256"
