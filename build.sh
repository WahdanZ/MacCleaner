#!/bin/zsh
# Build → self-test → ad-hoc sign → install to /Applications.
set -e -o pipefail
cd "$(dirname "$0")"
swift test --package-path Packages/MacCleanerKit 2>&1 | tail -1
scripts/xcbuild.sh CODE_SIGN_IDENTITY=-
APP="build/Release/Mac Cleaner.app"
echo "--- self-test"
scripts/selftest.sh "$APP"
codesign --force --deep --sign - "$APP"
pkill -x "Mac Cleaner" || true
sleep 1
rm -rf "/Applications/Mac Cleaner.app"
ditto "$APP" "/Applications/Mac Cleaner.app"
codesign --verify "/Applications/Mac Cleaner.app" && echo "installed, signature valid"
