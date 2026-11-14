import Foundation
import MacCleanerCore

// Overwrite-then-delete (the Shredder), moved here from the app's former Shredder engine step for step (M01-04c). Two parts:
//
// * `shredSnapshot(at:)` lists an item once, without following links, and either refuses it (nothing changed) or
//   returns the exact `.tree` target to review, with its sizes from the same walk.
// * `overwriteAndRemove` acts on exactly such a target, approved: it never lists a folder to decide what to delete.
//
// How it stays safe while other apps keep using the disk:
// 1. Work through open folders, not paths. The parent folder is opened without following any link
//    (O_NOFOLLOW_ANY) and checked against the reviewed parent; everything else is relative to open folder
//    descriptors (openat, fstatat, renameat, unlinkat), never following links. Swapping a folder for a link after
//    that can't redirect the work.
// 2. Move, then check, then act. Each file or link is moved (renameatx_np with RENAME_EXCL, so an occupied staging
//    name is never replaced) into a private staging folder (random name, mode 700) next to the item and checked there. A file is checked against its reviewed identity, its link count
//    (exactly 1) and its flags (no lock) before the move, after the move, on the open descriptor immediately before
//    the overwrite, and once more before the unlink. Anything else is moved back (RENAME_EXCL, never overwriting)
//    and kept.
// 3. Overwrite, flush, delete, then re-check through the open file: data another app appended through a handle it
//    already had is overwritten too before the file is closed.
// 4. Stop at the first failure. What was already shredded is gone; the failed entry and everything not yet
//    processed stay where they are. Folders are removed only when empty (rmdir), so an entry that appeared after
//    review keeps its folder. The result says exactly what went and what stayed.
//
// Limits that remain (also in SAFETY_MODEL.md §3a): between a check and the next step there is no atomic "act only
// if unchanged" call on macOS. A process of the same user can write to a file it already had open after the last
// re-check (the tail overwrite narrows this, and an unfinished tail is reported as a warning), add a hard link in the
// instant between the open-descriptor check and the overwrite (the overwrite would then reach that link too), or find
// and change the staging folder (mode 700, but it is the same user). And on APFS/SSDs an overwrite can't guarantee
// the old blocks are unrecoverable (copy-on-write, snapshots, wear levelling).

/// Why an item can't be shredded; nothing was changed.
public struct ShredRefusal: Error, Sendable, Hashable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// One reviewed item, as one walk saw it: the `.tree` target to approve, and its sizes from the same `stat` calls.
public struct ShredSnapshot: Sendable, Hashable {
    /// `CleanupTarget.tree(parent:root:entries:)`.
    public let target: CleanupTarget
    /// The files' logical sizes added up.
    public let logicalBytes: Int64
    /// The space the item takes on disk (allocated blocks of the item, its files, links and folders).
    public let allocatedBytes: Int64
    /// Files to overwrite.
    public let fileCount: Int
}

/// Test-only points inside `overwriteAndRemove`, to make an overwrite fail or let "another app" act at the worst
/// moment. Package-internal: the app can't set them.
struct ShredHooks: Sendable {
    /// Replaces the real overwrite: given the open file and the range, returns bytes written and an error.
    var overwrite: (@Sendable (Int32, off_t, off_t) -> (written: off_t, error: String?))?
    /// Replaces only the `pwrite` call inside the real overwrite (`overwriteZeros`), to make it see a short write.
    var pwrite: LocalFileSystem.PositionalWrite?
    /// Before the parent folder is opened.
    var beforeStart: (@Sendable () -> Void)?
    /// After a file or link passed its check in place, right before it is moved to staging. Gets its path.
    var beforeMove: (@Sendable (String) -> Void)?
    /// Right after a file or link was moved to staging. Gets its original path and its staging path.
    var afterMove: (@Sendable (String, String) -> Void)?
    /// After a file was opened in staging, before the check on the open descriptor. Gets its staging path.
    var afterOpen: (@Sendable (String) -> Void)?
    /// After a file was overwritten and flushed, right before it is unlinked. Gets its staging path.
    var afterOverwrite: (@Sendable (String) -> Void)?
    /// After a folder's entries are done, right before the folder itself is removed. Gets its path.
    var beforeFolderRemove: (@Sendable (String) -> Void)?
    /// Right before the staging folder is removed, with its path.
    var beforeStagingCleanup: (@Sendable (String) -> Void)?
}

