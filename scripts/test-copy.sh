#!/usr/bin/env bash
# Run the app with any flag from a test copy — its own bundle id (own preferences) and a
# throwaway data folder — never from the Debug build itself.
#
#   scripts/test-copy.sh --design-selftest
#   scripts/test-copy.sh --module-audit <out-dir>
#
# The Debug build shares the installed app's bundle id, and the app builds its state (which
# reads the data file and writes preferences) before it looks at any flag. Run from the Debug
# build, even a "pure" self-test rewrote the installed app's sidebar order.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh >/dev/null

APP="${TMPDIR%/}/StudyBarTestCopy.app"
rm -rf "$APP"
cp -R .build/Build/Products/Debug/StudyBar.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.studybar.StudyBar.test" "$APP/Contents/Info.plist"

# The same identity build.sh signs with; SB_SIGN_ID=- forces ad-hoc.
SIGN_ID="${SB_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --deep --sign "${SIGN_ID:--}" "$APP" 2>/dev/null

DATA="$(mktemp -d)"
trap 'rm -rf "$DATA"' EXIT

STUDYBAR_DATA_DIR="$DATA" "$APP/Contents/MacOS/StudyBar" "$@"
