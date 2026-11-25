#!/bin/bash
# Release this fork: a universal MacShot.dmg that installs as its own app
# (com.lifedever.macshot) and updates itself through Sparkle from this fork's
# GitHub Releases.
#
#   scripts/release.sh 4.5.0-fork.1             build, sign and package; nothing leaves this Mac
#   scripts/release.sh 4.5.0-fork.1 --publish   tag the built commit, push the tag and create
#                                               the GitHub Release from the files built before
#
# Before building: write release-notes/<version>.md (Markdown) and commit it. Sparkle shows
# those notes in its update window; the GitHub Release gets them plus first-launch steps.
# Before publishing: push main. The script pushes only the tag.
#
# Signing. There is no Apple Developer ID, so everything is signed with the self-signed
# "MacShot Dev Local" certificate that scripts/build-install.sh uses, and nothing is
# notarized. People open the app once through System Settings › Privacy & Security. The
# signature stays the same from release to release, so macOS keeps their Screen Recording
# grant and Sparkle accepts the update. Losing the certificate breaks both for every
# installed copy: keep a .p12 export of it.
#
# Updates. Sparkle's private EdDSA key lives in the login keychain under the account
# "macshot" (made with `generate_keys --account macshot`). SPARKLE_PUBLIC_KEY is the half
# shipped in the app; the script refuses to sign with any other key, because installed
# copies would reject the update. Back the key up: `generate_keys --account macshot -x <file>`.
#
# The appcast is an asset of each release, read through releases/latest/download, so a
# release commits nothing to the repository and never touches upstream's appcast.xml.
#
# The local build (scripts/build-install.sh) keeps upstream's bundle ID and has no feed,
# so it never updates itself; see BuildVariant.softwareUpdatesEnabled.

set -euo pipefail

REPO="lifedever/macshot"
BUNDLE_ID="com.lifedever.macshot"
APP_NAME="MacShot"                 # MACSHOT_PRODUCT_NAME: the bundle and executable name
IDENTITY="MacShot Dev Local"
SPARKLE_ACCOUNT="macshot"
SPARKLE_PUBLIC_KEY="+eM6WuPGe4u/gGSJx+kJ5R+zl4EUX/13DiDxmSmeuFg="
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
DMG_NAME="$APP_NAME.dmg"          # stable name: releases/latest/download/MacShot.dmg always works

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="/tmp/macshot-release-build"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }
usage() { echo "usage: scripts/release.sh <version> [--publish]" >&2; exit 2; }

[ $# -ge 1 ] && [ $# -le 2 ] || usage
VERSION="$1"
PUBLISH=0
case "${2:-}" in
    "") ;;
    --publish) PUBLISH=1 ;;
    *) usage ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "version '$VERSION' should look like 4.5.0 or 4.5.0-fork.1"

TAG="v$VERSION"
OUT="/tmp/macshot-release/$VERSION"
NOTES="$ROOT/release-notes/$VERSION.md"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$DMG_NAME"

cd "$ROOT"
[ -s "$NOTES" ] || die "write the release notes first: release-notes/$VERSION.md"
[ -z "$(git status --porcelain)" ] \
    || die "the working tree has changes; a release is built from a commit, so commit them first"

tag_is_free() {
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        die "tag $TAG already exists locally"
    fi
    local status=0
    git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 || status=$?
    case $status in
        0) die "tag $TAG already exists on origin" ;;
        2) ;;   # no such tag: good
        *) die "can't reach origin to check tag $TAG" ;;
    esac
}

# The highest sparkle:version in the latest release's appcast, or nothing before the first release.
previous_build_number() {
    local latest
    latest="$(gh release list --repo "$REPO" --exclude-drafts --limit 20 --json tagName,isLatest \
        --jq 'map(select(.isLatest))[0].tagName // ""')" \
        || die "can't list the releases on $REPO (is gh logged in?)"
    [ -n "$latest" ] || return 0
    gh release download "$latest" --repo "$REPO" --pattern appcast.xml --output - \
        | python3 -c '
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
print(max(int(v.text) for v in ET.parse(sys.stdin).findall(".//sparkle:version", ns)))' \
        || die "can't read appcast.xml from release $latest"
}

