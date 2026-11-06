#!/bin/bash
# Puts the release scripts/release.sh made onto tiri.build: the DMG for people, the zip and update.json for
# updates, and /download/Tiri.dmg pointing at the newest. Deploying makes it public, so it asks first.
#   scripts/publish-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE="build/release"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$RELEASE/Tiri.app/Contents/Info.plist")"
DMG="$RELEASE/Tiri-$VERSION.dmg"; ZIP="$RELEASE/Tiri-$VERSION.zip"; FEED="$RELEASE/update.json"
for file in "$DMG" "$ZIP" "$FEED"; do [ -f "$file" ] || { echo "No $file. Run scripts/release.sh first." >&2; exit 1; }; done
# What's going up has to be what Apple notarized.
xcrun stapler validate "$DMG" >/dev/null
spctl -a -t open --context context:primary-signature "$DMG"
grep -q "https://tiri.build/download/Tiri-$VERSION.zip" "$FEED" || { echo "update.json doesn't point at tiri.build/download/Tiri-$VERSION.zip." >&2; exit 1; }
# Cloudflare serves files up to 25 MiB.
for file in "$DMG" "$ZIP"; do [ "$(stat -f %z "$file")" -lt 26214400 ] || { echo "$file is over 25 MiB, too big for the site." >&2; exit 1; }; done

PUBLIC="site/public"
mkdir -p "$PUBLIC/download"
cp "$DMG" "$ZIP" "$PUBLIC/download/"
cp "$FEED" "$PUBLIC/update.json"
printf '/download/Tiri.dmg /download/Tiri-%s.dmg 302\n' "$VERSION" > "$PUBLIC/_redirects"
echo "Ready in $PUBLIC: Tiri $VERSION."
read -r -p "Deploy tiri.build now? This makes it public. [y/N] " answer
[ "$answer" = "y" ] || { echo "Not deployed."; exit 0; }
(cd site && npm run deploy)
