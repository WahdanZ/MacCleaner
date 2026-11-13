import Darwin
import Foundation
import Testing
import MacCleanerCore
@testable import MacCleanerPlatform
@testable import MacCleanerFeatures

// MARK: - Fakes

/// An in-memory file system. Like the real one, every changing operation re-checks the expected identity.
final class FakeFS: CleanupFileSystem, @unchecked Sendable {   // all state behind `lock`
    enum Op: Equatable { case trash(String), remove(String) }

    private let lock = NSLock()
    private var items: [String: FileIdentity]
    private var _ops: [Op] = []
    private var partial: [String: RemovalResult] = [:]
    private var failing: Set<String> = []
    private var denied: Set<String> = []
    /// Runs inside an operation, after the executor's own check and before the fake's last-moment check.
    private var hook: (@Sendable (String) -> Void)?

    init(_ items: [FileIdentity]) { self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) }) }

    private func locked<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }

    var ops: [Op] { locked { _ops } }
    func put(_ i: FileIdentity) { locked { items[i.path] = i } }
    func delete(_ path: String) { locked { items[path] = nil } }
    func partially(_ path: String, _ r: RemovalResult) { locked { partial[path] = r } }
    func fail(_ path: String) { locked { _ = failing.insert(path) } }
    func denyPermission(_ path: String) { locked { _ = denied.insert(path) } }
    func onAct(_ f: @escaping @Sendable (String) -> Void) { locked { hook = f } }

    func identity(at path: String) throws -> FileIdentity? { locked { items[path] } }

    func entries(of folder: FileIdentity) throws -> [FileIdentity] {
        try locked {
            guard let now = items[folder.path] else { throw FileSystemRefusal.missing }
            if let m = folder.mismatch(against: now) { throw FileSystemRefusal.changed(m) }
            return items.values.filter { $0.isDirectChild(of: folder) }.sorted { $0.path < $1.path }
        }
    }

    private func act(_ item: FileIdentity, _ op: Op) throws {
        if let h = locked({ hook }) { h(item.path) }
        try locked {
            guard let now = items[item.path] else { throw FileSystemRefusal.missing }
            if let m = item.mismatch(against: now) { throw FileSystemRefusal.changed(m) }
            if failing.contains(item.path) { throw PlatformError(message: "\(item.path): Operation not permitted") }
            if denied.contains(item.path) { throw FileSystemRefusal.permissionDenied("\(item.path): owned by root") }
            _ops.append(op)
            if partial[item.path] == nil { items = items.filter { !PathRules.isInside($0.key, item.path) } }
        }
    }

    func moveToTrash(_ item: FileIdentity) throws -> TrashResult {
        try act(item, .trash(item.path))
        return TrashResult(bytes: item.size, recoveryPath: "/Users/tester/.Trash/" + (item.path as NSString).lastPathComponent)
    }

    /// Asks `protection` about one made-up entry inside a folder, the way the real walk asks about every entry.
    func remove(_ item: FileIdentity, protection: RemovalProtection) throws -> RemovalResult {
        try act(item, .remove(item.path))
        if item.kind == .directory, let why = protection(item.path + "/nested") {
            return RemovalResult(freedBytes: 0, kept: [KeptEntry(path: item.path + "/nested", reason: .protected(why))])
        }
        return locked { partial[item.path] } ?? RemovalResult(freedBytes: item.size)
    }
}

struct Protected: ProtectionChecking {
    var paths: Set<String> = []
    func refusal(path: String, disposition: Disposition) -> String? { paths.contains(path) ? "Protected in Settings" : nil }
}

