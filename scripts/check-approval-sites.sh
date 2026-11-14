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
#   * the Shredder (M01-04c-2): its snapshot is taken only by ShredReview (the one place a review is built) and by the
#     package; the overwrite-then-delete disposition is named only by the review, the protection rules, the Shredder model's plan guard and the self-test;
#     the Platform's overwriteAndRemove is reached only through the executor; ShredEngine is gone; the snapshot-counting
#     seam (`shredSnapshotter:`) is passed only by the self-test
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

# The Shredder (M01-04c-2). One snapshot per item, taken where the review is built; the executor does the shredding.
only_in "shred snapshots taken in the app" 'shredSnapshot\(' MacCleaner \
    MacCleaner/ShredReview.swift MacCleaner/SelfTest.swift
only_in "shred snapshots taken inside MacCleanerKit" 'shredSnapshot\(' Packages/MacCleanerKit/Sources \
    Packages/MacCleanerKit/Sources/MacCleanerPlatform/LocalFileSystem+Shred.swift
only_in "overwrite-then-delete named in the app" 'overwriteThenDelete' MacCleaner \
    MacCleaner/ShredReview.swift MacCleaner/AppProtection.swift MacCleaner/Shredder.swift MacCleaner/SelfTest.swift
only_in "overwriteAndRemove called in the app" 'overwriteAndRemove\(' MacCleaner
only_in "overwriteAndRemove inside MacCleanerKit" 'overwriteAndRemove\(' Packages/MacCleanerKit/Sources \
    Packages/MacCleanerKit/Sources/MacCleanerPlatform/LocalFileSystem+Shred.swift \
    Packages/MacCleanerKit/Sources/MacCleanerFeatures/CleanupExecutor.swift \
    Packages/MacCleanerKit/Sources/MacCleanerCore/CleanupFileSystem.swift
# Executor runs in the app: ApprovedTrash.swift (the Trash path: moveToTrash) and Shredder.swift (the approved shred).
only_in "cleanup executor runs (.execute) in the app" '\.execute[[:space:]]*\(' MacCleaner \
    MacCleaner/ApprovedTrash.swift MacCleaner/Shredder.swift
only_in "the removed ShredEngine (app)" 'ShredEngine' MacCleaner
only_in "the removed ShredEngine (package sources)" 'ShredEngine' Packages/MacCleanerKit/Sources
only_in "the removed ShredEngine (package tests)" 'ShredEngine' Packages/MacCleanerKit/Tests
only_in "the snapshot-counting seam passed" 'shredSnapshotter' MacCleaner \
    MacCleaner/ShredReview.swift MacCleaner/SelfTest.swift
# One shred flow only: the Shredder screen builds its review (ShredReview.snapshots + ReviewBuild.shred) and runs it;
# nothing else may build a shred plan that could be approved elsewhere. Dispositions are never built from raw values.
only_in "shred reviews listed (ShredReview.snapshots)" 'ShredReview\.snapshots[[:space:]]*\(' MacCleaner \
    MacCleaner/Shredder.swift MacCleaner/SelfTest.swift
only_in "shred reviews built (ReviewBuild.shred)" 'ReviewBuild\.shred[[:space:]]*\(' MacCleaner \
    MacCleaner/Shredder.swift MacCleaner/SelfTest.swift
only_in "dispositions made from raw values" 'Disposition\(rawValue' MacCleaner

exit $status
