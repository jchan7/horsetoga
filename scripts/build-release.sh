#!/usr/bin/env bash
# Release build → build/export/HorseToga.app. Developer ID-signed when HORSETOGA_TEAM_ID is
# set and the certificate exists; otherwise an ad-hoc build for local testing.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: build-release.sh <version> [build-number]}"
BUILD="${2:-$(git rev-list --count HEAD)}"

# project.yml is the source of truth; mirror into the generated pbxproj when xcodegen is absent.
sed -i '' -E "s/^( *MARKETING_VERSION:).*/\1 $VERSION/; s/^( *CURRENT_PROJECT_VERSION:).*/\1 $BUILD/" project.yml
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
else
  echo "warn: xcodegen not installed — reusing HorseToga.xcodeproj and patching versions in place"
  sed -i '' -E "s/(MARKETING_VERSION = )[^;]*;/\1$VERSION;/; s/(CURRENT_PROJECT_VERSION = )[^;]*;/\1$BUILD;/" HorseToga.xcodeproj/project.pbxproj
fi

rm -rf build/HorseToga.xcarchive build/export
mkdir -p build

SIGNED=0
if [[ -n "${HORSETOGA_TEAM_ID:-}" ]] && security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  SIGNED=1
  SIGN_ARGS=(HORSETOGA_TEAM_ID="$HORSETOGA_TEAM_ID")
elif security find-identity -p codesigning 2>/dev/null | grep -q "${HORSETOGA_SIGN_ID:-HorseToga Signing}"; then
  # No Developer ID, but a stable self-signed identity exists: use it instead of
  # ad-hoc so the shipped app's code identity is stable across updates and macOS
  # doesn't re-prompt every user for Keychain access after each update. Still not
  # notarizable (Gatekeeper will warn on first open), but far better UX than ad-hoc.
  echo "signing with self-signed identity '${HORSETOGA_SIGN_ID:-HorseToga Signing}' (no Developer ID → not notarized, but stable Keychain trust)"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="${HORSETOGA_SIGN_ID:-HorseToga Signing}" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=)
else
  echo "!! no HORSETOGA_TEAM_ID / Developer ID and no self-signed identity → AD-HOC build (runs locally, NOT distributable, re-prompts Keychain each update)"
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=)
fi

xcodebuild archive \
  -project HorseToga.xcodeproj -scheme HorseToga -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/HorseToga.xcarchive \
  "${SIGN_ARGS[@]}" \
  | grep -E "error:|warning: .*code ?sign|ARCHIVE" || true
[[ -d build/HorseToga.xcarchive/Products/Applications/HorseToga.app ]] || { echo "archive failed"; exit 1; }

mkdir -p build/export
if [[ $SIGNED == 1 ]]; then
  sed "s/TEAM_ID/$HORSETOGA_TEAM_ID/" scripts/exportOptions.template.plist > build/exportOptions.plist
  xcodebuild -exportArchive -archivePath build/HorseToga.xcarchive \
    -exportOptionsPlist build/exportOptions.plist -exportPath build/export | grep -E "error:|EXPORT" || true
else
  cp -R build/HorseToga.xcarchive/Products/Applications/HorseToga.app build/export/
fi

codesign --verify --deep --strict --verbose=2 build/export/HorseToga.app
codesign -dv build/export/HorseToga.app 2>&1 | grep -E "Authority|Identifier|flags" || true
echo "built build/export/HorseToga.app  (version $VERSION build $BUILD, signed=$SIGNED)"
