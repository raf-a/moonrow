#!/bin/sh
# Packages build/Moonrow.app (from scripts/build-app.sh) for a release, into build/release/:
# Moonrow-<version>.dmg, Moonrow-<version>.zip and SHA256SUMS.
# Usage: scripts/package-release.sh <version>
#
# Notarizes and staples when an App Store Connect API key is in the environment:
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, and NOTARY_KEY_PATH (the .p8 file).
# The app must then be signed with a Developer ID (MOONROW_SIGN_IDENTITY in build-app.sh).
set -eu
version="${1:?usage: scripts/package-release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

app="build/Moonrow.app"
out="build/release"
[ -d "$app" ] || { echo "error: no $app; run scripts/build-app.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$app"
rm -rf "$out"
mkdir -p "$out"

notarize=0
if [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] && [ -n "${NOTARY_KEY_PATH:-}" ]; then
  notarize=1
fi
submit() {
  xcrun notarytool submit "$1" --wait \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
}

# The app is notarized first (through a zip, which notarytool accepts) so its ticket can be
# stapled before it goes into the DMG and the zip people download.
if [ "$notarize" = 1 ]; then
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  submit "$out/notarize.zip"
  rm "$out/notarize.zip"
  xcrun stapler staple "$app"
fi

zip="$out/Moonrow-$version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

dmg="$out/Moonrow-$version.dmg"
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Moonrow.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "Moonrow $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$staging"
if [ -n "${MOONROW_SIGN_IDENTITY:-}" ] && [ "$MOONROW_SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$MOONROW_SIGN_IDENTITY" --timestamp "$dmg"
fi
if [ "$notarize" = 1 ]; then
  submit "$dmg"
  xcrun stapler staple "$dmg"
fi

(cd "$out" && shasum -a 256 "Moonrow-$version.dmg" "Moonrow-$version.zip" > SHA256SUMS)
echo "Packaged $root/$out:"
ls -1 "$out"