final class TestClock: @unchecked Sendable {   // `now` behind `lock`
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

private let home = "/Users/tester"
private func item(_ rel: String, inode: UInt64, kind: FileIdentity.Kind = .file, size: Int64 = 100) -> FileIdentity {
    FileIdentity(path: home + "/" + rel, device: 1, inode: inode, kind: kind, size: size, modificationNanos: 5,
                 capturedAtNanos: 10)
}
private func candidate(_ id: String, _ targets: [CleanupTarget], risk: CleanupRisk = .safeRegenerable) -> CleanupCandidate {
    CleanupCandidate(id: id, module: "caches", title: id, targets: targets, estimatedBytes: 100, risk: risk,
                     recommended: true, explanation: "")
}
private func plan(_ entries: [CleanupPlan.Entry]) throws -> CleanupPlan { try CleanupPlan(entries) }

/// Runs `plan` with a fresh approval and collects every event.
private func run(_ exec: CleanupExecutor, _ plan: CleanupPlan) async throws -> (CleanupReport, [ProgressEvent]) {
    let approval = try await exec.approve(plan, by: .userInApp)
    let (stream, cont) = AsyncStream.makeStream(of: ProgressEvent.self)
    let report = try await exec.execute(plan, approval: approval, progress: cont)
    var events: [ProgressEvent] = []
    for await e in stream { events.append(e) }
    return (report, events)
}

private func results(_ r: CleanupReport) -> [String: ItemOutcome.Result] {
    Dictionary(r.outcomes.map { o -> (String, ItemOutcome.Result) in
        if case .file(let f) = o.target { return (f.path, o.result) }
        return (o.candidateID, o.result)
    }, uniquingKeysWith: { a, _ in a })
}

// MARK: - Revalidation

@Suite("Executor: revalidation")
struct ExecutorRevalidationTests {
    let file = item("Library/Caches/a.log", inode: 1)
    let folder = item("Library/Caches/App", inode: 2, kind: .directory)

    @Test func carriesOutAnUnchangedPlan() async throws {
        let fs = FakeFS([file, folder])
        let p = try plan([.init(candidate("f", [.file(file)]), .trash), .init(candidate("d", [.file(folder)]), .permanentDelete)])
        let (report, events) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(fs.ops == [.trash(file.path), .remove(folder.path)])
        #expect(report.allSucceeded && report.freedBytes == 100 && report.movedToTrashBytes == 100)
        #expect(events.first == .cleanupStarted(planDigest: p.digest, targetCount: 2))
        #expect(events.last == .finished(report))
        #expect(events.count == 4)
    }

    @Test func identitySwapIsSkippedAndReported() async throws {
        let fs = FakeFS([file])
        let p = try plan([.init(candidate("f", [.file(file)]), .permanentDelete)])
        fs.put(item("Library/Caches/a.log", inode: 99))
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(results(report)[file.path] == .skipped(.changed(.replaced)))
        #expect(fs.ops.isEmpty && !report.allSucceeded)
    }

    @Test func symlinkSwapIsSkippedAndReported() async throws {
        let fs = FakeFS([folder])
        let p = try plan([.init(candidate("d", [.file(folder)]), .permanentDelete)])
        fs.put(item("Library/Caches/App", inode: 50, kind: .symlink))
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(results(report)[folder.path] == .skipped(.changed(.kindChanged(from: .directory, to: .symlink))))
        #expect(fs.ops.isEmpty)
    }

    @Test func aSwapRacingTheOperationIsCaughtByTheFileSystem() async throws {
        let fs = FakeFS([file])
        let p = try plan([.init(candidate("f", [.file(file)]), .permanentDelete)])
        let swapped = item("Library/Caches/a.log", inode: 77)
        fs.onAct { _ in fs.put(swapped) }   // after the executor's check, before the delete
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(results(report)[file.path] == .skipped(.changed(.replaced)))
        #expect(fs.ops.isEmpty)
    }

    @Test func newlyProtectedIsSkippedAndReported() async throws {
        let fs = FakeFS([file])
        let p = try plan([.init(candidate("f", [.file(file)]), .trash)])
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected(paths: [file.path]))
        let (report, _) = try await run(exec, p)
        #expect(results(report)[file.path] == .skipped(.protected("Protected in Settings")))
        #expect(fs.ops.isEmpty)
    }

