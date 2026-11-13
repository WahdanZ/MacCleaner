#!/bin/bash
# Fails when a cleanup approval could be issued outside a verified confirmation boundary (M01-04b).
#
# This only finds UNEXPECTED CALL SITES in the source. It does not prove that a person confirmed anything; the
# self-test checks the confirmation behaviour itself (scripts/selftest.sh, "Approved Trash").
#
# Allowed:
#   * approvals issued (CleanupExecutor.approve / an Approver label): MacCleaner/ReviewConfirmation.swift
#   * ReviewConfirmation.confirm(...) called: the review sheet (MacCleaner/Review.swift) and the self-test
#   * ApprovedTrash(...) made: MacCleaner/ReviewConfirmation.swift
#   * inside MacCleanerKit, approvals are issued only by CleanupExecutor itself
set -u
cd "$(dirname "$0")/.."

status=0
# $1 = what, $2 = extended regex, $3 = directory, rest = allowed files. Comment lines are ignored.
only_in() {
    local what="$1" pattern="$2" dir="$3"; shift 3
    local hits
    hits=$(grep -rnE --include='*.swift' "$pattern" "$dir" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
    for allowed in "$@"; do
        hits=$(printf '%s\n' "$hits" | grep -v "^$allowed:" || true)
    done
    hits=$(printf '%s\n' "$hits" | sed '/^$/d')
    if [ -n "$hits" ]; then
        echo "✗ $what outside its allowed files:"
        printf '%s\n' "$hits" | sed 's/^/  /' 
        status=1
    else
        echo "✓ $what only where allowed"
    fi
}

# An instance call (executor.approve, foo().approve); MCPServer.approve is the MCP preview check, not an approval.
only_in "cleanup approvals issued (.approve)" '(^|[^A-Za-z0-9_])([a-z_][A-Za-z0-9_]*|\))\.approve\(' MacCleaner \
    MacCleaner/ReviewConfirmation.swift
only_in "approver labels" '\.(userInApp|userInTerminal|userViaMCPPrompt|standingPolicy)\b' MacCleaner \
    MacCleaner/ReviewConfirmation.swift
only_in "review confirmations" 'ReviewConfirmation\.confirm\(' MacCleaner \
    MacCleaner/Review.swift MacCleaner/SelfTest.swift
only_in "approved-Trash values made" 'ApprovedTrash\(' MacCleaner \
    MacCleaner/ReviewConfirmation.swift
only_in "approvals issued inside MacCleanerKit" '\.(approve|issue)\(' Packages/MacCleanerKit/Sources \
    Packages/MacCleanerKit/Sources/MacCleanerFeatures/CleanupExecutor.swift

exit $status
