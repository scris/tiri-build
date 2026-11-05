#!/bin/bash
# Assembles build/Tiri.app, signs it, and installs the tiri CLI to ~/.local/bin.
#   ./build.sh           release build
#   ./build.sh debug     debug build
# Signed with a personal identity of your own, made the first time (scripts/personal-identity.sh), so macOS
# keeps its answer about folders across rebuilds. Set TIRI_SIGN_IDENTITY to use another of yours, like a Developer
# ID, or to - for ad-hoc. Either identity turns on the hardened runtime, so what you run is what a release runs.
# scripts/release.sh is the way to a notarized build. It sets the other two:
#   TIRI_BUILD_DIR    somewhere other than build/, so a running Tiri isn't deleted, with no CLI installed
#   TIRI_SIGN_TIMESTAMP=1    a secure timestamp, which notarization requires and which needs the network
# A copy made for someone's own Tiri (see Sources/TiriCore/YourTiriChanges.swift) sets TIRI_COPY=personal,
# TIRI_BUNDLE_ID, TIRI_RELEASE_COMMIT and TIRI_SIGN_KEYCHAIN too.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
source scripts/swift-setup.sh
swift build -c "$CONFIG" --product TiriApp
swift build -c "$CONFIG" --product tiri
swift build -c "$CONFIG" --product tiri-session
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

OUT="${TIRI_BUILD_DIR:-build}"
APP="$OUT/Tiri.app"
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/TiriApp" "$APP/Contents/MacOS/Tiri"
cp "$BIN_DIR/tiri" "$APP/Contents/Resources/bin/tiri"
cp "$BIN_DIR/tiri-session" "$APP/Contents/Resources/bin/tiri-session"
cp Resources/Info.plist "$APP/Contents/Info.plist"
scripts/stamp-bundle.sh "$APP" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
cp -R Resources/textmate Resources/grammars Resources/language-servers "$APP/Contents/Resources/"
cp -R Resources/remote "$APP/Contents/Resources/remote"
cp -R Resources/web "$APP/Contents/Resources/web"

IDENTITY="${TIRI_SIGN_IDENTITY:-}"
KEYCHAIN="${TIRI_SIGN_KEYCHAIN:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(scripts/personal-identity.sh)"
  KEYCHAIN="${TIRI_HOME:-$HOME/Library/Application Support/Tiri}/your-tiri/identity/personal.keychain-db"
fi
SIGN=(codesign --force --sign "$IDENTITY")
if [ -n "$KEYCHAIN" ]; then SIGN+=(--keychain "$KEYCHAIN"); fi
if [ "$IDENTITY" != "-" ]; then SIGN+=(--options runtime); fi
if [ "${TIRI_SIGN_TIMESTAMP:-}" = "1" ]; then SIGN+=(--timestamp); else SIGN+=(--timestamp=none); fi

# Inside out: every program in the bundle, then the bundle around them. The helpers that get copied
# to Mac servers count too, and notarization looks at those as well.
for program in "$APP/Contents/Resources/bin/tiri" "$APP/Contents/Resources/bin/tiri-session" \
               "$APP"/Contents/Resources/remote/tiri-remote-darwin-*; do
  "${SIGN[@]}" "$program"
done
"${SIGN[@]}" --entitlements Resources/Tiri.entitlements "$APP"

if [ -n "${TIRI_BUILD_DIR:-}" ]; then
  echo "Built $APP"
  exit 0
fi

mkdir -p "$HOME/.local/bin"
# Removed first: if Settings put a link here, copying would write into the app it points at.
rm -f "$HOME/.local/bin/tiri"
cp "$BIN_DIR/tiri" "$HOME/.local/bin/tiri"
codesign --force --sign - --timestamp=none "$HOME/.local/bin/tiri"

echo "Built $APP"
echo "Installed CLI to $HOME/.local/bin/tiri"
