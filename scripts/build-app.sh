#!/bin/sh
# Builds Moonrow.app into build/. Usage: scripts/build-app.sh [debug|release]
# Run outside Claude Code's sandbox (SwiftPM needs it).
#
# Environment, all optional (the release workflow sets them):
#   MOONROW_VERSION        CFBundleShortVersionString, e.g. 1.2.0 (default: 0.1 plus git describe)
#   MOONROW_BUILD          CFBundleVersion (default: 1)
#   MOONROW_UNIVERSAL=1    build for arm64 and x86_64
#   MOONROW_SIGN_IDENTITY  codesign identity, e.g. "Developer ID Application: …" (default: ad hoc)
set -eu
config="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Source paths compiled in (#filePath, debug info) are made relative to the checkout.
set -- -c "$config" -Xswiftc -file-prefix-map -Xswiftc "$root/=" -Xcc "-ffile-prefix-map=$root/="
if [ "${MOONROW_UNIVERSAL:-0}" = 1 ]; then
  set -- "$@" --arch arm64 --arch x86_64
fi
swift build "$@" --product Moonrow
swift build "$@" --product moonrow-ssh-helper
bindir="$(swift build "$@" --show-bin-path)"

app="build/Moonrow.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bindir/Moonrow" "$app/Contents/MacOS/Moonrow"
# Runs ssh for the tunnels and answers its prompts; the app looks for it next to its executable.
cp "$bindir/moonrow-ssh-helper" "$app/Contents/MacOS/moonrow-ssh-helper"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" Assets/AppIcon.iconset
# Liquid Glass icon (macOS 26+): compile Assets/AppIcon.icon (Icon Composer) into Assets.car.
# Needs Xcode 26+'s actool. macOS 14-15 keep using AppIcon.icns (actool may regenerate it from
# AppIcon.icon). Without actool, or if it fails, the app ships the .icns only, as before.
icon_name_key=""
if [ -d Assets/AppIcon.icon ] && xcrun --find actool >/dev/null 2>&1; then
  partial="build/AppIcon-partial.plist"
  if xcrun actool Assets/AppIcon.icon \
       --compile "$app/Contents/Resources" \
       --app-icon AppIcon --include-all-app-icons \
       --platform macosx --target-device mac \
       --minimum-deployment-target 14.0 \
       --output-partial-info-plist "$partial" \
       --errors --warnings --output-format human-readable-text \
     && [ -f "$app/Contents/Resources/Assets.car" ]; then
    icon_name_key="<key>CFBundleIconName</key><string>AppIcon</string>"
  else
    echo "warning: actool could not compile Assets/AppIcon.icon; shipping AppIcon.icns only" >&2
  fi
  rm -f "$partial"
else
  echo "warning: no Xcode 26+ actool; shipping AppIcon.icns only (no Liquid Glass icon)" >&2
fi
version="${MOONROW_VERSION:-0.1 ($(git describe --tags --always --dirty 2>/dev/null || echo dev))}"
build_number="${MOONROW_BUILD:-1}"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Moonrow</string>
  <key>CFBundleIdentifier</key><string>app.moonrow.Moonrow</string>
  <key>CFBundleName</key><string>Moonrow</string>
  <key>CFBundleDisplayName</key><string>Moonrow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  $icon_name_key
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SQL File</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>sql</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# The helper is nested code: it's signed before the bundle that seals it. A real identity gets
# the hardened runtime and a secure timestamp, which notarization requires.
identity="${MOONROW_SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
  sign() { codesign --force --sign - "$@"; }
else
  sign() { codesign --force --sign "$identity" --options runtime --timestamp "$@"; }
fi
sign "$app/Contents/MacOS/moonrow-ssh-helper"
sign "$app"
echo "Built $root/$app"
