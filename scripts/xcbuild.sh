#!/bin/zsh
# The one way to build the app from the command line (CI, release workflow, build.sh, release.sh).
#   scripts/xcbuild.sh [BUILD_SETTING=value …]      e.g. scripts/xcbuild.sh CODE_SIGN_IDENTITY=-
# Builds the MacCleaner target (Release) and the local package it links (Packages/MacCleanerKit).
# Result: build/Release/Mac Cleaner.app. Prints errors and warnings; the full log is build/xcodebuild.log.
#
# Why SYMROOT is set: in a target-based build (-target) every project uses its own build folder, so the
# local package's module would land in Packages/MacCleanerKit/build and the app's compile wouldn't find
# it ("no such module 'MacCleanerCore'"). One shared, absolute build folder for both fixes that, on a
# fresh checkout, with every Xcode version we use (16.x on CI, 26.x locally).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
LOG="$ROOT/build/xcodebuild.log"
set +e
xcodebuild -project "$ROOT/MacCleaner.xcodeproj" -target MacCleaner -configuration Release \
  SYMROOT="$ROOT/build" "$@" build > "$LOG" 2>&1
STATUS=$?
set -e
grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' "$LOG" | grep -v appintentsmetadataprocessor | sort -u || true
[[ $STATUS == 0 ]] && grep -q 'BUILD SUCCEEDED' "$LOG" || { echo "Build failed (full log: $LOG)" >&2; exit 1; }
