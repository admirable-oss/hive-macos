#!/usr/bin/env bash
# Notarizes and staples a signed app or disk image.
#
#   APPLE_ID=me@example.com APPLE_TEAM_ID=ABCDE12345 APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#     scripts/release/notarize.sh build/export/Hive.app
#
# APPLE_APP_PASSWORD is an app-specific password for APPLE_ID.
set -euo pipefail

TARGET="${1:?the .app or .dmg to notarize}"
: "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"

SUBMIT="$TARGET"
if [ -d "$TARGET" ]; then
  # notarytool takes a zip, a dmg or a pkg, not a bare bundle.
  SUBMIT="$(mktemp -d)/$(basename "$TARGET").zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

xcrun notarytool submit "$SUBMIT" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait --timeout 30m
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [ -d "$TARGET" ]; then
  spctl --assess --type exec --verbose=2 "$TARGET"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
fi
