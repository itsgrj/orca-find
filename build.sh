#!/bin/zsh
# Builds "Orca Find.app" into ./build. Usage: ./build.sh [debug|release] [--open]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Orca Find.app"

echo "▸ Compiling ($CONFIG)…"
# -emit-const-values: the compiler writes down the App Intents (Shortcuts, Siri) so appintentsmetadataprocessor
# can describe them to macOS below. Xcode does this by itself; SwiftPM needs to be asked.
swift build -c "$CONFIG" -Xswiftc -emit-const-values \
  -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PWD/tools/appintents-protocols.json" \
  2>&1 | grep -E "error|Compiling|Build complete" | grep -v "^warning" || true
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
# SwiftPM leaves an rpath into this Mac's Xcode; on other Macs it doesn't exist (dyld and XProtect probe it).
for rp in $(otool -l "$APP/Contents/MacOS/OrcaFind" | awk '/LC_RPATH/{getline;getline;print $2}' | grep '^/Applications/Xcode' || true); do
  install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/OrcaFind" 2>/dev/null || true
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
cp -R Resources/Fonts Resources/Backgrounds "$APP/Contents/Resources/"
# About › credits (licence credit for the optional speech model).
cp Resources/Credits.rtf "$APP/Contents/Resources/"
# The notes for this version: the welcome-back card after an update (Services/Updater.swift).
cp Resources/WhatsNew.json "$APP/Contents/Resources/"
# In-app updates (Sparkle). Orca isn't sandboxed, so Sparkle's XPC helpers aren't needed.
mkdir -p "$APP/Contents/Frameworks"
cp -R ".build/$CONFIG/Sparkle.framework" "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
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

# Shortcuts & Siri: Metadata.appintents tells macOS about Orca's actions (Services/Intents.swift).
# Without it the actions exist in the code but never show up in the Shortcuts app.
echo "▸ Shortcuts actions…"
META_TMP="$(mktemp -d)"
find "$PWD/Sources/OrcaFind" -name "*.swift" > "$META_TMP/sources.txt"
find "$PWD/.build" -name "*.swiftconstvalues" -path "*OrcaFind*" -newer "$PWD/Package.swift" 2>/dev/null | grep -v OrcaFindTests > "$META_TMP/constvals.txt" || true
if [[ -s "$META_TMP/constvals.txt" ]] && xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")" \
    --module-name OrcaFind --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')" \
    --platform-family macOS --deployment-target 14.0 --bundle-identifier "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)" \
    --target-triple "$ARCH-apple-macos14.0" --binary-file "$APP/Contents/MacOS/OrcaFind" \
    --source-file-list "$META_TMP/sources.txt" --swift-const-vals-list "$META_TMP/constvals.txt" --force >/dev/null 2>&1 \
    || echo "  (couldn't describe the Shortcuts actions; the app still works)"
else
  echo "  (skipped: needs Xcode's appintentsmetadataprocessor)"
fi
rm -rf "$META_TMP"

# "Orca" in every Share menu: a tiny sandboxed extension that hands what was shared to the app
# (Extensions/OrcaShare). SwiftPM can't build app extensions, so it's compiled here.
echo "▸ Share menu extension…"
EXT="$APP/Contents/PlugIns/OrcaShare.appex"
mkdir -p "$EXT/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -module-name OrcaShare Extensions/OrcaShare/ShareViewController.swift \
  -o "$EXT/Contents/MacOS/OrcaShare" -Xlinker -e -Xlinker _NSExtensionMain -framework Cocoa \
  -target "$(uname -m)-apple-macos14.0" 2>&1 | grep -E "error" || true
[[ -x "$EXT/Contents/MacOS/OrcaShare" ]] || { echo "Share extension failed to build"; exit 1; }
cp Extensions/OrcaShare/Info.plist "$EXT/Contents/Info.plist"

# Sign with Orca's own Apple identity when the keychain has one, so macOS sees every build as the same app
# and keeps the permissions you gave it (Screen Recording, Microphone…). An ad-hoc signature changes with
# every build, which silently drops them. "Developer ID Application" is what ships to customers;
# "Apple Development" is the free one Xcode makes for testing. Override with ORCA_SIGN_IDENTITY.
IDS="$(security find-identity -v -p codesigning 2>/dev/null)"
IDENTITY="${ORCA_SIGN_IDENTITY:-$(echo "$IDS" | { grep -o '"Developer ID Application: [^"]*"' || true; } | head -1 | tr -d '"')}"
# "Orca Find Signing" is Orca's own free certificate (tools/make_signing_cert.sh): same identity on every
# build and every update, so macOS keeps the permissions people gave Orca after it updates itself.
IDENTITY="${IDENTITY:-$(echo "$IDS" | { grep -o '"Orca Find Signing"' || true; } | head -1 | tr -d '"')}"
IDENTITY="${IDENTITY:-$(echo "$IDS" | { grep -o '"Apple Development: [^"]*"' || true; } | head -1 | tr -d '"')}"
IDENTITY="${IDENTITY:--}"
echo "▸ Signing (${IDENTITY/#-/ad-hoc})…"
# The extension first, with its sandbox entitlement (macOS only loads sandboxed extensions); then the app.
# Not --deep: that would re-sign the extension without its entitlement.
codesign --force --sign "$IDENTITY" --entitlements Extensions/OrcaShare/OrcaShare.entitlements "$EXT" >/dev/null 2>&1
# Sparkle's helpers (inside out), then the framework itself.
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" "$FW/Versions/B/Autoupdate" >/dev/null 2>&1
codesign --force --sign "$IDENTITY" "$FW/Versions/B/Updater.app" >/dev/null 2>&1
codesign --force --sign "$IDENTITY" "$FW" >/dev/null 2>&1
codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1
codesign --verify --deep "$APP" && echo "✓ Built $APP"
# Tell macOS about this copy so its Share menu entry points here.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
pluginkit -a "$EXT" >/dev/null 2>&1 || true

if [[ "${2:-}" == "--open" ]]; then
  # Only this copy: other Orca processes (e.g. snapshot renders from another folder) keep running.
  pkill -f "$PWD/$APP/Contents/MacOS/OrcaFind" 2>/dev/null || true
  open "$APP"
fi
