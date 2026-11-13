import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Overwrites files with zeros, then deletes them.
///
/// How it stays safe while other apps keep using the disk:
/// 1. **Plan when reviewed.** `plan` lists the item without following links and records every entry's
///    identity (device, inode, type) and, for files, size and modification time. Anything that can't be
///    shredded safely refuses the whole item before anything changes.
/// 2. **Work through open folders, not paths.** Execution opens the item's folder once, checks it is the
///    planned folder, and does everything relative to open folder descriptors (`openat`, `fstatat`,
///    `renameat`, `unlinkat`, all without following links). Replacing a folder or swapping it for a link
///    after that point can't redirect the work elsewhere.
/// 3. **Move, then check, then act.** Each file or link is first moved (`renameat`) into a private staging
///    folder (random name, mode 700) next to the item, and checked there. If what was moved isn't exactly
///    the planned object (another app saved over it), it is moved back (`RENAME_EXCL`, never overwriting)
///    and kept. The overwrite and delete then happen only on the private name.
/// 4. **Overwrite, flush, delete, then re-check through the open file.** After unlinking, the file is still
///    open; if another app holding it open appended data meanwhile, that tail is overwritten too before closing.
/// 5. **Stop at the first failure.** What was already shredded is gone; the failed file and everything not
///    yet processed stay at their original place. The result says exactly which.
///
/// Limits (also in SAFETY_MODEL.md): a process of the same user can still write to a file it already had
/// open after the last re-check, or find and change the staging folder; there is no atomic
/// "delete only if unchanged" call on macOS. And on APFS/SSDs an overwrite can't guarantee the old blocks
/// are unrecoverable (copy-on-write, snapshots, wear levelling).
enum ShredEngine {
    struct Result {
        /// The whole item is gone and nothing was left behind (no staging folder, nothing kept).
        var removed = false
        /// The staging folder, when it couldn't be removed afterwards (it may hold items that couldn't be put
        /// back, or something another app put there). The user is told where it is.
        var leftover: String?
        /// Files that were overwritten, flushed and then deleted.
        var overwritten = 0
        /// Files and folders left in place after a step failed, with why. Nothing is ever deleted
        /// without its overwrite succeeding first.
        var kept: [String] = []
        /// Files that were kept after their overwrite had already started: their content is partly zeroed.
        var damaged: [String] = []
        /// Things the user should know that didn't stop the shred (e.g. another app kept writing to a file).
        var warnings: [String] = []
        /// Set when nothing was changed.
        var refused: String?
    }

    /// Largest file the Shredder overwrites. Bigger items are refused before anything is changed.
    static let maxFileSize: off_t = 4_000_000_000

    /// One planned entry. Names are relative to the parent folder.
    indirect enum Node {
        case file(String, stat)
        case link(String, stat)
        case folder(String, stat, [Node])

        var name: String {
            switch self { case .file(let n, _), .link(let n, _), .folder(let n, _, _): return n }
        }
        var info: stat {
            switch self { case .file(_, let s), .link(_, let s), .folder(_, let s, _): return s }
        }
        var fileCount: Int {
            switch self {
            case .file: return 1
            case .link: return 0
            case .folder(_, _, let c): return c.reduce(0) { $0 + $1.fileCount }
            }
        }
    }

    /// What was reviewed: the item, the folder it is in, and every entry inside.
    struct Plan {
        let url: URL
        let parent: stat
        let root: Node
    }

    struct Refusal: Error { let reason: String; init(_ r: String) { reason = r } }

