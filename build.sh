#!/bin/zsh
# Builds "Orca Find.app" into ./build. Usage: ./build.sh [debug|release] [--open]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Orca Find.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" 2>&1 | grep -E "error|Compiling|Build complete" | grep -v "^warning" || true
BIN=".build/$CONFIG/OrcaFind"
[[ -x "$BIN" ]] || { echo "Build failed"; exit 1; }

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ Drawing app icon…"
  TMP=$(mktemp -d)
  swift tools/make_icon.swift "$TMP/icon_1024.png" >/dev/null
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OrcaFind"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Fonts Resources/Backgrounds "$APP/Contents/Resources/"
# MobileCLIP-S2 (~190 MB) for describing pictures; fetched + compiled once by tools/fetch_mobileclip.sh.
[[ -d Resources/Models/mobileclip_s2_text.mlmodelc ]] || ./tools/fetch_mobileclip.sh
cp -R Resources/Models "$APP/Contents/Resources/"
printf "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify "$APP" && echo "✓ Built $APP"

if [[ "${2:-}" == "--open" ]]; then
  pkill -x OrcaFind 2>/dev/null || true
  open "$APP"
fi
