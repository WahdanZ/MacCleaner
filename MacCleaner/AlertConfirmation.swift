import Foundation
import MacCleanerCore

/// The destructive button of a "Remove …?" alert (Extensions, Startup items) turning the person's click into a
/// cleanup approval for exactly the item the alert names, alongside the review sheet (ReviewConfirmation) and
/// verified MCP/CLI confirms (ToolConfirmation). It uses the same executor approval; it is not another kind of
/// authorization.
///
/// The item's identity was captured by its scan and checked when the alert was shown
/// (`AppCleanup.scannedSnapshot`); a one-item Trash plan is built from exactly that and approved as `.userInApp`.
/// scripts/check-approval-sites.sh allows approvals here, and calls to `confirm` only from the alert buttons
/// (SystemItems.swift) and the self-test.
enum AlertConfirmation {
    /// The person pressed the alert's destructive button for `id` / `name`. `shown` is what was captured when the
    /// alert appeared. `then` gets the approval, or why there is none (nothing is approved for a stale item).
    @MainActor
    static func confirm(id: String, name: String, shown: (identity: FileIdentity?, refusal: String?), module: String,
                        then run: @escaping @MainActor (TrashApproval?, String?) -> Void) {
        guard let identity = shown.identity,
              let plan = AppCleanup.trashPlan([(id, name, identity, 0, "Confirmed in the Remove alert")], module: module) else {
            run(nil, shown.refusal ?? "It couldn't be identified. Scan again")
            return
        }
        if let why = AppCleanup.nonTrashRefusal(plan) { run(.refused(plan: plan, reason: why), nil); return }
        Task { @MainActor in
            do {
                run(.approved(ApprovedTrash(plan: plan, approval: try await AppCleanup.executor.approve(plan, by: .userInApp))), nil)
            } catch {
                run(.refused(plan: plan, reason: "No approval was issued (\(error)); nothing was moved"), nil)
            }
        }
    }
}
