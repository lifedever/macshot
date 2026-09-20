#!/bin/bash
# Build this fork for local use and replace the copy in /Applications.
#
# Signs with a self-signed certificate that lives in the login keychain, so the
# code signature — and therefore macOS's Screen Recording / Accessibility grants
# — stay identical across rebuilds. Reinstalling does not re-trigger the
# permission prompts. (Switching *away* from the upstream developer's signature
# invalidates the old grants once; re-approve after the first install.)
#
# Regenerate the certificate (only needed on a fresh machine):
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="MacShot Dev Local"
DERIVED="/tmp/macshot-rel"
APP_NAME="MacShot"          # PRODUCT_NAME: names the bundle and its executable
TARGET="/Applications/$APP_NAME.app"
LOG="/tmp/macshot-install.log"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "error: signing identity '$IDENTITY' not found in the keychain." >&2
    echo "       See the header of this script to recreate it." >&2
    exit 1
fi

echo "==> Building arm64 Release (log: $LOG)"
xcodebuild -project "$ROOT/macshot.xcodeproj" -scheme macshot -configuration Release \
    -derivedDataPath "$DERIVED" -arch arm64 ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    build > "$LOG" 2>&1

BUILT="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "error: build produced no app at $BUILT" >&2; exit 1; }

# Confirm this really is the binary that was just built — xcodebuild reports
# success even when it silently reuses a stale product directory.
#
# Capture each command's output before matching instead of piping into `grep -q`:
# grep exits on its first match, the writer gets SIGPIPE, and `set -o pipefail`
# turns that into a spurious failure.
ARCHS_FOUND="$(lipo -archs "$BUILT/Contents/MacOS/$APP_NAME")"
[[ " $ARCHS_FOUND " == *" arm64 "* ]] \
    || { echo "error: built binary is '$ARCHS_FOUND', not arm64" >&2; exit 1; }
# --verbose=2 is the level that prints the Authority lines; plain -dv does not.
SIGN_INFO="$(codesign -dv --verbose=2 "$BUILT" 2>&1)"
[[ "$SIGN_INFO" == *"Authority=$IDENTITY"* ]] \
    || { echo "error: built app is not signed with '$IDENTITY'" >&2; exit 1; }

echo "==> Quitting the running instance"
# Builds before the MacShot rename shipped a lowercase executable, so look for both names.
# `|| true` on each: under `set -e` a bare failing pgrep would abort the script, and "no
# such process" is the normal case here.
running_pids() { { pgrep -x "$APP_NAME" || true; pgrep -x macshot || true; } | tr '\n' ' '; }

osascript -e 'quit app id "com.sw33tlie.macshot.macshot"' 2>/dev/null || true
for _ in $(seq 10); do
    [ -z "$(running_pids)" ] && break
    sleep 0.3
done

# Quit can be swallowed by a modal panel. Fall back to SIGTERM on exactly the pids we
# just resolved — never a name-pattern kill, which could hit unrelated processes.
STRAGGLERS="$(running_pids)"
if [ -n "$STRAGGLERS" ]; then
    echo "    quit ignored; sending SIGTERM to: $STRAGGLERS"
    kill $STRAGGLERS 2>/dev/null || true
    sleep 0.5
fi
if [ -n "$(running_pids)" ]; then
    echo "error: $APP_NAME is still running; quit it and retry" >&2
    exit 1
fi

echo "==> Replacing $TARGET"
rm -rf "$TARGET"
cp -R "$BUILT" "$TARGET"

echo "==> Launching"
open "$TARGET"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"
