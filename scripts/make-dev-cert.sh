#!/bin/bash
# Creates a self-signed code-signing identity so Screen Recording permission survives rebuilds.
# macOS keys the permission to the app's signature; ad-hoc signatures change on every build.
set -euo pipefail

NAME="${1:?usage: make-dev-cert.sh <identity name>}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Identity \"$NAME\" already exists."
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
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout pass:kuroko -out "$WORK/cert.p12"

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P kuroko -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\""
echo "Done. Build with: make run"
