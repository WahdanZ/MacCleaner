import AppKit
import CoreGraphics

/// Who approved a destructive tool call that didn't come through the MCP connection.
enum ToolApproval: Sendable {
    /// The person at the terminal: typed "yes" at the CLI prompt, or passed --yes.
    case terminal
}

/// What Mac Cleaner itself shows the person before an MCP tool deletes or moves anything. Built from the
/// preview Mac Cleaner returned (never from text the AI client sends), and kept with that preview.
struct ApprovalRequest: Sendable {
    let tool: String
    /// The button title, e.g. "Delete Permanently".
    let verb: String
    /// One line per item, exactly as the preview listed them, plus the total.
    let lines: [String]
}

/// A confirm from an AI client (MCP) is a request, not an approval: an agent can call preview and confirm
/// itself. So before any MCP tool changes anything, Mac Cleaner asks the person in its own window.
enum HumanApproval {
    /// How Mac Cleaner asks. Replaced only by the self-test.
    nonisolated(unsafe) static var ask: (ApprovalRequest) -> Bool = askWithDialog
    /// The dialog cancels itself after this long, so an unattended request never goes ahead.
    /// MACCLEANER_APPROVAL_TIMEOUT can only shorten it (1–120 s), for testing the cancel path.
    static var timeout: TimeInterval {
        let fallback: TimeInterval = 120
        guard let raw = ProcessInfo.processInfo.environment["MACCLEANER_APPROVAL_TIMEOUT"], let v = TimeInterval(raw) else { return fallback }
        return min(fallback, max(1, v))
    }

    /// True when a person's login session with a screen is available (not over SSH, not in a headless job).
    static var hasGUISession: Bool { CGSessionCopyCurrentDictionary() != nil }

    /// Shows a native alert listing every item. Cancel is the default button; only clicking the destructive
    /// button approves. No screen, not on the main thread, or no answer in time → not approved.
    static func askWithDialog(_ r: ApprovalRequest) -> Bool {
        guard hasGUISession, Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { () -> Bool in
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "An AI assistant asks Mac Cleaner to \(r.verb.lowercased())"
            alert.informativeText = """
                This request came through Mac Cleaner's AI connection (\(r.tool)). Continue only if you asked \
                for it and the list below is what you expect. If you cancel or don't answer within \
                \(Int(timeout / 60)) minutes, nothing is changed.
                """
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\r"
            let go = alert.addButton(withTitle: r.verb)
            go.keyEquivalent = ""
            go.hasDestructiveAction = true

            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = r.lines.joined(separator: "\n")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.documentView = text
            alert.accessoryView = scroll

            let timer = Timer(timeInterval: timeout, repeats: false) { _ in
                MainActor.assumeIsolated { NSApplication.shared.abortModal() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            let answer = alert.runModal()
            timer.invalidate()
            return answer == .alertSecondButtonReturn
        }
    }
}
