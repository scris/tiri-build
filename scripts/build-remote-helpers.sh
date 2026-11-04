#!/bin/bash
# Builds the helper Tiri puts on servers, for what servers run. Static, so they need nothing there.
# The results are checked in under Resources/remote, so building Tiri doesn't need zig.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v zig >/dev/null || { echo "needs zig: brew install zig" >&2; exit 1; }
VERSION="$(cat Remote/tiri-remote.c Sources/tiri-session/main.c | shasum -a 256 | cut -c1-12)"
mkdir -p Resources/remote
rm -f Resources/remote/tiri-remote-*
for target in x86_64-linux-musl aarch64-linux-musl; do
  arch="${target%%-*}"
  zig cc -target "$target" -Os -s -static -Wall -Wno-unused-function -DTIRI_REMOTE_VERSION="\"$VERSION\"" \
    -o "Resources/remote/tiri-remote-linux-$arch" Remote/tiri-remote.c
  rm -f "Resources/remote/tiri-remote-linux-$arch.o"
done
# A Mac as the server: one binary for both of its kinds. Static isn't a thing there.
for arch in arm64 x86_64; do
  clang -arch "$arch" -Os -mmacosx-version-min=11 -DTIRI_REMOTE_VERSION="\"$VERSION\"" -o "Resources/remote/tiri-remote-darwin-$arch" Remote/tiri-remote.c
done
printf %s "$VERSION" > Resources/remote/VERSION
ls -la Resources/remote
