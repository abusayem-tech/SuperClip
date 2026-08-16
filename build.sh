#!/bin/bash
# Build SuperClip.app — self-contained menubar clipboard manager, no Xcode project.
#
#   ./build.sh            native arch only, fast — for local iteration
#   ./build.sh --universal arm64 + x86_64 — required if you'll share the app
set -euo pipefail

cd "$(dirname "$0")"

APP="build/SuperClip.app"
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
  SystemStats.swift
  PanelController.swift
  PreferencesController.swift
)
VERSION="1.0"
UNIVERSAL=false
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=true

rm -rf SuperClip.app "$APP" build-tmp
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" build-tmp
touch build/.metadata_never_index

python3 - "$CONTENTS/Resources" <<'PY'
import os, struct, zlib, sys
out_dir = sys.argv[1]

def png(path, w, h, rgba):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + rgba[y*w*4:(y+1)*w*4] for y in range(h))
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)

def draw(size):
    px = bytearray(size * size * 4)
    def setp(x, y, r, g, b, a=255):
        if 0 <= x < size and 0 <= y < size:
            i = (y * size + x) * 4
            px[i:i+4] = bytes((r, g, b, a))
    def fill(x0, y0, x1, y1, r, g, b, a=255):
        for y in range(y0, y1):
            for x in range(x0, x1):
                setp(x, y, r, g, b, a)
    s = size
    # teal rounded board
    m = max(2, s // 16)
    fill(s//6, s//5, s - s//6, s - s//8, 15, 118, 110)
    # clip
    fill(s//3, s//10, s - s//3, s//5 + m, 45, 212, 191)
    fill(s//3 + m, s//5 - m, s - s//3 - m, s//5 + 2*m, 15, 118, 110)
    return bytes(px)

src = "/tmp/superclip-appicon-1024.png"
png(src, 1024, 1024, draw(1024))
iconset = "/tmp/AppIcon.iconset"
os.makedirs(iconset, exist_ok=True)
sizes = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"),
         (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
         (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"),
         (1024, "icon_512x512@2x.png")]
for dim, name in sizes:
    png(os.path.join(iconset, name), dim, dim, draw(dim))
os.system(f'iconutil -c icns "{iconset}" -o "{os.path.join(out_dir, "AppIcon.icns")}"')
print("wrote AppIcon.icns")
PY

if $UNIVERSAL; then
  echo "Compiling universal (arm64 + x86_64)…"
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macosx13.0" \
      -framework IOKit \
      -o "build-tmp/SuperClip-$arch" "${SOURCES[@]}"
  done
  lipo -create -output "$CONTENTS/MacOS/SuperClip" \
    build-tmp/SuperClip-arm64 build-tmp/SuperClip-x86_64
else
  echo "Compiling ($(uname -m))…"
    swiftc -O -target "$(uname -m)-apple-macosx13.0" \
      -framework IOKit \
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
  <key>CFBundleIdentifier</key><string>dev.nasimulhasan.superclip.menu</string>
  <key>CFBundleExecutable</key><string>SuperClip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key><true/>
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
    --identifier dev.nasimulhasan.superclip.menu \
    --sign "$IDENTITY" "$APP"
else
  echo "No Developer ID found — signing ad-hoc (recipients will see a Gatekeeper warning)."
  # A stable identifier keeps Control Center from treating each rebuild as a new
  # menu bar app, which would drop it from "Allow in the Menu Bar".
  codesign --force --identifier dev.nasimulhasan.superclip.menu --sign - "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo
echo "Built $(pwd)/$APP  [$(lipo -archs "$CONTENTS/MacOS/SuperClip")]"
echo
echo "Next:"
echo "  ./install.sh"
echo "  Config (optional): ~/.config/superclip/config.json"
