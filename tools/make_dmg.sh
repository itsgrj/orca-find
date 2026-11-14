#!/bin/zsh
# Packs build/Orca Find.app into a shareable disk image: build/Orca-Find-<version>.dmg
# (the app + an Applications shortcut to drag it onto + a short "how to open" note).
# Run ./build.sh release first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Orca Find.app"
[[ -d "$APP" ]] || { echo "No $APP — run ./build.sh release first"; exit 1; }
VERSION="$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)"
DMG="build/Orca-Find-$VERSION.dmg"
STAGE="$(mktemp -d)/Orca Find"
mkdir -p "$STAGE"

ditto "$APP" "$STAGE/Orca Find.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open.txt" <<'EOF'
1. Drag Orca Find onto the Applications folder.
2. Open Orca Find from Applications.
3. If your Mac says it can't check the app for malicious software:
   open System Settings › Privacy & Security, scroll down, and click "Open Anyway" next to Orca Find.
   (Or right-click Orca Find › Open on older versions of macOS.)
You only need to do this once.

Needs macOS 14 or later on an Apple silicon Mac (M1 or newer).
EOF

rm -f "$DMG"
hdiutil create -volname "Orca Find" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
hdiutil verify "$DMG" >/dev/null && echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
