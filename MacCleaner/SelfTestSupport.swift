import Foundation

extension SelfTest {
    /// Stands in for Mac Cleaner's confirmation window during the self-test, so no real window ever appears.
    final class ApprovalRecorder {
        var asked: [ApprovalRequest] = []
        var answer = true
    }

    static let approvals = ApprovalRecorder()

    /// Called before `run()` (see `Entry.main`): MCP confirms in the self-test are answered by `approvals`.
    static func installTestApprover() {
        HumanApproval.ask = { r in approvals.asked.append(r); return approvals.answer }
    }
}
