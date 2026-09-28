#!/usr/bin/env bash
# Notarize + staple a DMG. Needs: xcrun notarytool store-credentials horsetoga-notary …
set -euo pipefail
cd "$(dirname "$0")/.."
DMG="${1:?usage: notarize.sh release/HorseToga-<version>.dmg}"
PROFILE="${NOTARY_PROFILE:-horsetoga-notary}"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
# Gatekeeper's verdict on the app inside, exactly as a customer's Mac sees it.
MOUNT=$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}')
trap 'hdiutil detach "$MOUNT" -quiet' EXIT
spctl --assess --type execute --verbose=2 "$MOUNT/HorseToga.app"
echo "notarized + stapled $DMG"
