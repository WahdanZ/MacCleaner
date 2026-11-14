#!/bin/zsh
# Synthetic tests for scripts/check-warnings.sh (no build needed). Run in CI before the real check.
#   scripts/test-check-warnings.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-warnings.sh"
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
P=/Users/runner/work/MacCleaner/MacCleaner
A="main actor-isolated static property 'k' can not be referenced from a nonisolated context"
B16="capture of 'b' with non-sendable type 'T' in a '@Sendable' closure"   # Xcode 16.x wording
B26="capture of 'b' with non-Sendable type 'T' in a '@Sendable' closure"   # Xcode 26.x wording
FAILS=0
log() { for w in "$@"; do print -r -- "$P/MacCleaner/${w%%|*}.swift:1:1: warning: ${w#*|}"; done > "$D/log"; }
base() { { print "# test baseline"; for l in "$@"; do print -r -- "$l"; done; } > "$D/base"; }
run() { WARNINGS_BASELINE="$D/base" "$CHECK" "$D/log" >/dev/null 2>&1; }
expect() { # expect <pass|fail> <name>
  run; local rc=$?
  if [[ $1 == pass && $rc == 0 ]] || [[ $1 == fail && $rc == 1 ]]; then print "ok   $2"; else print "FAIL $2 (rc=$rc, wanted $1)"; FAILS=$((FAILS+1)); fi
}
ENTRY_A="MacCleaner/A.swift: $A"
ENTRY_B="MacCleaner/B.swift: $B26 || MacCleaner/B.swift: $B16"
base "$ENTRY_A" "$ENTRY_B"
log "A|$A" "B|$B26";          expect pass "Xcode 26 wording passes"
log "A|$A" "B|$B16";          expect pass "Xcode 16 wording passes"
log "A|$A" "B|$B16" "C|new";  expect fail "a new warning fails"
log "B|$B26";                 expect fail "a fixed warning with a stale baseline entry fails"
base "$ENTRY_B";              expect pass "removing the fixed warning from the baseline passes"
log "A|$A" "B|$B26";          expect fail "reintroducing the warning later fails"
log "B|$B26" "B2|$B26";       expect fail "an unlisted warning with the same text in another file fails"
: > "$D/log"; base "$ENTRY_A"; expect fail "no warnings at all while the baseline still lists one fails"
: > "$D/log"; base;           expect pass "no warnings and an empty baseline passes"
(( FAILS == 0 )) && print "check-warnings tests passed" || { print "$FAILS check-warnings test(s) failed" >&2; exit 1; }
