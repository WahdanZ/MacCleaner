#!/bin/zsh
# Builds the TEST-HOOKS variant of the app: Release settings plus MACCLEANER_TEST_HOOKS, into build/test-hooks.
#   scripts/build-test-hooks.sh        → build/test-hooks/Release/Mac Cleaner.app
# It adds test-only modes that must never ship (the self-test's crash child, `--selftest-child`). It is never
# signed for release or packaged: release.yml, release.sh and build.sh build the plain Release app, and
# scripts/check-no-test-hooks.sh fails if a test-only mode is found in it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/xcbuild.sh" CODE_SIGN_IDENTITY=- SYMROOT="$ROOT/build/test-hooks" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MACCLEANER_TEST_HOOKS'
test -x "$ROOT/build/test-hooks/Release/Mac Cleaner.app/Contents/MacOS/Mac Cleaner"
