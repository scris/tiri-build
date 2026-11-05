#!/bin/bash
# Compiles Resources/AppIcon.icon, the layered source you can open in Icon Composer, into the
# Resources/Assets.car and Resources/AppIcon.icns that go in the app. Run it after changing the icon.
# They're committed so that an ordinary build doesn't need actool, which only comes with Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# actool wants absolute paths.
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$TMP" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$TMP/partial.plist" --output-format human-readable-text >/dev/null
cp "$TMP/Assets.car" "$TMP/AppIcon.icns" "$ROOT/Resources/"
echo "Compiled Resources/Assets.car and Resources/AppIcon.icns"
