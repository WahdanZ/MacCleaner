#if MACCLEANER_TEST_HOOKS
import AppKit
import CoreFoundation
import Foundation

/// Test-only probes for the self-test's child processes (`--mcp`, `--cli`). Compiled only into the test-hooks build
/// (scripts/build-test-hooks.sh), never into Release: scripts/check-no-test-hooks.sh greps the Release binary for
/// every environment variable named here. Nothing writes to stdout (stdout is the MCP JSON-RPC channel).
enum TestHooks {
    /// Run-loop fingerprint: bumped by a repeating timer on the main run loop (common modes). It only advances while
    /// something is spinning the main run loop.
    nonisolated(unsafe) static var ticks = 0

    private static func append(_ line: String, to path: String) {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Called once from `Entry.main`, in the test-hooks block, before any dispatch.
    static func installFromEnvironment() {
        let env = ProcessInfo.processInfo.environment

        if let path = env["MACCLEANER_TEST_HOME_PROBE"] { append(SafetyGuard.home.path, to: path) }

        if env["MACCLEANER_TEST_APP_RUNNING"] == "1" { AppEngine.testRunningOverride = true }
        if env["MACCLEANER_TEST_APP_QUIT"] == "0" { AppEngine.testQuitOverride = false }

        if let path = env["MACCLEANER_TEST_APPROVAL_PROBE"] {
            let delayMS = env["MACCLEANER_TEST_APPROVAL_DELAY_MS"].flatMap(Int.init) ?? 0
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.05, 0.05, 0, 0) { _ in
                ticks += 1
            }
            CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
            HumanApproval.ask = { _ in
                if delayMS > 0 { usleep(UInt32(delayMS) * 1000) }   // stands in for an open dialog
                let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()).map { ($0.rawValue as String) } ?? "nil"
                append("main=\(pthread_main_np()) isMainThread=\(Thread.isMainThread) "
                       + "mainRunLoop=\(CFRunLoopGetCurrent() == CFRunLoopGetMain()) mode=\(mode) ticks=\(ticks)", to: path)
                return false
            }
        }
    }
}
#endif
