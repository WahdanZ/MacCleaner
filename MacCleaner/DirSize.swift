import Darwin
import Foundation

/// Fast folder sizing with getattrlistbulk(2). One system call returns a whole batch of directory entries with
/// their type and allocated size, so there is no URL object, no resource-value cache and no separate stat per file
/// (what FileManager's enumerator does). Every sub-folder is a job for the shared `WalkPool`, so a single huge
/// folder is read by all its threads at once instead of one.
///
/// The total is the same number the old enumerator produced: the sum of ATTR_FILE_ALLOCSIZE (what
/// `URLResourceKey.totalFileAllocatedSizeKey` reports) of every non-folder below the root, hidden files and package
/// contents included, AppleDouble "._" files left out, symlinks counted as themselves and never followed.
/// Folders it cannot read count as 0.
enum DirSize {
    /// How many locations or apps a scan measures at once.
    static let width = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 12))
    private static let bufferSize = 128 * 1024

    static func allocated(atPath path: String) -> Int64 { measure(atPath: path).bytes }

    /// The size, and whether every folder below was read to the end. A folder that cannot be opened at all counts
    /// as 0 every time (as before); one whose listing fails part-way makes the result incomplete, and an
    /// incomplete size is never cached.
    static func measure(atPath path: String) -> (bytes: Int64, complete: Bool) {
        let total = Total()
        WalkPool.shared.run { group in visit(path, group, total) }
        return (total.value, total.complete)
    }

    private static func visit(_ path: String, _ group: WalkPool.Group, _ total: Total) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        let (bytes, dirs, read) = list(fd)
        close(fd)   // children are opened by path, so open descriptors never pile up
        total.add(bytes)
        if read != .complete { total.markIncomplete() }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for d in dirs {
            let sub = prefix + d
            group.add { visit(sub, group, total) }
        }
    }

    private final class Total: @unchecked Sendable {
        private let lock = NSLock()
        private var n: Int64 = 0
        private var whole = true
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return n }
        var complete: Bool { lock.lock(); defer { lock.unlock() }; return whole }
        func add(_ k: Int64) { if k != 0 { lock.lock(); n += k; lock.unlock() } }
        func markIncomplete() { lock.lock(); whole = false; lock.unlock() }
    }

    /// Allocated bytes of the non-folder entries in an open directory, and the names of its sub-folders.
    private static func list(_ fd: Int32) -> (Int64, [String], Read) {
        var total: Int64 = 0
        var dirs: [String] = []
        let read = forEach(fd, details: false) { r in
            if r.type == fsobj_type_t(VDIR.rawValue) {
                dirs.append(String(cString: r.name))
            } else {
                total += r.size
            }
        }
        return (total, dirs, read)
    }

    fileprivate static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }

    /// One entry as read, valid only inside the callback. Turn the name or dates into objects only when needed:
    /// a big walk sees millions of entries and most of them are only counted.
    struct Raw {
        var name: UnsafePointer<CChar>
        var type: fsobj_type_t
        var size: Int64 = 0
        var modified: timespec?
        var accessed: timespec?
        var flags: UInt32 = 0

        var isDirectory: Bool { type == fsobj_type_t(VDIR.rawValue) }
        var isSymlink: Bool { type == fsobj_type_t(VLNK.rawValue) }
        var isRegularFile: Bool { type == fsobj_type_t(VREG.rawValue) }
        /// What FileManager's `.skipsHiddenFiles` skips: a leading dot or the hidden flag.
        var isHidden: Bool { name[0] == 0x2E || flags & UInt32(UF_HIDDEN) != 0 }
        var nameString: String { String(cString: name) }
        var modifiedDate: Date? { modified.map(DirSize.date) }
        var accessedDate: Date? { accessed.map(DirSize.date) }
    }

    /// A file URL whose path has exactly these bytes. `URL(fileURLWithPath:)` converts the string to its
    /// file-system form first, which on macOS 15 decomposes non-ASCII names ("ü" → "u" + "̈"); FileManager's own
    /// URLs (what the scans used before, and what the guards compare against) keep the name as stored.
    static func fileURL(_ path: String, isDirectory: Bool) -> URL {
        path.withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: isDirectory, relativeTo: nil) }
    }

    /// How far a folder listing got.
    enum Read { case complete, partial, unreadable }

    /// Calls `body` for each entry of a folder (with dates and flags).
    @discardableResult
    static func forEachEntry(atPath path: String, _ body: (Raw) -> Void) -> Read {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }
        return forEach(fd, details: true, body)
    }

    /// Calls `body` for every readable entry of an open directory: name, type, allocated size (0 for folders)
    /// and, with `details`, modification and access time and BSD flags. `.partial` if the listing failed after
    /// some entries were read, `.unreadable` if nothing could be read.
    @discardableResult
    private static func forEach(_ fd: Int32, details: Bool, _ body: (Raw) -> Void) -> Read {
        var req = attrlist()
        req.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        req.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE)
        if details {
            req.commonattr |= attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME) | attrgroup_t(ATTR_CMN_FLAGS)
        }
        req.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buf.deallocate() }
        var first = true
        func has(_ set: attrgroup_t, _ bit: Int32) -> Bool { set & attrgroup_t(bit) != 0 }

        while true {
            let count = getattrlistbulk(fd, &req, buf, bufferSize, 0)
            if count < 0 { return first ? .unreadable : .partial }   // what was read so far stays counted
            first = false
            if count == 0 { break }
            var entry = buf
            for _ in 0..<count {
                // Layout (see getattrlistbulk(2)): length, returned set, then the requested attributes in bit
                // order (NAME, OBJTYPE, MODTIME, ACCTIME, FLAGS), except ATTR_CMN_ERROR, which comes first.
                // File attributes follow the common ones.
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                let common = returned.commonattr

                if has(common, ATTR_CMN_ERROR) {
                    let err = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                    if err != 0 { continue }
                }
                guard has(common, ATTR_CMN_NAME) else { continue }
                let ref = field.loadUnaligned(as: attrreference_t.self)
                let name = UnsafePointer((field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size

                guard has(common, ATTR_CMN_OBJTYPE) else { continue }
                var r = Raw(name: name, type: field.loadUnaligned(as: fsobj_type_t.self))
                field += MemoryLayout<fsobj_type_t>.size
                // FileManager never lists AppleDouble "._name" files (it does list "._name" folders); skip them
                // too so every total matches what the app reported before.
                if r.type != fsobj_type_t(VDIR.rawValue) && name[0] == 0x2E && name[1] == 0x5F { continue }

                if has(common, ATTR_CMN_MODTIME) {
                    r.modified = field.loadUnaligned(as: timespec.self)
                    field += MemoryLayout<timespec>.size
                }
                if has(common, ATTR_CMN_ACCTIME) {
                    r.accessed = field.loadUnaligned(as: timespec.self)
                    field += MemoryLayout<timespec>.size
                }
                if has(common, ATTR_CMN_FLAGS) {
                    r.flags = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) {
                    r.size = Int64(field.loadUnaligned(as: off_t.self))
                }
                body(r)
            }
        }
        return .complete
    }
}