sign() { codesign --force --timestamp=none --sign "$IDENTITY" "$@"; }

build() {
    local signing
    signing="$(security find-identity -v -p codesigning)"
    [[ "$signing" == *"\"$IDENTITY\""* ]] \
        || die "signing identity '$IDENTITY' is not in the keychain (see scripts/build-install.sh)"
    tag_is_free

    local commit build_number previous
    commit="$(git rev-parse HEAD)"
    # Sparkle compares this number, never the version string. The commit count only grows
    # on main; the check below catches anything that would make it go backwards.
    build_number="$(git rev-list --count HEAD)"
    previous="$(previous_build_number)"
    if [ -n "$previous" ] && [ "$build_number" -le "$previous" ]; then
        die "build number $build_number is not above the latest release's $previous; Sparkle would not offer it"
    fi

    rm -rf "$OUT" "$DERIVED/Build"
    mkdir -p "$OUT"
    local log="$OUT/build.log"
    step "Building $APP_NAME $VERSION ($build_number), arm64 + x86_64 (log: $log)"
    xcodebuild -project "$ROOT/macshot.xcodeproj" -scheme macshot -configuration Release \
        -derivedDataPath "$DERIVED" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        MACSHOT_BUNDLE_ID="$BUNDLE_ID" \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$build_number" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        build > "$log" 2>&1 \
        || { tail -30 "$log" >&2; die "build failed (full log: $log)"; }

    local built="$DERIVED/Build/Products/Release/$APP_NAME.app"
    [ -d "$built" ] || die "the build produced no app at $built"
    local archs
    archs="$(lipo -archs "$built/Contents/MacOS/$APP_NAME")"
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] \
        || die "the binary is '$archs', expected arm64 and x86_64"
    ditto "$built" "$APP"

    step "Writing the update feed into Info.plist"
    local min_system
    min_system="$(python3 - "$APP/Contents/Info.plist" "$BUNDLE_ID" "$VERSION" "$build_number" \
        "$FEED_URL" "$SPARKLE_PUBLIC_KEY" <<'PY'
import plistlib, sys
path, bundle_id, version, build, feed, key = sys.argv[1:]
with open(path, "rb") as f:
    info = plistlib.load(f)
for name, want in (("CFBundleIdentifier", bundle_id),
                   ("CFBundleShortVersionString", version),
                   ("CFBundleVersion", build)):
    if info.get(name) != want:
        sys.exit(f"{name} is {info.get(name)!r}, expected {want!r}")
info.update({
    "SUFeedURL": feed,
    "SUPublicEDKey": key,
    # Sandboxed: Sparkle installs through its installer XPC service.
    "SUEnableInstallerLauncherService": True,
    "SUEnableAutomaticChecks": True,
    "SUScheduledCheckInterval": 86400,
})
with open(path, "wb") as f:
    plistlib.dump(info, f)
print(info["LSMinimumSystemVersion"])
PY
)"

    # Sparkle's installer is reached through mach services named after the bundle ID, so the
    # sandbox exceptions in the repository's entitlements (upstream's ID) are rewritten.
    local entitlements="$OUT/macshot.entitlements"
    python3 - "$ROOT/macshot/macshot.entitlements" "$entitlements" "$BUNDLE_ID" <<'PY'
import plistlib, sys
src, dst, bundle_id = sys.argv[1:]
with open(src, "rb") as f:
    ent = plistlib.load(f)
key = "com.apple.security.temporary-exception.mach-lookup.global-name"
names = [n for n in ent.get(key, []) if not n.endswith(("-spks", "-spki"))]
ent[key] = names + [f"{bundle_id}-spks", f"{bundle_id}-spki"]
ent.pop("com.apple.security.get-task-allow", None)
with open(dst, "wb") as f:
    plistlib.dump(ent, f)
