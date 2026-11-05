#!/bin/bash
# The signing identity of one person's own Tiri builds: a self-signed certificate in a keychain of its own.
#   scripts/personal-identity.sh [folder]     prints the identity's hash, and makes it the first time
# Every build signed with it has the same designated requirement, so macOS keeps its answers about folders
# across rebuilds. Nothing is added to the login keychain or the keychain search list, and nothing asks.
# Written to `folder`, by default the identity folder of Your Tiri:
#   personal.keychain-db    the keychain
#   secret                  its password, readable only by you
#   hash                    the certificate's SHA-1, what codesign is told to use
# /usr/bin/openssl by its full path: a newer one from Homebrew writes a file `security` can't read.
set -euo pipefail

SUPPORT="${TIRI_HOME:-$HOME/Library/Application Support/Tiri}"
DIR="${1:-$SUPPORT/your-tiri/identity}"
KEYCHAIN="$DIR/personal.keychain-db"

if [ ! -s "$DIR/hash" ] || [ ! -s "$DIR/secret" ] || [ ! -f "$KEYCHAIN" ]; then
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  rm -f "$KEYCHAIN" "$DIR/secret" "$DIR/hash"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cat >"$WORK/certificate.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Tiri Personal
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  SECRET="$(/usr/bin/openssl rand -hex 24)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 7300 -sha256 \
    -config "$WORK/certificate.cnf" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
    -passout "pass:$SECRET" -name "Tiri Personal" >/dev/null 2>&1
  security create-keychain -p "$SECRET" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$SECRET" "$KEYCHAIN"
  security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$SECRET" -T /usr/bin/codesign -x >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SECRET" "$KEYCHAIN" >/dev/null 2>&1
  (umask 077; printf %s "$SECRET" >"$DIR/secret")
  /usr/bin/openssl x509 -in "$WORK/cert.pem" -outform der | shasum -a 1 | cut -d' ' -f1 | tr 'a-z' 'A-Z' | tr -d '\n' >"$DIR/hash"
fi

# Signing fails with a locked keychain, and a Mac locks them on its own schedule.
security unlock-keychain -p "$(cat "$DIR/secret")" "$KEYCHAIN"
cat "$DIR/hash"
echo
