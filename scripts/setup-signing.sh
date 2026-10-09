#!/usr/bin/env bash
#
# One-time setup of a STABLE self-signed code-signing identity for Ziggy Listens.
#
# Why: macOS ties TCC permissions (Screen Recording, Microphone) to an app's
# code-signing identity. Ad-hoc signatures (`codesign -s -`) change on every
# build, so the OS treats each rebuild as a new app and re-prompts for Screen
# Recording. Signing every build with ONE stable cert makes the grant persist,
# so you (and testers) approve permissions once.
#
# This is NOT an Apple Developer ID cert — it's a free self-signed cert. The
# DMG is still un-notarized, so first launch still needs the one-time Gatekeeper
# "Open Anyway". It only fixes the repeating *permission* prompts.
#
# Safe to re-run (recreates the keychain + cert). Fully non-interactive.
set -euo pipefail

IDENTITY="${SIGN_IDENTITY:-Ziggy Listens Self-Signed}"
KCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/ziggy-signing.keychain-db}"
KPASS="${SIGN_KEYCHAIN_PW:-ziggy-signing}"   # protects only this local dev cert

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "==> Generating self-signed code-signing certificate ($IDENTITY)"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY/O=Ziggy Listens" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy + SHA1 MAC/PBE so macOS `security` can import the PKCS#12 (OpenSSL 3
# defaults to algorithms the Security framework rejects).
echo "==> Packaging PKCS#12"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -name "$IDENTITY" -passout pass:"$KPASS" \
  -legacy -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

echo "==> Creating dedicated signing keychain"
security delete-keychain "$KCHAIN" 2>/dev/null || true
security create-keychain -p "$KPASS" "$KCHAIN"
security set-keychain-settings "$KCHAIN"           # no auto-lock timeout
security unlock-keychain -p "$KPASS" "$KCHAIN"

echo "==> Importing identity + allowing codesign to use it"
security import "$WORK/id.p12" -k "$KCHAIN" -P "$KPASS" -A -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KPASS" "$KCHAIN" >/dev/null

echo "==> Adding keychain to the user search list (existing entries kept)"
CUR=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
security list-keychains -d user -s $CUR "$KCHAIN"

echo "==> Done. Identity:"
security find-identity -p codesigning "$KCHAIN" | sed -n 's/^/    /p'
echo
echo "    build_dmg.sh will now sign with \"$IDENTITY\" automatically."
