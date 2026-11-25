#!/bin/bash
# Release this fork: one DMG per architecture (MacShot-Apple-Silicon.dmg, MacShot-Intel.dmg)
# that installs as its own app (com.lifedever.macshot) and updates itself through Sparkle
# from this fork's GitHub Releases.
#
#   scripts/release.sh 4.5.0-fork.2             build, sign and package; nothing leaves this Mac
#   scripts/release.sh 4.5.0-fork.2 --publish   tag the built commit, push the tag and create
#                                               the GitHub Release from the files built before
#   scripts/release.sh --install                the current code, uncommitted changes included,
#                                               installed into /Applications for this Mac
#                                               (scripts/build-install.sh runs this)
#
# There is one app. A local install is built, signed and given its feed exactly like a release,
# for this Mac's architecture only. It keeps the version of the latest release it contains (the
# newest tag) while carrying newer code; its build number is the commit count, as a release's
# is, so the next release is offered to it as an update like to anyone else.
#
# Before building: write release-notes/<version>.md (Markdown) and commit it. Sparkle shows
# those notes in its update window; the GitHub Release gets them plus download and
# first-launch steps. Before publishing: push main. The script pushes only the tag.
#
# Architectures. The app is built once, universal, and split with `ditto --arch` into an
# arm64 and an x86_64 copy, each signed and packaged on its own. Each has its own feed,
# appcast-<arch>.xml; the app picks it by the Mac it runs on, not by the build
# (SoftwareUpdater.feedURLString), so an Intel copy on Apple silicon updates to the native
# one. appcast.xml, the SUFeedURL every build carries, lists both DMGs (the arm64 one marked
# with sparkle:hardwareRequirements) for builds that predate the per-architecture feeds:
# 4.5.0-fork.1, the only release that shipped a universal DMG.
#
# Signing. There is no Apple Developer ID, so everything is signed with the self-signed
# "MacShot Dev Local" certificate that scripts/build-install.sh uses, and nothing is
# notarized. People open the app once through System Settings › Privacy & Security. The
# signature stays the same from release to release, so macOS keeps their Screen Recording
# and Accessibility grants and Sparkle accepts the update. Losing the certificate breaks
# both for every installed copy: keep a .p12 export of it.
#
# Updates. Sparkle's private EdDSA key lives in the login keychain under the account
# "macshot" (backed up in 1Password: "MacShot Sparkle 更新签名私钥"). SPARKLE_PUBLIC_KEY is
# the half shipped in the app; the script refuses to sign with any other key, because
# installed copies would reject the update.
#
# The appcasts are assets of each release, read through releases/latest/download, so a
# release commits nothing to the repository and never touches upstream's appcast.xml.
#

set -euo pipefail

REPO="lifedever/macshot"
BUNDLE_ID="com.lifedever.macshot"
APP_NAME="MacShot"                 # MACSHOT_PRODUCT_NAME: the bundle and executable name
IDENTITY="MacShot Dev Local"
SPARKLE_ACCOUNT="macshot"
SPARKLE_PUBLIC_KEY="+eM6WuPGe4u/gGSJx+kJ5R+zl4EUX/13DiDxmSmeuFg="
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
ARCHES=(arm64 x86_64)

# Stable asset names, so releases/latest/download/<name> always works (the README links them).
dmg_name() {
    case "$1" in
        arm64) echo "$APP_NAME-Apple-Silicon.dmg" ;;
        x86_64) echo "$APP_NAME-Intel.dmg" ;;
        *) echo "unknown architecture $1" >&2; return 1 ;;
    esac
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="/tmp/macshot-release-build"

INSTALL_DERIVED="/tmp/macshot-rel"      # kept between local installs: incremental builds
INSTALL_TARGET="/Applications/$APP_NAME.app"
INSTALL_LOG="/tmp/macshot-install.log"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }
usage() { echo "usage: scripts/release.sh <version> [--publish] | scripts/release.sh --install" >&2; exit 2; }

cd "$ROOT"

# The version a local install shows: the newest release tag this commit contains.
latest_release_version() {
    local tag
    tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*-fork.*' 2>/dev/null)" \
        || die "no release tag (v...-fork.N) in this commit's history to take the version from"
    echo "${tag#v}"
}

