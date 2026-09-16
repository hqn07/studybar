#!/usr/bin/env bash
# Build then (re)launch StudyBar.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh "${1:-}"
pkill -f "StudyBar.app/Contents/MacOS/StudyBar" 2>/dev/null || true
sleep 0.5
CONFIG="Debug"
[ "${1:-}" = "release" ] && CONFIG="Release"
APP=".build/Build/Products/$CONFIG/StudyBar.app"   # not `find | head -1`: it could pick the other config
# Keep the installed copy in /Applications fresh so Spotlight/Launchpad open the latest.
rm -rf /Applications/StudyBar.app
cp -R "$APP" /Applications/StudyBar.app
open -a /Applications/StudyBar.app
echo "Launched /Applications/StudyBar.app — graduation-cap icon in your menu bar."