    @Test func theLiveProtectionRulesReachEveryEntryOfARemoval() async throws {
        let fs = FakeFS([folder])
        let p = try plan([.init(candidate("d", [.file(folder)]), .permanentDelete)])
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected(paths: [folder.path + "/nested"]))
        let (report, _) = try await run(exec, p)
        #expect(results(report)[folder.path] == .partiallyDone(
            freedBytes: 0, kept: [KeptEntry(path: folder.path + "/nested", reason: .protected("Protected in Settings"))], damaged: []))
    }

    @Test func aCallersPreconditionCanRefuseSingleItems() async throws {
        let other = item("Library/Caches/b.log", inode: 9)
        let fs = FakeFS([file, other])
        let p = try plan([.init(candidate("f", [.file(file)]), .trash), .init(candidate("o", [.file(other)]), .trash)])
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let approval = try await exec.approve(p, by: .userInApp)
        #expect(await exec.outstandingApprovals == 1)
        let report = try await exec.execute(p, approval: approval, precondition: { id, _ in id == "f" ? "no copy left" : nil })
        #expect(results(report)[file.path] == .skipped(.preconditionFailed("no copy left")))
        let left = await exec.outstandingApprovals
        #expect(fs.ops == [.trash(other.path)] && left == 0)
    }

    @Test func aPermissionRefusalIsDistinctFromOtherOutcomes() async throws {
        let fs = FakeFS([file])
        fs.denyPermission(file.path)
        let p = try plan([.init(candidate("f", [.file(file)]), .trash)])
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(results(report)[file.path] == .permissionDenied("\(file.path): owned by root"))
        #expect(fs.ops.isEmpty && !report.allSucceeded)
    }

    @Test func alreadyDeletedIsReportedAsMissing() async throws {
        let fs = FakeFS([file])
        let p = try plan([.init(candidate("f", [.file(file)]), .permanentDelete)])
        fs.delete(file.path)
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(results(report)[file.path] == .skipped(.missing))
    }

    @Test func aFileWrittenSinceReviewIsSkipped() async throws {
        let fs = FakeFS([file])
        let p = try plan([.init(candidate("f", [.file(file)]), .permanentDelete)])
        fs.put(item("Library/Caches/a.log", inode: 1, size: 101))
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(results(report)[file.path] == .skipped(.changed(.contentChanged)))
    }
}

// MARK: - Folder contents

@Suite("Executor: folder contents")
struct ExecutorContentsTests {
    let folder = item("Library/Caches/App", inode: 10, kind: .directory)
    var a: FileIdentity { item("Library/Caches/App/a", inode: 11) }
    var b: FileIdentity { item("Library/Caches/App/b", inode: 12, kind: .directory) }

    @Test func onlyReviewedEntriesAreRemoved() async throws {
        let added = item("Library/Caches/App/new", inode: 13)
        let fs = FakeFS([folder, a, b])
        let p = try plan([.init(candidate("c", [.directoryContents(folder: folder, entries: [a, b])]), .permanentDelete)])
        fs.put(added)
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        let r = results(report)
        #expect(r[added.path] == .skipped(.addedAfterReview))
        #expect(r[a.path] == .removed(bytes: 100) && r[b.path] == .removed(bytes: 100))
        #expect(fs.ops == [.remove(a.path), .remove(b.path)])
        let stillThere = try (fs.identity(at: added.path), fs.identity(at: folder.path))
        #expect(stillThere.0 != nil && stillThere.1 != nil)
        #expect(!report.allSucceeded)   // something was left on purpose: say so
    }

    @Test func aReviewedEntrySwappedIsSkipped() async throws {
        let fs = FakeFS([folder, a, b])
        let p = try plan([.init(candidate("c", [.directoryContents(folder: folder, entries: [a, b])]), .permanentDelete)])
        fs.put(item("Library/Caches/App/b", inode: 99, kind: .symlink))
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(results(report)[b.path] == .skipped(.changed(.kindChanged(from: .directory, to: .symlink))))
        #expect(fs.ops == [.remove(a.path)])
    }

    @Test func aSwappedFolderTouchesNothing() async throws {
        let fs = FakeFS([folder, a, b])
        let p = try plan([.init(candidate("c", [.directoryContents(folder: folder, entries: [a, b])]), .permanentDelete)])
        fs.put(item("Library/Caches/App", inode: 66, kind: .symlink))
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        #expect(report.outcomes.allSatisfy { $0.result == .skipped(.changed(.kindChanged(from: .directory, to: .symlink))) })
        #expect(report.outcomes.count == 2 && fs.ops.isEmpty)
    }
}

// MARK: - Partial results and failures

