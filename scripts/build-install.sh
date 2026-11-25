#!/bin/bash
# Install the current code, uncommitted changes included, into /Applications.
#
# This is `scripts/release.sh --install`: the same app as a release — same bundle ID
# (com.lifedever.macshot), same certificate, same update feed — built for this Mac's
# architecture. It shows the version of the latest release it contains while carrying newer
# code, and its build number is the commit count, so the next release reaches it as an update.
# Installing a release over it, or it over a release, keeps settings and permissions.
#
# The certificate is self-signed and lives in the login keychain. macOS ties Screen Recording
# and Accessibility grants to the bundle ID plus this certificate, so they survive every
# reinstall and every update. Losing it means granting them again: keep a .p12 export.
#
# Regenerate the certificate (only on a fresh machine, and only if the .p12 is gone —
# a new one makes every installed copy ask for permissions again):
#   /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
#     -keyout dev.key -out dev.crt -subj "/CN=MacShot Dev Local" \
#     -addext "basicConstraints=critical,CA:FALSE" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
#   /usr/bin/openssl pkcs12 -export -out dev.p12 -inkey dev.key -in dev.crt \
#     -name "MacShot Dev Local" -passout pass:PASS
#   security import dev.p12 -k ~/Library/Keychains/login.keychain-db -P PASS \
#     -T /usr/bin/codesign -T /usr/bin/security
#   security add-trusted-cert -r trustRoot -p codeSign \
#     -k ~/Library/Keychains/login.keychain-db dev.crt
# Use /usr/bin/openssl (LibreSSL), not Homebrew's OpenSSL 3 — its PKCS12 output
# uses ciphers the macOS Security framework rejects on import.

set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release.sh" --install
