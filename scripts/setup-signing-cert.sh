#!/usr/bin/env bash
# Sets up a permanent self-signed Code Signing certificate named "Lectern Release Signing"
# in your macOS Keychain to prevent Keychain authorization prompts on app updates.
#
# Background:
# Ad-hoc signed binaries (`codesign --sign -`) have their macOS Keychain Access Control
# Lists (ACL) bound to the binary's `cdhash`. Because `cdhash` changes on every rebuild,
# macOS prompts the user for Keychain permission (for Canvas tokens, Google Docs tokens,
# transcription API keys, etc.) on every update.
#
# A persistent Code Signing certificate ensures the app retains the exact same Designated
# Requirement (DR) across releases, so macOS allows Keychain access seamlessly after updates.
#
# Alternative (GUI method):
# 1. Open Keychain Access -> Certificate Assistant -> Create a Certificate...
# 2. Name: "Lectern Release Signing"
# 3. Identity Type: "Self Signed Root"
# 4. Certificate Type: "Code Signing"
# 5. Check "Let me override defaults" to extend validity (e.g. 7300 days).
# 6. Click Create.
set -euo pipefail

CERT_NAME="Lectern Release Signing"
BACKUP_PATH="${HOME}/Desktop/Lectern-Release-Signing-BACKUP.p12"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --backup-path) BACKUP_PATH="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "Checking for existing code signing identity: \"$CERT_NAME\"..."

if security find-identity -p codesigning -v | grep -q "\"$CERT_NAME\""; then
  if [[ $FORCE -eq 0 ]]; then
    echo "✓ Code signing identity \"$CERT_NAME\" is already installed and valid in Keychain."
    echo "  (Use --force to regenerate if you need a new one)."
    exit 0
  else
    echo "Regenerating certificate as requested by --force..."
    security delete-certificate -c "$CERT_NAME" 2>/dev/null || true
  fi
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

OPENSSL_CNF="$TMPDIR/cert.cnf"
cat > "$OPENSSL_CNF" <<EOF
[req]
distinguished_name = req_distinguished_name
prompt = no
x509_extensions = v3_code_sign

[req_distinguished_name]
CN = $CERT_NAME
O = Lectern App

[v3_code_sign]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOF

echo "Generating 20-year self-signed Code Signing certificate..."
openssl req -new -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMPDIR/key.pem" \
  -out "$TMPDIR/cert.pem" \
  -days 7300 \
  -config "$OPENSSL_CNF" 2>/dev/null

# Bundle into PKCS#12 archive
# Note: macOS Security framework requires legacy encryption when importing PKCS#12 created by OpenSSL 3
openssl pkcs12 -export -legacy \
  -inkey "$TMPDIR/key.pem" \
  -in "$TMPDIR/cert.pem" \
  -out "$TMPDIR/cert.p12" \
  -passout pass:lectern 2>/dev/null

DEFAULT_KEYCHAIN="$(security default-keychain | tr -d ' "\n')"
if [[ -z "$DEFAULT_KEYCHAIN" ]]; then
  DEFAULT_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
fi

echo "Importing identity into $DEFAULT_KEYCHAIN..."
security import "$TMPDIR/cert.p12" -k "$DEFAULT_KEYCHAIN" -P lectern -T /usr/bin/codesign

echo "Marking certificate as trusted for code signing..."
security add-trusted-cert -r trustRoot -p codeSign "$TMPDIR/cert.pem"

# Verify it was imported and is valid for code signing
if ! security find-identity -p codesigning -v | grep -q "\"$CERT_NAME\""; then
  echo "Error: Certificate was imported but not found in valid code signing identities." >&2
  exit 1
fi

# Export backup .p12
cp "$TMPDIR/cert.p12" "$BACKUP_PATH"
chmod 600 "$BACKUP_PATH"

echo ""
echo "================================================================="
echo "✓ Success! \"$CERT_NAME\" is installed and ready."
echo "================================================================="
echo "A backup of this certificate and private key has been saved to:"
echo "  $BACKUP_PATH"
echo "  (Import password: lectern)"
echo ""
echo "CRITICAL: Keep this backup in a safe place (e.g. 1Password / iCloud)."
echo "If you switch Macs, import this .p12 file so your app releases retain"
echo "the same cryptographic identity and avoid resetting user Keychains."
echo "================================================================="