PY

    step "Signing with $IDENTITY"
    # Inside out, and never --deep: each piece keeps its own entitlements. Sparkle's helpers
    # arrive ad-hoc signed and are re-signed with our certificate like the app. Hardened
    # runtime stays off, as in the local build: its library validation refuses frameworks
    # signed by a certificate without a Team ID, and nothing here is notarized.
    local sparkle="$APP/Contents/Frameworks/Sparkle.framework"
    [ -d "$sparkle" ] || die "Sparkle.framework is missing from the app"
    local sparkle_version_dir
    sparkle_version_dir="$(cd "$sparkle/Versions/Current" && pwd -P)"
    local item
    for item in "$sparkle_version_dir"/XPCServices/*.xpc; do
        sign --preserve-metadata=entitlements "$item"     # Downloader.xpc has its own
    done
    sign "$sparkle_version_dir/Autoupdate"
    sign "$sparkle_version_dir/Updater.app"
    sign "$sparkle"
    while IFS= read -r -d '' item; do
        sign "$item"
    done < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
        \( -name '*.framework' -o -name '*.dylib' \) ! -name Sparkle.framework -print0)
    for item in "$APP"/Contents/XPCServices/*.xpc; do
        sign "$item"                                     # macshotOCR: unsandboxed by design
    done
    sign --entitlements "$entitlements" "$APP"

    step "Checking the signatures"
    codesign --verify --deep --strict "$APP" || die "codesign --verify failed"
    local info
    for item in "$APP" "$sparkle" "$sparkle_version_dir/Autoupdate" "$sparkle_version_dir/Updater.app" \
        "$sparkle_version_dir"/XPCServices/*.xpc "$APP"/Contents/XPCServices/*.xpc; do
        info="$(codesign -dv --verbose=2 "$item" 2>&1)"
        [[ "$info" == *"Authority=$IDENTITY"* ]] || die "$item is not signed by $IDENTITY"
    done
    for item in "$sparkle_version_dir/XPCServices/Installer.xpc" "$APP"/Contents/XPCServices/*.xpc; do
        info="$(codesign -d --entitlements - --xml "$item" 2>/dev/null || true)"
        [[ "$info" != *"app-sandbox"* ]] || die "$item is sandboxed; it could not do its job"
    done
    codesign -d --entitlements - --xml "$APP" 2>/dev/null | python3 -c '
import plistlib, sys
ent = plistlib.loads(sys.stdin.buffer.read())
names = ent.get("com.apple.security.temporary-exception.mach-lookup.global-name", [])
need = [sys.argv[1] + "-spks", sys.argv[1] + "-spki"]
missing = [n for n in need if n not in names]
if missing or not ent.get("com.apple.security.app-sandbox") or "com.apple.security.get-task-allow" in ent:
    sys.exit(f"unexpected app entitlements: missing {missing}, keys {sorted(ent)}")' "$BUNDLE_ID" \
        || die "the app's entitlements are wrong"

    step "Packaging $DMG_NAME"
    local stage="$OUT/dmg"
    mkdir -p "$stage"
    ditto "$APP" "$stage/$APP_NAME.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$stage"

    # Check what people will actually download, not the staging copy.
    local mount="$OUT/mnt"
    mkdir -p "$mount"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$DMG" >/dev/null
    local mounted_ok=1
    codesign --verify --deep --strict "$mount/$APP_NAME.app" || mounted_ok=0
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$mount/$APP_NAME.app/Contents/Info.plist")" \
        = "$build_number" ] || mounted_ok=0
    [ -L "$mount/Applications" ] || mounted_ok=0
    hdiutil detach "$mount" >/dev/null
    rmdir "$mount"
    [ "$mounted_ok" = 1 ] || die "the app inside $DMG_NAME failed its checks"

    step "Signing the update for Sparkle"
    local sparkle_bin="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
    [ -x "$sparkle_bin/sign_update" ] || die "Sparkle's sign_update is missing from $sparkle_bin"
    local keychain_key
    keychain_key="$("$sparkle_bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" \
        || die "no Sparkle key for account '$SPARKLE_ACCOUNT' in the keychain"
    [ "$keychain_key" = "$SPARKLE_PUBLIC_KEY" ] \
        || die "the keychain's Sparkle key ($keychain_key) is not the one installed copies trust"
    local signature length
    signature="$("$sparkle_bin/sign_update" --account "$SPARKLE_ACCOUNT" -p "$DMG")"
    "$sparkle_bin/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$DMG" "$signature" >/dev/null \
        || die "the update signature does not verify"
    length="$(stat -f%z "$DMG")"

    step "Writing appcast.xml"
    python3 - "$OUT/appcast.xml" "$VERSION" "$build_number" "$min_system" "$NOTES" \
        "https://github.com/$REPO/releases/download/$TAG/$DMG_NAME" "$length" "$signature" \
        "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" "$REPO" <<'PY'
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr
out, version, build, min_system, notes_path, url, length, signature, date, repo = sys.argv[1:]
with open(notes_path, encoding="utf-8") as f:
    notes = f.read().strip().replace("]]>", "]]]]><![CDATA[>")
feed = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MacShot</title>
    <link>https://github.com/{repo}</link>
    <item>
      <title>{escape(version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_system)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/{repo}/releases</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
{notes}
]]></description>
      <enclosure url={quoteattr(url)} length="{length}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>
'''
with open(out, "w", encoding="utf-8") as f:
    f.write(feed)
ET.parse(out)
PY

    {
        cat "$NOTES"
        printf '\n\n---\n\n'
        printf '**下载**：下面的 `%s`，Apple 芯片和 Intel 的 Mac 都能用，需要 macOS %s 或更新。\n\n' \
            "$DMG_NAME" "$min_system"
        printf '**第一次打开**：这个版本没有经过 Apple 公证，macOS 会拦下它。'
        printf '关掉弹出的提示，然后打开「系统设置 › 隐私与安全性」，往下翻到「安全性」，点 MacShot 那一行的「仍要打开」。'
        printf '之后有新版本时会收到系统通知，在 MacShot 的设置里更新，不用再这样操作。\n'
    } > "$OUT/github-notes.md"

    cat > "$OUT/release.env" <<EOF
COMMIT=$commit
BUILD_NUMBER=$build_number
DMG_SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
EOF

    step "Built $APP_NAME $VERSION ($build_number) from ${commit:0:7}"
    echo "    $DMG ($(du -h "$DMG" | awk '{print $1}'))"
    echo "    $OUT/appcast.xml"
    echo "Publish with: scripts/release.sh $VERSION --publish"
}

publish() {
    [ -f "$OUT/release.env" ] || die "nothing built for $VERSION yet: run scripts/release.sh $VERSION"
    local commit="" dmg_sha=""
    commit="$(sed -n 's/^COMMIT=//p' "$OUT/release.env")"
    dmg_sha="$(sed -n 's/^DMG_SHA256=//p' "$OUT/release.env")"
    [ "$(git rev-parse HEAD)" = "$commit" ] \
        || die "HEAD is no longer the built commit ${commit:0:7}; rebuild"
    [ "$(shasum -a 256 "$DMG" | awk '{print $1}')" = "$dmg_sha" ] \
        || die "$DMG_NAME changed since it was built; rebuild"
    git fetch -q origin main
    git merge-base --is-ancestor "$commit" origin/main \
        || die "push main first: ${commit:0:7} is not on origin/main"
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        die "release $TAG already exists on $REPO"
    fi

    # A run that stopped after pushing the tag can be repeated: a tag already on the built
    # commit is reused, one anywhere else stops the release (and git refuses to move it).
    step "Tagging $TAG and pushing the tag"
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        [ "$(git rev-list -n 1 "$TAG")" = "$commit" ] || die "tag $TAG exists on another commit"
    else
        git tag -a "$TAG" -m "MacShot $VERSION" "$commit"
    fi
    git push origin "refs/tags/$TAG"

    step "Creating the GitHub Release"
    gh release create "$TAG" --repo "$REPO" --verify-tag --latest \
        --title "MacShot $VERSION" --notes-file "$OUT/github-notes.md" \
        "$DMG" "$OUT/appcast.xml"
    echo "Released: https://github.com/$REPO/releases/tag/$TAG"
}

if [ "$PUBLISH" = 1 ]; then publish; else build; fi
