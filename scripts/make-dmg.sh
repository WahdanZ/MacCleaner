#!/bin/zsh
# Packs an app into a compressed DMG with an Applications shortcut (drag to install).
# Usage: scripts/make-dmg.sh APP OUTPUT.dmg [SIGNING_IDENTITY]
# With a signing identity the DMG itself is signed too (needed before notarizing it).
set -euo pipefail

APP="$1"
DMG="$2"
IDENTITY="${3:-}"
[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Mac Cleaner.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"

# hdiutil sometimes reports "Resource busy" on CI machines; try a few times.
for attempt in 1 2 3; do
  if hdiutil create -volname "Mac Cleaner" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null; then break; fi
  [[ $attempt == 3 ]] && { echo "hdiutil failed" >&2; exit 1; }
  sleep 5
done

[[ -n "$IDENTITY" ]] && codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "$DMG"
