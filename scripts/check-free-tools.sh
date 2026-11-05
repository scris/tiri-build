#!/bin/bash
# Does Tiri still build with Apple's free Command Line Tools? It stops as soon as someone uses an Apple macro whose
# plugin ships only inside Xcode, and that's the first thing a person changing Tiri would run into.
#   scripts/check-free-tools.sh
# Builds in a temporary copy, from what git would keep. Touches nothing in this checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - 2>/dev/null | tar -xf - -C "$WORK"
cd "$WORK"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source scripts/swift-setup.sh
swift build -c debug --product TiriApp 2>&1 | grep -E 'error:|Compiling TiriApp|Build complete' | tail -5
swift build -c debug --product TiriApp >/dev/null 2>&1 || { echo "It doesn't build with the Command Line Tools." >&2; exit 1; }
echo "Builds with the Command Line Tools, against $(basename "$SDKROOT")."
