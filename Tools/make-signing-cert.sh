#!/bin/bash
# Creates a self-signed code-signing identity "Seek Dev" in your login keychain.
# build.sh signs with it automatically, so macOS keeps Seek's Accessibility / Automation
# permissions across rebuilds (ad-hoc signatures change with every build).
# Undo: Keychain Access → login → My Certificates → delete "Seek Dev".
set -euo pipefail

NAME="Seek Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "“${NAME}” already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cfg <<'CFG'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Seek Dev
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cfg 2>/dev/null
PASS=$(openssl rand -hex 12)
# -legacy keeps the PKCS#12 readable by macOS's `security` with OpenSSL 3.
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" -out seek.p12 -passout "pass:$PASS" 2>/dev/null \
    || openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out seek.p12 -passout "pass:$PASS"
security import seek.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign

security find-identity -p codesigning | grep "\"$NAME\"" && echo "Created “${NAME}”. Now run ./install.sh."
