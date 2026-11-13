import AppKit
import CryptoKit
import Foundation
import Observation

/// One item Mac Cleaner moved to the Trash, so it can be put back.
struct TrashedItem: Codable, Identifiable, Sendable {
    var id = UUID()
    let original: String
    let trashed: String
    let size: Int64
    let date: Date
    let source: String
    /// false for the staging folder of the password step (system files can't be put back by the app).
    let restorable: Bool

    var name: String { URL(fileURLWithPath: original).lastPathComponent }
    var stillInTrash: Bool { FileManager.default.fileExists(atPath: trashed) }
}

/// Persisted log (~/Library/Application Support/Mac Cleaner/trash-log.json), shared by the window and the
/// CLI/MCP process. Written from background threads by AppEngine.trash. Each change goes through
/// `SharedFile`, so entries one process adds are never lost when the other one writes.
final class TrashLog: @unchecked Sendable {
    static let shared = TrashLog()
    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? {
            let dir = SafetyGuard.home.appendingPathComponent("Library/Application Support/Mac Cleaner")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("trash-log.json")
        }()
    }

    func record(original: String, trashed: String, size: Int64, source: String, restorable: Bool) {
        SharedFile.update(file) { (items: inout [TrashedItem]) in
            items.insert(TrashedItem(original: original, trashed: trashed, size: size, date: Date(),
                                     source: source, restorable: restorable), at: 0)
            if items.count > 2000 { items.removeLast(items.count - 2000) }
            return true
        }
    }

    /// Entries whose file is still in the Trash (drops the rest: emptied or put back elsewhere).
    func present() -> [TrashedItem] {
        SharedFile.update(file) { (items: inout [TrashedItem]) in
            let before = items.count
            items.removeAll { !$0.stillInTrash }
            return items.count != before
        }
    }

    func remove(_ id: UUID) {
        SharedFile.update(file) { (items: inout [TrashedItem]) in
            let before = items.count
            items.removeAll { $0.id == id }
            return items.count != before
        }
    }

    func clear() {
        SharedFile.update(file) { (items: inout [TrashedItem]) in items = []; return true }
    }
}

/// Trash operations without UI (used by the window, the MCP server and the self-test).
enum TrashOps {
    struct Status: Sendable {
        /// nil when the Trash can't be read (no Full Disk Access and Finder not allowed).
        var totalBytes: Int64?
        var itemCount: Int?
        var source: String
        var appItems: [TrashedItem]
        var appBytes: Int64 { appItems.reduce(0) { $0 + $1.size } }
    }

    static var trashURL: URL { SafetyGuard.home.appendingPathComponent(".Trash") }

