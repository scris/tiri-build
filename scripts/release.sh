#!/bin/bash
# A notarized build of Tiri, in build/release, that opens anywhere with no warning:
#   Tiri-<version>.dmg    to drag into Applications
#   Tiri-<version>.zip    what the update feed points at
#   update.json           the feed's entry for that zip, at TIRI_DOWNLOAD_BASE
#   scripts/release.sh
# Needs a Developer ID Application certificate, and notary credentials saved once with:
#   xcrun notarytool store-credentials tiri-notary --apple-id <you> --team-id <team>
# Doesn't touch a running Tiri or the installed CLI, and publishes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

# TIRI_RELEASE_NOTES=<file> says what's new and what code moved. It's signed into the app, for repairs to read.
# TIRI_BUNDLE_ID=<id> makes a test release that macOS treats as another app, such as dev.tiri.test.update.
IDENTITY="${TIRI_RELEASE_IDENTITY:-Developer ID Application: Tianrun Qiu (CXA8L7KWZG)}"
PROFILE="${TIRI_NOTARY_PROFILE:-tiri-notary}"
OUT="build/release"
APP="$OUT/Tiri.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="$OUT/Tiri-$VERSION.zip"
DMG="$OUT/Tiri-$VERSION.dmg"
# The feed the app will look at, and where the zip is going to be put, for update.json. Nothing is uploaded.
FEED="${TIRI_UPDATE_FEED:-https://tiri.build/update.json}"
BASE="${TIRI_DOWNLOAD_BASE:-https://tiri.build/download}"

# Before minutes of building: is everything here?
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || { echo "No signing identity \"$IDENTITY\" in the keychain." >&2; exit 1; }
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notary credentials saved as \"$PROFILE\". Save them with:" >&2
  echo "  xcrun notarytool store-credentials $PROFILE --apple-id <you> --team-id <team>" >&2
  exit 1
fi

# What's built is what ships, source included, so nothing stray comes along with it.
if [ -n "$(git status --porcelain)" ]; then echo "There are uncommitted files. A release's source is what's in the repository." >&2; exit 1; fi

# What has to stay true of every release: people's own changes still go on it, and it builds with free tools.
scripts/replay-corpus.sh
scripts/check-free-tools.sh

rm -rf "$OUT"
TIRI_BUILD_DIR="$OUT" TIRI_SIGN_IDENTITY="$IDENTITY" TIRI_SIGN_TIMESTAMP=1 TIRI_UPDATE_FEED="$FEED" ./build.sh release

# What notarization would refuse, found here rather than after an upload.
codesign --verify --deep --strict --verbose=1 "$APP"
find "$APP" -type f -print0 | while IFS= read -r -d '' file; do
  case "$(file -b "$file")" in
    Mach-O*)
      details="$(codesign -dvv "$file" 2>&1)" || { echo "Not signed: $file" >&2; exit 1; }
      grep -q 'flags=.*runtime' <<<"$details" || { echo "No hardened runtime: $file" >&2; exit 1; }
      grep -q '^Timestamp=' <<<"$details" || { echo "No secure timestamp: $file" >&2; exit 1; }
      ;;
  esac
done
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then echo "A debugging entitlement is in there." >&2; exit 1; fi

# The disk image people download: the app beside a link to Applications. It's the one thing sent to Apple,
# and its ticket covers the app inside as well.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tiri-dmg.XXXXXX")"
trap 'rm -rf "${STAGE:?}"' EXIT
ditto "$APP" "$STAGE/Tiri.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Tiri -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "Sending $(basename "$DMG") to Apple. This usually takes a few minutes."
SUBMISSION="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format plist)"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print status' /dev/stdin <<<"$SUBMISSION")"
ID="$(/usr/libexec/PlistBuddy -c 'Print id' /dev/stdin <<<"$SUBMISSION")"
if [ "$STATUS" != "Accepted" ]; then
  echo "Apple said: $STATUS" >&2
  xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2
  exit 1
fi

# Tickets on both, so they open with no network too. The app's is the one the disk image's covered:
# it's the same app, so the zip for updates needs no second submission.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

# The feed's entry for this zip, once it's been put at $BASE. Publishing it is a separate step.
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
printf '{\n  "version": "%s",\n  "url": "%s/%s",\n  "sha256": "%s"\n}\n' "$VERSION" "${BASE%/}" "$(basename "$ZIP")" "$SHA" > "$OUT/update.json"
echo "Notarized: $DMG ($(du -h "$DMG" | cut -f1)) and $ZIP ($(du -h "$ZIP" | cut -f1)), with $OUT/update.json, submission $ID"