/// Folder sizes measured in the last minute, so scans that run one after another (Overview, Junk Files,
/// Applications, Developer Tools) don't walk the same folders again. Every function that deletes, moves to the
/// Trash or restores files clears it before and after, and a walk that overlaps a clear is not stored, so the app
/// never shows a size from before its own change.
/// Changes made outside the app show up once an entry is a minute old.
enum SizeCache {
    static let lifetime: TimeInterval = 60
    nonisolated(unsafe) static var enabled = true      // `bench` turns it off to time real walks
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sizes: [String: (bytes: Int64, at: Date)] = [:]

    static func get(_ path: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let e = sizes[path] else { return nil }
        if Date().timeIntervalSince(e.at) > lifetime { sizes[path] = nil; return nil }
        return e.bytes
    }

    nonisolated(unsafe) private static var gen: UInt64 = 0

    /// Read before measuring and pass to `put`: if the cache was cleared in between (the app deleted something
    /// while the walk ran), the measurement may be from before that change and is not stored.
    static var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return gen }

    static func put(_ path: String, _ bytes: Int64, generation: UInt64) {
        lock.lock(); if enabled && generation == gen { sizes[path] = (bytes, Date()) }; lock.unlock()
    }

    static func clear() { lock.lock(); gen &+= 1; sizes.removeAll(); lock.unlock() }
}

/// A fixed set of threads that run folder-listing jobs for every walk in the app (folder sizes, Storage Map).
/// A walk is a `Group`: its jobs may add more jobs (one per sub-folder), and `run` returns once all of them are done.
/// Jobs must not call `run` themselves (they would wait on the threads they occupy).
final class WalkPool: @unchecked Sendable {
    static let shared = WalkPool(threads: max(4, min(ProcessInfo.processInfo.activeProcessorCount, 16)))

    final class Group: @unchecked Sendable {
        fileprivate unowned let pool: WalkPool
        fileprivate var pending = 0
        fileprivate let done = DispatchSemaphore(value: 0)
        fileprivate init(_ pool: WalkPool) { self.pool = pool }

        /// Queues another job in this walk.
        func add(_ job: @escaping () -> Void) { pool.push(self, job) }
    }

    private let cond = NSCondition()
    private var jobs: [(Group, () -> Void)] = []
    private var peak = 0

    /// The most jobs ever waiting at once (for `bench`): newest-first order keeps the walk depth-first, so
    /// this stays near "folders per level × depth", not the size of the whole tree.
    var peakQueued: Int { cond.lock(); defer { cond.unlock() }; return peak }

    init(threads: Int) {
        for i in 0..<threads {
            let t = Thread { [unowned self] in self.work() }
            t.name = "WalkPool \(i)"
            t.qualityOfService = .userInitiated
            t.stackSize = 1 << 20
            t.start()
        }
    }

    /// Runs `root` and every job it adds, and returns when all are finished. Blocks the caller.
    func run(_ root: @escaping (Group) -> Void) {
        let g = Group(self)
        push(g) { root(g) }
        g.done.wait()
    }

    fileprivate func push(_ g: Group, _ job: @escaping () -> Void) {
        cond.lock()
        g.pending += 1
        jobs.append((g, job))   // newest first: a walk that just started is not stuck behind a big one
        peak = max(peak, jobs.count)
        cond.signal()
        cond.unlock()
    }

    private func work() {
        while true {
            cond.lock()
            while jobs.isEmpty { cond.wait() }
            var item: (Group, () -> Void)? = jobs.removeLast()
            cond.unlock()
            let g = item!.0
            autoreleasepool { item!.1() }
            item = nil      // drop the job (and what it captured) before its walk can be reported done
            cond.lock()
            g.pending -= 1
            let finished = g.pending == 0
            cond.unlock()
            if finished { g.done.signal() }
        }
    }
}
