#!/bin/zsh
# Build → self-test → ad-hoc sign → install to /Applications.
set -e -o pipefail
cd "$(dirname "$0")"
xcodebuild -project MacCleaner.xcodeproj -target MacCleaner -configuration Release CODE_SIGN_IDENTITY=- build \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' | sort -u
APP="build/Release/Mac Cleaner.app"
echo "--- self-test"
"$APP/Contents/MacOS/Mac Cleaner" --selftest
codesign --force --deep --sign - "$APP"
pkill -x "Mac Cleaner" || true
sleep 1
rm -rf "/Applications/Mac Cleaner.app"
ditto "$APP" "/Applications/Mac Cleaner.app"
codesign --verify "/Applications/Mac Cleaner.app" && echo "installed, signature valid"
