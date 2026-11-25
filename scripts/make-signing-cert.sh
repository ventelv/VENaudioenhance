#!/bin/zsh
# Creates a self-signed code-signing certificate, "VEN Local Signing", in your login keychain.
# scripts/build-app.sh then signs with it, so macOS remembers the microphone permission across
# rebuilds instead of asking after every build. It's not an Apple Developer ID: it doesn't stop
# Gatekeeper's warning on other Macs. The first build asks you to allow codesign to use the key:
# choose Always Allow.
set -euo pipefail
NAME="VEN Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."
  exit 0
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(openssl rand -hex 16)
# The keychain only reads PKCS#12 files in the older (3DES/SHA-1) format; OpenSSL 3+ needs -legacy for it.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/cert.p12" -passout "pass:$PASS" 2>/dev/null ||
  openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/cert.p12" -passout "pass:$PASS"
security import "$WORK/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Run scripts/build-app.sh to sign with it."
