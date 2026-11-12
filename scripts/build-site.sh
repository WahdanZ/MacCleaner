#!/bin/bash
# Assembles the product page into OUT (default: _site) from website/ and docs/screenshots/.
# Fills {{VERSION}} and {{DMG_SIZE}} from the newest release tag, so the page needs no JavaScript.
#   scripts/build-site.sh [OUT]          (uses `gh` for the DMG size when it is available)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-_site}"

VERSION=$(git tag --list 'v*' --sort=-v:refname | grep -v -- '-' | head -1 | sed 's/^v//')
: "${VERSION:?no release tag found}"

SIZE=""
if command -v gh >/dev/null 2>&1; then
  BYTES=$(gh release view "v$VERSION" --json assets \
            --jq ".assets[] | select(.name == \"MacCleaner-$VERSION.dmg\") | .size" 2>/dev/null || true)
  [[ -n "$BYTES" ]] && SIZE=$(awk -v b="$BYTES" 'BEGIN { printf "%.1f MB", b / 1000000 }')
fi
echo "version $VERSION, DMG ${SIZE:-size unknown}"

mkdir -p "$OUT" && find "$OUT" -mindepth 1 -delete   # keep the folder itself (a preview server may be serving it)
mkdir -p "$OUT/screenshots"
cp -R website/. "$OUT/"
cp docs/screenshots/*.png "$OUT/screenshots/"

for f in "$OUT"/*.html; do
  sed -e "s/{{VERSION}}/$VERSION/g" \
      -e "s/{{DMG_SIZE}}/${SIZE:-DMG}/g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
if grep -q '{{' "$OUT"/*.html; then echo "unfilled placeholder"; exit 1; fi
echo "built $OUT"