extension LocalFileSystem {
    /// Largest file the Shredder overwrites; an item holding a bigger one is refused when it is listed.
    public static let maxShredFileSize: off_t = 4_000_000_000
    /// The private staging folder's name prefix. An item holding one (an unfinished shred) is refused.
    public static let shredStagingPrefix = ".maccleaner-shred-"
    static let lockedFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    // MARK: - Listing

    /// Lists the item at `path` once, without following links, and refuses it (nothing changed) if any part can't be
    /// shredded safely: its folder can't be opened without following a link or can't be changed; it is a link; a
    /// folder inside is unreadable or unchangeable (its files would go unseen); a file has another hard link
    /// (overwriting it would erase the other copy), is locked or unwritable, or is over 4 GB; an entry is a socket,
    /// device or pipe, has a name that isn't valid text, is an unfinished shred's staging folder, or is on another
    /// volume. `path` must be the item's real path (no link in it).
    public func shredSnapshot(at path: String) -> Result<ShredSnapshot, ShredRefusal> {
        let url = URL(fileURLWithPath: path)
        let parentPath = url.deletingLastPathComponent().path, rootName = url.lastPathComponent
        let pfd = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard pfd >= 0 else {
            return .failure(ShredRefusal(errno == ELOOP ? "Its folder is reached through a link; add it from its real location"
                                                        : "Its folder can't be read"))
        }
        defer { Darwin.close(pfd) }
        var pst = stat()
        guard fstat(pfd, &pst) == 0, faccessat(pfd, ".", W_OK | X_OK, 0) == 0 else { return .failure(ShredRefusal("Its folder can't be changed")) }
        let parent = FileIdentity(path: parentPath, stat: pst)
        let now = Self.nowNanos()
        var entries: [FileIdentity] = []
        var logical: Int64 = 0, allocated: Int64 = 0, files = 0
        var rootIdentity: FileIdentity?
        var rootDevice: dev_t = 0

        func visit(_ dirfd: Int32, _ name: String, _ itemPath: String, isRoot: Bool) -> ShredRefusal? {
            let shown = (itemPath as NSString).lastPathComponent
            var st = stat()
            guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return ShredRefusal("\(shown) can't be read") }
            if isRoot { rootDevice = st.st_dev } else if st.st_dev != rootDevice { return ShredRefusal("\(shown) is on another volume") }
            if st.st_flags & Self.lockedFlags != 0 { return ShredRefusal("\(shown) is locked") }
            let id = FileIdentity(path: itemPath, stat: st, capturedAtNanos: now)
            func record() { if isRoot { rootIdentity = id } else { entries.append(id) }; allocated += Int64(st.st_blocks) * 512 }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if st.st_nlink != 1 { return ShredRefusal("\(shown) is a hard link to a file elsewhere, which shredding would erase too") }
                if st.st_size > Self.maxShredFileSize { return ShredRefusal("\(shown) is larger than 4 GB") }
                let w = openat(dirfd, name, O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard w >= 0 else { return ShredRefusal("\(shown) can't be written (locked or not yours)") }
                Darwin.close(w)
                record(); logical += Int64(st.st_size); files += 1
                return nil
            case S_IFLNK:
                if isRoot { return ShredRefusal("This is a link. Shred the original item instead") }
                record()
                return nil
            case S_IFDIR:
                let fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { return ShredRefusal("The folder \(shown) can't be read") }
                defer { Darwin.close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, Self.sameObject(opened, st) else { return ShredRefusal("\(shown) changed while it was being listed") }
                guard faccessat(fd, ".", R_OK | W_OK | X_OK, 0) == 0 else { return ShredRefusal("The folder \(shown) can't be changed") }
                let names: [String]
                switch Self.strictNames(in: fd) {
                case .names(let n): names = n
                case .invalidName: return ShredRefusal("\(shown) holds an item whose name isn't valid text")
                case .failed: return ShredRefusal("The folder \(shown) can't be read completely")
                }
                record()
                for n in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    if n.hasPrefix(Self.shredStagingPrefix) { return ShredRefusal("\(shown) holds an unfinished shred (\(n)); remove it first") }
                    if let refusal = visit(fd, n, itemPath + "/" + n, isRoot: false) { return refusal }
                }
                return nil
            default:
                return ShredRefusal("\(shown) is not a regular file or folder")
            }
        }

