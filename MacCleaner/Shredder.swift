import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Overwrites files with zeros, flushes them to disk, then deletes them.
///
/// Safety rules, re-checked right before anything is written:
/// - the same guards as Move to Trash (protected paths, account and system folders), on the
///   path as given and on its on-disk spelling (case and symlinked parents resolved);
/// - only inside your home folder (shredding is permanent, so /Applications is left to Uninstall);
/// - symlinks are never followed, and a file with more than one hard link is refused, because
///   overwriting it would also wipe the other names that share its data;
/// - a file is opened with O_NOFOLLOW and must still be the file that was checked (device + inode);
/// - any failed write or flush is an error: that file is not deleted and not counted as shredded.
///
/// On SSDs and APFS, macOS may keep old copies of blocks elsewhere, so the overwrite is best effort.
enum ShredEngine {
    /// Identity of a file on disk, taken with lstat (symlinks are not followed).
    struct FileID: Equatable, Sendable {
        let dev: Int32
        let ino: UInt64
        init(_ st: stat) { dev = st.st_dev; ino = st.st_ino }
    }

    /// `SF_DATALESS`: an iCloud or File Provider placeholder whose data isn't on this Mac.
    private static let datalessFlag: UInt32 = 0x4000_0000

    static func identity(_ url: URL) -> FileID? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? FileID(st) : nil
    }

    /// nil when the item may be shredded; otherwise why not. Used when it is added, in the
    /// review, and again by `shred` right before it writes anything. With `expected`, the item
    /// must still be the one that was added.
    static func reason(_ url: URL, expected: FileID? = nil) -> String? {
        let canonical = canonicalURL(url)
        if let why = TrashGuard.reason(url) ?? TrashGuard.reason(canonical) { return why }
        let home = SafetyGuard.home.path
        guard SafetyGuard.isInside(url.standardizedFileURL.path, home),
              SafetyGuard.isInside(canonical.path, home) else { return "Outside your home folder" }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return "Can't read it: \(errorText())" }
        if let expected, FileID(st) != expected { return "Changed since you added it. Remove it and add it again." }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return "Symbolic link: not followed, so the item it points to is left alone"
        case S_IFREG: return fileReason(st)
        case S_IFDIR: return nil   // Every file inside is checked before anything is written.
        default: return "Not a regular file or folder"
        }
    }

    /// Overwrites every file (folders: everything inside), flushes, then deletes.
    /// Returns nil only when every file was overwritten and the item is gone.
    static func shred(_ url: URL, expected: FileID?) -> String? {
        if let why = reason(url, expected: expected) { return why }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return "Can't read it: \(errorText())" }
        let id = FileID(st)
        if let expected, id != expected { return "Changed since you added it. Remove it and add it again." }
        guard st.st_mode & S_IFMT == S_IFDIR else { return shredFile(url, id: id) }

        // Folder: check every file first, so a refused file stops the folder before any write.
        let files: [(url: URL, id: FileID)]
        switch plan(url) {
        case .failure(let e): return e.message
        case .success(let f): files = f
        }
        for f in files {
            if let e = shredFile(f.url, id: f.id) {
                let rel = String(f.url.path.dropFirst(url.path.count + 1))
                return "\(rel): \(e). The folder was kept; files before this one were already shredded."
            }
        }
        // Only folders, symlinks (never followed) and empty special files are left.
        guard identity(url) == id else { return "Changed while shredding; the folder was kept" }
        do { try FileManager.default.removeItem(at: url); return nil }
        catch { return "Files were shredded, but the folder couldn't be removed: \(error.localizedDescription)" }
    }

    // MARK: Internals

    private struct PlanError: Error { let message: String }

    private static func errorText() -> String { String(cString: strerror(errno)) }

    /// The path with symlinked parents resolved and the last name spelled as it is on disk,
    /// so `~/documents` or `~/library/keychains/x` meet the same rules as their real spelling.
    private static func canonicalURL(_ url: URL) -> URL {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let name = (try? url.resourceValues(forKeys: [.nameKey]))?.name ?? url.lastPathComponent
        return parent.appendingPathComponent(name).standardizedFileURL
    }

    private static func fileReason(_ st: stat) -> String? {
        if st.st_nlink > 1 {
            return "Hard link: \(st.st_nlink) names share this file, and overwriting it would wipe the others too"
        }
        if st.st_flags & datalessFlag != 0 { return "Not downloaded to this Mac (iCloud). Download it first." }
        return nil
    }

    /// Every regular file inside a folder, refusing the whole folder if any one can't be shredded.
    private static func plan(_ folder: URL) -> Result<[(url: URL, id: FileID)], PlanError> {
        var problem: String?
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [],
                                               errorHandler: { u, err in
            problem = problem ?? "\(u.lastPathComponent): can't be read (\(err.localizedDescription))"
            return false
        })
        var files: [(url: URL, id: FileID)] = []
        while let u = e?.nextObject() as? URL {
            var st = stat()
            guard lstat(u.path, &st) == 0 else { problem = "\(u.lastPathComponent): can't be read"; break }
            // The enumerator doesn't descend into symlinks; the link itself is removed, its target is not touched.
            guard st.st_mode & S_IFMT == S_IFREG else { continue }
            if let why = fileReason(st) {
                let rel = String(u.path.dropFirst(folder.path.count + 1))
                problem = "Contains \(rel). \(why). Nothing was shredded."
                break
            }
            files.append((u, FileID(st)))
        }
        if let problem { return .failure(PlanError(message: problem)) }
        return .success(files)
    }

    /// Overwrites one regular file with zeros, flushes it to the disk, then deletes that same file.
    private static func shredFile(_ url: URL, id: FileID) -> String? {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return "Couldn't open it to overwrite (\(errorText())); not deleted" }
        var st = stat()
        guard fstat(fd, &st) == 0, FileID(st) == id, st.st_mode & S_IFMT == S_IFREG else {
            close(fd); return "Changed since it was checked; not touched"
        }
        if let why = fileReason(st) { close(fd); return why }

        var failure: String?
        let chunk = [UInt8](repeating: 0, count: 1 << 20)
        var offset: off_t = 0
        while offset < st.st_size {
            let n = Int(min(off_t(chunk.count), st.st_size - offset))
            let written = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, n, offset) }
            if written < 0 && errno == EINTR { continue }
            if written <= 0 {
                failure = "Overwrite failed at byte \(offset) (\(written < 0 ? errorText() : "nothing written"))"
                break
            }
            offset += off_t(written)
        }
        // F_FULLFSYNC asks the drive to write its cache too; fall back to fsync where it isn't supported.
        if failure == nil && fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 {
            failure = "Couldn't flush the overwrite to disk (\(errorText()))"
        }
        if close(fd) != 0 && failure == nil { failure = "Couldn't finish the overwrite (\(errorText()))" }
        if let failure { return failure + "; not deleted" }

        guard identity(url) == id else { return "Changed during the overwrite; not deleted" }
        guard unlink(url.path) == 0 else { return "Overwritten, but couldn't delete it (\(errorText()))" }
        return nil
    }
}

