#!/bin/bash
# Assembles build/Tiri.app, ad-hoc signs it, and installs the tiri CLI to ~/.local/bin.
#   ./build.sh           release build
#   ./build.sh debug     debug build
# Ad-hoc signing gives each build a new identity, so macOS asks for folder access again after
# every rebuild. Set TIRI_SIGN_IDENTITY to a signing identity of yours to keep the answer.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product TiriApp
swift build -c "$CONFIG" --product tiri
swift build -c "$CONFIG" --product tiri-session
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Tiri.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/TiriApp" "$APP/Contents/MacOS/Tiri"
cp "$BIN_DIR/tiri" "$APP/Contents/Resources/bin/tiri"
cp "$BIN_DIR/tiri-session" "$APP/Contents/Resources/bin/tiri-session"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/textmate Resources/grammars "$APP/Contents/Resources/"
cp -R Resources/remote "$APP/Contents/Resources/remote"
cp -R Resources/web "$APP/Contents/Resources/web"

# Ad-hoc is enough to run locally and to ask for notifications.
IDENTITY="${TIRI_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Resources/bin/tiri"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Resources/bin/tiri-session"
codesign --force --sign "$IDENTITY" --timestamp=none --entitlements Resources/Tiri.entitlements "$APP"

mkdir -p "$HOME/.local/bin"
# Removed first: if Settings put a link here, copying would write into the app it points at.
rm -f "$HOME/.local/bin/tiri"
cp "$BIN_DIR/tiri" "$HOME/.local/bin/tiri"
codesign --force --sign - --timestamp=none "$HOME/.local/bin/tiri"

echo "Built $APP"
echo "Installed CLI to $HOME/.local/bin/tiri"
