#!/usr/bin/env bash
# Package StudyBar.app into a distributable .dmg and emit a Homebrew Cask stub.
# NOTE: for frictionless installs you must codesign + notarize (needs an Apple
# Developer ID). Unsigned builds run after right-click > Open, or:
#   xattr -dr com.apple.quarantine /Applications/StudyBar.app
set -euo pipefail
cd "$(dirname "$0")/.."

DIST="dist"
rm -rf "$DIST"; mkdir -p "$DIST"

./scripts/build.sh release
APP=$(find .build/Build/Products -name "StudyBar.app" -type d | head -1)

# Single source of truth: MARKETING_VERSION (project.yml) → built app's
# CFBundleShortVersionString via $(MARKETING_VERSION). Read it from the built
# app so the .dmg name and cask version always match what shipped.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP/Contents/Info.plist")

# Staging folder with an Applications symlink for drag-install.
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/StudyBar-$VERSION.dmg"
hdiutil create -volname "StudyBar" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "DMG:  $DMG"
echo "SHA256: $SHA"

# Homebrew Cask — copy to a tap (hqn07/homebrew-studybar) as Casks/studybar.rb
# after the release .dmg is uploaded.
cat > "$DIST/studybar.rb" <<EOF
cask "studybar" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/hqn07/studybar/releases/download/v#{version}/StudyBar-#{version}.dmg"
  name "StudyBar"
  desc "Free menu bar study companion"
  homepage "https://github.com/hqn07/studybar"

  app "StudyBar.app"

  zap trash: [
    "~/Library/Application Support/StudyBar",
  ]
end
EOF
echo "Cask: $DIST/studybar.rb  (host in tap hqn07/homebrew-studybar as Casks/studybar.rb)"
