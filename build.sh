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

if [[ ! -f Resources/AppIcon.icns || ! -f Resources/MenuBarIcon.png ]]; then
  echo "▸ Drawing app icon…"
  python3 tools/icon/make_icon.py >/dev/null
fi

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OrcaFind"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
cp -R Resources/Fonts Resources/Backgrounds "$APP/Contents/Resources/"
# About › credits (licence credit for the optional speech model).
cp Resources/Credits.rtf "$APP/Contents/Resources/"
# MobileCLIP-S2 (~190 MB) for describing pictures; fetched + compiled once by tools/fetch_mobileclip.sh
# (the app downloads its own copy; this one is for running from .build and for the tokenizer files).
[[ -d Resources/Models/mobileclip_s2_text.mlmodelc ]] || ./tools/fetch_mobileclip.sh
# The two "Erase an object" models (LaMa ~200 MB, MI-GAN ~27 MB); fetched once by tools/fetch_eraser.sh.
# Only MI-GAN (the quick eraser) is bundled; LaMa is the downloadable Pro eraser.
[[ -d Resources/Models/LaMa.mlmodelc && -d Resources/Models/MIGAN.mlmodelc ]] || ./tools/fetch_eraser.sh
# Only small models ship inside the app. The big ones (picture understanding, Pro eraser, voice)
# are "Orca's private AI": downloaded once from inside the app (Services/PrivateAI.swift).
mkdir -p "$APP/Contents/Resources/Models"
for f in MIGAN.mlmodelc clip-vocab.json clip-merges.txt LICENSE_MODELS.txt LICENSE_LAMA.txt LICENSE_MIGAN.txt; do
  if [[ -e "Resources/Models/$f" ]]; then cp -R "Resources/Models/$f" "$APP/Contents/Resources/Models/"; fi
done
printf "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify "$APP" && echo "✓ Built $APP"

if [[ "${2:-}" == "--open" ]]; then
  pkill -x OrcaFind 2>/dev/null || true
  open "$APP"
fi
