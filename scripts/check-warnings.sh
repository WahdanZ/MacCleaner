#!/bin/zsh
# Warning budget: fails on any Swift compiler warning that is not listed in scripts/warnings-baseline.txt.
#   scripts/check-warnings.sh [LOG]        LOG defaults to build/xcodebuild.log (written by scripts/xcbuild.sh)
#   scripts/check-warnings.sh --list [LOG] prints the current warnings in baseline format (to refresh the file)
# The baseline lists every accepted warning as "<file>: <message>" (no line numbers, so edits that move code
# don't break it; a message that repeats in a file is listed once per occurrence; a line may give alternative
# wordings from different Xcode versions as "<file>: <msg> || <file>: <msg>"). New warnings fail the check.
# A baseline entry whose warning no longer occurs also fails: remove it in the same PR, so a warning that is
# fixed and later reintroduced fails instead of being waved through by a stale entry.
# Never add a line to make a new warning pass: fix the warning, or record why in the PR and docs/architecture/DECISIONS.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST=0; [[ "${1:-}" == "--list" ]] && { LIST=1; shift; }
LOG="${1:-$ROOT/build/xcodebuild.log}"
BASE="${WARNINGS_BASELINE:-$ROOT/scripts/warnings-baseline.txt}"   # the override is for scripts/test-check-warnings.sh
[[ -f "$LOG" ]] || { echo "no build log at $LOG (run scripts/xcbuild.sh first)" >&2; exit 2; }
CURRENT="$(mktemp)"; trap 'rm -f "$CURRENT" "$CURRENT".base "$CURRENT".raw "$CURRENT".canon' EXIT
# Compiler warnings only; the AppIntents metadata notice is not a Swift diagnostic.
# (grep exits 1 on no match; that is the goal state once every warning is fixed, so it must not abort the script.)
{ grep -E '^/.*\.swift:[0-9]+:[0-9]+: warning: ' "$LOG" || true; } | sort -u \
  | sed -E 's|^.*/(Packages/.*\.swift):[0-9]+:[0-9]+: warning: |\1: |; s|^.*/(MacCleaner/.*\.swift):[0-9]+:[0-9]+: warning: |\1: |' \
  | sort > "$CURRENT"
if (( LIST )); then cat "$CURRENT"; exit 0; fi
{ grep -v -E '^\s*(#|$)' "$BASE" || true; } > "$CURRENT.raw"
# A baseline line may list the same warning as worded by different compilers: "<key> || <key>". CI (Xcode 16.x)
# and local builds (Xcode 26.x) word a few diagnostics differently. The first form is the canonical one.
awk -F' \\|\\| ' '{print $1}' "$CURRENT.raw" | sort > "$CURRENT.base"
awk -F' \\|\\| ' 'NR==FNR { for (i=2;i<=NF;i++) alias[$i]=$1; next } { print (($0 in alias) ? alias[$0] : $0) }' "$CURRENT.raw" "$CURRENT" | sort > "$CURRENT.canon"
NEW="$(comm -13 "$CURRENT.base" "$CURRENT.canon")"
GONE="$(comm -23 "$CURRENT.base" "$CURRENT.canon")"
TOTAL=$(wc -l < "$CURRENT" | tr -d ' ')
FAIL=0
if [[ -n "$GONE" ]]; then
  echo "Baseline warnings that no longer occur (remove these lines from scripts/warnings-baseline.txt in this PR):" >&2
  echo "$GONE" | sed 's/^/  - /' >&2
  echo "A stale entry would let the same warning come back unnoticed, so the budget must shrink with the code." >&2
  FAIL=1
fi
if [[ -n "$NEW" ]]; then
  echo "NEW compiler warnings (not in scripts/warnings-baseline.txt):" >&2; echo "$NEW" | sed 's/^/  + /' >&2
  echo "Fix them; the warning budget only goes down." >&2
  FAIL=1
fi
(( FAIL == 0 )) || exit 1
echo "Warning budget OK: $TOTAL warning(s), all in the baseline, none stale."
