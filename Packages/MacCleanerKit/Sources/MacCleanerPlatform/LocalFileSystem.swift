import Darwin
import Foundation
import MacCleanerCore

// The executor's file operations on this Mac.
//
// A path check followed by a path-based delete can be raced: between the check and the delete another process can
// put something else at the path. So nothing here deletes by path:
//
// * Paths are opened with O_NOFOLLOW_ANY / AT_SYMLINK_NOFOLLOW_ANY: a symlink anywhere in the path is refused.
// * Permanent removal first MOVES the item (renameatx_np, RENAME_EXCL, relative to the open parent folder) into a
//   private staging folder next to it (mode 0700, random name), then checks the moved item's identity there. If it
//   isn't the reviewed item it is moved back and nothing is deleted. Only then is it deleted, through descriptors:
//   folders are opened with O_NOFOLLOW and each entry is unlinked relative to its open folder (unlinkat).
// * Inside a folder, anything created or changed after the identity was captured (birth time or status-change time
//   later than `capturedAtNanos`) is kept, and so is any other volume mounted inside. A folder that ends up with
//   kept entries is moved back to its original name so the kept entries stay where they were.
// * Moving to the Trash is reversible, so it is checked after the move: if the moved item isn't the reviewed one,
//   it is moved straight back (RENAME_EXCL) and reported.
//
// What this can't stop: a process of the same user that already holds an open descriptor (or working directory)
// inside the folder before it is staged can still change entries there while they are being deleted.

extension FileIdentity {
    /// The identity in a stat record from lstat / fstatat(AT_SYMLINK_NOFOLLOW), captured now.
    public init(path: String, stat s: stat, capturedAtNanos: Int64 = LocalFileSystem.nowNanos()) {
        let kind: Kind
        switch s.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        self.init(path: path, device: UInt64(UInt32(bitPattern: s.st_dev)), inode: UInt64(s.st_ino), kind: kind,
                  size: Int64(s.st_size), modificationNanos: LocalFileSystem.nanos(s.st_mtimespec),
                  linkCount: UInt32(s.st_nlink), flags: s.st_flags, capturedAtNanos: capturedAtNanos)
    }
}

/// A failed system call or an unsafe situation, in words for the person.
public struct PlatformError: Error, Sendable, CustomStringConvertible {
    public let description: String

    init(_ operation: String, _ path: String, _ code: Int32 = errno) {
        description = "\(operation) \(path): \(String(cString: strerror(code)))"
    }

    init(message: String) { description = message }
}

public struct LocalFileSystem: CleanupFileSystem {
    /// Moves an item to the Trash and returns where it went.
    public typealias TrashMover = @Sendable (URL) throws -> URL

    /// The real Trash (FileManager.trashItem).
    public static let systemTrash: TrashMover = { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        guard let dest = out as URL? else { throw PlatformError(message: "\(url.path) was not moved to the Trash") }
        return dest
    }

    static let stagingPrefix = ".maccleaner-rm-"

    /// Test-only: runs right before an item is moved (to staging or to the Trash), after it passed its check, so
    /// tests can swap it at the worst moment. nil in the app.
    typealias BeforeMove = @Sendable (String) -> Void

    private let trashMover: TrashMover
    private let beforeMove: BeforeMove?

    /// `trashMover` is replaced only by tests, so they never touch the person's Trash.
    public init(trashMover: @escaping TrashMover = LocalFileSystem.systemTrash) {
        self.init(trashMover: trashMover, beforeMove: nil)
    }

    init(trashMover: @escaping TrashMover, beforeMove: BeforeMove?) {
        self.trashMover = trashMover
        self.beforeMove = beforeMove
    }

    public static func nanos(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }

    public static func nowNanos() -> Int64 {
        var t = timespec()
        clock_gettime(CLOCK_REALTIME, &t)
        return nanos(t)
    }

    // MARK: - Reading

