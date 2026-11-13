#!/bin/zsh
# Finishes a release the Release workflow left as a DRAFT:
#   1. downloads its DMG and checksum,
#   2. verifies them (scripts/verify-release.sh: checksum, Developer ID team, notarization, Gatekeeper,
#      hardened runtime, entitlements, bundle ID, version) — nothing is signed if any check fails,
#   3. signs the DMG with the Ed25519 release key in your keychain (in-app updates need it),
#   4. verifies again including that signature, against the public key built into the app,
#   5. uploads MacCleaner-<version>.dmg.sig,
#   6. only with --publish: publishes the draft and starts the website deploy.
#
#   TEAM_ID=ABCDE12345 scripts/sign-release.sh v1.4.0             verify + sign; the release stays a draft
#   TEAM_ID=ABCDE12345 scripts/sign-release.sh v1.4.0 --publish   …and publish it
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?Usage: TEAM_ID=TEAMID scripts/sign-release.sh vX.Y.Z [--publish]}"
PUBLISH="${2:-}"
: "${TEAM_ID:?Set TEAM_ID to the 10-character Developer ID team that signs releases}"
V="${TAG#v}"
DMG="MacCleaner-$V.dmg"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

gh release download "$TAG" -p "$DMG" -p "$DMG.sha256" -D "$TMP"
scripts/verify-release.sh "$TMP/$DMG" --version "$V" --team "$TEAM_ID" --no-sig
swift scripts/release-key.swift sign "$TMP/$DMG" >/dev/null
scripts/verify-release.sh "$TMP/$DMG" --version "$V" --team "$TEAM_ID"
gh release upload "$TAG" "$TMP/$DMG.sig" --clobber
echo "Signed $TAG."

if [[ "$PUBLISH" == "--publish" ]]; then
  gh release edit "$TAG" --draft=false
  [[ "$V" == *-* ]] || gh workflow run pages.yml --ref main
  echo "Published $TAG. The app will now offer it as an update."
else
  echo "The release is still a draft. Check it on GitHub, then run: TEAM_ID=$TEAM_ID scripts/sign-release.sh $TAG --publish"
fi
