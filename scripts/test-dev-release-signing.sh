#!/usr/bin/env bash
# Exercise the real release entry point without building or publishing anything.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/scripts" "$FIXTURE/bin"
cp "$ROOT/scripts/release-dev.sh" "$ROOT/scripts/release-signing.sh" "$FIXTURE/scripts/"
cp "$ROOT/project.yml" "$FIXTURE/"
cat > "$FIXTURE/bin/git" <<'EOF'
#!/bin/bash
case "$*" in
  'status --porcelain') ;;
  'rev-parse --abbrev-ref HEAD') echo main ;;
  'rev-parse HEAD'|'rev-parse --short=7 HEAD') echo abc1234 ;;
  *) exit 1 ;;
esac
EOF
cat > "$FIXTURE/bin/security" <<'EOF'
#!/bin/bash
printf '%s\n' "${TEST_IDENTITIES:-}"
EOF
cat > "$FIXTURE/scripts/build-app.sh" <<'EOF'
#!/bin/bash
touch "$BUILD_MARKER"
exit 91
EOF
chmod +x "$FIXTURE/bin/"* "$FIXTURE/scripts/build-app.sh"
export PATH="$FIXTURE/bin:$PATH" BUILD_MARKER="$FIXTURE/build-started"
source "$ROOT/scripts/release-signing.sh"
unset LECTERN_SIGN_IDENTITY

expect_rejected() {
  rm -f "$BUILD_MARKER"
  if bash "$FIXTURE/scripts/release-dev.sh" > "$FIXTURE/output" 2>&1; then
    echo 'FAIL: unsigned dev release accepted' >&2
    exit 1
  fi
  if [[ -e "$BUILD_MARKER" ]]; then
    echo 'FAIL: dev release reached build without the pinned certificate' >&2
    exit 1
  fi
  grep -q 'Error:' "$FIXTURE/output"
}

export TEST_IDENTITIES=''
expect_rejected
export TEST_IDENTITIES="1) $LECTERN_RELEASE_CERTIFICATE \"Lectern Release Signing\""
export LECTERN_SIGN_IDENTITY=-
expect_rejected
unset LECTERN_SIGN_IDENTITY
export TEST_IDENTITIES='1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Lectern Release Signing"'
expect_rejected
export TEST_IDENTITIES="1) $LECTERN_RELEASE_CERTIFICATE \"Lectern Release Signing\""
status=0
bash "$FIXTURE/scripts/release-dev.sh" > "$FIXTURE/output" 2>&1 || status=$?
[[ "$status" == 91 && -e "$BUILD_MARKER" ]]
echo 'PASS: dev releases reject missing, ad-hoc, and replacement identities; original identity reaches build'
