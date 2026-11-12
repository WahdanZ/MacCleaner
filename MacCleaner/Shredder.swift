import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ShredEngine {
    struct Result {
        var removed = false
        var overwritten = 0
        /// Files that were deleted without being overwritten, with why.
        var notOverwritten: [String] = []
        /// Set when nothing was changed.
        var refused: String?
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

    /// Regular files in an item (the item itself, or everything inside a folder), not following links.
    static func files(in url: URL) -> [(url: URL, info: stat)] {
        var out: [(url: URL, info: stat)] = []
        func add(_ u: URL) {
            var st = stat()
            if lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { out.append((u, st)) }
        }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return [] }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [],
                                                   errorHandler: { _, _ in true })
            while let f = e?.nextObject() as? URL { add(f) }
        } else {
            add(url)
        }
        return out
    }

    /// Overwrites one regular file with zeros (up to 4 GB) and flushes it to disk. nil when done.
    static func overwrite(_ url: URL) -> String? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return "can't be read" }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard st.st_nlink == 1 else { return "it's a hard link" }
        guard st.st_size > 0 else { return nil }
        guard st.st_size <= 4_000_000_000 else { return "larger than 4 GB" }
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        defer { close(fd) }
        var now = stat()
        guard fstat(fd, &now) == 0, now.st_ino == st.st_ino, now.st_nlink == 1 else { return "it changed while shredding" }
        let chunk = [UInt8](repeating: 0, count: 1 << 20)
        var offset: off_t = 0
        while offset < st.st_size {
            let n = Int(min(off_t(chunk.count), st.st_size - offset))
            let written = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, n, offset) }
            guard written == n else { return "writing failed" }
            offset += off_t(n)
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { return "couldn't flush to disk" }
        return nil
    }

    /// Checks the item again, refuses it untouched if any file inside is a hard link (overwriting it
    /// would erase the other copy too) or can't be written, then overwrites every file and deletes it.
    static func shred(_ url: URL) -> Result {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        var r = Result()
        if let why = reason(url) { r.refused = why; return r }
        let list = files(in: url)
        let links = list.filter { $0.info.st_nlink > 1 }
        if !links.isEmpty {
            r.refused = "\(links.count) file(s) inside are hard links to files elsewhere, which shredding would erase too. Nothing was changed."
            return r
        }
        let locked = list.filter { access($0.url.path, W_OK) != 0 }
        if !locked.isEmpty {
            r.refused = "\(locked.count) file(s) inside can't be written (locked or not yours). Nothing was changed."
            return r
        }
        for f in list {
            if let why = overwrite(f.url) { r.notOverwritten.append("\(f.url.lastPathComponent): \(why)") }
            else { r.overwritten += 1 }
        }
        do { try FileManager.default.removeItem(at: url); r.removed = true }
        catch { r.refused = error.localizedDescription }
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

    func shred() async {
        let list = ready
        guard !list.isEmpty else { return }
        working = true
        var bytes: Int64 = 0, problems: [String] = [], partial = 0
        for i in list {
            let u = i.url
            let r = await Task.detached(operation: { ShredEngine.shred(u) }).value
            if let why = r.refused { problems.append("\(u.lastPathComponent): \(why)"); continue }
            bytes += i.size
            items.removeAll { $0.id == i.id }
            if !r.notOverwritten.isEmpty {
                partial += r.notOverwritten.count
                problems.append("\(u.lastPathComponent): deleted, but \(r.notOverwritten.count) file(s) weren't overwritten (\(r.notOverwritten[0]))")
            }
        }
        if bytes > 0 { HistoryStore.shared.add("Files Shredded", bytes: bytes, symbol: "printer", outcome: .deleted) }
        let done = partial == 0 ? "Overwrote and deleted \(ByteText.string(bytes))." : "Deleted \(ByteText.string(bytes))."
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
                                    Button { m.items.removeAll { $0.id == i.id } } label: { Image(systemName: "xmark.circle.fill") }
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
                Button { review.present(ReviewBuild.shred(m.items) { Task { await m.shred() } }) } label: {
                    Label(m.ready.isEmpty ? "Shred" : "Shred \(ByteText.string(m.total))", systemImage: "flame")
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.ready.isEmpty || m.working)
            }
        }
    }
}
