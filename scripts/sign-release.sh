#!/bin/zsh
# Signs a published release for in-app updates: downloads its DMG, checks the SHA-256, signs it with
# the release key in your keychain, and uploads MacCleaner-<version>.dmg.sig to the release.
# Until a release has its .sig, the app doesn't offer it as an update.
#   scripts/sign-release.sh v1.4.0
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?Usage: scripts/sign-release.sh vX.Y.Z}"
V="${TAG#v}"
DMG="MacCleaner-$V.dmg"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

gh release download "$TAG" -p "$DMG" -p "$DMG.sha256" -D "$TMP"
(cd "$TMP" && shasum -a 256 -c "$DMG.sha256")
swift scripts/release-key.swift sign "$TMP/$DMG" >/dev/null
gh release upload "$TAG" "$TMP/$DMG.sig" --clobber
echo "Signed $TAG. The app will now offer it as an update."
