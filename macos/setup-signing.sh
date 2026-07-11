#!/bin/bash
# One-time: create a stable, self-signed code-signing identity for local Kaze builds.
#
# Why: ad-hoc signing (`codesign -s -`) changes the app's code hash on every build, which
# resets the Screen Recording / Microphone permissions each rebuild. Signing with a fixed
# self-signed certificate gives a stable "designated requirement" (keyed on the cert hash),
# so macOS keeps the TCC grants across rebuilds. The cert is NOT trusted for distribution —
# it's only for keeping local permissions sticky. codesign uses it fine despite being
# untrusted; no Keychain trust prompt is required.
#
# Safe to re-run: it recreates the dedicated keychain from scratch and never touches your
# login keychain. Keychain password is fixed ("kazelocal") since it only guards this
# throwaway local signing key.
set -euo pipefail

IDENTITY="Kaze Local Signing"
KC="$HOME/Library/Keychains/kaze-signing.keychain-db"
KC_PASS="kazelocal"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Generating self-signed code-signing certificate"
# Homebrew's OpenSSL 3 is fine for key/cert generation...
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

echo "==> Packaging identity (LibreSSL for Apple-compatible PKCS#12)"
# ...but the .p12 MUST be built with system LibreSSL — OpenSSL 3's MAC algorithm is
# rejected by macOS `security import` ("MAC verification failed").
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$KC_PASS" -name "$IDENTITY" 2>/dev/null

echo "==> Creating dedicated keychain (never touches your login keychain)"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"          # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$TMP/identity.p12" -k "$KC" -P "$KC_PASS" -T /usr/bin/codesign -A
# Let codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null 2>&1
# Add to the search list so `codesign -s "<name>"` resolves it.
security list-keychains -d user -s "$KC" $(security list-keychains -d user | sed 's/"//g') >/dev/null

echo "==> Verifying"
security find-identity -p codesigning "$KC" | grep "$IDENTITY" && \
    echo "Done. build-app.sh will now sign with '$IDENTITY'." || \
    { echo "FAILED: identity not found"; exit 1; }
