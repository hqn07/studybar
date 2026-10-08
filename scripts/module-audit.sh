#!/usr/bin/env bash
# Render every module of the window — three widths, dark and light — plus each module on an
# empty store and the menu-bar popover, into <out-dir> with an index.html to look through.
#
#   scripts/module-audit.sh <out-dir>
#
# Run it before a release: two layout bugs reached the user first because nothing looked at
# every screen at every width. It renders from a copy of the Debug build with its own bundle id
# (its own preferences) and a throwaway data folder, because rendering the window writes
# preferences and the Debug build otherwise shares the installed app's.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: scripts/module-audit.sh <out-dir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

./scripts/build.sh >/dev/null

APP="${TMPDIR%/}/StudyBarAudit.app"
rm -rf "$APP"
cp -R .build/Build/Products/Debug/StudyBar.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.studybar.StudyBar.test" "$APP/Contents/Info.plist"

# The same identity build.sh signs with; SB_SIGN_ID=- forces ad-hoc.
SIGN_ID="${SB_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --deep --sign "${SIGN_ID:--}" "$APP" 2>/dev/null

DATA="$(mktemp -d)"
trap 'rm -rf "$DATA"' EXIT

set +e
STUDYBAR_DATA_DIR="$DATA" "$APP/Contents/MacOS/StudyBar" --module-audit "$OUT"
status=$?
set -e

echo "$(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') PNGs in $OUT"
exit $status