@Suite("Executor: partial outcomes")
struct ExecutorPartialTests {
    @Test func partialFailedAndUnsupportedAreReportedAndTheRestContinues() async throws {
        let part = item("p", inode: 1, kind: .directory), bad = item("bad", inode: 2), ok = item("ok", inode: 3)
        let shred = item("s", inode: 4)
        let fs = FakeFS([part, bad, ok, shred])
        let kept = [KeptEntry(path: part.path + "/locked", reason: .failed("Operation not permitted"))]
        fs.partially(part.path, RemovalResult(freedBytes: 40, kept: kept))
        fs.fail(bad.path)
        let simctl = ToolCommand(executable: "/usr/bin/xcrun", arguments: ["simctl"], consequence: "A runtime")
        let p = try plan([.init(candidate("p", [.file(part)]), .permanentDelete),
                          .init(candidate("bad", [.file(bad)]), .permanentDelete),
                          .init(candidate("s", [.file(shred)]), .overwriteThenDelete),
                          .init(candidate("cmd", [.command(simctl)]), .command),
                          .init(candidate("ok", [.file(ok)]), .permanentDelete)])
        let (report, _) = try await run(CleanupExecutor(fileSystem: fs, protection: Protected()), p)
        let r = results(report)
        #expect(r[part.path] == .partiallyDone(freedBytes: 40, kept: kept, damaged: []))
        if case .failed(let why) = r[bad.path] { #expect(why.contains("not permitted")) } else { Issue.record("bad: \(String(describing: r[bad.path]))") }
        if case .failed = r[shred.path] {} else { Issue.record("overwrite should not run yet") }
        if case .failed = r["cmd"] {} else { Issue.record("commands should not run yet") }
        #expect(r[ok.path] == .removed(bytes: 100))
        #expect(fs.ops == [.remove(part.path), .remove(ok.path)])
        #expect(report.freedBytes == 140 && !report.allSucceeded)
    }
}

// MARK: - Approval

@Suite("Executor: approval")
struct ExecutorApprovalTests {
    let f = item("Library/Caches/x", inode: 1)

    @Test func anApprovalWorksOnceAndOnlyForItsPlan() async throws {
        let fs = FakeFS([f, item("Library/Caches/y", inode: 2)])
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let p = try plan([.init(candidate("x", [.file(f)]), .trash)])
        let other = try plan([.init(candidate("y", [.file(item("Library/Caches/y", inode: 2))]), .permanentDelete)])
        let a = try await exec.approve(p, by: .userInTerminal)

        await #expect(throws: CleanupApproval.Refusal.planChanged) { try await exec.execute(other, approval: a) }
        await #expect(throws: CleanupApproval.Refusal.alreadyUsed) { try await exec.execute(p, approval: a) }   // used up
        #expect(fs.ops.isEmpty)

        let b = try await exec.approve(p, by: .userInTerminal)
        _ = try await exec.execute(p, approval: b)
        await #expect(throws: CleanupApproval.Refusal.alreadyUsed) { try await exec.execute(p, approval: b) }
        #expect(fs.ops == [.trash(f.path)])
    }

    @Test func anotherExecutorsApprovalIsRefused() async throws {
        let fs = FakeFS([f])
        let p = try plan([.init(candidate("x", [.file(f)]), .trash)])
        let mine = CleanupExecutor(fileSystem: fs, protection: Protected())
        let theirs = CleanupExecutor(fileSystem: fs, protection: Protected())   // e.g. another process
        let a = try await theirs.approve(p, by: .userInApp)
        await #expect(throws: CleanupApproval.Refusal.notIssued) { try await mine.execute(p, approval: a) }
        #expect(fs.ops.isEmpty)
    }

    @Test func anExpiredApprovalIsRefusedAndTheStreamEnds() async throws {
        let fs = FakeFS([f])
        let clock = TestClock()
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected(), now: { clock.now })
        let p = try plan([.init(candidate("x", [.file(f)]), .trash)])
        let a = try await exec.approve(p, by: .userInApp, lifetime: 60)
        clock.advance(60)
        let (stream, cont) = AsyncStream.makeStream(of: ProgressEvent.self)
        await #expect(throws: CleanupApproval.Refusal.expired) { try await exec.execute(p, approval: a, progress: cont) }
        var events: [ProgressEvent] = []
        for await e in stream { events.append(e) }
        #expect(events.isEmpty && fs.ops.isEmpty)
    }

