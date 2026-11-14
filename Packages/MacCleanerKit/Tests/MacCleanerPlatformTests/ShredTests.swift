import Darwin
import Foundation
import Testing
import MacCleanerCore
@testable import MacCleanerPlatform

// Overwrite-then-delete on real files (M01-04c). Every Shredder safety check the app's self-test has today is here
// (numbered as in docs/architecture/M01-04C_DESIGN.md §6a), plus the revision-2 cases (§6b). "Another app" is
// played by the package-internal ShredHooks, at the exact moment each check guards.

private func shredFS(_ hooks: ShredHooks? = nil) -> LocalFileSystem {
    LocalFileSystem(trashMover: { _ in throw PlatformError(message: "no Trash in these tests") }, beforeMove: nil, shredHooks: hooks)
}

private struct Tree {
    let parent: FileIdentity, root: FileIdentity, entries: [FileIdentity]
    let snapshot: ShredSnapshot
    init(_ s: ShredSnapshot) throws {
        guard case .tree(let p, let r, let e) = s.target else { throw PlatformError(message: "not a tree") }
        parent = p; root = r; entries = e; snapshot = s
    }
    func without(_ path: String) -> (FileIdentity, FileIdentity, [FileIdentity]) { (parent, root, entries.filter { $0.path != path }) }
}

private func snapshot(_ fs: LocalFileSystem, _ path: String) throws -> Tree {
    switch fs.shredSnapshot(at: path) {
    case .success(let s): return try Tree(s)
    case .failure(let r): throw r
    }
}

private func refusal(_ box: Sandbox, _ rel: String) -> String? {
    if case .failure(let r) = shredFS().shredSnapshot(at: box.path(rel)) { return r.reason }
    return nil
}

private func shred(_ fs: LocalFileSystem, _ t: Tree, protection: @escaping RemovalProtection = unprotected) throws -> OverwriteRemovalResult {
    try fs.overwriteAndRemove(parent: t.parent, root: t.root, entries: t.entries, protection: protection)
}

private func text(_ box: Sandbox, _ rel: String) -> String? { try? String(contentsOfFile: box.path(rel), encoding: .utf8) }

/// No shred staging folder anywhere in the sandbox.
private func noStaging(_ box: Sandbox) -> Bool {
    let all = (FileManager.default.enumerator(atPath: box.root)?.allObjects as? [String]) ?? []
    return !all.contains { ($0 as NSString).lastPathComponent.hasPrefix(LocalFileSystem.shredStagingPrefix) }
}

private func blocks(_ path: String) -> Int64 { var s = stat(); lstat(path, &s); return Int64(s.st_blocks) * 512 }

/// A counter / flag shared with a hook (hooks are @Sendable).
private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

// MARK: - Listing (snapshot) refusals

@Suite("Shred: listing refuses what can't be shredded safely")
struct ShredSnapshotTests {
    @Test func hardLinksAreRefusedAsTheItemOrInside() throws {   // #1, §6b root file
        let box = try Sandbox()
        try box.file("item/a", "keep"); try box.dir("elsewhere")
        link(box.path("item/a"), box.path("elsewhere/alias"))
        #expect(refusal(box, "item")?.contains("hard link") == true)
        try box.file("f.txt", "keep too")
        link(box.path("f.txt"), box.path("elsewhere/alias2"))
        #expect(refusal(box, "f.txt")?.contains("hard link") == true)
        #expect(text(box, "elsewhere/alias") == "keep" && text(box, "elsewhere/alias2") == "keep too")
    }

    @Test func lockedUnreadableHugeSpecialAndLinkItemsAreRefused() throws {   // #3, #10, #11, #12, #21
        let box = try Sandbox()
        try box.file("locked/a"); chflags(box.path("locked/a"), UInt32(UF_IMMUTABLE))
        #expect(refusal(box, "locked")?.contains("locked") == true)
        try box.file("unreadable/sub/x"); chmod(box.path("unreadable/sub"), 0)
        #expect(refusal(box, "unreadable")?.contains("can't be read") == true)
        chmod(box.path("unreadable/sub"), 0o755)
        try box.file("huge/big", "")
        truncate(box.path("huge/big"), LocalFileSystem.maxShredFileSize + 1)   // sparse
        #expect(refusal(box, "huge")?.contains("4 GB") == true)
        try box.dir("fifo"); mkfifo(box.path("fifo/pipe"), 0o600)
        #expect(refusal(box, "fifo")?.contains("not a regular file") == true)
        try box.file("target"); try box.link("ln", to: box.path("target"))
        #expect(refusal(box, "ln")?.contains("link") == true)
        try box.file("unfinished/" + LocalFileSystem.shredStagingPrefix + "old/x")
        #expect(refusal(box, "unfinished")?.contains("unfinished shred") == true)
    }

