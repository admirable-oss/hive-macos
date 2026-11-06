#!/usr/bin/env bash
# Writes the Homebrew cask for a release, from its disk image's checksum.
#
#   VERSION=1.0.0 scripts/release/cask.sh build/release > hive-desktop.rb
set -euo pipefail

: "${VERSION:?}"
DIR="${1:?the release directory}"
REPO="${GITHUB_REPOSITORY:-admirable-oss/hive-macos}"
SHA="$(shasum -a 256 "$DIR/Hive-$VERSION.dmg" | cut -d' ' -f1)"

cat <<CASK
cask "hive-desktop" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Hive-#{version}.dmg"
  name "Hive Desktop"
  desc "Native macOS command center for coding agents running in Hive"
  homepage "https://hive.admir-saheta.com"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself from signed GitHub releases.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Hive.app"

  zap trash: [
    "~/Library/Application Support/Hive Desktop",
    "~/Library/Preferences/com.admirable-oss.hive.desktop.plist",
    "~/Library/Saved Application State/com.admirable-oss.hive.desktop.savedState",
  ]

  caveats <<~EOS
    Hive Desktop needs the Hive runtime. It offers to install it on first launch,
    or install it yourself: https://hive.admir-saheta.com/docs/getting-started/installation
  EOS
end
CASK
