#!/bin/bash
# Install SuperClip to /Applications, register it with macOS, add it to Login
# Items, and launch it.
#
# The app must be started through LaunchServices ("open"), not by executing the
# binary directly: a directly-executed binary gets an *ephemeral* status item,
# which never appears under System Settings > Control Center > Allow in the Menu Bar.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SuperClip"
APP="$APP_NAME.app"
DEST="/Applications/$APP"
BUNDLE_ID="dev.nasimulhasan.superclipbar"
LEGACY_AGENT="$HOME/Library/LaunchAgents/dev.nasimulhasan.superclip.plist"

echo "Building..."
./build.sh

# Earlier versions installed a LaunchAgent that exec'd the binary directly.
if [[ -f "$LEGACY_AGENT" ]]; then
  echo "Removing legacy LaunchAgent..."
  launchctl bootout "gui/$(id -u)/dev.nasimulhasan.superclip" 2>/dev/null || true
  rm -f "$LEGACY_AGENT"
fi

echo "Stopping any running copies..."
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
pkill -f "MacOS/$APP_NAME" 2>/dev/null || true
sleep 1

echo "Installing to ${DEST}..."
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

echo "Registering with LaunchServices..."
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$DEST" 2>/dev/null || true

echo "Adding to Login Items..."
osascript <<OSA 2>/dev/null || true
tell application "System Events"
  repeat with li in (every login item whose name is "$APP_NAME")
    delete li
  end repeat
  make login item at end with properties {path:"$DEST", hidden:false}
end tell
OSA

echo "Launching..."
open -a "$DEST"
sleep 4

if pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null; then
  echo
  echo "SuperClip is running:"
  pgrep -lf "$DEST/Contents/MacOS/$APP_NAME"
  echo
  echo 'Look for "Clip" in the menubar, near the clock.'
  echo "It is also listed under System Settings > Control Center > Allow in the Menu Bar."
else
  echo "ERROR: SuperClip did not stay running." >&2
  exit 1
fi
