#!/usr/bin/env bash
# Build StudyBar.app (Debug by default; pass "release" for Release).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Debug"
[ "${1:-}" = "release" ] && CONFIG="Release"

command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate

xcodebuild -project StudyBar.xcodeproj -scheme StudyBar \
  -configuration "$CONFIG" -derivedDataPath .build build

APP=$(find .build/Build/Products -name "StudyBar.app" -type d | head -1)
echo "Built: $APP"
