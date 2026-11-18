import Foundation
import MacCleanerCore

// Pins today's MCP / CLI / Trash behavior in separate processes (and the in-process MCP reply shapes) before the async
// migration of the `--mcp` / `--cli` entry points (M01-04d slice 4, PR 0). Every check here passes on the code as it is.
// The probes that need a hook (approval probe, run-loop fingerprint, app-running override) exist only in the
// test-hooks build: those checks are compiled under `#if MACCLEANER_TEST_HOOKS` and Release prints a skip line.

extension SelfTest {
    // MARK: Child-process harness

    /// Deadline for any one read from a child, and for a child to exit after its input closes.
    static let childDeadline: TimeInterval = 10

    /// The environment of every child: explicit, never inherited. `home` is the throwaway home folder.
    static func childEnvironment(home: String, extra: [String: String] = [:]) -> [String: String] {
        var env = ["CFFIXED_USER_HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        #if MACCLEANER_TEST_HOOKS
        env["MACCLEANER_TEST_TRASH_DIR"] = isolatedTrash.path   // a child that could move a file moves it into the isolated Trash
        #endif
        return env.merging(extra) { _, new in new }
    }

    /// One `--mcp` server in a separate process, talked to over pipes. Reads have a deadline; nothing waits unbounded.
    final class McpChild {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var buffer = Data()
        private var sawEOF = false
        private var inputClosed = false

        init?(home: String, extra: [String: String] = [:]) {
            guard let exe = Bundle.main.executableURL else { return nil }
            process.executableURL = exe
            process.arguments = ["--mcp"]
            process.environment = SelfTest.childEnvironment(home: home, extra: extra)
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            // A write to a child that already exited must fail, not kill the self-test (this pipe only; not inherited).
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        func send(_ text: String) {
            guard !inputClosed else { return }
            try? input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
        }

        func closeInput() {
            guard !inputClosed else { return }
            inputClosed = true
            try? input.fileHandleForWriting.close()
        }

        /// The next line the child wrote, or nil at end of output or after `timeout` seconds.
        func readLine(timeout: TimeInterval = SelfTest.childDeadline) -> String? {
            let end = Date().addingTimeInterval(timeout)
            let fd = output.fileHandleForReading.fileDescriptor
            while true {
                if let nl = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    return line
                }
                if sawEOF { return nil }
                let remaining = end.timeIntervalSinceNow
                if remaining <= 0 { return nil }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(min(remaining, 0.5) * 1000))
                if ready > 0 {
                    var chunk = [UInt8](repeating: 0, count: 65536)
                    let n = read(fd, &chunk, chunk.count)
                    if n > 0 { buffer.append(contentsOf: chunk[0..<n]) } else if n == 0 || errno != EINTR { sawEOF = true }
                }
            }
        }

        /// The next reply, parsed. nil when none arrived in time or it wasn't a JSON object.
        func readReply(timeout: TimeInterval = SelfTest.childDeadline) -> [String: Any]? {
            SelfTest.jsonObject(readLine(timeout: timeout))
        }

        /// Closes the child's input, collects everything it still writes, and waits (bounded) for it to exit. Kills it
        /// when it doesn't. `status` is nil when it had to be killed.
        func finish(timeout: TimeInterval = SelfTest.childDeadline) -> (status: Int32?, rest: [String]) {
            closeInput()
            let end = Date().addingTimeInterval(timeout)
            var rest: [String] = []
            while let line = readLine(timeout: max(0, end.timeIntervalSinceNow)) { rest.append(line) }
            while process.isRunning && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            if process.isRunning { kill(); return (nil, rest) }
            return (process.terminationStatus, rest)
        }

        func kill() {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Starts a `--mcp` child, runs `body`, and always kills it afterwards. False when it couldn't start.
    @discardableResult
    static func withMcpChild(home: String, extra: [String: String] = [:], _ body: (McpChild) -> Void) -> Bool {
        guard let child = McpChild(home: home, extra: extra) else { return false }
        defer { child.kill() }
        body(child)
        return true
    }

    static func jsonObject(_ line: String?) -> [String: Any]? {
        guard let line, let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func jsonLine(_ o: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    static func rpc(_ id: Int, _ method: String, _ params: [String: Any]? = nil) -> String {
        var o: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { o["params"] = params }
        return jsonLine(o)
    }

    static func toolCall(_ id: Int, _ tool: String, _ args: [String: Any]) -> String {
        rpc(id, "tools/call", ["name": tool, "arguments": args])
    }

    /// A tools/call reply's text (and error flag), plus the text parsed as JSON when it is.
    static func toolText(_ reply: [String: Any]?) -> (text: String, isError: Bool, json: [String: Any]?)? {
        guard let result = reply?["result"] as? [String: Any],
              let content = (result["content"] as? [[String: Any]])?.first, let text = content["text"] as? String else { return nil }
        return (text, result["isError"] as? Bool ?? false, jsonObject(text))
    }

    static func replyID(_ reply: [String: Any]?) -> Int? { reply?["id"] as? Int }

    /// What a child process did: its exit code (nil = it had to be killed) and what it printed.
    struct ChildRun {
        var code: Int32?
        var out: String
        var err: String
    }

    enum ChildInput { case none, text(String) }

    /// Runs `--cli <args>` in a separate process and waits at most `timeout` seconds (then kills it). Output goes to
    /// files in `scratch`, so a chatty child can never fill a pipe and hang the wait.
    static func runCLI(_ args: [String], home: String, input: ChildInput = .none, extra: [String: String] = [:],
                       timeout: TimeInterval = 20, scratch: URL) -> ChildRun {
        let fm = FileManager.default
        let outURL = scratch.appendingPathComponent("cli-out-\(UUID().uuidString).txt")
        let errURL = scratch.appendingPathComponent("cli-err-\(UUID().uuidString).txt")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer { try? fm.removeItem(at: outURL); try? fm.removeItem(at: errURL) }
        guard let exe = Bundle.main.executableURL, let outH = try? FileHandle(forWritingTo: outURL),
              let errH = try? FileHandle(forWritingTo: errURL) else { return ChildRun(code: nil, out: "", err: "") }
        defer { try? outH.close(); try? errH.close() }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--cli"] + args
        p.environment = childEnvironment(home: home, extra: extra)
        switch input {
        case .none:
            p.standardInput = FileHandle.nullDevice
        case .text(let s):
            let pipe = Pipe()   // small and closed before the child starts: it reads the text, then end of input
            try? pipe.fileHandleForWriting.write(contentsOf: Data(s.utf8))
            try? pipe.fileHandleForWriting.close()
            p.standardInput = pipe
        }
        p.standardOutput = outH
        p.standardError = errH
        guard (try? p.run()) != nil else { return ChildRun(code: nil, out: "", err: "") }
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        var code: Int32? = nil
        if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) } else { code = p.terminationStatus }
        return ChildRun(code: code, out: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                        err: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    // MARK: Entry point (called from SelfTest.run's Trash section)

    static func subprocessPins(dir: URL, runID: String) {
        print("MCP and CLI in separate processes: framing, ordering, exit codes, Trash refusals (M01-04d slice 4, pre-async baseline)")
        let home = SafetyGuard.home.path
        guard let account = accountHome, home != account.path else {
            check("the throwaway home differs from the real home before any child process starts", false)
            return
        }
        mcpFraming(home: home)
        mcpBurst(home: home)
        cliUnknownScan(home: home, scratch: dir)
        #if MACCLEANER_TEST_HOOKS
        // Every child that could move a file is gated on the isolated Trash AND on the sandbox home.
        if subprocessTrashIsIsolated() && childHomeIsSandbox(home: home, scratch: dir) {
            mcpOrdering(home: home, dir: dir, runID: runID)
            mcpApprovalProbe(home: home, dir: dir, runID: runID)
            mcpReplyAfterMove(home: home, dir: dir, runID: runID)
            cliTrashFiles(home: home, dir: dir, runID: runID)
            cliUnrecordedHumanOutput(home: home, dir: dir, runID: runID)
        }
        #else
        print("  - MCP approval probe, ordering behind a slow confirm, run-loop baseline, CLI trash-files refusals: test-hooks build only")
        #endif
        inProcessPins(dir: dir, runID: runID)
    }

    // MARK: 1. stdio framing (both builds)

    private static func mcpFraming(home: String) {
        var replies: [[String: Any]?] = []
        var finished: (status: Int32?, rest: [String]) = (nil, [])
        var afterNoise: [String: Any]?
        let started = withMcpChild(home: home) { c in
            c.send(rpc(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                         "clientInfo": ["name": "selftest", "version": "0"]]))
            replies.append(c.readReply())
            c.send(rpc(2, "ping"))
            replies.append(c.readReply())
            c.send(rpc(3, "tools/list"))
            replies.append(c.readReply())
            c.send(toolCall(4, "disk_status", [:]))
            replies.append(c.readReply())
            c.send(rpc(5, "nosuch/method"))
            replies.append(c.readReply())
            // No reply for: not JSON, an empty line, a notification (no id). The next line out must be the ping's.
            c.send("this is not json")
            c.send("")
            c.send(jsonLine(["jsonrpc": "2.0", "method": "notifications/initialized"]))
            c.send(rpc(6, "ping"))
            afterNoise = c.readReply()
            finished = c.finish()
        }
        check("--mcp starts as a separate process", started)
        func keys(_ i: Int) -> [String] { ((replies[i]?["result"] as? [String: Any])?.keys.sorted()) ?? [] }
        check("--mcp: one reply per request, in order, with the request's id (initialize, ping, tools/list, disk_status, unknown)",
              replies.count == 5 && (0..<5).allSatisfy { replyID(replies[$0]) == $0 + 1 }
              && replies.allSatisfy { $0?["jsonrpc"] as? String == "2.0" })
        check("--mcp initialize: top-level reply keys are exactly id, jsonrpc, result; result keys are exactly protocolVersion, capabilities, serverInfo, instructions",
              replies.count == 5 && replies[0]?.keys.sorted() == ["id", "jsonrpc", "result"]
              && keys(0) == ["capabilities", "instructions", "protocolVersion", "serverInfo"]
              && (replies[0]?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        check("--mcp ping: the result is an empty object", replies.count == 5 && replies[1]?.keys.sorted() == ["id", "jsonrpc", "result"] && keys(1).isEmpty)
        check("--mcp tools/list: result keys are exactly [tools] and it lists disk_status",
              replies.count == 5 && keys(2) == ["tools"]
              && ((replies[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "disk_status" } == true)
        let status = replies.count == 5 ? toolText(replies[3]) : nil
        check("--mcp tools/call disk_status: result keys are exactly content, isError; isError false; text is JSON",
              replies.count == 5 && keys(3) == ["content", "isError"] && status?.isError == false && status?.json != nil)
        let unknownError = replies.count == 5 ? replies[4]?["error"] as? [String: Any] : nil
        check("--mcp unknown method: a JSON-RPC error, code -32601, message \"Method not found: nosuch/method\", and no result",
              replies.count == 5 && replies[4]?["result"] == nil && unknownError?["code"] as? Int == -32601
              && unknownError?["message"] as? String == "Method not found: nosuch/method")
        check("--mcp: invalid JSON, an empty line and a notification (no id) get no reply (the next line out is the ping's)",
              replyID(afterNoise) == 6)
        check("--mcp: closing stdin exits with status 0 and nothing more is printed", finished.status == 0 && finished.rest.isEmpty)
    }

    // MARK: 2. burst then EOF (both builds)

    private static func mcpBurst(home: String) {
        var lines: [String] = []
        var status: Int32?
        let started = withMcpChild(home: home) { c in
            c.send((1...50).map { rpc($0, "ping") }.joined(separator: "\n"))
            let done = c.finish()   // EOF immediately after the burst
            lines = done.rest
            status = done.status
        }
        let ids = lines.map { replyID(jsonObject($0)) }
        check("--mcp: 50 pings then immediate EOF are answered 50 times, ids 1…50 in order, and the exit status is 0",
              started && ids == (1...50).map { Optional($0) } && status == 0)
    }

    // MARK: 7. CLI unknown scan (both builds)

    private static func cliUnknownScan(home: String, scratch: URL) {
        let r = runCLI(["bench", "nosuchscan"], home: home, scratch: scratch)
        check("--cli bench nosuchscan exits 64 with the \"Unknown scan\" message on stderr (within 20 s)",
              r.code == 64 && r.err.hasPrefix("Unknown scan “nosuchscan”. Scans: junk, storage,") && r.out.isEmpty)
    }

    // MARK: In-process pins

    private static func inProcessPins(dir: URL, runID: String) {
        let fm = FileManager.default
        func file(_ name: String, _ text: String = "x") -> URL {
            let u = dir.appendingPathComponent("pin-\(name)-\(runID).txt")
            try? Data(text.utf8).write(to: u)
            return u
        }
        func log(_ u: URL) -> [TrashedItem] { TrashLog.shared.present().filter { $0.original == AppCleanup.physicalPath(u) } }
        func putBack(_ u: URL) -> Bool { log(u).first.map { TrashOps.restore($0) == nil } ?? false }
        defer { installTestApprover(); approvals.answer = true }

        // 11. MCP move_to_trash with one item that can't be moved: today's reply shape.
        let free = file("partial-free"), locked = file("partial-locked")
        approvals.asked = []; approvals.answer = true
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        let paths = [free.path, locked.path]
        let preview = (try? MCPServer.call("move_to_trash", ["paths": paths])) as? [String: Any]
        let reply = (try? MCPServer.call("move_to_trash", ["paths": paths, "confirm": true,
                                                           "preview_id": preview?["preview_id"] as? String ?? ""])) as? [String: Any]
        chflags(locked.path, 0)
        let errors = reply?["errors"] as? [String] ?? []
        check("MCP move_to_trash with one locked item: the reply keys are exactly errors, moved_to_trash, note",
              reply?.keys.sorted() == ["errors", "moved_to_trash", "note"]
              && reply?["note"] as? String == "Empty the Trash to free the space.")
        check("MCP move_to_trash with one locked item: moved_to_trash lists only the free one, errors has one entry for the locked one",
              (reply?["moved_to_trash"] as? [String]) == [Scanner.tilde(free)] && errors.count == 1
              && errors.first?.hasPrefix(Scanner.tilde(locked) + ": ") == true && errors.first != Scanner.tilde(locked) + ": ")
        check("MCP move_to_trash with one locked item: the free one is in the Trash, the locked one is still on disk and unrecorded, one confirmation window",
              !fm.fileExists(atPath: free.path) && fm.fileExists(atPath: locked.path) && log(locked).isEmpty
              && log(free).count == 1 && approvals.asked.count == 1)
        _ = putBack(free)

        // 10. uninstall_app of a running app that won't quit (needs the hooks-only running/quit override).
        #if MACCLEANER_TEST_HOOKS
        let appURL = SafetyGuard.home.appendingPathComponent("Applications/SelfTestRunning\(runID).app")
        let bundleID = "com.example.selftest.running\(runID)"   // unique: only this fake app can match it
        try? fm.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: appURL.appendingPathComponent("Contents/data.txt"))
        (["CFBundleIdentifier": bundleID, "CFBundleName": "SelfTestRunning\(runID)"] as NSDictionary)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"), atomically: true)
        defer {
            AppEngine.testRunningOverride = nil
            AppEngine.testQuitOverride = nil
            try? fm.removeItem(at: appURL)
        }
        AppEngine.testRunningOverride = true
        AppEngine.testQuitOverride = false
        approvals.asked = []; approvals.answer = true
        let outstanding = { wait { await AppCleanup.executor.outstandingApprovals } ?? -1 }
        let before = outstanding()
        let appPreview = (try? MCPServer.call("uninstall_app", ["app": bundleID])) as? [String: Any]
        var failure = ""
        do {
            _ = try MCPServer.call("uninstall_app", ["app": bundleID, "confirm": true,
                                                     "preview_id": appPreview?["preview_id"] as? String ?? ""])
        } catch { failure = "\(error)" }
        check("MCP uninstall_app preview of a running app reports running: true",
              appPreview?["preview"] as? Bool == true && appPreview?["running"] as? Bool == true)
        check("MCP uninstall_app of a running app that won't quit: the error says it \"did not quit\" and nothing is moved",
              failure.contains("did not quit") && fm.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path)
              && fm.fileExists(atPath: appURL.appendingPathComponent("Contents/data.txt").path) && log(appURL).isEmpty)
        check("…the person was asked exactly once, and no executor approval was issued (outstanding approvals unchanged)",
              approvals.asked.count == 1 && before >= 0 && outstanding() == before)
        #else
        print("  - MCP uninstall_app of a running app that won't quit: test-hooks build only (needs the running/quit override)")
        #endif
    }
}

#if MACCLEANER_TEST_HOOKS
extension SelfTest {
    // MARK: Gate

    /// Asks a child of this build for its home folder (MACCLEANER_TEST_HOME_PROBE) and requires it to be this run's
    /// throwaway home, not the account's. Destructive children run only when this is true.
    static func childHomeIsSandbox(home: String, scratch: URL) -> Bool {
        let probe = scratch.appendingPathComponent("home-probe-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: probe) }
        let r = runCLI(["status"], home: home, extra: ["MACCLEANER_TEST_HOME_PROBE": probe.path], scratch: scratch)
        let seen = (try? String(contentsOf: probe, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trash = runCLI(["status"], home: home, extra: ["MACCLEANER_TEST_TRASH_PROBE": "1"], scratch: scratch)   // the env destructive children get
        let ok = r.code == 0 && seen == home && accountHome.map { seen != $0.path } == true
            && trash.out.trimmingCharacters(in: .whitespacesAndNewlines) == "trash-destination: \(isolatedTrash.path)"
        check("a child started with the destructive children's own environment reports the throwaway home and the isolated Trash before any child that could move a file runs", ok)
        if !ok { print("    (skipping the child-process checks that could move files: child home \"\(seen ?? "nil")\", exit \(r.code.map(String.init) ?? "killed"))") }
        return ok
    }

    // MARK: Helpers

    private static func isolatedTrashCount() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: isolatedTrash.path))?.count ?? -1 }

    /// The probe file's lines as key→value maps ("main=1 isMainThread=true …").
    private static func probeLines(_ path: String) -> [[String: String]] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map { line in
            Dictionary(line.split(separator: " ").compactMap { part -> (String, String)? in
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                return kv.count == 2 ? (kv[0], kv[1]) : nil
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    private static func sandboxFile(_ dir: URL, _ name: String, _ runID: String, _ text: String = "x") -> URL {
        let u = dir.appendingPathComponent("pin-\(name)-\(runID).txt")
        try? Data(text.utf8).write(to: u)
        return u
    }

    /// Sends a move_to_trash preview for `path` and returns its preview_id (read from the reply).
    private static func previewMove(_ c: McpChild, id: Int, path: String) -> String? {
        c.send(toolCall(id, "move_to_trash", ["paths": [path]]))
        return toolText(c.readReply())?.json?["preview_id"] as? String
    }

    private static func confirmLine(_ id: Int, path: String, previewID: String) -> String {
        toolCall(id, "move_to_trash", ["paths": [path], "confirm": true, "preview_id": previewID])
    }

    // MARK: 3 and 5. ordering behind a slow confirm

    static func mcpOrdering(home: String, dir: URL, runID: String) {
        let fm = FileManager.default
        let trashBefore = isolatedTrashCount()

        // 3. A confirm that sits in a (simulated, 400 ms) dialog, then 20 queued pings, then EOF.
        let f3 = sandboxFile(dir, "order-queue", runID)
        let probe3 = dir.appendingPathComponent("approval-probe-queue-\(runID).txt")
        var lines3: [String] = [], status3: Int32?
        let ok3 = withMcpChild(home: home, extra: ["MACCLEANER_TEST_APPROVAL_PROBE": probe3.path,
                                                    "MACCLEANER_TEST_APPROVAL_DELAY_MS": "400"]) { c in
            guard let pid = previewMove(c, id: 1, path: f3.path) else { return }
            c.send(confirmLine(2, path: f3.path, previewID: pid) + "\n" + (3...22).map { rpc($0, "ping") }.joined(separator: "\n"))
            let done = c.finish()
            lines3 = done.rest; status3 = done.status
        }
        let replies3: [[String: Any]] = lines3.compactMap { jsonObject($0) }
        check("--mcp behind a slow confirm (400 ms dialog): the confirm's reply and 20 queued pings all arrive, ids 2…22 in order, exit 0",
              ok3 && replies3.map { replyID($0) } == (2...22).map { Optional($0) } && status3 == 0)
        check("--mcp behind a slow confirm: the confirm's reply is the declined error, the pings' results are empty objects",
              toolText(replies3.first)?.isError == true && toolText(replies3.first)?.text.contains("did not approve") == true
              && replies3.dropFirst().allSatisfy { ($0["result"] as? [String: Any])?.isEmpty == true })
        check("--mcp behind a slow confirm: the file is untouched and the isolated Trash unchanged",
              fm.fileExists(atPath: f3.path) && isolatedTrashCount() == trashBefore)

        // 5. Confirm then, immediately, a ping (stdin stays open): the confirm's reply must be the first line.
        let f5 = sandboxFile(dir, "order-first", runID)
        let probe5 = dir.appendingPathComponent("approval-probe-first-\(runID).txt")
        var first: [String: Any]?, second: [String: Any]?, status5: Int32?
        let ok5 = withMcpChild(home: home, extra: ["MACCLEANER_TEST_APPROVAL_PROBE": probe5.path,
                                                    "MACCLEANER_TEST_APPROVAL_DELAY_MS": "400"]) { c in
            guard let pid = previewMove(c, id: 1, path: f5.path) else { return }
            c.send(confirmLine(2, path: f5.path, previewID: pid))
            c.send(rpc(3, "ping"))
            first = c.readReply(); second = c.readReply()
            status5 = c.finish().status
        }
        check("--mcp reply-after-dialog ordering: after a 400 ms dialog the confirm's reply (id 2) is the first line and the ping's (id 3) the second",
              ok5 && replyID(first) == 2 && toolText(first)?.text.contains("did not approve") == true && replyID(second) == 3 && status5 == 0)
        check("--mcp reply-after-dialog ordering: the file is untouched", fm.fileExists(atPath: f5.path) && isolatedTrashCount() == trashBefore)
    }

    // MARK: 4 and 6. the approval probe and the run-loop fingerprint

    static func mcpApprovalProbe(home: String, dir: URL, runID: String) {
        let fm = FileManager.default
        let trashBefore = isolatedTrashCount()

        // 4. The person is asked on the main thread; a "no" leaves the file where it is.
        let f4 = sandboxFile(dir, "probe", runID, "keep me")
        let probe4 = dir.appendingPathComponent("approval-probe-main-\(runID).txt")
        var reply4: [String: Any]?
        let ok4 = withMcpChild(home: home, extra: ["MACCLEANER_TEST_APPROVAL_PROBE": probe4.path]) { c in
            guard let pid = previewMove(c, id: 1, path: f4.path) else { return }
            c.send(confirmLine(2, path: f4.path, previewID: pid))
            reply4 = c.readReply()
            _ = c.finish()
        }
        let lines4 = probeLines(probe4.path)
        check("--mcp approval probe: HumanApproval.ask is called exactly once, on the main thread (main=1 isMainThread=true mainRunLoop=true)",
              ok4 && lines4.count == 1 && lines4.first?["main"] == "1" && lines4.first?["isMainThread"] == "true"
              && lines4.first?["mainRunLoop"] == "true")
        check("--mcp approval probe: a declined confirm replies with an error that says the person \"did not approve\"",
              replyID(reply4) == 2 && toolText(reply4)?.isError == true && toolText(reply4)?.text.contains("did not approve") == true)
        check("--mcp approval probe: the file is unmoved and unchanged, and the isolated Trash is unchanged",
              (try? String(contentsOf: f4, encoding: .utf8)) == "keep me" && isolatedTrashCount() == trashBefore)

        // 6. Baseline before PR 1a: the sync read loop never spins the main run loop.
        let f6 = sandboxFile(dir, "baseline", runID)
        let probe6 = dir.appendingPathComponent("approval-probe-baseline-\(runID).txt")
        var ping6: [String: Any]?
        let ok6 = withMcpChild(home: home, extra: ["MACCLEANER_TEST_APPROVAL_PROBE": probe6.path]) { c in
            c.send(rpc(1, "ping"))
            ping6 = c.readReply()
            guard let pid = previewMove(c, id: 2, path: f6.path) else { return }
            usleep(300_000)   // idle: a 50 ms timer on the main run loop would tick ~6 times if anything spun it
            c.send(confirmLine(3, path: f6.path, previewID: pid))
            _ = c.readReply()
            _ = c.finish()
        }
        let lines6 = probeLines(probe6.path)
        check("baseline (sync loop, before PR 1a): the main run loop isn't running while MCP handles a request (probe: ticks=0, mode=nil)",
              ok6 && replyID(ping6) == 1 && lines6.count == 1 && lines6.first?["ticks"] == "0" && lines6.first?["mode"] == "nil"
              && fm.fileExists(atPath: f6.path))
        if let l = lines6.first { print("    (run-loop fingerprint today: \(l))") }
    }

    // MARK: approved move: the reply comes only after the move

    static func mcpReplyAfterMove(home: String, dir: URL, runID: String) {
        let fm = FileManager.default
        let f = sandboxFile(dir, "reply-after-move", runID, "moved by mcp")
        let probe = dir.appendingPathComponent("approval-probe-move-\(runID).txt")
        let trashBefore = isolatedTrashCount()
        var first: [String: Any]?, second: [String: Any]?, status: Int32?
        var goneWhenReplyRead = false, trashedWhenReplyRead = false
        let ok = withMcpChild(home: home, extra: ["MACCLEANER_TEST_APPROVAL_PROBE": probe.path,
                                                   "MACCLEANER_TEST_APPROVAL_DELAY_MS": "400",
                                                   "MACCLEANER_TEST_APPROVAL_ANSWER": "yes"]) { c in
            guard let pid = previewMove(c, id: 1, path: f.path) else { return }
            c.send(confirmLine(2, path: f.path, previewID: pid))
            c.send(rpc(3, "ping"))
            first = c.readReply()
            // Right after the confirm's reply is read, before the ping's: the move must already have happened.
            goneWhenReplyRead = !fm.fileExists(atPath: f.path)
            trashedWhenReplyRead = isolatedTrashCount() == trashBefore + 1
            second = c.readReply()
            status = c.finish().status
        }
        let moved = toolText(first)?.json?["moved_to_trash"] as? [String]
        check("--mcp reply only after the move: an approved confirm (400 ms dialog, answer yes) asks once on the main thread (main=1)",
              ok && probeLines(probe.path).count == 1 && probeLines(probe.path).first?["main"] == "1"
              && probeLines(probe.path).first?["isMainThread"] == "true")
        check("--mcp reply only after the move: the confirm's reply is the first line and reports the file moved",
              replyID(first) == 2 && toolText(first)?.isError == false && moved == [Scanner.tilde(f)])
        check("--mcp reply only after the move: when that reply is read the file is already gone from its place and in the isolated Trash",
              goneWhenReplyRead && trashedWhenReplyRead)
        check("--mcp reply only after the move: the ping's reply is second and EOF exits 0", replyID(second) == 3 && status == 0)
        if let e = TrashLog.shared.present().first(where: { $0.original == AppCleanup.physicalPath(f) }) { _ = TrashOps.restore(e) }
    }

    // MARK: 8. CLI trash-files: --yes vs. no TTY

    static func cliTrashFiles(home: String, dir: URL, runID: String) {
        let fm = FileManager.default
        func log(_ u: URL) -> [TrashedItem] { TrashLog.shared.present().filter { $0.original == AppCleanup.physicalPath(u) } }

        let moved = sandboxFile(dir, "cli-yes", runID, "moved")
        let yes = runCLI(["trash-files", moved.path, "--yes"], home: home, scratch: dir)
        check("--cli trash-files --yes: exits 0 and stdout lists the moved item, the file is gone",
              yes.code == 0 && yes.out.contains("moved to trash (1)") && yes.out.contains(Scanner.tilde(moved))
              && !fm.fileExists(atPath: moved.path))
        check("--cli trash-files --yes: the file is in the isolated Trash and logged as a --yes override",
              inIsolatedTrash(log(moved).first?.trashed)
              && log(moved).first?.source == "Command line (--yes, not confirmed by a person)")
        _ = log(moved).first.map { TrashOps.restore($0) }

        let stay = sandboxFile(dir, "cli-refused", runID, "stay")
        let trashBefore = isolatedTrashCount()
        let noInput = runCLI(["trash-files", stay.path], home: home, input: .none, scratch: dir)
        let typedYes = runCLI(["trash-files", stay.path], home: home, input: .text("yes\n"), scratch: dir)
        let typedNo = runCLI(["trash-files", stay.path], home: home, input: .text("no\n"), scratch: dir)
        check("--cli trash-files without --yes and stdin = /dev/null: exits 2 and the file stays",
              noInput.code == 2 && fm.fileExists(atPath: stay.path))
        check("--cli trash-files without --yes and piped \"yes\\n\" (not a TTY): exits 2 (refused), the file stays, stderr says nothing was changed",
              typedYes.code == 2 && fm.fileExists(atPath: stay.path) && typedYes.err.contains("Nothing was changed. Re-run with --yes"))
        check("--cli trash-files without --yes and piped \"no\\n\": exits 2, the file stays",
              typedNo.code == 2 && fm.fileExists(atPath: stay.path))
        check("--cli trash-files refusals print the preview and \"Preview only\" on stdout; the isolated Trash is unchanged",
              [noInput, typedYes, typedNo].allSatisfy { $0.out.contains("Preview only: nothing has been changed yet.") }
              && isolatedTrashCount() == trashBefore && log(stay).isEmpty
              && (try? String(contentsOf: stay, encoding: .utf8)) == "stay")
    }

    // MARK: 9. "moved but unrecorded", human-readable output

    static func cliUnrecordedHumanOutput(home: String, dir: URL, runID: String) {
        let fm = FileManager.default
        let logDir = SafetyGuard.home.appendingPathComponent("Library/Application Support/Mac Cleaner")
        let lockBlocker = logDir.appendingPathComponent("trash-log.json.lock")
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let hadLock = fm.fileExists(atPath: lockBlocker.path)
        let savedLock = hadLock ? try? Data(contentsOf: lockBlocker) : nil
        if hadLock { try? fm.removeItem(at: lockBlocker) }
        try? fm.createDirectory(at: lockBlocker, withIntermediateDirectories: false)   // the Put Back record can't be written
        let k1 = sandboxFile(dir, "cli-human-1", runID, "one"), k2 = sandboxFile(dir, "cli-human-2", runID, "two")
        let r = runCLI(["trash-files", k1.path, k2.path, "--yes"], home: home, scratch: dir)
        try? fm.removeItem(at: lockBlocker)
        if hadLock { fm.createFile(atPath: lockBlocker.path, contents: savedLock ?? Data()) }   // put back what was there
        let outLines = r.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The result follows the preview: everything after the "Going ahead" line.
        let result = outLines.drop { !$0.hasPrefix("Going ahead") }
        let recordLine = result.first { $0.contains("couldn't be recorded for Put Back") }
        let trashedTo: String? = recordLine.flatMap { l in
            guard let open = l.range(of: "moved to the Trash ("), let close = l.range(of: "), but") else { return nil }
            return String(l[open.upperBound..<close.lowerBound])
        }
        check("--cli trash-files --yes (human output) when the Put Back record fails: exit 0; the result lists the moved item and the unrecorded error",
              r.code == 0 && result.contains("moved to trash (1)") && result.contains("errors (2)")
              && result.contains { $0.hasPrefix("  • \(Scanner.tilde(k1))") } && recordLine?.contains(Scanner.tilde(k1)) == true)
        check("--cli trash-files --yes (human output) when the Put Back record fails: the second item is untouched and the output says why",
              fm.fileExists(atPath: k2.path) && !fm.fileExists(atPath: k1.path)
              && result.contains { $0.contains("\(Scanner.tilde(k2)): \(AppCleanup.unrecordedStop)") })
        check("--cli trash-files --yes (human output): the unrecorded move went into the isolated Trash, where the output said", inIsolatedTrash(trashedTo))
        if let trashedTo { try? fm.moveItem(atPath: trashedTo, toPath: k1.path) }
        check("…and the moved item is back from where the output said", fm.fileExists(atPath: k1.path))
    }
}
#endif
