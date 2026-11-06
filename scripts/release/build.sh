#!/usr/bin/env bash
# Builds, signs and exports Hive.app for a release.
#
#   VERSION=1.0.0 BUILD_NUMBER=42 TEAM_ID=ABCDE12345 scripts/release/build.sh
#
# Needs a "Developer ID Application" identity for TEAM_ID in the keychain. Writes
# build/export/Hive.app.
set -euo pipefail

: "${VERSION:?set VERSION, e.g. 1.0.0}"
: "${TEAM_ID:?set TEAM_ID to the Developer ID team}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build"

rm -rf "$BUILD/Hive.xcarchive" "$BUILD/export"
mkdir -p "$BUILD"

xcodebuild archive \
  -project "$ROOT/hive.xcodeproj" \
  -scheme hive \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD/Hive.xcarchive" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | tail -n 20

test -d "$BUILD/Hive.xcarchive" || { echo "archive failed" >&2; exit 1; }

sed "s/__TEAM_ID__/$TEAM_ID/" "$ROOT/Support/ExportOptions.plist" > "$BUILD/ExportOptions.plist"
xcodebuild -exportArchive \
  -archivePath "$BUILD/Hive.xcarchive" \
  -exportPath "$BUILD/export" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist"

# The target is named hive; ship it as Hive.app. The signature covers the bundle's
# contents, not its folder name.
if [ -d "$BUILD/export/hive.app" ]; then mv "$BUILD/export/hive.app" "$BUILD/export/Hive.app"; fi
codesign --verify --deep --strict --verbose=2 "$BUILD/export/Hive.app"
echo "Built $BUILD/export/Hive.app ($VERSION, build $BUILD_NUMBER)"
