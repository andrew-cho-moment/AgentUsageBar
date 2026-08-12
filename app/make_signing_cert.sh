#!/bin/bash
set -euo pipefail

# Creates a local, self-signed code-signing identity for AgentUsageBar.
#
# Why this exists: an ad-hoc signature ("codesign --sign -") produces a new code
# identity on every build. macOS keys two things to that identity:
#
#   1. UNUserNotificationCenter authorization. Ad-hoc signed apps are refused
#      outright with "Notifications are not allowed for this application".
#   2. Keychain ACLs. The "Always Allow" grant for reading Claude Code's OAuth
#      token is invalidated whenever the identity changes, so every rebuild
#      re-prompts.
#
# A stable self-signed certificate fixes both. It is NOT a Developer ID and cannot
# be notarized or distributed; it exists purely so this machine's copy has a
# consistent identity.
#
# Run once:   ./make_signing_cert.sh
# Then build: CODESIGN_IDENTITY="AgentUsageBar Dev" ./build.sh
#
# To undo:    security delete-certificate -c "AgentUsageBar Dev" \
#                 ~/Library/Keychains/login.keychain-db

IDENTITY="AgentUsageBar Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Identity '$IDENTITY' already exists. Nothing to do."
    echo "Build with: CODESIGN_IDENTITY=\"$IDENTITY\" ./build.sh"
    exit 0
fi

# LibreSSL's `req` has no -addext, so the extensions go in a config file.
cat > "$WORK/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[dn]
CN = AgentUsageBar Dev

[ext]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

# Pinned to the system LibreSSL: Homebrew's OpenSSL 3 defaults to PKCS#12 MAC and
# PBE algorithms that Security.framework rejects with "MAC verification failed".
OPENSSL=/usr/bin/openssl

echo "Generating key and self-signed certificate..."
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/cert.cnf" 2>/dev/null

# A transport password, used only between these two lines. `security import` with an
# empty password is unreliable across macOS versions.
P12PASS="$(uuidgen)"
"$OPENSSL" pkcs12 -export \
    -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -passout "pass:$P12PASS"

echo "Importing into login keychain (codesign is granted use of the key)..."
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

# Without this, codesign blocks on a keychain-access dialog for the new key.
# Prompts for the login password once; that is macOS guarding its own keychain.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -l "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1 \
  || echo "  (set-key-partition-list skipped; codesign may prompt once)"

# Trust for code signing, in the *user* trust domain — no sudo, no system changes.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
  || echo "  (add-trusted-cert skipped; signing usually still works untrusted)"

echo
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ Identity '$IDENTITY' is ready."
    echo "   Build with: CODESIGN_IDENTITY=\"$IDENTITY\" ./build.sh"
else
    echo "❌ Identity not visible to codesign. Inspect with:" >&2
    echo "   security find-identity -v -p codesigning" >&2
    exit 1
fi
