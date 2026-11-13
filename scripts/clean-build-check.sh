#!/bin/zsh
# Proves a fresh checkout builds and passes its tests, without any build output or package state from
# this working copy: checks out the committed HEAD into a new temporary worktree, then runs exactly what
# CI runs there — swift test (fresh scratch folder), scripts/xcbuild.sh, the MacCleanerCore link check and
# the isolated self-test. Uncommitted changes are NOT included. The worktree is removed afterwards.
#   scripts/clean-build-check.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WT="$(mktemp -d "${TMPDIR:-/tmp}/maccleaner-clean.XXXXXXXX")"
trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"' EXIT
git -C "$REPO" worktree add --quiet --detach "$WT" HEAD
cd "$WT"
echo "Clean check of $(git rev-parse --short HEAD) in $WT"
[[ ! -e build && ! -e Packages/MacCleanerKit/build && ! -e Packages/MacCleanerKit/.build ]] || { echo "not clean" >&2; exit 1; }
echo "--- swift test (Core package)"
swift test --package-path Packages/MacCleanerKit --scratch-path "$WT/.spm" 2>&1 | tail -1
echo "--- build (scripts/xcbuild.sh)"
scripts/xcbuild.sh CODE_SIGN_IDENTITY=-
APP="build/Release/Mac Cleaner.app"
N=$(nm -U "$APP/Contents/MacOS/Mac Cleaner" | grep -c MacCleanerCore || true); (( N > 0 )) || { echo "MacCleanerCore is not linked into the app" >&2; exit 1; }; echo "MacCleanerCore is linked into the app ($N symbols)"
echo "--- self-test (throwaway home)"
scripts/selftest.sh "$APP" | tail -1
echo "Clean check passed."
