#!/usr/bin/env bash
# 1024×1024 PNG → HorseToga/Resources/Assets.xcassets/AppIcon.appiconset (all macOS sizes).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:?usage: make-icon.sh <icon-1024.png>}"
DEST=HorseToga/Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$DEST"
emit() { sips -z "$2" "$2" "$SRC" --out "$DEST/$1" >/dev/null; }
emit icon_16x16.png 16;    emit icon_16x16@2x.png 32
emit icon_32x32.png 32;    emit icon_32x32@2x.png 64
emit icon_128x128.png 128; emit icon_128x128@2x.png 256
emit icon_256x256.png 256; emit icon_256x256@2x.png 512
emit icon_512x512.png 512; emit icon_512x512@2x.png 1024
cat > "$DEST/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "wrote $DEST"
