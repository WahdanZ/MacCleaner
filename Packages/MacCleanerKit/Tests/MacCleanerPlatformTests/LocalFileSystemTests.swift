import Darwin
import Foundation
import Testing
import MacCleanerCore
@testable import MacCleanerPlatform

// Real files in a throwaway folder (symlinks resolved, so paths have no symlinked parents). The Trash is a folder
// inside it: these tests never touch the person's Trash.

final class Sandbox {
    let root: String
    let trash: String
    let fm = FileManager.default

    init() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("maccleaner-fs-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        root = realPath(base.path)
        trash = root + "/.Trash"
        try fm.createDirectory(atPath: trash, withIntermediateDirectories: false)
    }

    deinit {
        // Unlock anything a test locked, then remove everything.
        if let e = fm.enumerator(atPath: root) { for case let rel as String in e { chflags(root + "/" + rel, 0) } }
        try? fm.removeItem(atPath: root)
    }

    func path(_ rel: String) -> String { root + "/" + rel }
    func dir(_ rel: String) throws { try fm.createDirectory(atPath: path(rel), withIntermediateDirectories: true) }
    func file(_ rel: String, _ text: String = "data") throws {
        try fm.createDirectory(atPath: (path(rel) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path(rel)))
    }
    func link(_ rel: String, to target: String) throws { try fm.createSymbolicLink(atPath: path(rel), withDestinationPath: target) }
    func exists(_ rel: String) -> Bool { var s = stat(); return lstat(path(rel), &s) == 0 }
    func names(_ rel: String = "") -> [String] { ((try? fm.contentsOfDirectory(atPath: rel.isEmpty ? root : path(rel))) ?? []).sorted() }

    var fakeTrash: LocalFileSystem.TrashMover {
        let trash = trash
        return { url in
            let dest = URL(fileURLWithPath: trash).appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    func fs(beforeMove: LocalFileSystem.BeforeMove? = nil) -> LocalFileSystem {
        LocalFileSystem(trashMover: fakeTrash, beforeMove: beforeMove)
    }

    /// The identity now, captured a little after the last change so "changed after review" is unambiguous.
    func capture(_ rel: String) throws -> FileIdentity {
        usleep(2000)
        return try #require(try fs().identity(at: path(rel)))
    }

    /// Lets the clock move past a capture before the next change.
    func tick() { usleep(2000) }
}

@Suite("LocalFileSystem: identity and listing")
struct LocalIdentityTests {
    @Test func capturesKindsWithoutFollowingLinks() throws {
        let box = try Sandbox()
        try box.file("f"); try box.dir("d"); try box.link("l", to: box.path("d"))
        let fs = box.fs()
        #expect(try fs.identity(at: box.path("f"))?.kind == .file)
        #expect(try fs.identity(at: box.path("d"))?.kind == .directory)
        #expect(try fs.identity(at: box.path("l"))?.kind == .symlink)
        #expect(try fs.identity(at: box.path("missing")) == nil)
        let a = try #require(try fs.identity(at: box.path("f"))), b = try #require(try fs.identity(at: box.path("f")))
        #expect(a.mismatch(against: b) == nil)
    }

    @Test func aSymlinkedParentIsRefused() throws {
        let box = try Sandbox()
        try box.file("real/f"); try box.link("via", to: box.path("real"))
        #expect(throws: FileSystemRefusal.changed(.replaced)) { try box.fs().identity(at: box.path("via/f")) }
    }

    @Test func listsDirectEntriesOnly() throws {
        let box = try Sandbox()
        try box.file("d/a"); try box.file("d/sub/deep"); try box.link("d/l", to: "/etc")
        let folder = try box.capture("d")
        let names = try box.fs().entries(of: folder).map { ($0.path as NSString).lastPathComponent }.sorted()
        #expect(names == ["a", "l", "sub"])
    }

    @Test func listingASwappedFolderIsRefused() throws {
        let box = try Sandbox()
        try box.file("d/a"); try box.file("other/secret")
        let folder = try box.capture("d")
        try box.fm.moveItem(atPath: box.path("d"), toPath: box.path("d-old"))
        try box.link("d", to: box.path("other"))
        #expect(throws: FileSystemRefusal.self) { try box.fs().entries(of: folder) }
    }
}

@Suite("LocalFileSystem: permanent removal")
struct LocalRemovalTests {
    @Test func removesAFile() throws {
        let box = try Sandbox()
        try box.file("f", String(repeating: "x", count: 10_000))
        let r = try box.fs().remove(try box.capture("f"), protection: unprotected)
        #expect(!box.exists("f") && r.kept.isEmpty && r.freedBytes > 0)
        #expect(box.names() == [".Trash"])   // no staging folder left behind
    }

    @Test func removesAFolderTreeWithoutFollowingLinks() throws {
        let box = try Sandbox()
        try box.file("outside/keep-me")
        try box.file("d/a"); try box.file("d/sub/b"); try box.link("d/sub/to-outside", to: box.path("outside"))
        try box.link("d/file-link", to: box.path("outside/keep-me"))
        let r = try box.fs().remove(try box.capture("d"), protection: unprotected)
        #expect(!box.exists("d") && r.kept.isEmpty)
        #expect(box.exists("outside/keep-me"))
        #expect(box.names() == [".Trash", "outside"])
    }

    @Test func keepsWhatWasAddedOrChangedAfterReview() throws {
        let box = try Sandbox()
        try box.file("d/old"); try box.file("d/sub/old-deep"); try box.file("d/stays/old")
        let item = try box.capture("d")
        box.tick()
        try box.file("d/new")                  // added after review, top level
        try box.file("d/sub/new-deep")         // added after review, deeper (also changes "sub")
        let r = try box.fs().remove(item, protection: unprotected)
        #expect(!box.exists("d/old") && !box.exists("d/stays"))
        #expect(box.exists("d/new") && box.exists("d/sub/new-deep") && box.exists("d/sub/old-deep"))
        #expect(Set(r.kept) == [KeptEntry(path: box.path("d/new"), reason: .changedAfterReview),
                                KeptEntry(path: box.path("d/sub"), reason: .changedAfterReview)])
        #expect(box.names() == [".Trash", "d"])   // put back under its own name, staging gone
    }

