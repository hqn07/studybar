#!/usr/bin/env bash
# Build StudyBar.app (Debug by default; pass "release" for Release).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Debug"
[ "${1:-}" = "release" ] && CONFIG="Release"

command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate

# Sign dev builds with a real identity when one exists.
#
# project.yml pins CODE_SIGN_IDENTITY to "-" (ad-hoc), which is right for the release CI: it
# ships unsigned on purpose. Locally it is expensive. An ad-hoc signature is a fresh identity
# on every build, and macOS keys privacy grants — Microphone, Speech Recognition, Screen
# Recording — and Keychain ACLs to the signature. So each ./scripts/run.sh silently revoked
# them: the app then showed "access off" with the grant still ticked in System Settings,
# because the tick belonged to the previous build. A stable identity survives rebuilds.
#
# Hardened runtime is off for these builds deliberately: with it on, a signed app needs an
# entitlement per protected resource, which is packaging work the dev loop does not need.
# Override the identity with SB_SIGN_ID, or SB_SIGN_ID=- to force ad-hoc.
SIGN_ID="${SB_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"

SIGN_ARGS=()
if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  echo "Signing as: $SIGN_ID"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_ID" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO)
else
  echo "Ad-hoc signing — macOS will ask for Microphone/Speech/Keychain access again after each install."
fi

xcodebuild -project StudyBar.xcodeproj -scheme StudyBar \
  -configuration "$CONFIG" -derivedDataPath .build "${SIGN_ARGS[@]}" build

APP=$(find .build/Build/Products -name "StudyBar.app" -type d | head -1)
echo "Built: $APP"