    /// Exact with Full Disk Access; otherwise asks Finder for the item list (macOS asks once to allow
    /// controlling Finder) when `useFinder` is true; otherwise only the items Mac Cleaner trashed.
    static func status(useFinder: Bool) -> Status {
        let app = TrashLog.shared.present()
        let fm = FileManager.default
        if let kids = try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil) {
            let visible = kids.filter { $0.lastPathComponent != ".DS_Store" }
            return Status(totalBytes: visible.reduce(0) { $0 + Scanner.allocatedSize($1) }, itemCount: visible.count,
                          source: "exact", appItems: app)
        }
        if useFinder, let paths = finderTrashPaths() {
            return Status(totalBytes: paths.reduce(0) { $0 + Scanner.allocatedSize(URL(fileURLWithPath: $1)) },
                          itemCount: paths.count, source: "finder", appItems: app)
        }
        return Status(totalBytes: nil, itemCount: nil, source: "app-only", appItems: app)
    }

    /// POSIX paths of everything in your Trash, via Finder (nil if Finder access was denied).
    /// Every Trash folder of this user: the home Trash and, on each other mounted volume, .Trashes/<uid>.
    /// (Finder's "Empty Trash" empties all of them.) `problems` names volumes whose Trash couldn't be checked,
    /// so callers report incomplete coverage instead of treating those volumes as having an empty Trash.
    static func locationsReport(volumes: [URL]? = nil) -> (folders: [URL], problems: [String]) {
        var out = [trashURL], problems: [String] = []
        let vols: [URL]
        if let volumes { vols = volumes }
        else if let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) {
            vols = mounted.filter { $0.path != "/" && !$0.path.hasPrefix("/System/Volumes") }
        } else {
            return (out, ["The mounted volumes couldn't be listed, so only the home Trash was checked"])
        }
        for v in vols {
            let t = v.appendingPathComponent(".Trashes/\(getuid())")
            var st = stat()
            if lstat(t.path, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFDIR { out.append(t) }
                else { problems.append("\(v.path): its Trash isn't a folder") }
            } else if errno != ENOENT {
                problems.append("\(v.path): its Trash couldn't be checked (\(String(cString: strerror(errno))))")
            }
        }
        return (out, problems)
    }

    static func locations() -> [URL] { locationsReport().folders }

    /// The items directly inside these Trash folders, and the folders that couldn't be read (never treated
    /// as empty).
    static func listAll(in folders: [URL] = locations()) -> (items: [String], unreadable: [String]) {
        var items: [String] = [], unreadable: [String] = []
        for f in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: f.path) else {
                unreadable.append(f.path); continue
            }
            items += names.filter { $0 != ".DS_Store" }.map { f.appendingPathComponent($0).path }
        }
        return (items.sorted(), unreadable)
    }

    /// One entry of a Trash item as reviewed: the item itself (`rel` "") or anything inside it. Links are
    /// recorded as links, never followed.
    struct Entry: Equatable, Sendable {
        let rel: String
        let dev: Int32, ino: UInt64, type: UInt16
        let size: Int64, mtime: Int, mtimeNs: Int
        init(_ rel: String, _ st: stat) {
            self.rel = rel; dev = st.st_dev; ino = st.st_ino; type = st.st_mode & S_IFMT
            size = st.st_size; mtime = st.st_mtimespec.tv_sec; mtimeNs = st.st_mtimespec.tv_nsec
        }
        /// Still this object: same device, inode and type, and for a file the same size and time.
        func matches(_ st: stat) -> Bool {
            st.st_dev == dev && st.st_ino == ino && (st.st_mode & S_IFMT) == type
                && (type != S_IFREG || (st.st_size == size && st.st_mtimespec.tv_sec == mtime && st.st_mtimespec.tv_nsec == mtimeNs))
        }
    }

    /// What was reviewed for one Trash item: every entry in it, so a folder is approved with exactly its
    /// contents at the time. `entries` is nil when part of it couldn't be read; such an item is never deleted.
    struct Snapshot: Sendable {
        let path: String
        let entries: [Entry]?
        /// Changes when anything in the item changes (added, removed, replaced, edited, or a folder's own time).
        var digest: String {
            guard let entries else { return "\(path)|unreadable" }
            let text = entries.map { "\($0.rel)\u{0}\($0.dev):\($0.ino):\($0.type):\($0.size):\($0.mtime).\($0.mtimeNs)" }
                .joined(separator: "\n")
            return "\(path)|\(entries.count)|" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        var isFolder: Bool { entries?.first?.type == S_IFDIR }
    }

    static func snapshot(_ path: String) -> Snapshot {
        var out: [Entry] = []
        func walk(_ rel: String) -> Bool {
            let full = rel.isEmpty ? path : path + "/" + rel
            var st = stat()
            guard lstat(full, &st) == 0 else { return false }
            out.append(Entry(rel, st))
            guard (st.st_mode & S_IFMT) == S_IFDIR else { return true }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: full) else { return false }
            for n in names.sorted() where !walk(rel.isEmpty ? n : rel + "/" + n) { return false }
            return true
        }
        return Snapshot(path: path, entries: walk("") ? out : nil)
    }

    /// Permanently deletes exactly the approved Trash items and, inside folders, exactly the approved entries.
    /// Each item must sit directly in one of `trashFolders`, not be protected, and still match its snapshot
    /// entirely (otherwise it stays whole). Then entries are removed deepest first, each re-checked right
    /// before; files and links are unlinked (links are never followed) and folders are removed only when
    /// empty, so anything added inside after the review stays — and so does its folder. If a step fails, the
    /// rest of that item stays and the result says it was only partly deleted.
    /// `beforeDelete` is for the self-test only (runs after the snapshot check, before the first removal).
    static func deleteApproved(_ approved: [Snapshot], trashFolders: [String], beforeDelete: ((String) -> Void)? = nil)
        -> (deleted: [String], kept: [String], partial: [String]) {
        SizeCache.clear(); defer { SizeCache.clear() }
        let folders = Set(trashFolders.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var deleted: [String] = [], kept: [String] = [], partial: [String] = []
        for item in approved {
            let u = URL(fileURLWithPath: item.path)
            let name = u.lastPathComponent
            guard folders.contains(u.deletingLastPathComponent().standardizedFileURL.path) else {
                kept.append("\(name): not directly in a Trash folder"); continue
            }
            if let why = ProtectedPaths.reason(u) { kept.append("\(name): \(why)"); continue }
            guard let entries = item.entries else { kept.append("\(name): part of it couldn't be read, so it was kept"); continue }
            guard snapshot(item.path).entries == entries else { kept.append("\(name): changed since the preview"); continue }
            beforeDelete?(item.path)
            // Deepest first, so a folder comes after everything in it.
            let order = entries.sorted { $0.rel.split(separator: "/").count > $1.rel.split(separator: "/").count }
            var removed = 0
            var problem: String?
            for e in order {
                let p = e.rel.isEmpty ? item.path : item.path + "/" + e.rel
                var st = stat()
                guard lstat(p, &st) == 0, e.matches(st) else { problem = "\(e.rel.isEmpty ? name : e.rel) changed while deleting"; break }
                if e.type == S_IFDIR {
                    if rmdir(p) != 0 {
                        problem = errno == ENOTEMPTY ? "new files appeared in \(e.rel.isEmpty ? name : e.rel); they were kept"
                                                     : "\(e.rel.isEmpty ? name : e.rel): \(String(cString: strerror(errno)))"
                        break
                    }
                } else if unlink(p) != 0 {
                    problem = "\(e.rel.isEmpty ? name : e.rel): \(String(cString: strerror(errno)))"; break
                }
                removed += 1
            }
            if let problem {
                if removed == 0 { kept.append("\(name): \(problem)") }
                else { partial.append("\(name): partly deleted (\(removed) of \(entries.count) entries); \(problem)") }
            } else {
                deleted.append(item.path)
            }
        }
        return (deleted, kept, partial)
    }

    static func finderTrashPaths() -> [String]? {
        let js = """
        var t = Application("Finder").trash.items();
        t.map(function (i) { return decodeURIComponent(i.url().replace(/^file:\\/\\//, "")).replace(/\\/$/, ""); }).join("\\n");
        """
        let r = Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", js], timeout: 60)
        guard r.status == 0, let out = r.output else { return nil }
        return out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }

    /// Empties the Trash through Finder. Returns nil on success.
    static func empty() -> String? {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        let r = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 1800)
        if r.status == 0 {
            TrashLog.shared.clear()
            return nil
        }
        let out = r.output ?? ""
        if out.contains("-1743") || out.lowercased().contains("not authorized") {
            return "Mac Cleaner isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation."
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Moves an item back to where it came from. Returns nil on success.
    static func restore(_ item: TrashedItem) -> String? {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        guard item.restorable else { return "System files are restored by dragging them out of the Trash in Finder." }
        let fm = FileManager.default
        let from = URL(fileURLWithPath: item.trashed)
        guard fm.fileExists(atPath: from.path) else {
            TrashLog.shared.remove(item.id)
            return "No longer in the Trash."
        }
        var to = URL(fileURLWithPath: item.original)
        if fm.fileExists(atPath: to.path) {
            // Something new is there now: restore next to it instead of overwriting.
            let ext = to.pathExtension
            let base = to.deletingPathExtension().lastPathComponent
            var n = 2
            repeat {
                to = to.deletingLastPathComponent().appendingPathComponent("\(base) (restored\(n > 2 ? " \(n - 1)" : ""))")
                    .appendingPathExtension(ext)
                n += 1
            } while fm.fileExists(atPath: to.path)
        }
        do {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: to)
            TrashLog.shared.remove(item.id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Window model

@MainActor @Observable
final class TrashModel {
    var status = TrashOps.Status(totalBytes: nil, itemCount: nil, source: "app-only", appItems: [])
    var busy = false
    var confirmingEmpty = false
    var showPutBack = false
    var message: (text: String, isError: Bool)?
    /// Set after the user allowed Finder once; then sizes refresh through Finder automatically.
    private var finderAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: "trashFinderAllowed") }
        set { UserDefaults.standard.set(newValue, forKey: "trashFinderAllowed") }
    }

    var displayBytes: Int64 { status.totalBytes ?? status.appBytes }
    var isExact: Bool { status.totalBytes != nil }

    func refresh(askFinder: Bool = false) async {
        let useFinder = askFinder || finderAllowed
        let s = await Task.detached(priority: .utility) { TrashOps.status(useFinder: useFinder) }.value
        status = s
        if askFinder { finderAllowed = s.source == "finder" || s.source == "exact" }
    }

    func empty() async {
        busy = true
        let before = Scanner.freeBytes()
        let expected = displayBytes
        let err = await Task.detached { TrashOps.empty() }.value
        if let err {
            message = (err, true)
        } else {
            try? await Task.sleep(for: .seconds(1))
            let measured = max(0, Scanner.freeBytes() - before)
            let size = expected > 0 ? expected : measured
            HistoryStore.shared.add("Trash Emptied", bytes: size, symbol: "trash.slash", outcome: .deleted, measuredFreeChange: measured)
            message = ("Trash emptied (\(ByteText.string(size))). Free space went up by \(ByteText.string(measured)) so far; macOS can take a moment to update it.", false)
            finderAllowed = true
        }
        await refresh()
        busy = false
    }

    func putBack(_ item: TrashedItem) async {
        busy = true
        if let err = await Task.detached(operation: { TrashOps.restore(item) }).value {
            message = ("\(item.name): \(err)", true)
        } else {
            message = ("Put back \(item.name) to \(Scanner.tilde(URL(fileURLWithPath: item.original).deletingLastPathComponent())).", false)
        }
        await refresh()
        busy = false
    }
}