    @Test func aStandingPolicyCantApproveReviewItems() async throws {
        let exec = CleanupExecutor(fileSystem: FakeFS([f]), protection: Protected())
        let p = try plan([.init(candidate("x", [.file(f)], risk: .reviewRequired), .permanentDelete)])
        await #expect(throws: ApprovalLedger.IssueRefusal.outsidePolicyScope(candidateID: "x")) {
            try await exec.approve(p, by: .standingPolicy(id: "safe-clean", version: 1))
        }
    }
}

// MARK: - Cancellation

@Suite("Executor: cancellation")
struct ExecutorCancellationTests {
    @Test func cancellingMidwayStopsBetweenTargets() async throws {
        let a = item("a", inode: 1), b = item("b", inode: 2), c = item("c", inode: 3)
        let fs = FakeFS([a, b, c])
        fs.onAct { _ in withUnsafeCurrentTask { $0?.cancel() } }   // cancelled while the first item is handled
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let p = try plan([.init(candidate("a", [.file(a)]), .permanentDelete),
                          .init(candidate("b", [.file(b)]), .permanentDelete),
                          .init(candidate("c", [.file(c)]), .permanentDelete)])
        let approval = try await exec.approve(p, by: .userInApp)
        let (stream, cont) = AsyncStream.makeStream(of: ProgressEvent.self)
        let report = try await Task { try await exec.execute(p, approval: approval, progress: cont) }.value
        var events: [ProgressEvent] = []
        for await e in stream { events.append(e) }
        let r = results(report)
        #expect(r[a.path] == .removed(bytes: 100))
        #expect(r[b.path] == .skipped(.cancelled) && r[c.path] == .skipped(.cancelled))
        #expect(report.wasCancelled && !report.allSucceeded && fs.ops == [.remove(a.path)])
        #expect(events.last == .cancelled && events.filter(\.isTerminal).count == 1)
    }

    @Test func cancellingInsideTheLastFoldersEntriesIsReportedAsCancelled() async throws {
        let folder = item("C", inode: 1, kind: .directory)
        let a = item("C/a", inode: 2), b = item("C/b", inode: 3)
        let fs = FakeFS([folder, a, b])
        fs.onAct { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let p = try plan([.init(candidate("c", [.directoryContents(folder: folder, entries: [a, b])]), .permanentDelete)])
        let approval = try await exec.approve(p, by: .userInApp)
        let (stream, cont) = AsyncStream.makeStream(of: ProgressEvent.self)
        let report = try await Task { try await exec.execute(p, approval: approval, progress: cont) }.value
        var events: [ProgressEvent] = []
        for await e in stream { events.append(e) }
        let r = results(report)
        #expect(r[a.path] == .removed(bytes: 100) && r[b.path] == .skipped(.cancelled))
        #expect(report.wasCancelled && !report.allSucceeded)
        #expect(events.last == .cancelled && events.filter(\.isTerminal).count == 1)
    }
}

// MARK: - End to end on real files

@Suite("Executor on real files")
struct ExecutorRealDiskTests {
    @Test func folderContentsOnDisk() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("maccleaner-exec-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = realPath(base.path)
        let cache = root + "/Cache", outside = root + "/outside"
        for d in [cache + "/sub", outside] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        for f in [cache + "/a", cache + "/sub/b", cache + "/swap-me", outside + "/precious"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: f))
        }
        let fs = LocalFileSystem(trashMover: { _ in throw PlatformError(message: "no Trash in this test") })
        usleep(2000)
        let folder = try #require(try fs.identity(at: cache))
        let entries = try fs.entries(of: folder)
        let p = try CleanupPlan([.init(CleanupCandidate(id: "cache", module: "caches", title: "Cache",
                                                        targets: [.directoryContents(folder: folder, entries: entries)],
                                                        estimatedBytes: 3, risk: .safeRegenerable, recommended: true,
                                                        explanation: ""), .permanentDelete)])
        usleep(2000)
        // After review: a new file appears, and a reviewed entry is swapped for a symlink to something precious.
        try Data("new".utf8).write(to: URL(fileURLWithPath: cache + "/added-later"))
        try fm.removeItem(atPath: cache + "/swap-me")
        try fm.createSymbolicLink(atPath: cache + "/swap-me", withDestinationPath: outside)

        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let approval = try await exec.approve(p, by: .userInApp)
        let report = try await exec.execute(p, approval: approval)
        let r = results(report)
        #expect(r[cache + "/a"] == .removed(bytes: r[cache + "/a"].flatMap { if case .removed(let b) = $0 { b } else { nil } } ?? -1))
        #expect(!fm.fileExists(atPath: cache + "/a") && !fm.fileExists(atPath: cache + "/sub"))
        #expect(r[cache + "/added-later"] == .skipped(.addedAfterReview) && fm.fileExists(atPath: cache + "/added-later"))
        #expect(r[cache + "/swap-me"] == .skipped(.changed(.kindChanged(from: .file, to: .symlink))))
        #expect(fm.fileExists(atPath: outside + "/precious") && fm.fileExists(atPath: cache))
        #expect(try fm.contentsOfDirectory(atPath: cache).sorted() == ["added-later", "swap-me"])   // no staging left
    }
}