MODE=build
if [ "${1:-}" = "--install" ]; then
    [ $# -eq 1 ] || usage
    MODE=install
    VERSION="$(latest_release_version)"
else
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    VERSION="$1"
    case "${2:-}" in
        "") ;;
        --publish) MODE=publish ;;
        *) usage ;;
    esac
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "version '$VERSION' should look like 4.5.0 or 4.5.0-fork.1"

TAG="v$VERSION"
OUT="/tmp/macshot-release/$VERSION"
NOTES="$ROOT/release-notes/$VERSION.md"

if [ "$MODE" != install ]; then
    [ -s "$NOTES" ] || die "write the release notes first: release-notes/$VERSION.md"
    [ -z "$(git status --porcelain)" ] \
        || die "the working tree has changes; a release is built from a commit, so commit them first"
fi

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

# Quiet unless it fails: every re-sign prints "replacing existing signature".
sign() {
    local out
    out="$(codesign --force --timestamp=none --sign "$IDENTITY" "$@" 2>&1)" || { echo "$out" >&2; return 1; }
}

# Sign one app inside out, never with --deep: each piece keeps its own entitlements. Sparkle's
# helpers arrive ad-hoc signed and are re-signed with our certificate like the app. Hardened
# runtime stays off, as in the local build: its library validation refuses frameworks signed
# by a certificate without a Team ID, and nothing here is notarized.
sign_app() {
    local app="$1" entitlements="$2"
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"
    [ -d "$sparkle" ] || die "Sparkle.framework is missing from $app"
    local sparkle_dir item info
    sparkle_dir="$(cd "$sparkle/Versions/Current" && pwd -P)"
    for item in "$sparkle_dir"/XPCServices/*.xpc; do
        sign --preserve-metadata=entitlements "$item"     # Downloader.xpc has its own
    done
    sign "$sparkle_dir/Autoupdate"
    sign "$sparkle_dir/Updater.app"
    sign "$sparkle"
    while IFS= read -r -d '' item; do
        sign "$item"
    done < <(find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
        \( -name '*.framework' -o -name '*.dylib' \) ! -name Sparkle.framework -print0)
    for item in "$app"/Contents/XPCServices/*.xpc; do
        sign "$item"                                     # macshotOCR: unsandboxed by design
    done
    sign --entitlements "$entitlements" "$app"

    codesign --verify --deep --strict "$app" || die "codesign --verify failed for $app"
    for item in "$app" "$sparkle" "$sparkle_dir/Autoupdate" "$sparkle_dir/Updater.app" \
        "$sparkle_dir"/XPCServices/*.xpc "$app"/Contents/XPCServices/*.xpc; do
        info="$(codesign -dv --verbose=2 "$item" 2>&1)"
        [[ "$info" == *"Authority=$IDENTITY"* ]] || die "$item is not signed by $IDENTITY"
    done
    for item in "$sparkle_dir/XPCServices/Installer.xpc" "$app"/Contents/XPCServices/*.xpc; do
        info="$(codesign -d --entitlements - --xml "$item" 2>/dev/null || true)"
        [[ "$info" != *"app-sandbox"* ]] || die "$item is sandboxed; it could not do its job"
    done
    codesign -d --entitlements - --xml "$app" 2>/dev/null | python3 -c '
import plistlib, sys
ent = plistlib.loads(sys.stdin.buffer.read())
names = ent.get("com.apple.security.temporary-exception.mach-lookup.global-name", [])
need = [sys.argv[1] + "-spks", sys.argv[1] + "-spki"]
missing = [n for n in need if n not in names]
if missing or not ent.get("com.apple.security.app-sandbox") or "com.apple.security.get-task-allow" in ent:
    sys.exit(f"unexpected app entitlements: missing {missing}, keys {sorted(ent)}")' "$BUNDLE_ID" \
        || die "the entitlements of $app are wrong"
}

# Take a build product out of Launch Services. Every copy of the app it knows — Xcode's output,
# the split per-architecture copies, a mounted DMG — is a candidate when something opens the app
# by bundle ID (a notification click, System Settings' app list), and these copies are unsigned or
# about to be deleted. Only /Applications/MacShot.app should be left.
forget_app() {
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$1" >/dev/null 2>&1 || true
}

require_identity() {
    local signing
    signing="$(security find-identity -v -p codesigning)"
    [[ "$signing" == *"\"$IDENTITY\""* ]] \
        || die "signing identity '$IDENTITY' is not in the keychain (see scripts/build-install.sh)"
}

# Sparkle's installer is reached through mach services named after the bundle ID. The
# repository's entitlements spell them $(PRODUCT_BUNDLE_IDENTIFIER)-spks/-spki for Xcode to
# expand; these builds are signed outside Xcode, so they are written out here.
write_entitlements() {
    python3 - "$ROOT/macshot/macshot.entitlements" "$1" "$BUNDLE_ID" <<'PY'
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
}

# Write the update feed into a built app and sign it: the same for a release and a local install.
prepare_app() {
    local app="$1" build_number="$2" entitlements="$3"
    python3 - "$app/Contents/Info.plist" "$BUNDLE_ID" "$VERSION" "$build_number" \
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
PY
    sign_app "$app" "$entitlements"
}

# Split the universal build into one architecture, write the update feed into it, sign it,
# package its DMG, check what people will download, and sign the DMG for Sparkle.
package_arch() {
    local arch="$1" built="$2" build_number="$3" entitlements="$4" sparkle_bin="$5"
    local dir="$OUT/$arch"
    local app="$dir/$APP_NAME.app"
    local dmg
    dmg="$OUT/$(dmg_name "$arch")"

    step "[$arch] Splitting out the $arch app"
    mkdir -p "$dir"
    ditto --arch "$arch" "$built" "$app"
    local file archs
    while IFS= read -r -d '' file; do
        archs="$(lipo -archs "$file" 2>/dev/null)" || continue      # not Mach-O
        [ "$archs" = "$arch" ] || die "$file is '$archs' after splitting out $arch"
    done < <(find "$app" -type f -print0)

    step "[$arch] Writing the update feed and signing with $IDENTITY"
    prepare_app "$app" "$build_number" "$entitlements"

    step "[$arch] Packaging $(basename "$dmg")"
    local stage="$dir/dmg"
    mkdir -p "$stage"
    ditto "$app" "$stage/$APP_NAME.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" \
        >/dev/null 2>&1 || die "hdiutil could not create $dmg"
    rm -rf "$stage"

    local mount="$dir/mnt" mounted_ok=1
    mkdir -p "$mount"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg" >/dev/null 2>&1 \
        || die "hdiutil could not mount $dmg"
    codesign --verify --deep --strict "$mount/$APP_NAME.app" || mounted_ok=0
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$mount/$APP_NAME.app/Contents/Info.plist")" \
        = "$build_number" ] || mounted_ok=0
    [ "$(lipo -archs "$mount/$APP_NAME.app/Contents/MacOS/$APP_NAME")" = "$arch" ] || mounted_ok=0
    [ -L "$mount/Applications" ] || mounted_ok=0
    forget_app "$mount/$APP_NAME.app"
    hdiutil detach "$mount" >/dev/null 2>&1
    rmdir "$mount"
    forget_app "$app"
    [ "$mounted_ok" = 1 ] || die "the app inside $(basename "$dmg") failed its checks"

    step "[$arch] Signing the update for Sparkle"
    local signature
    signature="$("$sparkle_bin/sign_update" --account "$SPARKLE_ACCOUNT" -p "$dmg")"
    "$sparkle_bin/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$dmg" "$signature" >/dev/null \
        || die "the update signature of $(basename "$dmg") does not verify"
    printf '%s\n' "$signature" > "$dir/signature"
}

build() {
    require_identity
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
    forget_app "$built"
    local archs
    archs="$(lipo -archs "$built/Contents/MacOS/$APP_NAME")"
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] \
        || die "the binary is '$archs', expected arm64 and x86_64"
    local min_system
    min_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$built/Contents/Info.plist")"

    local entitlements="$OUT/macshot.entitlements"
    write_entitlements "$entitlements"

    local sparkle_bin="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
    [ -x "$sparkle_bin/sign_update" ] || die "Sparkle's sign_update is missing from $sparkle_bin"
    local keychain_key
    keychain_key="$("$sparkle_bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" \
        || die "no Sparkle key for account '$SPARKLE_ACCOUNT' in the keychain"
    [ "$keychain_key" = "$SPARKLE_PUBLIC_KEY" ] \
        || die "the keychain's Sparkle key ($keychain_key) is not the one installed copies trust"

    local arch
    for arch in "${ARCHES[@]}"; do
        package_arch "$arch" "$built" "$build_number" "$entitlements" "$sparkle_bin"
    done

    step "Writing the appcasts"
    local item_args=()
    for arch in "${ARCHES[@]}"; do
        item_args+=("$arch" "$(dmg_name "$arch")" "$(stat -f%z "$OUT/$(dmg_name "$arch")")" \
            "$(cat "$OUT/$arch/signature")")
    done
    python3 - "$OUT" "$VERSION" "$build_number" "$min_system" "$NOTES" "$REPO" "$TAG" \
        "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" "${item_args[@]}" <<'PY'
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr
out, version, build, min_system, notes_path, repo, tag, date, *rest = sys.argv[1:]
with open(notes_path, encoding="utf-8") as f:
    notes = f.read().strip().replace("]]>", "]]]]><![CDATA[>")
items = {}
for arch, name, length, signature in zip(rest[0::4], rest[1::4], rest[2::4], rest[3::4]):
    # Never offer the arm64 build to an Intel Mac, even from the combined appcast.xml.
    hardware = "\n      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>" if arch == "arm64" else ""
    url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    items[arch] = f'''    <item>
      <title>{escape(version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(min_system)}</sparkle:minimumSystemVersion>{hardware}
      <sparkle:fullReleaseNotesLink>https://github.com/{repo}/releases</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
{notes}
]]></description>
      <enclosure url={quoteattr(url)} length="{length}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>'''

def write(filename, arches):
    path = f"{out}/{filename}"
    body = "\n".join(items[a] for a in arches)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MacShot</title>
    <link>https://github.com/{repo}</link>
{body}
  </channel>
</rss>
''')
    ET.parse(path)

for arch in items:
    write(f"appcast-{arch}.xml", [arch])
# For builds without per-architecture feeds. arm64 first: on Apple silicon both items qualify
# and the first of equal versions wins; on Intel the arm64 one is ruled out.
write("appcast.xml", ["arm64", "x86_64"])
PY
    for arch in "${ARCHES[@]}"; do
        [ -s "$OUT/appcast-$arch.xml" ] || die "appcast-$arch.xml was not written"
    done

    {
        cat "$NOTES"
        printf '\n\n---\n\n'
        printf '**下载**：Apple 芯片（M1、M2 等）的 Mac 下载 `%s`，Intel 芯片的 Mac 下载 `%s`。需要 macOS %s 或更新。' \
            "$(dmg_name arm64)" "$(dmg_name x86_64)" "$min_system"
        printf '不确定是哪种：点左上角苹果菜单 › 关于本机，「芯片」一行写着 Apple 就是 Apple 芯片，「处理器」一行写着 Intel 就是 Intel。\n\n'
        printf '**第一次打开**：这个版本没有经过 Apple 公证，macOS 会拦下它。'
        printf '关掉弹出的提示，然后打开「系统设置 › 隐私与安全性」，往下翻到「安全性」，点 MacShot 那一行的「仍要打开」。'
        printf '之后有新版本时会收到系统通知，在 MacShot 的设置里更新，不用再这样操作。\n'
    } > "$OUT/github-notes.md"

    {
        echo "COMMIT=$commit"
        echo "BUILD_NUMBER=$build_number"
        for arch in "${ARCHES[@]}"; do
            echo "DMG_SHA256_$arch=$(shasum -a 256 "$OUT/$(dmg_name "$arch")" | awk '{print $1}')"
        done
    } > "$OUT/release.env"

    step "Built $APP_NAME $VERSION ($build_number) from ${commit:0:7}"
    for arch in "${ARCHES[@]}"; do
        echo "    $OUT/$(dmg_name "$arch") ($(du -h "$OUT/$(dmg_name "$arch")" | awk '{print $1}'))"
    done
    echo "    $OUT/appcast.xml, appcast-arm64.xml, appcast-x86_64.xml"
    echo "Publish with: scripts/release.sh $VERSION --publish"
}

publish() {
    [ -f "$OUT/release.env" ] || die "nothing built for $VERSION yet: run scripts/release.sh $VERSION"
    local commit arch want
    commit="$(sed -n 's/^COMMIT=//p' "$OUT/release.env")"
    [ "$(git rev-parse HEAD)" = "$commit" ] \
        || die "HEAD is no longer the built commit ${commit:0:7}; rebuild"
    local assets=()
    for arch in "${ARCHES[@]}"; do
        want="$(sed -n "s/^DMG_SHA256_$arch=//p" "$OUT/release.env")"
        [ "$(shasum -a 256 "$OUT/$(dmg_name "$arch")" | awk '{print $1}')" = "$want" ] \
            || die "$(dmg_name "$arch") changed since it was built; rebuild"
        assets+=("$OUT/$(dmg_name "$arch")" "$OUT/appcast-$arch.xml")
    done
    assets+=("$OUT/appcast.xml")
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
        --title "MacShot $VERSION" --notes-file "$OUT/github-notes.md" "${assets[@]}"
    echo "Released: https://github.com/$REPO/releases/tag/$TAG"
}

# Running copies of MacShot. Builds before the MacShot rename shipped a lowercase executable.
running_pids() { { pgrep -x "$APP_NAME" || true; pgrep -x macshot || true; } | tr '\n' ' '; }

quit_running() {
    osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
    local _
    for _ in $(seq 10); do
        [ -z "$(running_pids)" ] && break
        sleep 0.3
    done
    # Quit can be swallowed by a modal panel. Fall back to SIGTERM on exactly the pids just
    # resolved — never a name-pattern kill, which could hit unrelated processes.
    local stragglers
    stragglers="$(running_pids)"
    if [ -n "$stragglers" ]; then
        echo "    quit ignored; sending SIGTERM to: $stragglers"
        kill $stragglers 2>/dev/null || true
        sleep 0.5
    fi
    [ -z "$(running_pids)" ] || die "$APP_NAME is still running; quit it and retry"
}

install_local() {
    require_identity
    local arch build_number
    arch="$(uname -m)"
    build_number="$(git rev-list --count HEAD)"
    step "Building $APP_NAME $VERSION ($build_number) for $arch from the current code (log: $INSTALL_LOG)"
    xcodebuild -project "$ROOT/macshot.xcodeproj" -scheme macshot -configuration Release \
        -derivedDataPath "$INSTALL_DERIVED" \
        ARCHS="$arch" ONLY_ACTIVE_ARCH=NO \
        MACSHOT_BUNDLE_ID="$BUNDLE_ID" \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$build_number" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        build > "$INSTALL_LOG" 2>&1 \
        || { tail -30 "$INSTALL_LOG" >&2; die "build failed (full log: $INSTALL_LOG)"; }

    local built="$INSTALL_DERIVED/Build/Products/Release/$APP_NAME.app"
    [ -d "$built" ] || die "the build produced no app at $built"
    forget_app "$built"
    local archs
    archs="$(lipo -archs "$built/Contents/MacOS/$APP_NAME")"
    [[ " $archs " == *" $arch "* ]] || die "the binary is '$archs', expected $arch"

    local work
    work="$(mktemp -d /tmp/macshot-install.XXXXXX)"
    ditto "$built" "$work/$APP_NAME.app"
    write_entitlements "$work/macshot.entitlements"
    step "Writing the update feed and signing with $IDENTITY"
    prepare_app "$work/$APP_NAME.app" "$build_number" "$work/macshot.entitlements"

    step "Quitting the running copy"
    quit_running
    step "Replacing $INSTALL_TARGET"
    rm -rf "$INSTALL_TARGET"
    ditto "$work/$APP_NAME.app" "$INSTALL_TARGET"
    forget_app "$work/$APP_NAME.app"
    rm -rf "$work"
    step "Launching"
    open "$INSTALL_TARGET"
    echo "Installed $APP_NAME $VERSION ($build_number)"
}

case "$MODE" in
    install) install_local ;;
    publish) publish ;;
    *) build ;;
esac
