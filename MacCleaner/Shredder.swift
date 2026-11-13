import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ShredEngine {
    struct Result {
        /// The whole item is gone.
        var removed = false
        /// Files that were overwritten, flushed and then deleted.
        var overwritten = 0
        /// Files and folders left in place after a step failed, with why. Nothing is ever deleted
        /// without its overwrite succeeding first.
        var kept: [String] = []
        /// Set when nothing was changed.
        var refused: String?
    }

    /// Largest file the Shredder overwrites. Bigger items are refused before anything is changed.
    static let maxFileSize: off_t = 4_000_000_000

    /// One entry of a planned shred, in the order it is processed (contents before their folder).
    enum Entry {
        case file(URL, stat)
        case link(URL, stat)
        case folder(URL, stat)

        var url: URL {
            switch self { case .file(let u, _), .link(let u, _), .folder(let u, _): return u }
        }
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

    private static let lockedFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    /// Lists everything in an item without following links, and refuses the item (nothing changed) if any
    /// part of it can't be shredded safely: an unreadable folder (its files would be deleted unseen), a hard
    /// link (overwriting it would erase the other copy), a locked or unwritable file, a file over 4 GB,
    /// a socket/device/pipe, or a link as the item itself.
    static func plan(_ url: URL) -> Swift.Result<[Entry], ShredRefusal> {
        var out: [Entry] = []
        func visit(_ u: URL, isRoot: Bool) -> String? {
            var st = stat()
            guard lstat(u.path, &st) == 0 else { return "\(u.lastPathComponent) can't be read" }
            if st.st_flags & lockedFlags != 0 { return "\(u.lastPathComponent) is locked" }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if st.st_nlink > 1 { return "\(u.lastPathComponent) is a hard link to a file elsewhere, which shredding would erase too" }
                if st.st_size > maxFileSize { return "\(u.lastPathComponent) is larger than 4 GB" }
                if access(u.path, W_OK) != 0 { return "\(u.lastPathComponent) can't be written (locked or not yours)" }
                out.append(.file(u, st))
            case S_IFLNK:
                if isRoot { return "This is a link. Shred the original item instead" }
                out.append(.link(u, st))             // removed as a link; its target is never opened
            case S_IFDIR:
                if access(u.path, R_OK | W_OK | X_OK) != 0 { return "The folder \(u.lastPathComponent) can't be read or changed" }
                let names: [String]
                do { names = try FileManager.default.contentsOfDirectory(atPath: u.path) }
                catch { return "The folder \(u.lastPathComponent) can't be read" }
                for n in names.sorted() {
                    if let why = visit(u.appendingPathComponent(n), isRoot: false) { return why }
                }
                out.append(.folder(u, st))
            default:
                return "\(u.lastPathComponent) is not a regular file or folder"
            }
            return nil
        }
        if let why = visit(url, isRoot: true) { return .failure(ShredRefusal(why)) }
        return .success(out)
    }

    struct ShredRefusal: Error { let reason: String; init(_ r: String) { reason = r } }

    /// True when `url` is still the same file system object that was planned.
    static func same(_ url: URL, _ planned: stat) -> Bool {
        var now = stat()
        return lstat(url.path, &now) == 0 && now.st_dev == planned.st_dev && now.st_ino == planned.st_ino
            && (now.st_mode & S_IFMT) == (planned.st_mode & S_IFMT)
    }

    /// Overwrites one planned regular file with zeros and flushes it to disk. nil when done.
    /// The file must still be the planned one (same device and inode, still one link, not grown past 4 GB).
    static func overwrite(_ url: URL, planned: stat) -> String? {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        defer { close(fd) }
        var now = stat()
        guard fstat(fd, &now) == 0, now.st_dev == planned.st_dev, now.st_ino == planned.st_ino,
              (now.st_mode & S_IFMT) == S_IFREG, now.st_nlink == 1 else { return "it changed while shredding" }
        guard now.st_size <= maxFileSize else { return "it grew larger than 4 GB" }
        let chunk = [UInt8](repeating: 0, count: 1 << 20)
        var offset: off_t = 0
        while offset < now.st_size {
            let n = Int(min(off_t(chunk.count), now.st_size - offset))
            let written = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, n, offset) }
            guard written == n else { return "writing failed" }
            offset += off_t(n)
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { return "couldn't flush to disk" }
        return nil
    }

    /// Checks the item again, plans it (refusing it untouched if any part can't be shredded), then for each
    /// file: overwrite → flush → check it is still the same file → delete. Links are deleted as links and
    /// folders only once empty. At the first failure it stops: the failed file and everything not yet
    /// processed stay where they are, and are listed in `kept`.
    /// `overwriter` is replaceable only so the self-test can simulate write and flush failures.
    static func shred(_ url: URL, overwriter: (URL, stat) -> String? = { overwrite($0, planned: $1) }) -> Result {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        var r = Result()
        if let why = reason(url) { r.refused = why; return r }
        let entries: [Entry]
        switch plan(url) {
        case .failure(let f): r.refused = f.reason + ". Nothing was changed."; return r
        case .success(let e): entries = e
        }
        for (i, e) in entries.enumerated() {
            var problem: String?
            switch e {
            case .file(let u, let st):
                if let why = overwriter(u, st) { problem = why }
                else if !same(u, st) { problem = "it changed while shredding" }
                else if unlink(u.path) != 0 { problem = String(cString: strerror(errno)) }
                else { r.overwritten += 1 }
            case .link(let u, let st):
                if !same(u, st) { problem = "it changed while shredding" }
                else if unlink(u.path) != 0 { problem = String(cString: strerror(errno)) }
            case .folder(let u, let st):
                if !same(u, st) { problem = "it changed while shredding" }
                else if rmdir(u.path) != 0 { problem = errno == ENOTEMPTY ? "new files appeared in it" : String(cString: strerror(errno)) }
            }
            if let problem {
                r.kept.append("\(e.url.lastPathComponent): \(problem)")
                let rest = entries.count - i - 1
                if rest > 0 { r.kept.append("\(rest) more item(s) not processed after that") }
                return r
            }
        }
        r.removed = true
        return r
    }
}

@MainActor @Observable
final class ShredderModel {
    struct Item: Identifiable { let id: String; let url: URL; let size: Int64; let blocked: String? }

    var items: [Item] = []
    var confirming = false
    var working = false
    var message: (text: String, isError: Bool)?
    var dropTargeted = false

    var ready: [Item] { items.filter { $0.blocked == nil } }
    var total: Int64 { ready.reduce(0) { $0 + $1.size } }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(where: { $0.url == u }) {
            items.append(Item(id: u.path, url: u, size: Scanner.allocatedSize(u), blocked: ShredEngine.reason(u)))
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
            let r = await Task.detached(operation: { ShredEngine.shred(u) }).value
            if let why = r.refused { problems.append("\(u.lastPathComponent): \(why)"); continue }
            if r.removed {
                bytes += i.size
                items.removeAll { $0.id == i.id }
            } else {
                // Stopped part-way: what was overwritten is gone, the rest is untouched. Re-measure what's left.
                partial += 1
                let left = Scanner.allocatedSize(u)
                bytes += max(0, i.size - left)
                if let at = items.firstIndex(where: { $0.id == i.id }) {
                    items[at] = Item(id: i.id, url: u, size: left, blocked: ShredEngine.reason(u))
                }
                problems.append("\(u.lastPathComponent): stopped after \(r.overwritten) file(s); the rest was kept (\(r.kept[0]))")
            }
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
