#!/bin/sh
# Checks a release on GitHub, usually the draft the Release workflow made, before anyone
# publishes it. Downloads its files, then checks the checksums, the appcast against the zip, the
# zip's EdDSA signature against the app's own key, the app's version, build number,
# architectures, code signature and notarization, and the DMG's signature and contents.
# Usage: scripts/check-release.sh <version> [<download folder>]
#
# Needs gh signed in to the repository. Run it outside a sandbox: codesign and spctl can report
# a valid signature as invalid inside one.
set -u
version="${1:?usage: scripts/check-release.sh <version> [<download folder>]}"
tag="v$version"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
dir="${2:-build/check-$version}"

failures=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
note() { echo "note  $1"; }
check() {
  description="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
same() { [ "$1" = "$2" ]; }

repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || exit 1
field() { gh release view "$tag" --json "$1" --jq ".$1"; }
url="$(field url)" || { echo "error: no release $tag on $repo" >&2; exit 1; }
echo "Checking $url"

# The release itself.
if [ "$(field isDraft)" = true ]; then pass "it's a draft"; else note "it's already published"; fi
check "it's named “Moonrow $version”" same "$(field name)" "Moonrow $version"
case "$version" in
  *-*) check "it's a prerelease" same "$(field isPrerelease)" true ;;
  *) check "it isn't a prerelease" same "$(field isPrerelease)" false ;;
esac
assets="$(gh release view "$tag" --json assets --jq '.assets[].name')"
for name in "Moonrow-$version.dmg" "Moonrow-$version.zip" SHA256SUMS appcast.xml; do
  check "it has $name" sh -c 'printf "%s\n" "$1" | grep -qxF "$2"' - "$assets" "$name"
done

rm -rf "$dir"
mkdir -p "$dir"
gh release download "$tag" -D "$dir" || { echo "error: couldn't download $tag" >&2; exit 1; }
zip="$dir/Moonrow-$version.zip"
dmg="$dir/Moonrow-$version.dmg"
appcast="$dir/appcast.xml"
check "the files match SHA256SUMS" sh -c 'cd "$1" && shasum -a 256 -c SHA256SUMS' - "$dir"

# The appcast: what Sparkle reads, and what it checks the download against.
xpath() { xmllint --xpath "string(//*[local-name()='item']/$1)" "$appcast" 2>/dev/null; }
check "appcast.xml is well formed" xmllint --noout "$appcast"
build="$(xpath "*[local-name()='version']")"
signature="$(xpath "*[local-name()='enclosure']/@*[local-name()='edSignature']")"
check "the appcast's version is $version" same "$(xpath "*[local-name()='shortVersionString']")" "$version"
check "the appcast's build number is set ($build)" test -n "$build"
check "the appcast's minimum macOS is set" test -n "$(xpath "*[local-name()='minimumSystemVersion']")"
check "the appcast downloads this release's zip" \
  same "$(xpath "*[local-name()='enclosure']/@url")" "https://github.com/$repo/releases/download/$tag/Moonrow-$version.zip"
check "the appcast's length is the zip's" same "$(xpath "*[local-name()='enclosure']/@length")" "$(stat -f %z "$zip")"
notes="$(xpath "*[local-name()='description']")"
title="$(printf '%s' "$notes" | sed -n 's:.*<h1>\(.*\)</h1>.*:\1:p' | head -1)"
check "the appcast has release notes${title:+ (“$title”)}" test -n "$title"

# The app in the zip, which is what Sparkle installs.
ditto -x -k "$zip" "$dir/zip"
app="$dir/zip/Moonrow.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null; }
check "the zip holds Moonrow.app" test -d "$app"
check "the app's version is $version" same "$(plist CFBundleShortVersionString)" "$version"
check "the app's build number is the appcast's" same "$(plist CFBundleVersion)" "$build"
check "the app reads the release feed" \
  same "$(plist SUFeedURL)" "https://github.com/$repo/releases/latest/download/appcast.xml"
check "the zip's EdDSA signature matches the app's key" \
  swift scripts/verify-ed25519.swift "$zip" "$signature" "$(plist SUPublicEDKey)"
archs="$(lipo -archs "$app/Contents/MacOS/Moonrow" 2>/dev/null)"
check "the app is universal ($archs)" sh -c 'case " $1 " in *" arm64 "*) ;; *) exit 1 ;; esac; case " $1 " in *" x86_64 "*) ;; *) exit 1 ;; esac' - "$archs"
check "the app's code signature is valid" codesign --verify --deep --strict "$app"
check "the app is signed with a Developer ID" sh -c 'codesign -dvv "$1" 2>&1 | grep -q "Authority=Developer ID Application"' - "$app"
check "the app is notarized" sh -c 'spctl -a -t exec -vv "$1" 2>&1 | grep -q "source=Notarized Developer ID"' - "$app"
check "the app's ticket is stapled" xcrun stapler validate "$app"

# The DMG people download from the release page.
check "the DMG's signature is valid" codesign --verify "$dmg"
check "the DMG's ticket is stapled" xcrun stapler validate "$dmg"
mount="$dir/dmg"
if hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"; then
  check "the DMG's app is $version" \
    same "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mount/Moonrow.app/Contents/Info.plist" 2>/dev/null)" "$version"
  check "the DMG links to Applications" test -L "$mount/Applications"
  hdiutil detach -quiet "$mount"
else
  fail "the DMG mounts"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All checks passed. Files are in $dir."
else
  echo "$failures check(s) failed. Files are in $dir."
  exit 1
fi
