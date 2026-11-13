#!/bin/bash
# Fails when a cleanup approval could be issued outside a verified confirmation boundary (M01-04b).
#
# This only finds UNEXPECTED CALL SITES in the source. It does not prove that a person confirmed anything; the
# self-test checks the confirmation behaviour itself (scripts/selftest.sh, "Approved Trash").
#
# Allowed (each a verified confirmation boundary):
#   * approvals issued (CleanupExecutor.approve / an Approver label): MacCleaner/ReviewConfirmation.swift (the review
#     sheet's button), MacCleaner/ToolConfirmation.swift (an MCP/CLI confirm already checked by MCPServer.approve),
#     MacCleaner/AlertConfirmation.swift (a Remove alert's destructive button, called only from SystemItems.swift) and
#     MacCleaner/AppOwnedTrash.swift (one folder Mac Cleaner made, with its operation's proof: `.appOwned` only there)
#   * cleanup executors made: AppCleanup's (ApprovedTrash.swift) and one per app-owned move (AppOwnedTrash.swift)
#   * app-owned moves: trashStaging only where the password step finishes (AppUninstall.swift), trashSkill only from
#     Disconnect (Integrations.swift), both also from the self-test; their proofs are made only by AdminStep
#     (`staging(fromOutput:`, also run by the self-test on a script run as you) and InstalledSkills (fileprivate inits)
#   * ReviewConfirmation.confirm(...) called: the review sheet (MacCleaner/Review.swift) and the self-test
#   * ApprovedTrash(...) made: the same two files
#   * a terminal approval (ToolApproval .terminal / .yesFlag) made: the CLI (after its TTY prompt or --yes) and the
#     self-test; MCPServer.ConfirmedPreview made: only MCPServer.approve (its initializer is fileprivate)
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
    MacCleaner/ReviewConfirmation.swift MacCleaner/ToolConfirmation.swift MacCleaner/AlertConfirmation.swift \
    MacCleaner/AppOwnedTrash.swift
# The self-test may name labels to compare against; it can't issue an approval (the rule above excludes it).
only_in "approver labels" '\.(userInApp|userInTerminal|userViaMCPPrompt|nonInteractiveOverride|standingPolicy)\b' MacCleaner \
    MacCleaner/ReviewConfirmation.swift MacCleaner/ToolConfirmation.swift MacCleaner/AlertConfirmation.swift MacCleaner/SelfTest.swift
only_in "review confirmations" 'ReviewConfirmation\.confirm\(' MacCleaner \
    MacCleaner/Review.swift MacCleaner/SelfTest.swift
only_in "approved-Trash values made" 'ApprovedTrash\(' MacCleaner \
    MacCleaner/ReviewConfirmation.swift MacCleaner/ToolConfirmation.swift MacCleaner/AlertConfirmation.swift \
    MacCleaner/AppOwnedTrash.swift
# App-owned approvals: only for the one folder an operation's proof names; never from the CLI, MCP or a cleanup flow.
only_in "app-owned approvals" '\.appOwned\b|AppOwnedKind' MacCleaner \
    MacCleaner/AppOwnedTrash.swift
only_in "cleanup executors made" 'CleanupExecutor\(' MacCleaner \
    MacCleaner/ApprovedTrash.swift MacCleaner/AppOwnedTrash.swift
only_in "staging folders moved as app-owned" 'trashStaging\(' MacCleaner \
    MacCleaner/AppOwnedTrash.swift MacCleaner/AppUninstall.swift MacCleaner/SelfTest.swift
only_in "installed skills moved as app-owned" 'trashSkill\(' MacCleaner \
    MacCleaner/AppOwnedTrash.swift MacCleaner/Integrations.swift MacCleaner/SelfTest.swift
only_in "staging proofs made" '(Staging\(folder:|staging\(fromOutput:)' MacCleaner \
    MacCleaner/AdminStep.swift MacCleaner/SelfTest.swift
only_in "installed-skill proofs made" 'Verified\(folder:' MacCleaner \
    MacCleaner/InstalledSkills.swift
only_in "alert confirmations" 'AlertConfirmation\.confirm\(' MacCleaner \
    MacCleaner/SystemItems.swift MacCleaner/SelfTest.swift
only_in "terminal approvals made" '(approval: *|\? *)\.(terminal|yesFlag)\b|ToolApproval\.(terminal|yesFlag)' MacCleaner \
    MacCleaner/CLI.swift MacCleaner/SelfTest.swift
only_in "confirmed previews made" 'ConfirmedPreview\(' MacCleaner \
    MacCleaner/MCPServer.swift
only_in "approvals issued inside MacCleanerKit" '\.(approve|issue)\(' Packages/MacCleanerKit/Sources \
    Packages/MacCleanerKit/Sources/MacCleanerFeatures/CleanupExecutor.swift

exit $status
