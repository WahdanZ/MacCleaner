#!/bin/zsh
# Phase 6 — Developer ID build for other Macs: sign (hardened runtime) → notarize → staple → DMG.
#
# One-time setup (needs a paid Apple Developer account):
#   1. Xcode › Settings › Accounts › Manage Certificates › "+" › Developer ID Application
#   2. Create an app-specific password at https://account.apple.com, then:
#        xcrun notarytool store-credentials maccleaner-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#   3. Run:  TEAM_ID=TEAMID ./release.sh
#
# Result: build/Mac Cleaner.dmg, notarized and stapled. Full Disk Access then survives updates,
# because the signature (team ID) stays the same between builds.
set -e -o pipefail
cd "$(dirname "$0")"

: "${TEAM_ID:?Set TEAM_ID to your 10-character Apple team ID}"
PROFILE="${NOTARY_PROFILE:-maccleaner-notary}"
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | sed -E 's/.*"(.*)"/\1/')
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' certificate for team $TEAM_ID in your keychain (see step 1)."; exit 1; }
echo "Signing as: $IDENTITY"

xcodebuild -project MacCleaner.xcodeproj -target MacCleaner -configuration Release \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_ENTITLEMENTS=MacCleaner/MacCleaner.entitlements \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' | sort -u

APP="build/Release/Mac Cleaner.app"
echo "--- self-test"
scripts/selftest.sh "$APP" > /dev/null && echo "self-test passed"
codesign --verify --strict --deep "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q apple-events || { echo "entitlements missing"; exit 1; }

echo "--- notarize app"
ZIP="build/Mac Cleaner.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "--- DMG"
DMG="build/Mac Cleaner.dmg"
scripts/make-dmg.sh "$APP" "$DMG" "$IDENTITY"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "--- verify"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
scripts/verify-release.sh "$DMG" --version "$VERSION" --team "$TEAM_ID" --no-sig
echo "Done: $DMG"
