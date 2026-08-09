# SuperClip — macOS menubar clipboard manager

Searchable local history of everything you copy — text, URLs, rich text, images,
and Finder file paths — for 30 days. Menubar-only, fully offline, free.

```
📋  hello world…                 ← menubar icon (+ optional preview / count)
┌──────────────────────────────────────┐
│ 🔍 Search clipboard                  │
│ [All][Text][Image][URL][Files][Pinned]│
│ ┌──────────────────────────────────┐ │
│ │ 🖼  screenshot.png    2m ago  ☆  │ │
│ │ 🔗  https://example.com  1h ago  │ │
│ │ ¶   meeting notes…   Yesterday   │ │
│ └──────────────────────────────────┘ │
│ 12 items              Clear History… │
└──────────────────────────────────────┘
```

**Privacy:** 100% local. No network calls, no accounts, no analytics, no iCloud.
History lives under `~/Library/Application Support/SuperClip/`.

## Install

```bash
./install.sh
```

This builds, copies to `/Applications/SuperClip.app`, registers a LaunchAgent
(start at login + keep alive), and launches the app.

Or manually:

```bash
./build.sh
open SuperClip.app
```

Move the `.app` anywhere you like — `/Applications` is fine.

### Config (optional)

Created automatically on first launch at `~/.config/superclip/config.json`:

```json
{
  "retentionDays": 30,
  "maxStorageMB": 500,
  "excludeApps": [],
  "menubarMode": "lastText",
  "pollIntervalMs": 500,
  "mergeTextWindowMs": 1500
}
```

```bash
chmod 600 ~/.config/superclip/config.json
```

Override path with `SUPERCLIP_CONFIG=/tmp/test.json`.

| Key | Meaning |
|---|---|
| `retentionDays` | Auto-delete unpinned non-snippet items older than this |
| `maxStorageMB` | Cap on DB + images; oldest unpinned items dropped first |
| `excludeApps` | Bundle IDs whose copies are ignored (e.g. `com.1password.1password`) |
| `menubarMode` | `iconOnly` · `lastText` · `count` |
| `pollIntervalMs` | Pasteboard poll interval (default 500) |
| `mergeTextWindowMs` | Merge same-app text bursts (0 disables) |

## Start at login

System Settings → General → Login Items → **+** → pick `SuperClip.app`.

Or:

```bash
osascript -e 'tell application "System Events" to make login item at end \
  with properties {path:"/Applications/SuperClip.app", hidden:true}'
```

## Behaviour

- Watches `NSPasteboard.general` via `changeCount` (≈0.5s, energy-tolerant).
- Stores text, URLs, RTF/HTML, images (PNG on disk), and Finder file paths.
- Dedupes consecutive identical copies; merges short same-app text bursts.
- Click a row (or ↑↓ + Enter) to copy it back; Esc closes the panel.
- ⌘F focuses search. Right-click a row for Copy as… / Pin / Save as Snippet / Delete.
- Drag rows into other apps.
- **Clear History…** keeps pins & snippets, deletes the rest, clears the system
  pasteboard, deletes image files, and `VACUUM`s the DB so disk is freed.
- **Clear Everything…** wipes pins/snippets too.

## Storage locations

| Path | Contents |
|---|---|
| `~/Library/Application Support/SuperClip/history.db` | Local index |
| `~/Library/Application Support/SuperClip/images/` | PNG blobs |
| `~/.config/superclip/config.json` | Preferences (`chmod 600`) |

Right-click the menubar icon → **Open Storage Folder**.

## Preferences

Right-click → **Preferences…** (or `,` from the context menu):

- Retention, max storage, exclude apps, merge window, menubar mode
- Storage health: used space, item/image counts, progress vs cap
- Purge expired / Clear History / Clear Everything

## Debug launch

```bash
./SuperClip.app/Contents/MacOS/SuperClip
SUPERCLIP_CONFIG=/tmp/superclip.json ./SuperClip.app/Contents/MacOS/SuperClip
```

## Share as DMG

```bash
./package-dmg.sh
```

Builds a universal binary and packs `SuperClip-<version>.dmg`.

### Gatekeeper / notarisation

Ad-hoc builds need **Open Anyway** once under Privacy & Security. With a
Developer ID, `build.sh` signs automatically. To notarise:

```bash
xcrun notarytool submit SuperClip-1.0.dmg --keychain-profile "notary" --wait
xcrun stapler staple SuperClip-1.0.dmg
```

## Troubleshooting

| Issue | Fix |
|---|---|
| No menubar icon | Look for **Clip** text near the clock. On macOS 26+ it may be in the menu bar **overflow** (chevron/arrow near Control Center) — drag it out if needed. Run `./install.sh` to reinstall with KeepAlive. |
| App won’t open | System Settings → Privacy & Security → Open Anyway |
| History empty | Copy something after launch; check excludeApps isn’t too broad |
| Disk growing | Lower `maxStorageMB`, shorten retention, or Clear History |
| Images not captured | Some apps put only proprietary types — try Copy again from Preview/Safari |

## Requirements

macOS 13+, Apple Silicon or Intel. No Xcode project, no dependencies — `swiftc` only.