    @Test func unknownSnapshotTimeKeepsEverythingInside() throws {
        let box = try Sandbox()
        try box.file("d/a")
        let now = try box.capture("d")
        let unknown = FileIdentity(path: now.path, device: now.device, inode: now.inode, kind: .directory, size: now.size,
                                   modificationNanos: now.modificationNanos)   // capturedAtNanos 0
        let r = try box.fs().remove(unknown, protection: unprotected)
        #expect(box.exists("d/a") && r.kept.contains(KeptEntry(path: box.path("d/a"), reason: .changedAfterReview)))
    }

    @Test func refusesAFolderSwappedForASymlinkBeforeTheMove() throws {
        let box = try Sandbox()
        try box.file("d/a"); try box.file("victim/precious")
        let item = try box.capture("d")
        try box.fm.moveItem(atPath: box.path("d"), toPath: box.path("d-moved"))
        try box.link("d", to: box.path("victim"))
        #expect(throws: FileSystemRefusal.changed(.kindChanged(from: .directory, to: .symlink))) { try box.fs().remove(item, protection: unprotected) }
        #expect(box.exists("victim/precious") && box.exists("d"))
    }

    @Test func refusesAnItemSwappedBetweenCheckAndMove() throws {
        let box = try Sandbox()
        try box.file("d/a")
        let item = try box.capture("d")
        let path = box.path("d")
        let fs = box.fs(beforeMove: { _ in
            // Another process wins the race: same name, different folder, holding something precious.
            try? FileManager.default.moveItem(atPath: path, toPath: path + "-orig")
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            try? Data("precious".utf8).write(to: URL(fileURLWithPath: path + "/precious"))
        })
        #expect(throws: FileSystemRefusal.changed(.replaced)) { try fs.remove(item, protection: unprotected) }
        #expect(box.exists("d/precious"))          // moved back, untouched
        #expect(box.names() == [".Trash", "d", "d-orig"])
    }