    @Test func aFolderReachedThroughALinkIsRefused() throws {
        let box = try Sandbox()
        try box.file("real/item/a"); try box.link("via", to: box.path("real"))
        #expect(refusal(box, "via/item")?.contains("link") == true)
    }

    @Test func theSnapshotIsCanonicalAndCarriesItsSizes() throws {
        let box = try Sandbox()
        try box.file("item/b", "bb"); try box.file("item/a-c", "x"); try box.file("item/a/z", "zzz")
        let t = try snapshot(shredFS(), box.path("item"))
        #expect(t.entries.map(\.path) == ["item/a", "item/a-c", "item/a/z", "item/b"].map(box.path).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        #expect(t.snapshot.fileCount == 3 && t.snapshot.logicalBytes == 6)
        #expect(t.snapshot.allocatedBytes == ([box.path("item")] + t.entries.map(\.path)).reduce(0) { $0 + blocks($1) })
        // The plan accepts exactly this target.
        _ = try CleanupPlan([.init(CleanupCandidate(id: "i", module: "shredder", title: "item", targets: [t.snapshot.target],
                                                    estimatedBytes: 6, risk: .reviewRequired, recommended: false, explanation: ""),
                                   .overwriteThenDelete)])
    }
}

// MARK: - Overwrite and remove

@Suite("Shred: overwrite and remove")
struct ShredExecutionTests {
    @Test func aFolderWithSubfoldersIsOverwrittenAndRemoved() throws {   // #4, §6b estimate
        let box = try Sandbox()
        try box.file("item/a", "secret a"); try box.file("item/sub/b", "secret b")
        let t = try snapshot(shredFS(), box.path("item"))
        let expected = ([box.path("item")] + t.entries.map(\.path)).reduce(0) { $0 + blocks($1) }
        let r = try shred(shredFS(), t)
        #expect(r.isComplete && r.filesOverwritten == 2 && r.warnings.isEmpty && !box.exists("item"))
        #expect(r.estimatedFreedBytes == expected && noStaging(box))
    }

    @Test func aClonedFileIsCountedByItsBlocksAsAnEstimate() throws {   // §6b estimate (APFS clone)
        let box = try Sandbox()
        try box.file("orig", String(repeating: "x", count: 100_000)); try box.dir("item")
        guard clonefile(box.path("orig"), box.path("item/clone"), 0) == 0 else { return }   // not APFS: nothing to check
        let t = try snapshot(shredFS(), box.path("item"))
        let expected = blocks(box.path("item")) + blocks(box.path("item/clone"))
        let r = try shred(shredFS(), t)
        #expect(r.isComplete && r.estimatedFreedBytes == expected)
        #expect(text(box, "orig") == String(repeating: "x", count: 100_000))   // the clone's original is untouched
    }

    @Test func aFailedWriteKeepsThatFileAndEverythingAfterIt() throws {   // #6, #7
        let box = try Sandbox()
        for n in ["a", "b", "c"] { try box.file("item/" + n, "secret " + n) }
        let calls = Box(0)
        var hooks = ShredHooks()
        hooks.overwrite = { fd, from, to in
            calls.value += 1
            return calls.value == 1 ? LocalFileSystem.overwriteZeros(fd, from: from, to: to) : (0, "writing failed")
        }
        let r = try shred(shredFS(hooks), try snapshot(shredFS(), box.path("item")))
        #expect(r.filesOverwritten == 1 && !box.exists("item/a"))
        #expect(text(box, "item/b") == "secret b" && text(box, "item/c") == "secret c")
        #expect(r.kept.first == KeptEntry(path: box.path("item/b"), reason: .failed("writing failed")) && r.damaged.isEmpty)
        #expect(box.exists("item") && noStaging(box))
    }

