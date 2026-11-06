#!/usr/bin/env bash
# Packages a notarized Hive.app for a release: a disk image for people, a zip for the
# in-app updater, checksums.txt for both, and a Homebrew cask.
#
#   VERSION=1.0.0 TEAM_ID=ABCDE12345 scripts/release/package.sh
#
# Writes to build/release/. Sign the disk image's notarization separately with notarize.sh.
set -euo pipefail

: "${VERSION:?}" "${TEAM_ID:?}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/export/Hive.app"
OUT="$ROOT/build/release"
test -d "$APP" || { echo "no $APP; run build.sh first" >&2; exit 1; }

rm -rf "$OUT" && mkdir -p "$OUT"
DMG="$OUT/Hive-$VERSION.dmg"
ZIP="$OUT/Hive-$VERSION.zip"

# A disk image with the app and a link to /Applications to drag it to.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Hive.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Hive $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

# The updater's archive: ditto keeps the signature's extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Packaged $DMG and $ZIP"
