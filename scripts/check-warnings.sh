#!/bin/zsh
# Warning budget: fails on any Swift compiler warning that is not listed in scripts/warnings-baseline.txt.
#   scripts/check-warnings.sh [LOG]        LOG defaults to build/xcodebuild.log (written by scripts/xcbuild.sh)
#   scripts/check-warnings.sh --list [LOG] prints the current warnings in baseline format (to refresh the file)
# The baseline lists every accepted warning as "<file>: <message>" (no line numbers, so edits that move code
# don't break it; a message that repeats in a file is listed once per occurrence). New warnings fail the check.
# Warnings that disappeared are reported so the baseline can shrink; remove those lines in the same PR.
# Never add a line to make a new warning pass: fix the warning, or record why in the PR and docs/architecture/DECISIONS.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST=0; [[ "${1:-}" == "--list" ]] && { LIST=1; shift; }
LOG="${1:-$ROOT/build/xcodebuild.log}"
BASE="$ROOT/scripts/warnings-baseline.txt"
[[ -f "$LOG" ]] || { echo "no build log at $LOG (run scripts/xcbuild.sh first)" >&2; exit 2; }
CURRENT="$(mktemp)"; trap 'rm -f "$CURRENT" "$CURRENT.base"' EXIT
# Compiler warnings only; the AppIntents metadata notice is not a Swift diagnostic.
# (grep exits 1 on no match; that is the goal state once every warning is fixed, so it must not abort the script.)
{ grep -E '^/.*\.swift:[0-9]+:[0-9]+: warning: ' "$LOG" || true; } | sort -u \
  | sed -E 's|^.*/(Packages/.*\.swift):[0-9]+:[0-9]+: warning: |\1: |; s|^.*/(MacCleaner/.*\.swift):[0-9]+:[0-9]+: warning: |\1: |' \
  | sort > "$CURRENT"
if (( LIST )); then cat "$CURRENT"; exit 0; fi
{ grep -v -E '^\s*(#|$)' "$BASE" || true; } | sort > "$CURRENT.base"
NEW="$(comm -13 "$CURRENT.base" "$CURRENT")"
GONE="$(comm -23 "$CURRENT.base" "$CURRENT")"
TOTAL=$(wc -l < "$CURRENT" | tr -d ' ')
[[ -z "$GONE" ]] || { echo "Warnings fixed since the baseline (remove these lines from scripts/warnings-baseline.txt):"; echo "$GONE" | sed 's/^/  - /'; }
if [[ -n "$NEW" ]]; then
  echo "NEW compiler warnings (not in scripts/warnings-baseline.txt):" >&2; echo "$NEW" | sed 's/^/  + /' >&2
  echo "Fix them; the warning budget only goes down." >&2; exit 1
fi
echo "Warning budget OK: $TOTAL warning(s), all in the baseline."
