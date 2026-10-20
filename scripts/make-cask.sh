#!/bin/sh
# Writes the Homebrew cask for a release to stdout: Casks/moonrow.rb in raf-a/homebrew-tap, which
# the Homebrew workflow updates when a release is published.
# Usage: scripts/make-cask.sh <version> <SHA256SUMS>
#
# SHA256SUMS is the release's own file, from scripts/package-release.sh; the cask installs the
# DMG and takes its checksum from there. The app updates itself, so the cask says
# `auto_updates`, and `brew upgrade` leaves it to Sparkle.
set -eu
usage="usage: scripts/make-cask.sh <version> <SHA256SUMS>"
version="${1:?$usage}"
sums="${2:?$usage}"
case "$version" in
  *-*) echo "error: $version is a prerelease; the cask only follows releases" >&2; exit 1 ;;
esac

dmg="Moonrow-$version.dmg"
sha="$(awk -v f="$dmg" '{ sub(/^\*/, "", $2) } $2 == f { print $1 }' "$sums")"
if ! printf '%s' "$sha" | grep -Eqx '[0-9a-f]{64}'; then
  echo "error: no checksum for $dmg in $sums" >&2
  exit 1
fi

cat <<EOF
cask "moonrow" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/raf-a/moonrow/releases/download/v#{version}/Moonrow-#{version}.dmg"
  name "Moonrow"
  desc "Database client for SQLite, PostgreSQL, MySQL and MariaDB"
  homepage "https://github.com/raf-a/moonrow"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Moonrow.app"

  zap trash: [
    "~/Library/Application Support/Moonrow",
    "~/Library/Caches/app.moonrow.Moonrow",
    "~/Library/HTTPStorages/app.moonrow.Moonrow",
    "~/Library/Preferences/app.moonrow.Moonrow.plist",
    "~/Library/Saved Application State/app.moonrow.Moonrow.savedState",
  ]
end
EOF
