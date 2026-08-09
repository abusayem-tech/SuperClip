#!/bin/bash
# Build SuperClip.app — self-contained menubar clipboard manager, no Xcode project.
#
#   ./build.sh            native arch only, fast — for local iteration
#   ./build.sh --universal arm64 + x86_64 — required if you'll share the app
set -euo pipefail

cd "$(dirname "$0")"

APP="SuperClip.app"
CONTENTS="$APP/Contents"
SOURCES=(
  SuperClip.swift
  Models.swift
  Theme.swift
  Format.swift
  Storage.swift
  PasteboardMonitor.swift
  Components.swift
  MenubarIcon.swift
  PanelController.swift
  PreferencesController.swift
)
VERSION="1.0"
UNIVERSAL=false
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=true

rm -rf "$APP" build-tmp
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" build-tmp

if $UNIVERSAL; then
  echo "Compiling universal (arm64 + x86_64)…"
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macosx13.0" \
      -o "build-tmp/SuperClip-$arch" "${SOURCES[@]}"
  done
  lipo -create -output "$CONTENTS/MacOS/SuperClip" \
    build-tmp/SuperClip-arm64 build-tmp/SuperClip-x86_64
else
  echo "Compiling ($(uname -m))…"
  swiftc -O -target "$(uname -m)-apple-macosx13.0" \
    -o "$CONTENTS/MacOS/SuperClip" "${SOURCES[@]}"
fi
rm -rf build-tmp

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SuperClip</string>
  <key>CFBundleDisplayName</key><string>SuperClip</string>
  <key>CFBundleIdentifier</key><string>dev.nasimulhasan.superclipbar</string>
  <key>CFBundleExecutable</key><string>SuperClip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>SuperClip</string>
  <!-- Menubar-only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp \
    --identifier dev.nasimulhasan.superclipbar \
    --sign "$IDENTITY" "$APP"
else
  echo "No Developer ID found — signing ad-hoc (recipients will see a Gatekeeper warning)."
  # A stable identifier keeps Control Center from treating each rebuild as a new
  # menu bar app, which would drop it from "Allow in the Menu Bar".
  codesign --force --identifier dev.nasimulhasan.superclipbar --sign - "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo
echo "Built $(pwd)/$APP  [$(lipo -archs "$CONTENTS/MacOS/SuperClip")]"
echo
echo "Next:"
echo "  open $APP"
echo "  Config (optional): ~/.config/superclip/config.json"
