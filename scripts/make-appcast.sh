#!/bin/sh
# Signs build/release/Moonrow-<version>.zip (from scripts/package-release.sh) for Sparkle and
# writes build/release/appcast.xml, a feed with that one update and its release notes, the HTML
# page scripts/render-release-notes.swift writes, which Sparkle's update window shows.
# Usage: scripts/make-appcast.sh <version> <build number> <zip URL> <release notes HTML>
#
# The EdDSA private key (as `generate_keys -x` exports it) comes from SPARKLE_PRIVATE_KEY, or
# from the file SPARKLE_PRIVATE_KEY_FILE names. The signature is checked against the public key
# in build/Moonrow.app's Info.plist, so a key that doesn't match the app's fails here.
set -eu
version="${1:?usage: scripts/make-appcast.sh <version> <build number> <zip URL> <release notes HTML>}"
build_number="${2:?missing build number}"
zip_url="${3:?missing zip URL}"
notes_html="${4:?missing release notes HTML}"
[ -f "$notes_html" ] || { echo "error: no $notes_html" >&2; exit 1; }
# Read before the cd, so a relative path is the caller's. A "]]>" in the page would end the CDATA
# section, so it's split across two.
notes="$(sed 's/]]>/]]]]><![CDATA[>/g' "$notes_html")"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

out="build/release"
zip="$out/Moonrow-$version.zip"
[ -f "$zip" ] || { echo "error: no $zip; run scripts/package-release.sh first" >&2; exit 1; }

# Sparkle's tools, pinned to the framework's version and checked against the release's digest.
sparkle_version=2.10.0
sparkle_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
tools="build/sparkle-$sparkle_version"
if [ ! -x "$tools/bin/sign_update" ]; then
  rm -rf "$tools"
  mkdir -p "$tools"
  tarball="$tools.tar.xz"
  curl -fsSL -o "$tarball" "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
  echo "$sparkle_sha256  $tarball" | shasum -a 256 -c - >/dev/null
  tar -xf "$tarball" -C "$tools" ./bin
  rm "$tarball"
fi

# The key goes to sign_update on stdin, never on the command line.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/bin/sign_update" --ed-key-file - -p "$zip")"
elif [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
  signature="$("$tools/bin/sign_update" --ed-key-file - -p "$zip" < "$SPARKLE_PRIVATE_KEY_FILE")"
else
  echo "error: set SPARKLE_PRIVATE_KEY or SPARKLE_PRIVATE_KEY_FILE" >&2
  exit 1
fi
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/Moonrow.app/Contents/Info.plist)"
swift scripts/verify-ed25519.swift "$zip" "$signature" "$public_key"

length="$(stat -f %z "$zip")"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$out/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Moonrow</title>
    <item>
      <title>Moonrow $version</title>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$notes]]></description>
      <enclosure url="$zip_url" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$out/appcast.xml"
echo "Wrote $root/$out/appcast.xml"