    @Test func aWriteFailingHalfWayIsReportedAsDamaged() throws {   // #8
        let box = try Sandbox()
        try box.file("item/a", "secret data")
        var hooks = ShredHooks()
        hooks.overwrite = { fd, from, _ in
            let zeros = [UInt8](repeating: 0, count: 3)
            _ = zeros.withUnsafeBytes { pwrite(fd, $0.baseAddress, 3, from) }
            return (3, "writing failed")
        }
        let r = try shred(shredFS(hooks), try snapshot(shredFS(), box.path("item")))
        #expect(r.damaged == [box.path("item/a")] && r.filesOverwritten == 0)
        #expect(text(box, "item/a")?.hasPrefix("\0\0\0") == true && noStaging(box))
        if case .failed(let why) = r.kept.first?.reason { #expect(why.contains("damaged")) } else { Issue.record("kept: \(r.kept)") }
    }

    @Test func aFailedFlushKeepsTheFile() throws {   // #9
        let box = try Sandbox()
        try box.file("item/a", "secret")
        var hooks = ShredHooks()
        hooks.overwrite = { _, from, to in (to - from, "couldn't flush to disk") }
        let r = try shred(shredFS(hooks), try snapshot(shredFS(), box.path("item")))
        #expect(r.filesOverwritten == 0 && box.exists("item/a") && !r.isComplete && noStaging(box))
    }

    @Test func aLinkInsideIsRemovedAndItsTargetIsUntouched() throws {   // #20
        let box = try Sandbox()
        try box.file("outside/precious", "keep"); try box.dir("item"); try box.link("item/ln", to: box.path("outside/precious"))
        let r = try shred(shredFS(), try snapshot(shredFS(), box.path("item")))
        #expect(r.isComplete && !box.exists("item") && text(box, "outside/precious") == "keep")
    }

    @Test func aStagingFolderThatCantBeRemovedIsReportedWithItsPath() throws {   // #22, §6b gone + leftover
        let box = try Sandbox()
        try box.file("item/a", "secret")
        let stage = Box("")
        var hooks = ShredHooks()
        hooks.beforeStagingCleanup = { path in stage.value = path; _ = FileManager.default.createFile(atPath: path + "/other-app", contents: Data()) }
        let r = try shred(shredFS(hooks), try snapshot(shredFS(), box.path("item")))
        #expect(!box.exists("item") && r.filesOverwritten == 1 && r.damaged.isEmpty)
        #expect(r.kept == [KeptEntry(path: stage.value, reason: .stagingLeftBehind)] && !r.isComplete)
        try FileManager.default.removeItem(atPath: stage.value)
    }

    @Test func theItemGoneButAFileLeftInStagingIsNotReportedAsShredded() throws {   // §6b gone + kept in staging
        let box = try Sandbox()
        try box.file("item/a", "secret a")
        var hooks = ShredHooks()
        // After the move, "another app" takes the name and swaps the staged file: it can't be put back.
        hooks.afterMove = { original, staged in
            try? FileManager.default.removeItem(atPath: staged)
            _ = FileManager.default.createFile(atPath: staged, contents: Data("swapped".utf8))
            _ = FileManager.default.createFile(atPath: original, contents: Data("took the name".utf8))
        }
        let t = try snapshot(shredFS(), box.path("item"))
        let r = try shred(shredFS(hooks), t)
        #expect(r.filesOverwritten == 0 && text(box, "item/a") == "took the name")
        let inStaging = r.kept.first { $0.path.contains(LocalFileSystem.shredStagingPrefix) && $0.reason != .stagingLeftBehind }
        #expect(inStaging != nil && r.kept.contains { $0.reason == .stagingLeftBehind })
        if let p = inStaging?.path { #expect((try? String(contentsOfFile: p, encoding: .utf8)) == "swapped") }
        if let s = r.kept.first(where: { $0.reason == .stagingLeftBehind })?.path { try? FileManager.default.removeItem(atPath: s) }
    }
}

// MARK: - Races: other apps changing things mid-shred

@Suite("Shred: races")
struct ShredRaceTests {
    @Test func dataAppendedAfterTheOverwriteIsOverwrittenToo() throws {   // #13
        let box = try Sandbox()
        try box.file("item/a", "secret-start")
        let writer = open(box.path("item/a"), O_RDWR)
        defer { close(writer) }
        let tail = Array("APPENDED-SECRET-DATA".utf8)
        var hooks = ShredHooks()
        hooks.afterOverwrite = { _ in var st = stat(); fstat(writer, &st); _ = tail.withUnsafeBytes { pwrite(writer, $0.baseAddress, tail.count, st.st_size) } }
        let r = try shred(shredFS(hooks), try snapshot(shredFS(), box.path("item")))
        var st = stat(); fstat(writer, &st)
        var seen = [UInt8](repeating: 1, count: Int(st.st_size))
        _ = seen.withUnsafeMutableBytes { pread(writer, $0.baseAddress, $0.count, 0) }
        #expect(r.isComplete && r.warnings.isEmpty && st.st_size > 12 && seen.allSatisfy { $0 == 0 })
    }

    @Test func aTailThatCantBeOverwrittenIsAWarning() throws {   // #13 (warning path)
        let box = try Sandbox()
        try box.file("item/a", "secret-start")
        let writer = open(box.path("item/a"), O_RDWR)
        defer { close(writer) }
        var hooks = ShredHooks()
        hooks.afterOverwrite = { _ in let t = Array("MORE".utf8); var st = stat(); fstat(writer, &st); _ = t.withUnsafeBytes { pwrite(writer, $0.baseAddress, 4, st.st_size) } }
        hooks.overwrite = { fd, from, to in from == 0 ? LocalFileSystem.overwriteZeros(fd, from: from, to: to) : (0, "writing failed") }
        let r = try shred(shredFS(hooks), try snapshot(shredFS(), box.path("item")))
        #expect(r.isComplete && r.warnings.first?.contains("another app added data") == true)
    }

    @Test func aFileReplacedRightBeforeTheMoveIsPutBackUntouched() throws {   // #14
        let box = try Sandbox()
        try box.file("item/a", "reviewed")
        let a = box.path("item/a")
        var hooks = ShredHooks()
        hooks.beforeMove = { p in guard p == a else { return }; try? FileManager.default.removeItem(atPath: p); _ = FileManager.default.createFile(atPath: p, contents: Data("new version".utf8)) }
        let r = try shred(shredFS(hooks), try snapshot(shredFS(), box.path("item")))
        #expect(text(box, "item/a") == "new version" && r.filesOverwritten == 0)
        #expect(r.kept.first == KeptEntry(path: a, reason: .changedAfterReview) && noStaging(box))
    }

    @Test func aFileEditedAfterReviewIsKeptAsItIs() throws {   // #15
        let box = try Sandbox()
        try box.file("item/a", "reviewed")
        let t = try snapshot(shredFS(), box.path("item"))
        usleep(2000); try box.file("item/a", "edited after the review")
        let r = try shred(shredFS(), t)
        #expect(text(box, "item/a") == "edited after the review" && r.kept.first?.reason == .changedAfterReview && r.filesOverwritten == 0)
    }

    @Test func entriesAddedAfterReviewAreUntouchedAndTheirFolderStays() throws {   // #16, §6b approved tree only
        let box = try Sandbox()
        try box.file("item/a", "a"); try box.file("item/sub/b", "b"); try box.file("item/z", "z")
        let t = try snapshot(shredFS(), box.path("item"))
        try box.file("item/sub/added", "not reviewed"); try box.file("item/newdir/x", "not reviewed")
        usleep(2000); try box.file("item/z", "replaced content")
        let r = try shred(shredFS(), t)
        // In review order: a and sub/b went; sub stays because of the unreviewed file and the shred stops there, so
        // z (changed after review) is never reached. Nothing unreviewed is touched.
        #expect(!box.exists("item/a") && !box.exists("item/sub/b") && text(box, "item/sub/added") == "not reviewed")
        #expect(r.kept == [KeptEntry(path: box.path("item/sub"), reason: .notEmpty)] && r.filesOverwritten == 2)
        #expect(text(box, "item/newdir/x") == "not reviewed" && text(box, "item/z") == "replaced content" && noStaging(box))
    }

    @Test func anEntryLeftOutOfTheApprovedTreeIsNeverTouched() throws {   // §6b approved tree only
        let box = try Sandbox()
        try box.file("item/a", "a"); try box.file("item/extra", "existed at review, not approved")
        let t = try snapshot(shredFS(), box.path("item"))
        let (p, root, entries) = t.without(box.path("item/extra"))
        let r = try shredFS().overwriteAndRemove(parent: p, root: root, entries: entries, protection: unprotected)
        #expect(!box.exists("item/a") && text(box, "item/extra") == "existed at review, not approved")
        #expect(r.kept == [KeptEntry(path: box.path("item"), reason: .notEmpty)])
    }

    @Test func aSubfolderSwappedForALinkBeforeStartingLeavesTheTargetUntouched() throws {   // #17
        let box = try Sandbox()
        try box.file("item/a", "a"); try box.file("item/sub/b", "b"); try box.file("outside/precious", "keep")
        let t = try snapshot(shredFS(), box.path("item"))
        let sub = box.path("item/sub"), outside = box.path("outside")
        var hooks = ShredHooks()
        hooks.beforeStart = { try? FileManager.default.removeItem(atPath: sub); try? FileManager.default.createSymbolicLink(atPath: sub, withDestinationPath: outside) }
        let r = try shred(shredFS(hooks), t)
        #expect(text(box, "outside/precious") == "keep" && r.kept.first == KeptEntry(path: sub, reason: .changedAfterReview))
    }

    @Test func aSubfolderSwappedForALinkMidShredLeavesTheTargetUntouched() throws {   // #18
        let box = try Sandbox()
        try box.file("item/sub/b", "b"); try box.file("outside/precious", "keep")
        let t = try snapshot(shredFS(), box.path("item"))
        let sub = box.path("item/sub"), b = box.path("item/sub/b"), outside = box.path("outside")
        var hooks = ShredHooks()
        hooks.beforeMove = { p in
            guard p == b else { return }
            try? FileManager.default.moveItem(atPath: sub, toPath: sub + "-moved")
            try? FileManager.default.createSymbolicLink(atPath: sub, withDestinationPath: outside)
        }
        let r = try shred(shredFS(hooks), t)
        // The planned file was shredded through the open folder; the link and its target were left alone.
        #expect(r.filesOverwritten == 1 && !box.exists("item/sub-moved/b") && text(box, "outside/precious") == "keep")
        #expect(r.kept.first == KeptEntry(path: sub, reason: .changedAfterReview))
    }

    @Test func theItemsFolderSwappedForALinkIsRefusedWithNothingChanged() throws {   // #19
        let box = try Sandbox()
        try box.file("parent/item/a", "a"); try box.file("outside/item/a", "other side")
        let t = try snapshot(shredFS(), box.path("parent/item"))
        let parent = box.path("parent"), outside = box.path("outside")
        var hooks = ShredHooks()
        hooks.beforeStart = {
            try? FileManager.default.moveItem(atPath: parent, toPath: parent + "-moved")
            try? FileManager.default.createSymbolicLink(atPath: parent, withDestinationPath: outside)
        }
        #expect(throws: FileSystemRefusal.changed(.replaced)) { try shred(shredFS(hooks), t) }
        #expect(text(box, "parent-moved/item/a") == "a" && text(box, "outside/item/a") == "other side" && noStaging(box))
    }

    @Test func aMissingParentIsReportedAsMissing() throws {
        let box = try Sandbox()
        try box.file("parent/item/a", "a")
        let t = try snapshot(shredFS(), box.path("parent/item"))
        try FileManager.default.removeItem(atPath: box.path("parent"))
        #expect(throws: FileSystemRefusal.missing) { try shred(shredFS(), t) }
    }

    @Test func aHardLinkAddedAfterReviewIsCaughtAtEveryCheck() throws {   // §6b link count
        // Before the move (in place), after the move (in staging), and on the open descriptor right before the overwrite.
        for stage in ["in place", "after move", "on open"] {
            let box = try Sandbox()
            try box.file("item/a", "secret"); try box.dir("elsewhere")
            let t = try snapshot(shredFS(), box.path("item"))
            let alias = box.path("elsewhere/alias")
            var hooks = ShredHooks()
            switch stage {
            case "in place": link(box.path("item/a"), alias)
            case "after move": hooks.afterMove = { _, staged in link(staged, alias) }
            default: hooks.afterOpen = { staged in link(staged, alias) }
            }
            let r = try shred(shredFS(hooks), t)
            #expect(r.filesOverwritten == 0 && text(box, "item/a") == "secret" && text(box, "elsewhere/alias") == "secret", "\(stage)")
            if case .failed(let why) = r.kept.first?.reason { #expect(why.contains("hard link"), "\(stage)") } else { Issue.record("\(stage): \(r.kept)") }
            #expect(noStaging(box), "\(stage)")
        }
    }

    @Test func aFileLockedAfterReviewIsKept() throws {   // §6b flags
        let box = try Sandbox()
        try box.file("item/a", "secret")
        let t = try snapshot(shredFS(), box.path("item"))
        chflags(box.path("item/a"), UInt32(UF_IMMUTABLE))
        let r = try shred(shredFS(), t)
        #expect(r.filesOverwritten == 0 && text(box, "item/a") == "secret")
        if case .failed(let why) = r.kept.first?.reason { #expect(why.contains("locked")) } else { Issue.record("\(r.kept)") }
    }

    @Test func anEntryProtectedDuringTheShredStopsTheItem() throws {   // #2, §4 per-entry protection
        let box = try Sandbox()
        for n in ["a", "b", "c"] { try box.file("item/" + n, n) }
        let t = try snapshot(shredFS(), box.path("item"))
        let b = box.path("item/b")
        let r = try shred(shredFS(), t, protection: { $0 == b ? "Protected in Settings" : nil })
        #expect(!box.exists("item/a") && text(box, "item/b") == "b" && text(box, "item/c") == "c")
        #expect(r.kept.first == KeptEntry(path: b, reason: .protected("Protected in Settings")) && r.filesOverwritten == 1)
    }
}