/// The path with every symlink resolved (realpath). URL.resolvingSymlinksInPath turns /private/var back into
/// /var, which is itself a symlink.
func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

// MARK: - Per-item completion

/// Thread-safe list for completion callbacks.
final class Journal<T: Sendable>: @unchecked Sendable {   // `items` behind `lock`
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite("Executor: per-item completion")
struct ExecutorCompletionTests {
    let a = item("a", inode: 1), b = item("b", inode: 2), c = item("c", inode: 3)

    @Test func eachItemIsFinishedBeforeTheNextIsTouched() async throws {
        let fs = FakeFS([a, b, c])
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let p = try plan([.init(candidate("a", [.file(a)]), .trash), .init(candidate("b", [.file(b)]), .trash),
                          .init(candidate("c", [.file(c)]), .trash)])
        let seen = Journal<(String, Int)>()   // (candidate, operations done when it was finished)
        let approval = try await exec.approve(p, by: .userInApp)
        let report = try await exec.execute(p, approval: approval, onItemFinished: { o in
            seen.add((o.candidateID, fs.ops.count)); return nil
        })
        #expect(seen.all.map(\.0) == ["a", "b", "c"])
        #expect(seen.all.map(\.1) == [1, 2, 3])   // a finished while only a had moved, and so on
        #expect(report.allSucceeded)
    }

    @Test func stoppingAfterAnItemLeavesTheRestUntouched() async throws {
        let fs = FakeFS([a, b, c])
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let p = try plan([.init(candidate("a", [.file(a)]), .trash), .init(candidate("b", [.file(b)]), .trash),
                          .init(candidate("c", [.file(c)]), .trash)])
        let approval = try await exec.approve(p, by: .userInApp)
        let report = try await exec.execute(p, approval: approval, onItemFinished: { o in
            o.candidateID == "a" ? "couldn't record it" : nil
        })
        let r = results(report)
        #expect(r[a.path] == .trashed(bytes: 100, recoveryPath: "/Users/tester/.Trash/a"))
        #expect(r[b.path] == .skipped(.preconditionFailed("couldn't record it")) && r[c.path] == r[b.path])
        #expect(fs.ops == [.trash(a.path)] && !report.wasCancelled && !report.allSucceeded)
        // The approval was used by this run, stopped or not.
        await #expect(throws: CleanupApproval.Refusal.alreadyUsed) { try await exec.execute(p, approval: approval) }
    }

    @Test func folderEntriesAreFinishedOneByOne() async throws {
        let folder = item("F", inode: 10, kind: .directory)
        let x = item("F/x", inode: 11), y = item("F/y", inode: 12)
        let fs = FakeFS([folder, x, y])
        let exec = CleanupExecutor(fileSystem: fs, protection: Protected())
        let p = try plan([.init(candidate("f", [.directoryContents(folder: folder, entries: [x, y])]), .permanentDelete)])
        let approval = try await exec.approve(p, by: .userInApp)
        let report = try await exec.execute(p, approval: approval, onItemFinished: { o in
            if case .file(let i) = o.target, i.path == x.path { return "stop after x" }
            return nil
        })
        #expect(fs.ops == [.remove(x.path)])
        #expect(results(report)[y.path] == .skipped(.preconditionFailed("stop after x")))
    }
}

