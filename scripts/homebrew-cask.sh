#!/bin/bash
# The Homebrew cask for the release scripts/release.sh made, so `brew tap tiri-build/tap` and then
# `brew install --cask tiri-build/tap/tiri` work. Homebrew 6 won't tap a third-party tap by itself.
# The cask lives in its own repository, tiri-build/homebrew-tap, because Homebrew finds `tiri-build/tap` there.
# It downloads from tiri.build, so a brew install is counted like any other (see site/src/worker.js).
#   scripts/homebrew-cask.sh            prints the cask
#   scripts/homebrew-cask.sh --publish  commits it to tiri-build/homebrew-tap as Casks/tiri.rb; that makes it public
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE="build/release"
TAP="tiri-build/homebrew-tap"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$RELEASE/Tiri.app/Contents/Info.plist")"
DMG="$RELEASE/Tiri-$VERSION.dmg"
[ -f "$DMG" ] || { echo "No $DMG. Run scripts/release.sh first." >&2; exit 1; }
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

cask() {
  cat <<EOF
cask "tiri" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://tiri.build/download/Tiri-#{version}.dmg"
  name "Tiri"
  desc "Workspace for Claude Code, Codex and other CLI coding agents"
  homepage "https://tiri.build/"

  livecheck do
    url "https://tiri.build/update.json"
    strategy :json do |json|
      json["version"]
    end
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Tiri.app"

  zap trash: [
    "~/Library/Application Support/Tiri",
    "~/Library/Caches/dev.tiri.app",
    "~/Library/Caches/dev.tiri.app.personal",
    "~/Library/Caches/Tiri",
    "~/Library/HTTPStorages/dev.tiri.app*",
    "~/Library/Preferences/dev.tiri.app.personal.plist",
    "~/Library/Preferences/dev.tiri.app.plist",
    "~/Library/WebKit/dev.tiri.app",
    "~/Library/WebKit/dev.tiri.app.personal",
  ]
end
EOF
}

if [ "${1:-}" != "--publish" ]; then cask; exit 0; fi

# The cask has to point at a file that's already on tiri.build: publish-release.sh comes first.
LIVE="$(curl -sf https://tiri.build/update.json | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])' || true)"
[ "$LIVE" = "$VERSION" ] || { echo "tiri.build is on ${LIVE:-nothing}, not $VERSION. Run scripts/publish-release.sh first." >&2; exit 1; }
CURRENT="$(gh api "repos/$TAP/contents/Casks/tiri.rb" --jq .sha 2>/dev/null || true)"
args=(-X PUT "repos/$TAP/contents/Casks/tiri.rb" -f "message=Tiri $VERSION" -f "content=$(cask | base64)")
[ -n "$CURRENT" ] && args+=(-f "sha=$CURRENT")
gh api "${args[@]}" --jq .commit.html_url
