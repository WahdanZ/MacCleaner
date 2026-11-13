import Foundation
import MacCleanerCore

/// The one place outside the review sheet that issues a cleanup approval: an MCP or CLI confirm that
/// `MCPServer.approve` has already verified, which is what a `ConfirmedPreview` proves (only `approve` can make
/// one). It means: a single-use preview of this tool, the same items (path and identity), and either the person's
/// yes in Mac Cleaner's own window (MCP), a "yes" typed at the terminal prompt, or the `--yes` override.
///
/// The approval names who that was, and `--yes` is never attributed to a person: it is `.nonInteractiveOverride`
/// in the approval and "Command line (--yes)" in the Trash log. scripts/check-approval-sites.sh allows approvals
/// only here and in ReviewConfirmation.
enum ToolConfirmation {
    static func approver(for approval: ToolApproval?) -> CleanupApproval.Approver {
        switch approval {
        case nil: return .userViaMCPPrompt
        case .terminal?: return .userInTerminal
        case .yesFlag?: return .nonInteractiveOverride
        }
    }

    /// The Trash log's `source` for a move, so the record says how it was approved.
    static func trashSource(for approval: ToolApproval?) -> String {
        switch approval {
        case nil: return "AI assistant"
        case .terminal?: return "Command line"
        case .yesFlag?: return "Command line (--yes, not confirmed by a person)"
        }
    }

    /// Approves the preview's Trash plan, attributed to whoever confirmed it, and moves it to the Trash through the
    /// cleanup executor (recorded per item for Put Back). Blocks until done: the MCP server and the CLI handle one
    /// call at a time, synchronously; none of this work needs the main thread.
    static func moveToTrash(_ confirmed: MCPServer.ConfirmedPreview) -> TrashRun {
        guard let plan = confirmed.trashPlan else { return TrashRun() }
        let approver = approver(for: confirmed.approvedBy), source = trashSource(for: confirmed.approvedBy)
        let slot = RunSlot()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let decision: TrashApproval
            do {
                decision = .approved(ApprovedTrash(plan: plan, approval: try await AppCleanup.executor.approve(plan, by: approver)))
            } catch {
                decision = .refused(plan: plan, reason: "No approval was issued (\(error)); nothing was moved")
            }
            slot.run = await AppCleanup.moveToTrash(decision, source: source)
            done.signal()
        }
        done.wait()
        return slot.run ?? TrashRun()
    }
}

/// Carries the result out of the detached task (written once before the semaphore is signalled).
private final class RunSlot: @unchecked Sendable {
    var run: TrashRun?
}
