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
        #expect(text(box, "item/a") == "keep" && text(box, "f.txt") == "keep too")   // nothing was changed
    }

    @Test func lockedUnreadableHugeSpecialAndLinkItemsAreRefused() throws {   // #3, #10, #11, #12, #21
        let box = try Sandbox()
        try box.file("locked/a"); chflags(box.path("locked/a"), UInt32(UF_IMMUTABLE))
        #expect(refusal(box, "locked")?.contains("locked") == true && text(box, "locked/a") == "data")
        try box.file("unreadable/f", "G"); try box.file("unreadable/sub/x", "H"); chmod(box.path("unreadable/sub"), 0)
        #expect(refusal(box, "unreadable")?.contains("can't be read") == true)
        chmod(box.path("unreadable/sub"), 0o755)
        #expect(text(box, "unreadable/f") == "G" && text(box, "unreadable/sub/x") == "H")   // untouched
        try box.file("huge/small", "small"); try box.file("huge/big", "")
        truncate(box.path("huge/big"), LocalFileSystem.maxShredFileSize + 1)   // sparse
        #expect(refusal(box, "huge")?.contains("4 GB") == true)
        #expect(text(box, "huge/small") == "small" && box.exists("huge/big"))   // untouched
        try box.file("fifo/f", "K"); mkfifo(box.path("fifo/pipe"), 0o600)
        #expect(refusal(box, "fifo")?.contains("not a regular file") == true && text(box, "fifo/f") == "K")
        try box.file("target", "outside"); try box.link("ln", to: box.path("target"))
        #expect(refusal(box, "ln")?.contains("link") == true)
        #expect(text(box, "target") == "outside" && (try? FileManager.default.destinationOfSymbolicLink(atPath: box.path("ln"))) == box.path("target"))
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
        try box.file("item/a", "secret a"); try box.file("item/sub/deeper/b", "secret b")
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
        #expect(text(box, "item/a") == "\0\0\0ret data" && noStaging(box))   // the start is zeroed, the rest as it was
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
        try box.file("outside/precious", "keep"); try box.file("item/f", "J"); try box.link("item/ln", to: box.path("outside/precious"))
        let r = try shred(shredFS(), try snapshot(shredFS(), box.path("item")))
        #expect(r.isComplete && r.filesOverwritten == 1 && !box.exists("item") && text(box, "outside/precious") == "keep")
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
        #expect(r.isComplete && r.filesOverwritten == 1 && r.warnings.isEmpty && !box.exists("item/a"))
        #expect(st.st_size == off_t(12 + tail.count) && seen.allSatisfy { $0 == 0 })
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

    @Test func aFileReplacedByAnAtomicSaveRightBeforeTheMoveIsPutBackUntouched() throws {   // #14, as another app saves (rename over)
        let box = try Sandbox()
        try box.file("item/a", "A"); try box.file("item/b", "B-old")
        let b = box.path("item/b"), saving = box.path("item/.b.saving")
        var hooks = ShredHooks()
        hooks.beforeMove = { p in
            guard p == b else { return }
            _ = FileManager.default.createFile(atPath: saving, contents: Data("B-new".utf8))
            _ = rename(saving, p)
        }
        let r = try shred(shredFS(hooks), try snapshot(shredFS(), box.path("item")))
        #expect(!box.exists("item/a") && text(box, "item/b") == "B-new" && r.filesOverwritten == 1)
        #expect(r.kept.first == KeptEntry(path: b, reason: .changedAfterReview) && noStaging(box))
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
        hooks.beforeStart = { try? FileManager.default.moveItem(atPath: sub, toPath: sub + "-moved"); try? FileManager.default.createSymbolicLink(atPath: sub, withDestinationPath: outside) }
        let r = try shred(shredFS(hooks), t)
        #expect(text(box, "outside/precious") == "keep" && r.kept.first == KeptEntry(path: sub, reason: .changedAfterReview))
        #expect(text(box, "item/sub-moved/b") == "b" && noStaging(box))   // the moved folder is untouched too
    }

    @Test func aSubfolderSwappedForALinkMidShredLeavesTheTargetUntouched() throws {   // #18
        let box = try Sandbox()
        try box.file("item/a", "a"); try box.file("item/sub/b", "b"); try box.file("outside/precious", "keep")
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
        #expect(r.filesOverwritten == 2 && !box.exists("item/a") && !box.exists("item/sub-moved/b") && text(box, "outside/precious") == "keep")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: sub)) == outside)
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

    @Test func aFileLockedAfterReviewIsCaughtAtEveryCheckBeforeTheOverwrite() throws {   // §6b flags, §3 checks 1-3
        // In place, after the move (a locked file can't be moved back, so it stays in staging, unchanged), and on the
        // open descriptor right before the overwrite. Nothing is overwritten, and the next entry is never touched.
        for stage in ["in place", "after move", "on open"] {
            let box = try Sandbox()
            try box.file("item/a", "secret"); try box.file("item/b", "next")
            let t = try snapshot(shredFS(), box.path("item"))
            var hooks = ShredHooks()
            switch stage {
            case "in place": chflags(box.path("item/a"), UInt32(UF_IMMUTABLE))
            case "after move": hooks.afterMove = { _, staged in chflags(staged, UInt32(UF_IMMUTABLE)) }
            default: hooks.afterOpen = { staged in chflags(staged, UInt32(UF_IMMUTABLE)) }
            }
            let r = try shred(shredFS(hooks), t)
            #expect(r.filesOverwritten == 0 && r.damaged.isEmpty && text(box, "item/b") == "next", "\(stage)")
            guard let kept = r.kept.first, case .failed(let why) = kept.reason else { Issue.record("\(stage): \(r.kept)"); continue }
            #expect(why.contains("locked"), "\(stage): \(why)")
            #expect((try? String(contentsOfFile: kept.path, encoding: .utf8)) == "secret", "\(stage): \(kept.path)")
        }
    }

    @Test func aFileLinkedOrLockedAfterTheOverwriteIsNotDeleted() throws {   // §3 check 4, the last one before the unlink
        // Its content is already overwritten (that can't be undone), but it isn't deleted: it stays in staging, is
        // reported as damaged at that path, and the item stops.
        for change in ["hard link", "locked"] {
            let box = try Sandbox()
            try box.file("item/a", "secret"); try box.file("item/b", "next"); try box.dir("elsewhere")
            let t = try snapshot(shredFS(), box.path("item"))
            let alias = box.path("elsewhere/alias")
            var hooks = ShredHooks()
            hooks.afterOverwrite = { staged in
                if change == "hard link" { link(staged, alias) } else { chflags(staged, UInt32(UF_IMMUTABLE)) }
            }
            let r = try shred(shredFS(hooks), t)
            #expect(r.filesOverwritten == 0 && text(box, "item/b") == "next", "\(change)")
            #expect(r.damaged.count == 1 && r.damaged.first?.contains(LocalFileSystem.shredStagingPrefix) == true, "\(change): \(r.damaged)")
            guard let kept = r.kept.first, case .failed(let why) = kept.reason else { Issue.record("\(change): \(r.kept)"); continue }
            #expect(why.contains(change == "hard link" ? "hard link" : "locked"), "\(change): \(why)")
            var st = stat()
            #expect(kept.path == r.damaged.first && lstat(kept.path, &st) == 0, "\(change): \(kept.path)")
        }
    }

    @Test func anOccupiedStagingSlotIsNeverReplaced() throws {   // exclusive move into staging
        // Another process puts something at the staging name the first file would get ("1"). The move fails instead
        // of replacing it: the reviewed file stays where it was, unchanged; the unexpected item stays untouched and is
        // reported through the work folder left behind; nothing after it is touched.
        let box = try Sandbox()
        try box.file("item/a", "secret"); try box.file("item/b", "next")
        let t = try snapshot(shredFS(), box.path("item"))
        let root = box.root
        var hooks = ShredHooks()
        hooks.beforeMove = { _ in
            guard let stage = (try? FileManager.default.contentsOfDirectory(atPath: root))?
                    .first(where: { $0.hasPrefix(LocalFileSystem.shredStagingPrefix) }) else { return }
            try? Data("intruder".utf8).write(to: URL(fileURLWithPath: root + "/" + stage + "/1"))
        }
        let r = try shred(shredFS(hooks), t)
        #expect(r.filesOverwritten == 0 && r.damaged.isEmpty && r.estimatedFreedBytes == 0)
        #expect(text(box, "item/a") == "secret" && text(box, "item/b") == "next")
        guard let kept = r.kept.first, case .failed(let why) = kept.reason else { Issue.record("\(r.kept)"); return }
        #expect(kept.path == box.path("item/a") && why.contains("already taken"), "\(kept.path): \(why)")
        let left = r.kept.first { $0.reason == .stagingLeftBehind }
        #expect(left.flatMap { try? String(contentsOfFile: $0.path + "/1", encoding: .utf8) } == "intruder", "\(r.kept)")
    }

    @Test func aShortWriteInTheRealOverwriteIsReportedAsDamaged() throws {   // overwriteZeros accounting, end to end
        // Only `pwrite` is replaced (it writes half of what it is asked); the real overwrite helper runs. The bytes
        // it wrote count, so the file is reported as damaged (put back at its own name), and the item stops.
        let box = try Sandbox()
        try box.file("item/a", String(repeating: "s", count: 4096)); try box.file("item/b", "next")
        let t = try snapshot(shredFS(), box.path("item"))
        var hooks = ShredHooks()
        hooks.pwrite = { fd, buf, n, off in pwrite(fd, buf, n / 2, off) }
        let r = try shred(shredFS(hooks), t)
        #expect(r.filesOverwritten == 0 && text(box, "item/b") == "next")
        #expect(r.damaged == [box.path("item/a")], "\(r.damaged)")
        guard let kept = r.kept.first, case .failed(let why) = kept.reason else { Issue.record("\(r.kept)"); return }
        #expect(kept.path == box.path("item/a") && why.contains("damaged"), "\(why)")
        let data = try Data(contentsOf: URL(fileURLWithPath: box.path("item/a")))
        #expect(data.count == 4096 && data.prefix(2048).allSatisfy { $0 == 0 } && data.suffix(2048).allSatisfy { $0 == UInt8(ascii: "s") })
        #expect(noStaging(box))
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

@Suite("Shred: the overwrite helper")
struct ShredOverwriteHelperTests {
    @Test func aShortWriteIsCountedAndStopsTheOverwrite() throws {
        // The real helper on a real file; on its second call pwrite returns a positive short count. Every byte it
        // reported is counted (and is zero on disk), and it stops with an error instead of going on.
        let box = try Sandbox()
        let size = 3 << 20, half = 1 << 19   // three 1 MB chunks; the second write stops half-way
        try box.file("f", String(repeating: "x", count: size))
        let fd = open(box.path("f"), O_RDWR | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let calls = Box(0)
        let r = LocalFileSystem.overwriteZeros(fd, from: 0, to: off_t(size), write: { fd, buf, n, off in
            calls.value += 1
            return pwrite(fd, buf, calls.value == 2 ? half : n, off)
        })
        #expect(r.error != nil && calls.value == 2)
        #expect(r.written == off_t((1 << 20) + half), "\(r.written)")
        let data = try Data(contentsOf: URL(fileURLWithPath: box.path("f")))
        #expect(data.count == size && data.prefix { $0 == 0 }.count == Int(r.written) && data.last == UInt8(ascii: "x"))
    }

    @Test func aFailedWriteCountsOnlyWhatWasWritten() throws {
        // pwrite fails outright on the second call: only the first chunk counts, and the error is reported.
        let box = try Sandbox()
        try box.file("f", String(repeating: "x", count: 2 << 20))
        let fd = open(box.path("f"), O_RDWR | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let calls = Box(0)
        let r = LocalFileSystem.overwriteZeros(fd, from: 0, to: off_t(2 << 20), write: { fd, buf, n, off in
            calls.value += 1
            if calls.value == 2 { errno = EIO; return -1 }
            return pwrite(fd, buf, n, off)
        })
        #expect(r.written == off_t(1 << 20) && r.error?.contains("writing failed") == true, "\(r)")
    }
}
