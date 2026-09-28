#!/usr/bin/env bash
# One-command release: build → DMG → notarize → appcast → GitHub release → tag.
#   HORSETOGA_TEAM_ID=XXXXXXXXXX scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version>}"
RELEASES_REPO="${HORSETOGA_RELEASES_REPO:-jchan7/horsetoga}"
DOWNLOAD_PREFIX="https://github.com/$RELEASES_REPO/releases/download/v$VERSION/"

[[ -z $(git status --porcelain) ]] || { echo "working tree not clean — commit first"; exit 1; }
[[ -n "${HORSETOGA_TEAM_ID:-}" ]] || { echo "HORSETOGA_TEAM_ID is required for a real release (scripts/bootstrap.sh)"; exit 1; }

scripts/build-release.sh "$VERSION"
scripts/make-dmg.sh
DMG="release/HorseToga-$VERSION.dmg"
scripts/notarize.sh "$DMG"

# Sparkle's tools ship inside the resolved package.
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -maxdepth 6 -type d 2>/dev/null | head -1)
[[ -n $SPARKLE_BIN ]] || { echo "Sparkle tools not found — build once in Xcode so SPM resolves the package"; exit 1; }
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" release/

# Publish: the DMG and appcast.xml are both assets of this repo's GitHub release.
# Sparkle reads .../releases/latest/download/appcast.xml, which always resolves
# to the newest release, so no separate releases repo is needed.
gh release create "v$VERSION" "$DMG" release/appcast.xml --repo "$RELEASES_REPO" \
  --title "HorseToga $VERSION" --notes "HorseToga $VERSION" || \
  gh release upload "v$VERSION" "$DMG" release/appcast.xml --repo "$RELEASES_REPO" --clobber

git add project.yml
git commit -m "Release $VERSION" >/dev/null || true
git tag -f "v$VERSION"
echo
echo "released HorseToga $VERSION → $DOWNLOAD_PREFIX$(basename "$DMG")"
echo "push the tag when ready: git push origin main --tags"
