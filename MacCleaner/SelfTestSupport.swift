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
        setApprover { r in approvals.asked.append(r); return approvals.answer }
    }

    // MCPServer and HumanApproval.ask are main-actor state. The self-test runs synchronously on the main thread
    // (never inside a main-queue callout), so these assume that isolation instead of hopping.
    static func setApprover(_ ask: @escaping @MainActor (ApprovalRequest) -> Bool) {
        MainActor.assumeIsolated { HumanApproval.ask = ask }
    }

    static func mcpCall(_ name: String, _ a: [String: Any], approval: ToolApproval? = nil) throws -> Any {
        let r = wait { () async -> Result<Any, Error> in
            do { return .success(try await MCPServer.call(name, a, approval: approval)) } catch { return .failure(error) }
        }
        // A timeout is a failure, never a silent pass: record a failed check and throw so every caller sees it.
        guard let r else {
            check("MCP call \(name) did not finish in time", false)
            throw MCPServer.ToolError(description: "MCP call \(name) did not finish in time")
        }
        return try r.get()
    }
}
