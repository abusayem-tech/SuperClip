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
APP="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
BUNDLE_ID="dev.nasimulhasan.superclip.menu"
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
# Drop the project-folder copy so Launchpad / Spotlight only show /Applications.
if [[ -d "$PWD/SuperClip.app" ]]; then
  "$LSREGISTER" -u "$PWD/SuperClip.app" 2>/dev/null || true
  rm -rf "$PWD/SuperClip.app"
fi
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

echo "Allowing the menu bar extra..."
defaults write com.apple.controlcenter "NSStatusItem Visible SuperClip" -bool true
defaults write com.apple.controlcenter "NSStatusItem VisibleCC SuperClip" -bool true
defaults write com.apple.controlcenter "NSStatusItem Preferred Position SuperClip" -float 70
defaults write "$BUNDLE_ID" "NSStatusItem Visible SuperClip" -bool true
defaults write "$BUNDLE_ID" "NSStatusItem VisibleCC SuperClip" -bool true
defaults write -g "NSStatusItem Visible SuperClip" -bool true
defaults write -g "NSStatusItem VisibleCC SuperClip" -bool true
killall ControlCenter 2>/dev/null || true

echo "Installing KeepAlive LaunchAgent..."
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/${BUNDLE_ID}.plist"
mkdir -p "$AGENT_DIR"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-W</string>
    <string>-a</string>
    <string>$DEST</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || launchctl load "$AGENT_PLIST" 2>/dev/null || true

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
