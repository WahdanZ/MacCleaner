import Foundation
import MacCleanerCore

/// The one place in the app that turns a person's confirmation into a cleanup approval.
///
/// The review sheet's confirm button calls `confirm`, and nothing else does (scripts/check-approval-sites.sh fails
/// CI if `approve(` with an approver, or a call to this type, appears anywhere else; the self-test calls it to test
/// it). The plan was built when the sheet opened, from the identities it shows; it is approved as it is, never
/// rebuilt or extended here. What happens to legacy (not yet migrated) items is unchanged.
enum ReviewConfirmation {
    /// The person pressed the review sheet's confirm button for `request`.
    @MainActor
    static func confirm(_ request: ReviewRequest) {
        let ids = Set(request.allowed.map(\.id))
        guard let run = request.performApproved else {
            request.perform(ids)   // legacy flow
            return
        }
        guard let plan = request.trashPlan else {
            run(ids, nil)
            return
        }
        Task { @MainActor in
            run(ids, await approve(plan))
        }
    }

    /// Records the approval. If the executor refuses to issue one, says why, so nothing is moved silently or
    /// reported as done.
    private static func approve(_ plan: CleanupPlan) async -> TrashApproval {
        do {
            return .approved(ApprovedTrash(plan: plan, approval: try await AppCleanup.executor.approve(plan, by: .userInApp)))
        } catch {
            return .refused(plan: plan, reason: "No approval was issued (\(error)); nothing was moved")
        }
    }
}
