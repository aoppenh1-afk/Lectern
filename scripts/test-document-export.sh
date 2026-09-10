#!/usr/bin/env bash
# Regression checks for Word formatting and PDF pagination, with reviewable files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lectern-export-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
swiftc -o "$BUILD_DIR/check" \
  "$ROOT/Sources/Lectern/ImportExport/LectureDocumentRenderer.swift" \
  "$ROOT/Sources/Lectern/Generation/NotesMarkdown.swift" \
  "$ROOT/Sources/Lectern/GoogleDocs/NotesMarkdownConverter.swift" \
  "$ROOT/Tests/DocumentExportRegression/main.swift"
"$BUILD_DIR/check" "$@"