    /// Test-only hooks to simulate failures and other apps acting at the worst moment. Empty in the app.
    struct Hooks {
        /// Replaces the real overwrite: given the open file and the range, returns bytes written and an error.
        var overwrite: ((Int32, off_t, off_t) -> (written: off_t, error: String?))? = nil
        /// After the plan is checked, before anything is opened.
        var beforeStart: (() -> Void)? = nil
        /// After a file or link passed its identity check, right before it is moved to staging.
        var beforeMove: ((URL) -> Void)? = nil
        /// After a file was overwritten and flushed, right before it is unlinked.
        var afterOverwrite: ((URL) -> Void)? = nil
        /// After a folder's contents are done, right before the folder itself is removed.
        var beforeFolderRemove: ((URL) -> Void)? = nil
        /// Right before the staging folder is removed, with its location.
        var beforeStagingCleanup: ((URL) -> Void)? = nil
    }

    /// Why an item can't be shredded. Checked when it is added and again right before shredding,
    /// so something protected or moved in between is refused.
    static func reason(_ url: URL) -> String? {
        if let why = TrashGuard.reason(url) { return why }
        if !SafetyGuard.isInside(TrashGuard.key(url), SafetyGuard.home.path.lowercased()) {
            return "Only items in your home folder can be shredded"
        }
        return nil
    }

    static let stagingPrefix = ".maccleaner-shred-"
    private static let lockedFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    private static func errorText() -> String { String(cString: strerror(errno)) }

