#!/bin/bash
# Fails if a test-only mode is compiled into an app meant to ship.
#   scripts/check-no-test-hooks.sh "build/Release/Mac Cleaner.app"
#   scripts/check-no-test-hooks.sh --expect-hooks "build/test-hooks/Release/Mac Cleaner.app"   (proves the check sees them)
set -euo pipefail
EXPECT=0
if [ "${1:-}" = "--expect-hooks" ]; then EXPECT=1; shift; fi
BIN="${1:?usage: check-no-test-hooks.sh [--expect-hooks] path/to/Mac Cleaner.app}/Contents/MacOS/Mac Cleaner"
test -x "$BIN"
N=$(strings -a "$BIN" | grep -c -e '--selftest-child' -e 'MACCLEANER_TEST_TRASH_DIR' || true)
if [ "$EXPECT" = 1 ]; then
  [ "$N" -gt 0 ] || { echo "✗ expected the test-hooks build to contain its test-only modes"; exit 1; }
  echo "✓ the test-hooks build contains its test-only mode (the check can see it)"
else
  [ "$N" = 0 ] || { echo "✗ $BIN contains a test-only mode (--selftest-child or MACCLEANER_TEST_TRASH_DIR)"; exit 1; }
  echo "✓ no test-only mode in $BIN"
fi
