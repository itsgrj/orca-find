#!/bin/zsh
# Ships a new version of Orca Find to everyone who has it.
#
#   1. Bump CFBundleShortVersionString (e.g. 1.2.0) and CFBundleVersion (+1) in Resources/Info.plist.
#   2. Write what got better, in plain words, in Resources/WhatsNew.json (same version number).
#   3. tools/release.sh            → builds and signs build/Orca-Find.zip, the DMG and build/appcast.xml
#      tools/release.sh --publish  → also creates the GitHub release with all three attached
#
# Every installed Orca reads https://github.com/itsgrj/orca-find/releases/latest/download/appcast.xml once
# a day, so publishing the release *is* pushing the update. The zip is signed with Orca's update key
# (login keychain, account "orca-find"; back it up with
# .build/artifacts/sparkle/Sparkle/bin/generate_keys --account orca-find -x orca-update-key.txt).
# Without that key, no installed copy will ever accept another update.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="itsgrj/orca-find"
SPARKLE=".build/artifacts/sparkle/Sparkle/bin"
PLIST="Resources/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
MINOS="$(plutil -extract LSMinimumSystemVersion raw "$PLIST")"
NOTES_VERSION="$(python3 -c 'import json;print(json.load(open("Resources/WhatsNew.json"))["version"])')"
[[ "$NOTES_VERSION" == "$VERSION" ]] || { echo "Resources/WhatsNew.json is for $NOTES_VERSION but the app is $VERSION"; exit 1; }
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 && [[ "${1:-}" == "--publish" ]]; then
  echo "v$VERSION is already on GitHub. Bump the version first."; exit 1
fi

./build.sh release
SIGNER="$(codesign -dvv "build/Orca Find.app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ -n "$SIGNER" ]] || { echo "The app is only ad-hoc signed. Run tools/make_signing_cert.sh first, so people keep their permissions after updating."; exit 1; }
./tools/make_dmg.sh

ZIP="build/Orca-Find.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "build/Orca Find.app" "$ZIP"
SIG="$("$SPARKLE/sign_update" --account orca-find "$ZIP")"   # sparkle:edSignature="…" length="…"

URL="${ORCA_RELEASE_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$VERSION}/Orca-Find.zip"
VERSION="$VERSION" BUILD="$BUILD" MINOS="$MINOS" SIG="$SIG" URL="$URL" REPO="$REPO" python3 - <<'PY'
import json, os, html
from email.utils import formatdate
v, notes = os.environ["VERSION"], json.load(open("Resources/WhatsNew.json"))["notes"]
items = "\n".join(
    f'        <li data-symbol="{html.escape(n["symbol"])}"><b>{html.escape(n["title"])}</b> — {html.escape(n["detail"])}</li>'
    for n in notes)
appcast = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Orca Find</title>
    <link>https://github.com/{os.environ["REPO"]}/releases</link>
    <item>
      <title>Orca Find {v}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{os.environ["BUILD"]}</sparkle:version>
      <sparkle:shortVersionString>{v}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{os.environ["MINOS"]}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <description><![CDATA[
      <ul>
{items}
      </ul>
      ]]></description>
      <enclosure url="{os.environ["URL"]}" {os.environ["SIG"]} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
'''
open("build/appcast.xml", "w").write(appcast)
md = "\n".join(f'- **{n["title"]}.** {n["detail"]}' for n in notes)
md += "\n\n**New here?** Download **Orca-Find-%s.dmg**, open it and drag Orca Find into Applications.\n" % v
md += "**Already have Orca?** It updates itself. Open the menu bar list or the Update button in the window.\n"
open("build/release-notes.md", "w").write(md)
PY
echo "✓ build/appcast.xml, $ZIP, build/Orca-Find-$VERSION.dmg"

if [[ "${1:-}" == "--publish" ]]; then
  # Draft first, then each file (a retried upload replaces instead of failing), then go live — so a slow
  # upload never leaves a half-published release that installed copies would try to read.
  gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 || \
    gh release create "v$VERSION" -R "$REPO" --draft --title "Orca Find $VERSION" --notes-file build/release-notes.md --target main
  for f in build/appcast.xml "$ZIP" "build/Orca-Find-$VERSION.dmg"; do
    for try in 1 2 3; do gh release upload "v$VERSION" -R "$REPO" "$f" --clobber && break; sleep 5; done
  done
  LEN="$(gh release view "v$VERSION" -R "$REPO" --json assets -q '.assets[] | select(.name=="Orca-Find.zip") | .size')"
  [[ "$LEN" == "$(stat -f %z "$ZIP")" ]] || { echo "Uploaded zip size ($LEN) doesn't match; release left as a draft."; exit 1; }
  gh release edit "v$VERSION" -R "$REPO" --draft=false --latest
  echo "✓ Published. Every Orca checks within a day; the new version goes in when people quit Orca."
else
  echo "Nothing published. Run again with --publish to put v$VERSION on GitHub."
fi
