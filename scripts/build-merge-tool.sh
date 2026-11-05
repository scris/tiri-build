#!/bin/bash
# Builds Mergiraf, a merge driver that understands syntax, with the Swift profile it doesn't have yet.
#   scripts/build-merge-tool.sh <output file>
# Updates use it, when it's at your-tiri/tools/mergiraf, before anything has to ask an agent. Nothing depends on
# it: without it Git's own merge runs, and what it can't do goes to repair. Needs Rust 1.91 or newer.
# Mergiraf is GPL-3.0, which is why this builds it rather than Tiri's repository carrying it.
set -euo pipefail
OUT="${1:?output file}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
curl -fsSL https://static.crates.io/crates/mergiraf/mergiraf-0.19.1.crate | tar -xz -C "$WORK"
cd "$WORK/mergiraf-0.19.1"
# The published Cargo.toml is rewritten by the registry. The patch is against the one the project wrote.
mv Cargo.toml.orig Cargo.toml
patch -s -p1 <"$HERE/mergiraf-swift.patch"
# It names a development helper that isn't in the published package.
sed -i '' 's/^members = .*/members = []/' Cargo.toml
if command -v rustup >/dev/null 2>&1; then cargo +stable build -q --release; else cargo build -q --release; fi
mkdir -p "$(dirname "$OUT")"
cp target/release/mergiraf "$OUT"
strip "$OUT" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$OUT"