@MainActor @Observable
final class ShredderModel {
    struct Item: Identifiable {
        let id: String
        let url: URL
        let size: Int64
        /// Identity when added; shredding refuses the item if the path now names a different file.
        let identity: ShredEngine.FileID?
        var blocked: String?
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
            items.append(Item(id: u.path, url: u, size: Scanner.allocatedSize(u),
                              identity: ShredEngine.identity(u), blocked: ShredEngine.reason(u)))
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
        var bytes: Int64 = 0, errors: [String] = []
        for i in list {
            let u = i.url, expected = i.identity
            // ShredEngine re-checks every guard right before it writes.
            if let e = await Task.detached(operation: { ShredEngine.shred(u, expected: expected) }).value {
                errors.append("\(u.lastPathComponent): \(e)")
                if let k = items.firstIndex(where: { $0.id == i.id }) { items[k].blocked = "Not shredded: \(e)" }
            } else {
                bytes += i.size
                items.removeAll { $0.id == i.id }
            }
        }
        if bytes > 0 {
            HistoryStore.shared.add("Files Overwritten and Deleted", bytes: bytes, symbol: "printer", outcome: .deleted)
        }
        let done = "Overwrote and deleted \(ByteText.string(bytes)) (best effort on SSDs)."
        message = errors.isEmpty ? (done, false)
                                 : ("\(done) \(errors.count) not shredded: \(errors.prefix(2).joined(separator: "; "))", true)
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
                        Text("Shredded files are overwritten, skip the Trash and can't be put back.")
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
                Text("Files are overwritten with zeros, then deleted. On SSDs and APFS, macOS can keep old copies of blocks, so this can't guarantee the old data is gone. FileVault encryption is the real protection.")
                    .font(.caption).foregroundStyle(Palette.dim).lineLimit(3)
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
