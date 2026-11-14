#!/bin/zsh
# Makes "Orca Find Signing": a free, self-made code-signing certificate used only for Orca, in the login
# keychain. build.sh picks it up automatically. Because every build (and every update) is then signed by
# the same identity, macOS keeps the permissions people gave Orca (Screen Recording, Microphone…)
# when it updates itself. macOS asks for your password once, to trust it for code signing.
# Back it up: Keychain Access › login › My Certificates › "Orca Find Signing" › Export (.p12).
# A paid Apple "Developer ID Application" certificate can replace it later (build.sh prefers that one).
set -euo pipefail
NAME="Orca Find Signing"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then echo "✓ $NAME already installed"; exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$T/cfg" -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$NAME" -out "$T/id.p12" -passout "pass:$PASS" 2>/dev/null
KC="$HOME/Library/Keychains/login.keychain-db"
security import "$T/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "▸ macOS will ask for your password to trust \"$NAME\" for code signing…"
security add-trusted-cert -p codeSign -k "$KC" "$T/cert.pem"
security find-identity -v -p codesigning | grep "\"$NAME\"" && echo "✓ $NAME is ready"
