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

# Settings (UserDefaults) are not moved by CFFIXED_USER_HOME: cfprefsd still uses ~/Library/Preferences.
# The self-test keeps its settings in memory instead; check that the user's own list is unchanged and that
# no settings file was written.
REAL_PREFS="$(/usr/bin/defaults read io.github.wahdanz.maccleaner protectedPaths 2>/dev/null | /usr/bin/shasum || true)"
LEFT_BEFORE="$(ls "$HOME/Library/Preferences" 2>/dev/null | grep -c 'maccleaner.selftest' || true)"

# CFFIXED_USER_HOME makes Foundation (homeDirectoryForCurrentUser, NSHomeDirectory) use TEST_HOME.
set +e
CFFIXED_USER_HOME="$TEST_HOME" "$BIN" --selftest
CODE=$?
set -e

if [[ "$(/usr/bin/defaults read io.github.wahdanz.maccleaner protectedPaths 2>/dev/null | /usr/bin/shasum || true)" != "$REAL_PREFS" ]]; then
  echo "FAILED: your Protected list changed during the self-test" >&2; exit 3
fi
LEFT_AFTER="$(ls "$HOME/Library/Preferences" 2>/dev/null | grep -c 'maccleaner.selftest' || true)"
if (( LEFT_AFTER > LEFT_BEFORE )); then
  echo "FAILED: the self-test wrote $((LEFT_AFTER - LEFT_BEFORE)) settings file(s) to ~/Library/Preferences" >&2; exit 3
fi
exit $CODE
