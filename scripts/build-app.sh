#!/bin/sh
# Builds Tabula.app into build/. Usage: scripts/build-app.sh [debug|release]
# Run outside Claude Code's sandbox (SwiftPM needs it).
set -eu
config="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c "$config" --product Tabula
bin="$(swift build -c "$config" --show-bin-path)/Tabula"

app="build/Tabula.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Tabula"
version="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Tabula</string>
  <key>CFBundleIdentifier</key><string>dev.tabula.Tabula</string>
  <key>CFBundleName</key><string>Tabula</string>
  <key>CFBundleDisplayName</key><string>Tabula</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1 ($version)</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SQLite Database</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>sqlite</string><string>sqlite3</string><string>db</string><string>db3</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Built $root/$app"