    @Test func refusesAFileReplacedAtTheSamePath() throws {
        let box = try Sandbox()
        try box.file("f", "old")
        let item = try box.capture("f")
        try box.fm.removeItem(atPath: box.path("f")); try box.file("f", "new")
        #expect(throws: FileSystemRefusal.self) { try box.fs().remove(item, protection: unprotected) }
        #expect(box.exists("f"))
    }

    @Test func aSymlinkIsRemovedAsTheLinkItself() throws {
        let box = try Sandbox()
        try box.file("target/precious"); try box.link("l", to: box.path("target"))
        _ = try box.fs().remove(try box.capture("l"), protection: unprotected)
        #expect(!box.exists("l") && box.exists("target/precious"))
    }

    @Test func aLockedEntryIsKeptAndReported() throws {
        let box = try Sandbox()
        try box.file("d/locked"); try box.file("d/free")
        #expect(chflags(box.path("d/locked"), UInt32(UF_IMMUTABLE)) == 0)
        let r = try box.fs().remove(try box.capture("d"), protection: unprotected)
        #expect(!box.exists("d/free") && box.exists("d/locked"))
        #expect(r.kept.count == 1 && r.kept[0].path == box.path("d/locked"))
        if case .failed = r.kept[0].reason {} else { Issue.record("expected a failure reason, got \(r.kept[0].reason)") }
        #expect(box.names() == [".Trash", "d"])
    }

    @Test func aHardLinkedFileFreesNothing() throws {
        let box = try Sandbox()
        try box.file("f", String(repeating: "x", count: 50_000))
        #expect(link(box.path("f"), box.path("f2")) == 0)
        let r = try box.fs().remove(try box.capture("f"), protection: unprotected)
        #expect(r.freedBytes == 0 && box.exists("f2"))
    }

    @Test func aMissingItemIsReportedAsMissing() throws {
        let box = try Sandbox()
        try box.file("f")
        let item = try box.capture("f")
        try box.fm.removeItem(atPath: box.path("f"))
        #expect(throws: FileSystemRefusal.missing) { try box.fs().remove(item, protection: unprotected) }
    }
}

@Suite("LocalFileSystem: Trash")
struct LocalTrashTests {
    @Test func movesToTheTrashAndMeasures() throws {
        let box = try Sandbox()
        try box.file("d/a", String(repeating: "x", count: 20_000))
        let r = try box.fs().moveToTrash(try box.capture("d"))
        #expect(!box.exists("d") && r.bytes > 0)
        #expect(FileManager.default.fileExists(atPath: r.recoveryPath + "/a"))
    }

    @Test func aSwapBeforeTheMoveIsPutBack() throws {
        let box = try Sandbox()
        try box.file("f", "reviewed")
        let item = try box.capture("f")
        let path = box.path("f")
        let fs = box.fs(beforeMove: { _ in
            try? FileManager.default.removeItem(atPath: path)
            try? Data("someone else's".utf8).write(to: URL(fileURLWithPath: path))
        })
        #expect(throws: FileSystemRefusal.self) { try fs.moveToTrash(item) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "someone else's")   // back where it was
        #expect(box.names(".Trash").isEmpty)
    }
}

/// The path with every symlink resolved (realpath). URL.resolvingSymlinksInPath turns /private/var back into
/// /var, which is itself a symlink.
func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

let unprotected: RemovalProtection = { _ in nil }

/// Protection rules that can change while a removal runs, like Settings › Protection does.
final class LiveRules: @unchecked Sendable {   // `paths` and `prefixes` behind `lock`
    private let lock = NSLock()
    private var paths: Set<String> = []
    private var prefixes: [String] = []
    private(set) var asked = 0

    func protect(_ p: String) { lock.lock(); paths.insert(p); lock.unlock() }
    func protectEverything(under p: String) { lock.lock(); prefixes.append(p); lock.unlock() }

    var check: RemovalProtection {
        { [self] path in
            lock.lock(); defer { lock.unlock() }
            asked += 1
            if paths.contains(path) || prefixes.contains(where: { PathRules.isInside(path, $0) }) { return "Protected in Settings" }
            return nil
        }
    }
}