    static func sameObject(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT)
    }
    /// Same object and, for a file, same size and modification time as when it was planned.
    static func unchanged(_ now: stat, _ planned: stat) -> Bool {
        guard sameObject(now, planned) else { return false }
        guard (planned.st_mode & S_IFMT) == S_IFREG else { return true }
        return now.st_size == planned.st_size && now.st_mtimespec.tv_sec == planned.st_mtimespec.tv_sec
            && now.st_mtimespec.tv_nsec == planned.st_mtimespec.tv_nsec
    }

    /// Names in an open folder (not "." or ".."). nil if the listing failed part-way.
    static func names(in dirfd: Int32) -> [String]? {
        let copy = dup(dirfd)
        guard copy >= 0, let dir = fdopendir(copy) else { if copy >= 0 { close(copy) }; return nil }
        defer { closedir(dir) }
        rewinddir(dir)
        var out: [String] = []
        while true {
            errno = 0
            guard let ent = readdir(dir) else { return errno == 0 ? out : nil }
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                let bytes = raw.prefix(Int(ent.pointee.d_namlen))
                return String(decoding: bytes, as: UTF8.self)
            }
            if name != "." && name != ".." { out.append(name) }
        }
    }

    /// Lists everything in an item without following links, and refuses the item (nothing changed) if any
    /// part of it can't be shredded safely: an unreadable folder (its files would be deleted unseen), a hard
    /// link (overwriting it would erase the other copy), a locked or unwritable file, a file over 4 GB,
    /// a socket/device/pipe, a name that isn't valid text, or a link as the item itself.
    static func plan(_ url: URL) -> Swift.Result<Plan, Refusal> {
        if let why = reason(url) { return .failure(Refusal(why)) }
        let parentPath = url.deletingLastPathComponent().path
        let pfd = open(parentPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard pfd >= 0 else { return .failure(Refusal("Its folder can't be read")) }
        defer { close(pfd) }
        var pst = stat()
        guard fstat(pfd, &pst) == 0, faccessat(pfd, ".", W_OK | X_OK, 0) == 0 else {
            return .failure(Refusal("Its folder can't be changed"))
        }
        func visit(_ dirfd: Int32, _ name: String, _ path: String, isRoot: Bool) -> Swift.Result<Node, Refusal> {
            func no(_ why: String) -> Swift.Result<Node, Refusal> { .failure(Refusal(why)) }
            let shown = (path as NSString).lastPathComponent
            var st = stat()
            guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return no("\(shown) can't be read") }
            if st.st_flags & lockedFlags != 0 { return no("\(shown) is locked") }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if st.st_nlink > 1 { return no("\(shown) is a hard link to a file elsewhere, which shredding would erase too") }
                if st.st_size > maxFileSize { return no("\(shown) is larger than 4 GB") }
                let w = openat(dirfd, name, O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard w >= 0 else { return no("\(shown) can't be written (locked or not yours)") }
                close(w)
                return .success(.file(name, st))
            case S_IFLNK:
                return isRoot ? no("This is a link. Shred the original item instead") : .success(.link(name, st))
            case S_IFDIR:
                let fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { return no("The folder \(shown) can't be read") }
                defer { close(fd) }
                var now = stat()
                guard fstat(fd, &now) == 0, sameObject(now, st) else { return no("\(shown) changed while it was being listed") }
                guard faccessat(fd, ".", R_OK | W_OK | X_OK, 0) == 0 else { return no("The folder \(shown) can't be changed") }
                guard let entries = names(in: fd) else { return no("The folder \(shown) can't be read completely") }
                var children: [Node] = []
                for n in entries.sorted() {
                    if n.hasPrefix(stagingPrefix) { return no("\(shown) holds an unfinished shred (\(n)); remove it first") }
                    switch visit(fd, n, path + "/" + n, isRoot: false) {
                    case .failure(let f): return .failure(f)
                    case .success(let c): children.append(c)
                    }
                }
                return .success(.folder(name, st, children))
            default:
                return no("\(shown) is not a regular file or folder")
            }
        }
        switch visit(pfd, url.lastPathComponent, url.path, isRoot: true) {
        case .failure(let f): return .failure(f)
        case .success(let root): return .success(Plan(url: url, parent: pst, root: root))
        }
    }

    /// Writes zeros over [from, to) of an open file and flushes it to the disk. Returns bytes written and an error.
    static func overwrite(_ fd: Int32, from: off_t, to: off_t) -> (written: off_t, error: String?) {
        let chunk = [UInt8](repeating: 0, count: 1 << 20)
        var offset = from
        while offset < to {
            let n = Int(min(off_t(chunk.count), to - offset))
            let w = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, n, offset) }
            guard w == n else { return (offset - from, "writing failed") }
            offset += off_t(n)
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { return (offset - from, "couldn't flush to disk") }
        return (offset - from, nil)
    }

    /// Plans and shreds in one go (no review in between). The app plans at review time and calls `shred(_ plan:)`.
    static func shred(_ url: URL, hooks: Hooks = Hooks()) -> Result {
        switch plan(url) {
        case .failure(let f): var r = Result(); r.refused = f.reason + ". Nothing was changed."; return r
        case .success(let p): return shred(p, hooks: hooks)
        }
    }

    /// Shreds exactly what was planned. See the type comment for the steps and guarantees.
    static func shred(_ plan: Plan, hooks: Hooks = Hooks()) -> Result {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        var r = Result()
        if let why = reason(plan.url) { r.refused = why + ". Nothing was changed."; return r }
        hooks.beforeStart?()
        let parentURL = plan.url.deletingLastPathComponent()
        let pfd = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard pfd >= 0 else { r.refused = "Its folder can't be opened. Nothing was changed."; return r }
        defer { close(pfd) }
        var pst = stat()
        guard fstat(pfd, &pst) == 0, sameObject(pst, plan.parent) else {
            r.refused = "The folder holding it was moved or replaced since you reviewed it. Nothing was changed."
            return r
        }
        // Private staging folder next to the item (same volume, so moves are atomic renames).
        let stageName = stagingPrefix + UUID().uuidString.lowercased()
        let stagePath = parentURL.appendingPathComponent(stageName).path
        guard mkdirat(pfd, stageName, 0o700) == 0 else {
            r.refused = "Couldn't prepare the shred (\(errorText())). Nothing was changed."; return r
        }
        let sfd = openat(pfd, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var sst = stat()
        guard sfd >= 0, fstat(sfd, &sst) == 0, sst.st_uid == getuid(), sst.st_mode & 0o777 == 0o700 else {
            if sfd >= 0 { close(sfd) }
            unlinkat(pfd, stageName, AT_REMOVEDIR)
            r.refused = "Couldn't prepare the shred. Nothing was changed."; return r
        }
        var serial = 0
        var stopped = false

        /// Moves `name` back from staging without replacing anything that took its place.
        func putBack(_ tmp: String, _ dirfd: Int32, _ name: String) -> String? {
            renameatx_np(sfd, tmp, dirfd, name, UInt32(RENAME_EXCL)) == 0 ? nil : "\(stagePath)/\(tmp)"
        }
        func keep(_ path: String, _ why: String) {
            r.kept.append("\((path as NSString).lastPathComponent): \(why)")
            stopped = true
        }

        func process(_ node: Node, in dirfd: Int32, path: String) {
            guard !stopped else { return }
            let url = URL(fileURLWithPath: path)
            switch node {
            case .file(let name, let planned), .link(let name, let planned):
                let isFile = (planned.st_mode & S_IFMT) == S_IFREG
                var now = stat()
                guard fstatat(dirfd, name, &now, AT_SYMLINK_NOFOLLOW) == 0, unchanged(now, planned) else {
                    return keep(path, "it changed since you reviewed it")
                }
                hooks.beforeMove?(url)
                serial += 1
                let tmp = "\(serial)"
                guard renameat(dirfd, name, sfd, tmp) == 0 else { return keep(path, "couldn't be moved (\(errorText()))") }
                var moved = stat()
                guard fstatat(sfd, tmp, &moved, AT_SYMLINK_NOFOLLOW) == 0, unchanged(moved, planned) else {
                    let left = putBack(tmp, dirfd, name)
                    return keep(path, left.map { "it was replaced while shredding and is now in \($0)" }
                                ?? "it was replaced while shredding; the new version is back in place, untouched")
                }
                if !isFile {
                    if unlinkat(sfd, tmp, 0) != 0 {
                        let left = putBack(tmp, dirfd, name)
                        return keep(path, "couldn't be removed" + (left.map { "; it is in \($0)" } ?? ""))
                    }
                    return
                }
                let fd = openat(sfd, tmp, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                var open_st = stat()
                guard fd >= 0, fstat(fd, &open_st) == 0, unchanged(open_st, planned), open_st.st_nlink == 1 else {
                    if fd >= 0 { close(fd) }
                    let left = putBack(tmp, dirfd, name)
                    return keep(path, "it changed while shredding" + (left.map { "; it is in \($0)" } ?? ""))
                }
                defer { close(fd) }
                let size = open_st.st_size
                let done = hooks.overwrite?(fd, 0, size) ?? overwrite(fd, from: 0, to: size)
                if let why = done.error {
                    if done.written > 0 { r.damaged.append(url.lastPathComponent) }
                    let left = putBack(tmp, dirfd, name)
                    let note = done.written > 0 ? " (partly overwritten, so its content is damaged)" : ""
                    return keep(path, why + note + (left.map { "; it is in \($0)" } ?? ""))
                }
                hooks.afterOverwrite?(url)
                // Last check that the private name is still this file, then delete it.
                var last = stat()
                guard fstatat(sfd, tmp, &last, AT_SYMLINK_NOFOLLOW) == 0, sameObject(last, open_st) else {
                    return keep(path, "its staging copy changed; nothing more was deleted")
                }
                guard unlinkat(sfd, tmp, 0) == 0 else {
                    let left = putBack(tmp, dirfd, name)
                    return keep(path, "overwritten but couldn't be deleted" + (left.map { "; it is in \($0)" } ?? ""))
                }
                r.overwritten += 1
                // The file is still open here. If another app that had it open appended meanwhile, overwrite
                // that tail too. (Its blocks stay allocated until every open handle is closed.)
                var covered = size
                for _ in 0..<5 {
                    var grown = stat()
                    guard fstat(fd, &grown) == 0, grown.st_size > covered else { break }
                    let extra = hooks.overwrite?(fd, covered, grown.st_size) ?? overwrite(fd, from: covered, to: grown.st_size)
                    if let why = extra.error {
                        r.warnings.append("\(url.lastPathComponent): another app added data while it was shredded, and that part couldn't be overwritten (\(why))")
                        break
                    }
                    covered = grown.st_size
                }
                var final = stat()
                if fstat(fd, &final) == 0, final.st_size > covered {
                    r.warnings.append("\(url.lastPathComponent): another app kept writing to it while it was shredded; its newest data was not overwritten")
                }
            case .folder(let name, let planned, let children):
                let fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var now = stat()
                guard fd >= 0, fstat(fd, &now) == 0, sameObject(now, planned) else {
                    if fd >= 0 { close(fd) }
                    return keep(path, "the folder was moved or replaced since you reviewed it")
                }
                for c in children { process(c, in: fd, path: path + "/" + c.name) }
                close(fd)
                guard !stopped else { return }
                hooks.beforeFolderRemove?(url)
                // Only an empty folder can be removed (rmdir), so this never deletes data.
                var here = stat()
                guard fstatat(dirfd, name, &here, AT_SYMLINK_NOFOLLOW) == 0, sameObject(here, planned) else {
                    return keep(path, "the folder was moved or replaced while shredding; its shredded contents are gone, the folder was left")
                }
                if unlinkat(dirfd, name, AT_REMOVEDIR) != 0 {
                    return keep(path, errno == ENOTEMPTY ? "new files appeared in it; they were left untouched" : errorText())
                }
            }
        }

        process(plan.root, in: pfd, path: plan.url.path)
        close(sfd)
        hooks.beforeStagingCleanup?(URL(fileURLWithPath: stagePath))
        if unlinkat(pfd, stageName, AT_REMOVEDIR) != 0 {
            r.leftover = stagePath
            r.kept.append("The shred's work folder couldn't be removed and may still hold items: \(stagePath)")
        }
        // Only "removed" when the item is gone and nothing stayed behind anywhere.
        r.removed = !stopped && r.leftover == nil
        if stopped {
            let total = plan.root.fileCount
            if total > r.overwritten { r.kept.append("\(total - r.overwritten) of \(total) file(s) were kept") }
        }
        return r
    }
}

@MainActor @Observable
final class ShredderModel {
    struct Item: Identifiable {
        let id: String; let url: URL; let size: Int64; let blocked: String?
        /// What was reviewed: shredding acts on exactly this, and keeps anything that changed since.
        var plan: ShredEngine.Plan? = nil
    }

    static func item(_ u: URL) -> Item {
        switch ShredEngine.plan(u) {
        case .success(let p): return Item(id: u.path, url: u, size: Scanner.allocatedSize(u), blocked: nil, plan: p)
        case .failure(let f): return Item(id: u.path, url: u, size: Scanner.allocatedSize(u), blocked: f.reason)
        }
    }

    var items: [Item] = []
    var confirming = false
    var working = false
    var message: (text: String, isError: Bool)?
    var dropTargeted = false

    var ready: [Item] { items.filter { $0.blocked == nil } }
    var total: Int64 { ready.reduce(0) { $0 + $1.size } }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(where: { $0.url == u }) {
            items.append(Self.item(u))
        }
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Add to Shredder"
        if p.runModal() == .OK { add(p.urls) }
    }

    /// Shreds exactly the reviewed items that are still ready (not blocked since).
    func shred(_ reviewed: [Item]) async {
        let ids = Set(ready.map(\.id))
        let list = reviewed.filter { ids.contains($0.id) }
        guard !list.isEmpty else { return }
        working = true
        var bytes: Int64 = 0, problems: [String] = [], partial = 0
        for i in list {
            let u = i.url
            guard let plan = i.plan else { continue }
            let r = await Task.detached(operation: { ShredEngine.shred(plan) }).value
            if let why = r.refused { problems.append("\(u.lastPathComponent): \(why)"); continue }
            var gone = stat()
            if r.removed {
                bytes += i.size
                items.removeAll { $0.id == i.id }
            } else if let leftover = r.leftover, lstat(u.path, &gone) != 0 {
                // The item itself is gone, but the work folder stayed (it may hold something): say where.
                bytes += i.size
                items.removeAll { $0.id == i.id }
                problems.append("\(u.lastPathComponent): shredded, but its work folder couldn't be removed and may still hold items: \(leftover)")
            } else {
                // Stopped part-way: what was overwritten is gone, the rest is untouched. Re-measure what's left.
                partial += 1
                let left = Scanner.allocatedSize(u)
                bytes += max(0, i.size - left)
                if let at = items.firstIndex(where: { $0.id == i.id }) {
                    // Re-planned, so a second Shred acts on what is left now (after another review).
                    let again = Self.item(u)
                    items[at] = Item(id: i.id, url: u, size: left, blocked: again.blocked, plan: again.plan)
                }
                problems.append("\(u.lastPathComponent): stopped after \(r.overwritten) file(s); the rest was kept (\(r.kept[0]))")
            }
            if !r.damaged.isEmpty {
                problems.append("partly overwritten and kept, so damaged: \(r.damaged.joined(separator: ", "))")
            }
            problems += r.warnings
        }
        if bytes > 0 { HistoryStore.shared.add("Files Shredded", bytes: bytes, symbol: "printer", outcome: .deleted) }
        let done = partial == 0 ? "Overwrote and deleted \(ByteText.string(bytes))."
                                : "Overwrote and deleted \(ByteText.string(bytes)); \(partial) item(s) only partly."
        message = problems.isEmpty ? (done, false)
                                   : (done + " \(problems.count) problem(s): \(problems.prefix(2).joined(separator: "; "))", true)
        working = false
    }
}