    public func identity(at path: String) throws -> FileIdentity? {
        var s = stat()
        guard fstatat(AT_FDCWD, path, &s, AT_SYMLINK_NOFOLLOW_ANY) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return nil
            case ELOOP: throw FileSystemRefusal.changed(.replaced)   // a folder above it became a symlink
            default: throw PlatformError("stat", path)
            }
        }
        return FileIdentity(path: path, stat: s)
    }

    public func entries(of folder: FileIdentity) throws -> [FileIdentity] {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw refusal(afterFailing: "open", folder) }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw PlatformError("stat", folder.path) }
        if let m = folder.mismatch(against: FileIdentity(path: folder.path, stat: s)) { throw FileSystemRefusal.changed(m) }
        guard let names = Self.names(in: fd) else { throw PlatformError("list", folder.path) }
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let now = Self.nowNanos()
        return names.compactMap { name in
            guard !name.hasPrefix(Self.stagingPrefix) else { return nil }   // our own, never an entry
            var c = stat()
            guard fstatat(fd, name, &c, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }   // gone since listing
            return FileIdentity(path: base + name, stat: c, capturedAtNanos: now)
        }
    }

    // MARK: - Trash

    public func moveToTrash(_ item: FileIdentity) throws -> TrashResult {
        let parent = try Parent(of: item)
        defer { parent.close() }
        let s = try parent.statChecked(item)
        let bytes = Self.allocated(parent, s)
        beforeMove?(item.path)
        let dest = try trashMover(URL(fileURLWithPath: item.path))
        var moved = stat()
        guard fstatat(AT_FDCWD, dest.path, &moved, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PlatformError(message: "\(item.path) was moved to the Trash at \(dest.path) but couldn't be checked there")
        }
        if let m = item.mismatch(against: FileIdentity(path: item.path, stat: moved)) {
            if renameatx_np(AT_FDCWD, dest.path, parent.fd, parent.name, UInt32(RENAME_EXCL)) == 0 {
                throw FileSystemRefusal.changed(m)
            }
            throw PlatformError(message: "\(item.path) changed just before it was moved to the Trash. What was moved "
                                + "couldn't be put back and is in the Trash at \(dest.path)")
        }
        return TrashResult(bytes: bytes, recoveryPath: dest.path)
    }

    // MARK: - Permanent removal

    public func remove(_ item: FileIdentity) throws -> RemovalResult {
        let parent = try Parent(of: item)
        defer { parent.close() }
        _ = try parent.statChecked(item)

        let staging = try Staging(in: parent)
        defer { staging.close() }
        beforeMove?(item.path)
        guard renameatx_np(parent.fd, parent.name, staging.fd, Staging.slot, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            staging.remove()
            if code == ENOENT { throw FileSystemRefusal.missing }
            throw PlatformError("move", item.path, code)
        }

        // What was moved is now reachable only through the private staging folder. Is it the reviewed item?
        var s = stat()
        guard fstatat(staging.fd, Staging.slot, &s, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw PlatformError(message: "\(item.path) was moved to \(staging.itemPath) but couldn't be checked there")
        }
        if let m = item.mismatch(against: FileIdentity(path: item.path, stat: s)) {
            try putBack(staging, parent, item, otherwise: "\(item.path) changed while it was being removed")
            throw FileSystemRefusal.changed(m)
        }

        var result = RemovalResult()
        guard item.kind == .directory else {
            guard unlinkat(staging.fd, Staging.slot, 0) == 0 else {
                let code = errno
                try putBack(staging, parent, item, otherwise: "\(item.path) couldn't be deleted")
                throw PlatformError("delete", item.path, code)
            }
            staging.remove()
            result.freedBytes = Self.freed(s)
            return result
        }

        let fd = openat(staging.fd, Staging.slot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var opened = stat()
        guard fd >= 0, fstat(fd, &opened) == 0, opened.st_dev == s.st_dev, opened.st_ino == s.st_ino else {
            if fd >= 0 { Darwin.close(fd) }
            try putBack(staging, parent, item, otherwise: "\(item.path) couldn't be opened")
            throw PlatformError(message: "\(item.path) couldn't be opened for removal; nothing was deleted")
        }
        var kept: [(rel: String, reason: KeptEntry.Reason)] = []
        Self.removeContents(of: fd, rel: "", device: s.st_dev, cutoff: item.capturedAtNanos,
                            freed: &result.freedBytes, kept: &kept)
        Darwin.close(fd)

        if unlinkat(staging.fd, Staging.slot, AT_REMOVEDIR) == 0 {
            staging.remove()
            result.freedBytes += Self.freed(s)
            return result
        }
        if kept.isEmpty { kept.append(("", .failed(String(cString: strerror(errno))))) }
        // Something stays: put the folder back under its own name so what was kept is where it was.
        let base: String
        if renameatx_np(staging.fd, Staging.slot, parent.fd, parent.name, UInt32(RENAME_EXCL)) == 0 {
            staging.remove()
            base = item.path
        } else {
            base = staging.itemPath   // its name was taken meanwhile; say where it is
        }
        result.kept = kept.map { KeptEntry(path: base + $0.rel, reason: $0.reason) }
        return result
    }

    /// Moves the staged item back to its own name. If the name was taken meanwhile, says where the item is.
    private func putBack(_ staging: Staging, _ parent: Parent, _ item: FileIdentity, otherwise what: String) throws {
        if renameatx_np(staging.fd, Staging.slot, parent.fd, parent.name, UInt32(RENAME_EXCL)) == 0 {
            staging.remove()
            return
        }
        throw PlatformError(message: "\(what), and something new took its name. Nothing was deleted; "
                            + "the item is at \(staging.itemPath)")
    }

    /// After an open of `item` failed: a refusal when it is gone or changed, else the system error.
    private func refusal(afterFailing op: String, _ item: FileIdentity) -> Error {
        let code = errno
        switch code {
        case ENOENT: return FileSystemRefusal.missing
        case ELOOP, ENOTDIR:
            if let now = try? identity(at: item.path) { return FileSystemRefusal.changed(item.mismatch(against: now) ?? .replaced) }
            return FileSystemRefusal.changed(.replaced)
        default: return PlatformError(op, item.path, code)
        }
    }

    // MARK: - Walks

    /// Created or changed after `cutoff`: not part of what was reviewed.
    private static func changedAfter(_ s: stat, _ cutoff: Int64) -> Bool {
        nanos(s.st_birthtimespec) > cutoff || nanos(s.st_ctimespec) > cutoff
    }

    /// Deletes what is inside the open folder, entry by entry through descriptors. Keeps (and records) entries
    /// created or changed after `cutoff`, other volumes, and whatever the system refuses to delete.
    private static func removeContents(of fd: Int32, rel: String, device: dev_t, cutoff: Int64,
                                       freed total: inout Int64, kept: inout [(rel: String, reason: KeptEntry.Reason)]) {
        guard let names = names(in: fd) else { kept.append((rel, .failed("couldn't list its contents"))); return }
        for name in names {
            let childRel = rel + "/" + name
            var s = stat()
            guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { kept.append((childRel, .failed(String(cString: strerror(errno))))) }
                continue
            }
            if s.st_dev != device { kept.append((childRel, .otherVolume)); continue }
            if changedAfter(s, cutoff) { kept.append((childRel, .changedAfterReview)); continue }
            if s.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var opened = stat()
                guard child >= 0, fstat(child, &opened) == 0, opened.st_dev == s.st_dev, opened.st_ino == s.st_ino else {
                    if child >= 0 { Darwin.close(child) }
                    kept.append((childRel, .failed("changed while being removed")))
                    continue
                }
                let before = kept.count
                removeContents(of: child, rel: childRel, device: device, cutoff: cutoff, freed: &total, kept: &kept)
                Darwin.close(child)
                if unlinkat(fd, name, AT_REMOVEDIR) == 0 { total += freed(s) }
                else if kept.count > before { kept.append((childRel, .notEmpty)) }
                else { kept.append((childRel, .failed(String(cString: strerror(errno))))) }
            } else if unlinkat(fd, name, 0) == 0 {
                total += freed(s)
            } else {
                kept.append((childRel, .failed(String(cString: strerror(errno)))))
            }
        }
    }

    /// Space on disk the item takes, everything below a folder included, no links followed, no other volumes.
    private static func allocated(_ parent: Parent, _ s: stat) -> Int64 {
        let own = Int64(s.st_blocks) * 512
        guard s.st_mode & S_IFMT == S_IFDIR else { return own }
        let fd = openat(parent.fd, parent.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return own }
        defer { Darwin.close(fd) }
        return own + measure(fd, device: s.st_dev)
    }

    private static func measure(_ fd: Int32, device: dev_t) -> Int64 {
        var total: Int64 = 0
        for name in names(in: fd) ?? [] {
            var s = stat()
            guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_dev == device else { continue }
            total += Int64(s.st_blocks) * 512
            guard s.st_mode & S_IFMT == S_IFDIR else { continue }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            total += measure(child, device: device)
            Darwin.close(child)
        }
        return total
    }

    /// What unlinking this entry frees: nothing while another hard link to a file remains.
    private static func freed(_ s: stat) -> Int64 {
        if s.st_mode & S_IFMT != S_IFDIR, s.st_nlink > 1 { return 0 }
        return Int64(s.st_blocks) * 512
    }

    /// Names in an open folder (not "." or ".."). nil if the listing failed part-way.
    static func names(in dirfd: Int32) -> [String]? {
        let copy = dup(dirfd)
        guard copy >= 0, let dir = fdopendir(copy) else { if copy >= 0 { Darwin.close(copy) }; return nil }
        defer { closedir(dir) }
        rewinddir(dir)
        var out: [String] = []
        while true {
            errno = 0
            guard let ent = readdir(dir) else { return errno == 0 ? out : nil }
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                String(decoding: raw.prefix(Int(ent.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { out.append(name) }
        }
    }
}

// MARK: - Open folders

/// The open folder an item is in, reached without following any symlink.
private struct Parent {
    let fd: Int32
    let path: String
    let name: String

    init(of item: FileIdentity) throws {
        // Plain string checks: URL standardization rewrites /private/var to /var, which is itself a symlink.
        let parts = item.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard item.path.hasPrefix("/"), let last = parts.last,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PlatformError(message: "\(item.path) isn't a plain absolute path")
        }
        let name = String(last)
        let parentPath = String(item.path.dropLast(name.count + 1))
        path = parentPath.isEmpty ? "/" : parentPath
        fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: throw FileSystemRefusal.missing
            case ELOOP, ENOTDIR: throw FileSystemRefusal.changed(.replaced)   // a folder above became a symlink
            default: throw PlatformError("open", path)
            }
        }
        self.name = name
        var own = stat()
        guard fstat(fd, &own) == 0 else { Darwin.close(fd); throw PlatformError("stat", path) }
        var s = stat()
        // Never remove a volume mounted here, or anything that isn't on the folder's own volume.
        if fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_dev != own.st_dev {
            Darwin.close(fd)
            throw PlatformError(message: "\(item.path) is another volume mounted here; it is never removed")
        }
    }

    func close() { Darwin.close(fd) }

    /// The item's stat now, refusing when it is gone or isn't `item`.
    func statChecked(_ item: FileIdentity) throws -> stat {
        var s = stat()
        guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw FileSystemRefusal.missing }
            throw PlatformError("stat", item.path)
        }
        if let m = item.mismatch(against: FileIdentity(path: item.path, stat: s)) { throw FileSystemRefusal.changed(m) }
        return s
    }
}

/// A private folder (0700, random name) next to the item, on the same volume, that the item is moved into before
/// anything is deleted.
private struct Staging {
    static let slot = "item"
    let fd: Int32
    let parentFD: Int32
    let name: String
    let itemPath: String

    init(in parent: Parent) throws {
        parentFD = parent.fd
        name = LocalFileSystem.stagingPrefix + UUID().uuidString
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw PlatformError("create", parent.path + "/" + name) }
        fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            unlinkat(parent.fd, name, AT_REMOVEDIR)
            throw PlatformError("open", parent.path + "/" + name, code)
        }
        itemPath = parent.path + "/" + name + "/" + Self.slot
    }

    func close() { Darwin.close(fd) }

    /// Removes the staging folder if it is empty; a non-empty one is left for the person (its path is reported).
    func remove() { unlinkat(parentFD, name, AT_REMOVEDIR) }
}
