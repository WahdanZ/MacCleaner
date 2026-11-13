#!/bin/zsh
# Runs the safety self-test in a fresh, throwaway home folder, so it can never read or change your
# own files. Usage: scripts/selftest.sh [path/to/Mac Cleaner.app]
set -e -o pipefail
APP="${1:-build/Release/Mac Cleaner.app}"
BIN="$APP/Contents/MacOS/Mac Cleaner"
[[ -x "$BIN" ]] || { echo "No app at $APP — build first." >&2; exit 2; }

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/maccleaner-selftest-home.XXXXXXXX")"
trap 'chmod -R u+rwX "$TEST_HOME" 2>/dev/null; rm -rf "$TEST_HOME"' EXIT
# The standard folders the guards and fixtures expect to find in a home folder.
mkdir -p "$TEST_HOME"/{Documents,Downloads,Desktop,Movies,Pictures,Music,Public,.cache,.Trash} \
         "$TEST_HOME"/Library/{Caches,Keychains,Logs,Preferences,"Application Support",Containers}

# CFFIXED_USER_HOME makes Foundation (homeDirectoryForCurrentUser, NSHomeDirectory) use TEST_HOME.
CFFIXED_USER_HOME="$TEST_HOME" "$BIN" --selftest
