#!/bin/bash
# Package SuperClip.app into a distributable .dmg.
#
#   ./package-dmg.sh
#
# Produces SuperClip-<version>.dmg containing the app and a shortcut to
# /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP="SuperClip.app"
VOLNAME="SuperClip"
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
DMG="SuperClip-$VERSION.dmg"
STAGING="dmg-staging"

echo "Building universal app…"
./build.sh --universal

echo
echo "Staging…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/READ ME FIRST.txt" <<'TXT'
SuperClip — menubar clipboard manager
=====================================

100% local. No accounts, no cloud, no network.

1. Drag "SuperClip" onto the Applications folder.

2. First launch may be blocked by Gatekeeper if the app isn't notarised:
     - Double-click it. macOS may refuse.
     - Open System Settings > Privacy & Security, scroll down, and click
       "Open Anyway" next to the SuperClip message.
   You only do this once.

3. Launch SuperClip. A clipboard icon appears in the menubar.
   Click for history; right-click for Clear / Preferences / Quit.

4. Optional config (created automatically on first launch):

     ~/.config/superclip/config.json

   chmod 600 that file if you edit it by hand.

5. Start at login:
   System Settings > General > Login Items > "+" > SuperClip

Requires macOS 13 or later. Works on Apple Silicon and Intel.
TXT

echo "Creating ${DMG}…"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  -fs HFS+ \
  "$DMG" >/dev/null

rm -rf "$STAGING"

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "Built $(pwd)/$DMG  ($SIZE)"
echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "Signed with a Developer ID. To remove the Gatekeeper warning entirely,"
  echo "notarise it — see README.md."
else
  echo "NOTE: ad-hoc signed build. Recipients must approve it once in"
  echo "      System Settings > Privacy & Security (steps are in the DMG)."
fi
