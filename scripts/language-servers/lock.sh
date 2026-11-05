#!/bin/bash
# Writes the exact versions and hashes Tiri may install, into Resources/language-servers. Nothing
# newer reaches anyone until this runs again and a release carries it, which is the point: a package
# that goes bad upstream doesn't reach anyone because they opened a file.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="$PWD/Resources/language-servers"
mkdir -p "$OUT"

npm_lock() { # id, package@version...
  local id="$1"; shift
  local dir="$OUT/$id"
  rm -rf "$dir"; mkdir -p "$dir"
  ( cd "$dir"
    printf '{"name":"tiri-%s","private":true}\n' "$id" > package.json
    npm install --package-lock-only --ignore-scripts --no-audit --no-fund --save-exact --registry=https://registry.npmjs.org "$@" >/dev/null 2>&1 )
  echo "$id: $*"
}

npm_lock typescript typescript-language-server@6.0.3 typescript@6.0.3
npm_lock bash bash-language-server@5.8.1
npm_lock yaml yaml-language-server@2.0.0
npm_lock web vscode-langservers-extracted@4.10.0

mkdir -p "$OUT/python"
printf 'basedpyright==1.40.2\n' | uv pip compile - --universal --generate-hashes --no-header --quiet --python-version 3.10 -o "$OUT/python/requirements.txt"
echo "python: basedpyright==1.40.2"
