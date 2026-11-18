import Foundation
import MacCleanerCore

/// The one place in the app that turns a person's confirmation into a cleanup approval.
///
/// The review sheet's confirm button calls `confirm`, and nothing else does (scripts/check-approval-sites.sh fails
/// CI if `approve(` with an approver, or a call to this type, appears anywhere else; the self-test calls it to test
/// it). The plan was built when the sheet opened, from the identities it shows; it is approved as it is, never
/// rebuilt or extended here. What happens to legacy (not yet migrated) items is unchanged.
///
/// The legacy fallback is kept on purpose: a request without `performApproved` is confirmed by calling its
/// `perform` with the allowed ids. Four reviews still use it because their modules are not on the executor yet:
/// junk/caches (`ReviewBuild.junk`), build files (`ReviewBuild.projects`), app cache (`ReviewBuild.appCache`) and
/// the Homebrew uninstall review (inline in AppsView). It goes away when those modules move to the executor
/// (M01-06...). A request that has a `cleanupPlan` must also set `performApproved`, otherwise the plan would be
/// ignored and `perform` would run unapproved. The self-test checks that rule for the builders it can build, and pins
/// three of the legacy builders (junk, appCache, projects); the inline Homebrew review (AppsView) is not covered.
enum ReviewConfirmation {
    /// The person pressed the review sheet's confirm button for `request`.
    @MainActor
    static func confirm(_ request: ReviewRequest) {
        let ids = Set(request.allowed.map(\.id))
        guard let run = request.performApproved else {
            request.perform(ids)   // legacy flow, kept on purpose (see the type's doc)
            return
        }
        guard let plan = request.cleanupPlan else {
            run(ids, nil)
            return
        }
        Task { @MainActor in
            run(ids, await approve(plan))
        }
    }

    /// Records the approval. If the executor refuses to issue one, says why, so nothing is moved silently or
    /// reported as done.
    private static func approve(_ plan: CleanupPlan) async -> ReviewApproval {
        do {
            return .approved(ApprovedTrash(plan: plan, approval: try await AppCleanup.executor.approve(plan, by: .userInApp)))
        } catch {
            return .refused(plan: plan, reason: "No approval was issued (\(error)); nothing was moved")
        }
    }
}
