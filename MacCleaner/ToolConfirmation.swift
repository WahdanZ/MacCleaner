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

    /// The Trash log `source` for an engine's Trash items approved through MCP or the CLI ("Developer SDKs · AI
    /// assistant", "System Data · Command line (--yes, …)").
    static func trashSource(_ module: String, for approval: ToolApproval?) -> String {
        "\(module) · \(trashSource(for: approval))"
    }

    /// Approves the preview's Trash plan, attributed to whoever confirmed it. nil when the preview had no Trash
    /// items. Waits for the executor (the MCP server and the CLI are synchronous).
    static func approveTrash(_ confirmed: MCPServer.ConfirmedPreview) -> TrashApproval? {
        guard let plan = confirmed.trashPlan else { return nil }
        let approver = approver(for: confirmed.approvedBy)
        let slot = ApprovalSlot()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                slot.value = .approved(ApprovedTrash(plan: plan, approval: try await AppCleanup.executor.approve(plan, by: approver)))
            } catch {
                slot.value = .refused(plan: plan, reason: "No approval was issued (\(error)); nothing was moved")
            }
            done.signal()
        }
        done.wait()
        return slot.value
    }

    /// Approves the preview's Trash plan and moves it to the Trash through the cleanup executor (recorded per item
    /// for Put Back).
    static func moveToTrash(_ confirmed: MCPServer.ConfirmedPreview) -> TrashRun {
        guard let decision = approveTrash(confirmed) else { return TrashRun() }
        return AppCleanup.moveToTrashBlocking(decision, source: trashSource(for: confirmed.approvedBy))
    }
}

/// Carries the approval out of the detached task (written once before the semaphore is signalled).
private final class ApprovalSlot: @unchecked Sendable {
    var value: TrashApproval?
}