struct ShredderView: View {
    @Environment(ShredderModel.self) private var m
    @Environment(ReviewCenter.self) private var review

    var body: some View {
        @Bindable var m = m
        VStack(spacing: 14) {
            if let msg = m.message { MessageBar(text: msg.text, isError: msg.isError) { m.message = nil } }
            VStack(spacing: 0) {
                if m.items.isEmpty {
                    VStack(spacing: 14) {
                        IconTile(symbol: "printer", color: Palette.accent, size: 70)
                        Text("Drop files or folders here").font(.system(size: 20, weight: .semibold))
                        Text("Shredded items skip the Trash and can't be put back.")
                            .font(.system(size: 13)).foregroundStyle(Palette.dim)
                        Button { m.choose() } label: { Label("Choose files…", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(m.items) { i in
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: i.url.path)).resizable().frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(i.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(i.blocked ?? Scanner.tilde(i.url.deletingLastPathComponent()))
                                            .font(.system(size: 11))
                                            .foregroundStyle(i.blocked == nil ? Palette.faint : Palette.danger)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(ByteText.string(i.size)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                    Button { m.items.removeAll { $0.id == i.id } } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove from list")
                                        .buttonStyle(.plain).foregroundStyle(Palette.faint)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .opacity(m.dropTargeted ? 1 : 0)
            )
            .dropDestination(for: URL.self) { urls, _ in
                m.add(urls)
                return !urls.isEmpty
            } isTargeted: { m.dropTargeted = $0 }

            HStack {
                Text("On SSDs, macOS may keep old copies of blocks, so overwriting can't guarantee recovery is impossible. FileVault encryption is the real protection.")
                    .font(.caption).foregroundStyle(Palette.dim).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !m.items.isEmpty {
                    Button("Add more…") { m.choose() }.buttonStyle(.bordered)
                }
                Button { review.present(ReviewBuild.shred(m.items) { items in Task { await m.shred(items) } }) } label: {
                    Label(m.ready.isEmpty ? "Shred" : "Shred \(ByteText.string(m.total))", systemImage: "flame")
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.ready.isEmpty || m.working)
            }
        }
    }
}