        if let refusal = visit(pfd, rootName, parentPath == "/" ? "/" + rootName : parentPath + "/" + rootName, isRoot: true) {
            return .failure(refusal)
        }
        guard let root = rootIdentity else { return .failure(ShredRefusal("It can't be read")) }
        entries.sort(by: CleanupPlan.treeOrder)
        return .success(ShredSnapshot(target: .tree(parent: parent, root: root, entries: entries),
                                      logicalBytes: logical, allocatedBytes: allocated, fileCount: files))
    }

    // MARK: - Overwrite and remove

    public func overwriteAndRemove(parent: FileIdentity, root: FileIdentity, entries: [FileIdentity],
                                   protection: RemovalProtection) throws -> OverwriteRemovalResult {
        let hooks = shredHooks
        hooks?.beforeStart?()
        // The parent, reached without following any link, must be the reviewed folder; the item in it the reviewed item.
        let pfd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard pfd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw FileSystemRefusal.missing
            case ELOOP: throw FileSystemRefusal.changed(.replaced)
            default: throw PlatformError("open", parent.path)
            }
        }
        defer { Darwin.close(pfd) }
        var pst = stat()
        guard fstat(pfd, &pst) == 0 else { throw PlatformError("stat", parent.path) }
        if let m = parent.mismatch(against: FileIdentity(path: parent.path, stat: pst)) { throw FileSystemRefusal.changed(m) }
        let rootName = (root.path as NSString).lastPathComponent
        var rst = stat()
        guard fstatat(pfd, rootName, &rst, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw FileSystemRefusal.missing }
            throw PlatformError("stat", root.path)
        }
        if let m = root.mismatch(against: FileIdentity(path: root.path, stat: rst)) { throw FileSystemRefusal.changed(m) }

        // Private staging folder next to the item (same volume, so moves are atomic renames).
        let stageName = Self.shredStagingPrefix + UUID().uuidString.lowercased()
        let stagePath = parent.path + "/" + stageName
        guard mkdirat(pfd, stageName, 0o700) == 0 else {
            throw PlatformError(message: "Couldn't prepare the shred (\(String(cString: strerror(errno)))). Nothing was changed.")
        }
        let sfd = openat(pfd, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var sst = stat()
        guard sfd >= 0, fstat(sfd, &sst) == 0, sst.st_uid == getuid(), sst.st_mode & 0o777 == 0o700 else {
            if sfd >= 0 { Darwin.close(sfd) }
            unlinkat(pfd, stageName, AT_REMOVEDIR)
            throw PlatformError(message: "Couldn't prepare the shred. Nothing was changed.")
        }

        var r = OverwriteRemovalResult()
        var stopped = false
        var serial = 0
        // Each folder's reviewed entries, in review order. Only these are ever touched.
        var children: [String: [FileIdentity]] = [:]
        for e in entries { children[(e.path as NSString).deletingLastPathComponent, default: []].append(e) }

        func keep(_ path: String, _ reason: KeptEntry.Reason) {
            r.kept.append(KeptEntry(path: path, reason: reason))
            stopped = true
        }
        /// Moves a staged entry back to its name without replacing anything that took its place. nil when it is back;
        /// otherwise where it is now.
        func putBack(_ tmp: String, _ dirfd: Int32, _ name: String) -> String? {
            renameatx_np(sfd, tmp, dirfd, name, UInt32(RENAME_EXCL)) == 0 ? nil : stagePath + "/" + tmp
        }
        /// nil when `st` is still the reviewed `planned` entry (identity; for a file also exactly one link and no
        /// lock flags); otherwise why not.
        func refusal(_ st: stat, _ planned: FileIdentity) -> KeptEntry.Reason? {
            if planned.mismatch(against: FileIdentity(path: planned.path, stat: st)) != nil { return .changedAfterReview }
            guard planned.kind == .file else { return nil }
            if st.st_nlink != 1 { return .failed("it gained another hard link since you reviewed it, so overwriting it would erase that copy too") }
            if st.st_flags & Self.lockedFlags != 0 { return .failed("it was locked since you reviewed it") }
            return nil
        }

        func process(_ e: FileIdentity, in dirfd: Int32) {
            guard !stopped else { return }
            let name = (e.path as NSString).lastPathComponent
            if let why = protection(e.path) { return keep(e.path, .protected(why)) }
            switch e.kind {
            case .file, .symlink:
                var now = stat()
                guard fstatat(dirfd, name, &now, AT_SYMLINK_NOFOLLOW) == 0 else {
                    return keep(e.path, errno == ENOENT ? .changedAfterReview : .failed(String(cString: strerror(errno))))
                }
                if let why = refusal(now, e) { return keep(e.path, why) }
                hooks?.beforeMove?(e.path)
                serial += 1
                let tmp = "\(serial)"
                // Exclusive: an occupied staging slot (something put there by another process) is never replaced.
                guard renameatx_np(dirfd, name, sfd, tmp, UInt32(RENAME_EXCL)) == 0 else {
                    let why = errno == EEXIST ? "its place in the work folder was already taken by something else, so it wasn't moved"
                                              : "it couldn't be moved (\(String(cString: strerror(errno))))"
                    return keep(e.path, .failed(why))
                }
                hooks?.afterMove?(e.path, stagePath + "/" + tmp)
                var moved = stat()
                let movedWhy: KeptEntry.Reason? = fstatat(sfd, tmp, &moved, AT_SYMLINK_NOFOLLOW) == 0 ? refusal(moved, e) : .changedAfterReview
                if let why = movedWhy {
                    guard let left = putBack(tmp, dirfd, name) else { return keep(e.path, why) }
                    // Still in staging (its name was taken, or it was locked, which also blocks the rename): say why
                    // it was stopped and where it is.
                    let cause: String
                    if case .failed(let w) = why { cause = w } else { cause = "it changed while shredding" }
                    return keep(left, .failed(cause + ", and it couldn't be moved back, so it is in the work folder"))
                }
                if e.kind == .symlink {
                    let blocks = Int64(moved.st_blocks) * 512
                    guard unlinkat(sfd, tmp, 0) == 0 else {
                        let left = putBack(tmp, dirfd, name)
                        return keep(left ?? e.path, .failed("the link couldn't be removed"))
                    }
                    r.estimatedFreedBytes += blocks
                    return
                }
                let fd = openat(sfd, tmp, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 { hooks?.afterOpen?(stagePath + "/" + tmp) }
                // Immediately before the overwrite, through the open descriptor: still the reviewed file, one link,
                // not locked.
                var opened = stat()
                let openWhy: KeptEntry.Reason? = fd >= 0 && fstat(fd, &opened) == 0 ? refusal(opened, e) : .failed("it couldn't be opened")
                if let why = openWhy {
                    if fd >= 0 { Darwin.close(fd) }
                    let left = putBack(tmp, dirfd, name)
                    return keep(left ?? e.path, why)
                }
                defer { Darwin.close(fd) }
                let size = opened.st_size
                let writer = hooks?.pwrite ?? Self.systemPwrite
                let done = hooks?.overwrite?(fd, 0, size) ?? Self.overwriteZeros(fd, from: 0, to: size, write: writer)
                if let why = done.error {
                    let left = putBack(tmp, dirfd, name)
                    if done.written > 0 { r.damaged.append(left ?? e.path) }
                    let note = done.written > 0 ? " (partly overwritten, so its content is damaged)" : ""
                    return keep(left ?? e.path, .failed(why + note))
                }
                hooks?.afterOverwrite?(stagePath + "/" + tmp)
                // Last check before deleting it (design §3, check 4): the private name is still this file, with exactly
                // one link and no lock flags. Its content is already overwritten; a failure here only stops the delete.
                var last = stat(), current = stat()
                let lastWhy: String?
                if fstatat(sfd, tmp, &last, AT_SYMLINK_NOFOLLOW) != 0 || !Self.sameObject(last, opened) {
                    lastWhy = "its staging name changed"
                } else if last.st_nlink != 1 {
                    lastWhy = "it gained another hard link"
                } else if last.st_flags & Self.lockedFlags != 0 {
                    lastWhy = "it was locked"
                } else if fstat(fd, &current) != 0 {
                    lastWhy = "it couldn't be checked again"
                } else {
                    lastWhy = nil
                }
                if let lastWhy {
                    r.damaged.append(stagePath + "/" + tmp)
                    return keep(stagePath + "/" + tmp, .failed("it was overwritten, but \(lastWhy), so it wasn't deleted and nothing more was"))
                }
                let blocks = Int64(current.st_blocks) * 512
                guard unlinkat(sfd, tmp, 0) == 0 else {
                    let left = putBack(tmp, dirfd, name)
                    r.damaged.append(left ?? e.path)
                    return keep(left ?? e.path, .failed("it was overwritten but couldn't be deleted"))
                }
                r.filesOverwritten += 1
                r.estimatedFreedBytes += blocks
                // The file is still open. If another app that had it open appended meanwhile, overwrite that tail too.
                var covered = size
                for _ in 0..<5 {
                    var grown = stat()
                    guard fstat(fd, &grown) == 0, grown.st_size > covered else { break }
                    let extra = hooks?.overwrite?(fd, covered, grown.st_size) ?? Self.overwriteZeros(fd, from: covered, to: grown.st_size, write: writer)
                    if let why = extra.error {
                        r.warnings.append("\(name): another app added data while it was shredded, and that part couldn't be overwritten (\(why))")
                        break
                    }
                    covered = grown.st_size
                }
                var final = stat()
                if fstat(fd, &final) == 0, final.st_size > covered {
                    r.warnings.append("\(name): another app kept writing to it while it was shredded; its newest data was not overwritten")
                }
            case .directory:
                let fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var now = stat()
                guard fd >= 0, fstat(fd, &now) == 0, e.mismatch(against: FileIdentity(path: e.path, stat: now)) == nil else {
                    if fd >= 0 { Darwin.close(fd) }
                    return keep(e.path, .changedAfterReview)
                }
                for c in children[e.path] ?? [] { process(c, in: fd) }
                Darwin.close(fd)
                guard !stopped else { return }
                hooks?.beforeFolderRemove?(e.path)
                if let why = protection(e.path) { return keep(e.path, .protected(why)) }
                var here = stat()
                guard fstatat(dirfd, name, &here, AT_SYMLINK_NOFOLLOW) == 0,
                      e.mismatch(against: FileIdentity(path: e.path, stat: here)) == nil else {
                    return keep(e.path, .changedAfterReview)
                }
                // Only an empty folder can be removed (rmdir): an entry that wasn't reviewed keeps it.
                guard unlinkat(dirfd, name, AT_REMOVEDIR) == 0 else {
                    return keep(e.path, errno == ENOTEMPTY ? .notEmpty : .failed(String(cString: strerror(errno))))
                }
                r.estimatedFreedBytes += Int64(here.st_blocks) * 512
            case .other:
                keep(e.path, .failed("it isn't a file, folder or link"))
            }
        }

        process(root, in: pfd)
        Darwin.close(sfd)
        hooks?.beforeStagingCleanup?(stagePath)
        if unlinkat(pfd, stageName, AT_REMOVEDIR) != 0 {
            r.kept.append(KeptEntry(path: stagePath, reason: .stagingLeftBehind))
        }
        return r
    }

    // MARK: - Helpers

    static func sameObject(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT)
    }

    /// `pwrite(2)`'s shape, so a test can make the real write helper see a short or failed write.
    typealias PositionalWrite = @Sendable (Int32, UnsafeRawPointer?, Int, off_t) -> Int
    static let systemPwrite: PositionalWrite = { pwrite($0, $1, $2, $3) }

    /// Writes zeros over [from, to) of an open file and flushes it to the disk. Returns bytes written and an error.
    /// `written` counts every byte a write reported, including those of a short write, so a file that was partly
    /// overwritten is never reported as untouched. A short write stops the overwrite (fail closed).
    static func overwriteZeros(_ fd: Int32, from: off_t, to: off_t,
                               write: PositionalWrite = systemPwrite) -> (written: off_t, error: String?) {
        let chunk = [UInt8](repeating: 0, count: 1 << 20)
        var offset = from
        while offset < to {
            let n = Int(min(off_t(chunk.count), to - offset))
            let w = chunk.withUnsafeBytes { write(fd, $0.baseAddress, n, offset) }
            if w > 0 { offset += off_t(w) }
            guard w == n else {
                return (offset - from, w < 0 ? "writing failed (\(String(cString: strerror(errno))))" : "writing stopped part-way")
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { return (offset - from, "couldn't flush to disk") }
        return (offset - from, nil)
    }

    enum Listing { case names([String]), invalidName, failed }

    /// Names in an open folder (not "." or ".."), or why there are none: the listing failed part-way, or a name isn't
    /// valid UTF-8 (it couldn't be named again exactly).
    static func strictNames(in dirfd: Int32) -> Listing {
        let copy = dup(dirfd)
        guard copy >= 0, let dir = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; return .failed }
        defer { closedir(dir) }
        rewinddir(dir)
        var out: [String] = []
        var valid = true
        while true {
            errno = 0
            guard let ent = readdir(dir) else { return errno != 0 ? .failed : valid ? .names(out) : .invalidName }
            let bytes = withUnsafeBytes(of: ent.pointee.d_name) { Array($0.prefix(Int(ent.pointee.d_namlen))) }
            guard let name = String(bytes: bytes, encoding: .utf8) else { valid = false; continue }
            if name != "." && name != ".." { out.append(name) }
        }
    }
}
