#!/usr/bin/env bash
# Time switching to each module — a Release build, offscreen, from a test copy (own bundle id,
# throwaway data folder). Run it before a release: Notes once took ~450 ms to open on a real
# term of lecture notes and nothing measured it.
#
#   scripts/switch-bench.sh                  # on the module audit's seeded term
#   scripts/switch-bench.sh path/to/data.json  # on a copy of a real store (deleted afterwards)
#   SWITCH_LOOP=notes,convert scripts/switch-bench.sh …   # switch back and forth for 15 s, for
#                                                         # `sample <pid>` to profile
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh release >/dev/null

APP="${TMPDIR%/}/StudyBarBench.app"
rm -rf "$APP"
cp -R .build/Build/Products/Release/StudyBar.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.studybar.StudyBar.test" "$APP/Contents/Info.plist"
SIGN_ID="${SB_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --deep --sign "${SIGN_ID:--}" "$APP" 2>/dev/null

DATA="$(mktemp -d)"
trap 'rm -rf "$DATA"' EXIT
SEED=1
if [ -n "${1:-}" ]; then cp "$1" "$DATA/data.json"; SEED=0; fi

STUDYBAR_DATA_DIR="$DATA" SWITCH_SEED="$SEED" SWITCH_LOOP="${SWITCH_LOOP:-}" "$APP/Contents/MacOS/StudyBar" --switch-bench
