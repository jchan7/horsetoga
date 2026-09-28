#!/usr/bin/env bash
# build/export/HorseToga.app → release/HorseToga-<version>.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/export/HorseToga.app
[[ -d $APP ]] || { echo "run scripts/build-release.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGE=build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE" release
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
OUT="release/HorseToga-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "HorseToga $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  codesign --sign "Developer ID Application" --timestamp "$OUT"
else
  echo "warn: DMG left unsigned (no Developer ID certificate)"
fi
echo "wrote $OUT"
