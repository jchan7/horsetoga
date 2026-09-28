#!/usr/bin/env bash
# Checks the release toolchain and prints what's missing. Nothing is installed for you.
set -u
ok=1
check() { if command -v "$1" >/dev/null 2>&1; then echo "  ok   $1"; else echo "  MISSING $1  →  $2"; ok=0; fi; }
echo "HorseToga release toolchain:"
check brew     "/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
check xcodegen "brew install xcodegen"
check gh       "brew install gh && gh auth login"
check xcodebuild "install Xcode 26+ from the App Store"
echo
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "  ok   Developer ID Application certificate"
else
  echo "  MISSING Developer ID Application certificate → enroll at developer.apple.com, then Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates"
  ok=0
fi
if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-horsetoga-notary}" >/dev/null 2>&1; then
  echo "  ok   notarytool profile '${NOTARY_PROFILE:-horsetoga-notary}'"
else
  echo "  MISSING notarytool profile → xcrun notarytool store-credentials ${NOTARY_PROFILE:-horsetoga-notary} --apple-id <id> --team-id <TEAM> --password <app-specific-password>"
  ok=0
fi
[[ -n "${HORSETOGA_TEAM_ID:-}" ]] && echo "  ok   HORSETOGA_TEAM_ID=$HORSETOGA_TEAM_ID" || { echo "  MISSING HORSETOGA_TEAM_ID env var (your 10-char Apple team id)"; ok=0; }
echo
[[ $ok == 1 ]] && echo "ready to release" || echo "fix the items above, then run scripts/release.sh <version>"