@Suite("LocalFileSystem: protection during removal")
struct LocalProtectionTests {
    @Test func aDescendantProtectedDuringRemovalIsKeptWithItsFolders() throws {
        let box = try Sandbox()
        try box.file("d/a"); try box.file("d/sub/keep"); try box.file("d/sub/other")
        let item = try box.capture("d")
        let rules = LiveRules()
        let keep = box.path("d/sub/keep")
        let fs = box.fs(beforeMove: { _ in rules.protect(keep) })   // protected after the executor's check
        let r = try fs.remove(item, protection: rules.check)
        #expect(box.exists("d/sub/keep"))
        #expect(!box.exists("d/a") && !box.exists("d/sub/other"))
        #expect(Set(r.kept) == [KeptEntry(path: keep, reason: .protected("Protected in Settings")),
                                KeptEntry(path: box.path("d/sub"), reason: .notEmpty)])
        #expect(box.names() == [".Trash", "d"])
    }

    @Test func protectingTheWholeFolderMidWalkStopsEveryFurtherDeletion() throws {
        let box = try Sandbox()
        for n in ["a", "b", "c", "d", "e"] { try box.file("f/" + n) }
        let item = try box.capture("f")
        let rules = LiveRules()
        let root = box.path("f")
        // The person protects the folder while the first entry is being handled.
        let check: RemovalProtection = { path in
            let why = rules.check(path)
            if rules.asked == 1 { rules.protectEverything(under: root) }
            return why
        }
        let r = try box.fs().remove(item, protection: check)
        #expect(box.names("f").count >= 4)                      // at most the first entry went
        #expect(r.kept.contains(KeptEntry(path: root, reason: .protected("Protected in Settings"))))
        #expect(box.names() == [".Trash", "f"])
    }

    @Test func anItemProtectedBeforeTheDeleteIsPutBackUntouched() throws {
        let box = try Sandbox()
        try box.file("d/a")
        let item = try box.capture("d")
        let rules = LiveRules()
        let path = box.path("d")
        let fs = box.fs(beforeMove: { _ in rules.protect(path) })
        #expect(throws: FileSystemRefusal.protected("Protected in Settings")) { try fs.remove(item, protection: rules.check) }
        #expect(box.exists("d/a") && box.names() == [".Trash", "d"])
    }
}

@Suite("LocalFileSystem: staging leftovers")
struct LocalStagingTests {
    /// Drops a file into the removal's staging folder, so the folder can't be removed afterwards.
    static func intrude(_ parent: String) {
        let fm = FileManager.default
        guard let staging = (try? fm.contentsOfDirectory(atPath: parent))?.first(where: { $0.hasPrefix(LocalFileSystem.stagingPrefix) })
        else { return }
        try? Data("intruder".utf8).write(to: URL(fileURLWithPath: parent + "/" + staging + "/intruder"))
    }

    @Test func aStagingFolderLeftBehindAfterSuccessIsReported() throws {
        let box = try Sandbox()
        try box.file("f")
        let root = box.root
        let r = try box.fs(beforeMove: { _ in Self.intrude(root) }).remove(try box.capture("f"), protection: unprotected)
        #expect(!box.exists("f"))
        let staging = try #require(box.names().first { $0.hasPrefix(LocalFileSystem.stagingPrefix) })
        #expect(r.kept == [KeptEntry(path: box.path(staging), reason: .stagingLeftBehind)])
    }

    @Test func aStagingFolderLeftBehindAfterARefusalIsReported() throws {
        let box = try Sandbox()
        try box.file("f", "reviewed")
        let item = try box.capture("f")
        let root = box.root, path = box.path("f")
        let fs = box.fs(beforeMove: { _ in
            Self.intrude(root)
            try? FileManager.default.removeItem(atPath: path)
            try? Data("someone else's".utf8).write(to: URL(fileURLWithPath: path))
        })
        do {
            _ = try fs.remove(item, protection: unprotected)
            Issue.record("expected a refusal")
        } catch let e as PlatformError {
            let staging = try #require(box.names().first { $0.hasPrefix(LocalFileSystem.stagingPrefix) })
            #expect(e.description.contains("changed since it was reviewed") && e.description.contains(box.path(staging)))
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "someone else's")
    }
}
