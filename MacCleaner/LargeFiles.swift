import AppKit
import Observation
import SwiftUI

struct BigFile: Identifiable, Sendable {
    let id: String
    let url: URL
    let size: Int64
    let modified: Date?
    let lastOpened: Date?

    var lastTouched: Date? { [modified, lastOpened].compactMap { $0 }.max() }
}

enum LargeFileScanner {
    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// Files in your home folder (skipping ~/Library, hidden files and app bundles) that are at least
    /// `minLarge` big, or at least `minOld` big and untouched since `oldBefore`.
    ///
    /// Same rules as a FileManager enumerator over the home folder with `.skipsHiddenFiles` and
    /// `.skipsPackageDescendants` (minus ~/Library), but each folder is one getattrlistbulk batch and a
    /// `WalkPool` job, so big folders are read by several threads at once.
    static func scan(minLarge: Int64, minOld: Int64, oldBefore: Date, cancel: Cancel,
                     progress: @escaping @Sendable (Int) -> Void) -> [BigFile] {
        let home = SafetyGuard.home.path
        let library = home + "/Library"
        let floor = min(minLarge, minOld)
        let found = Found(progress)

        func visit(_ dir: String, _ group: WalkPool.Group) {
            if cancel.isSet { return }
            var out: [BigFile] = []
            var seen = 0
            // Only folders and files over the size floor get a name string, URL or dates.
            DirSize.forEachEntry(atPath: dir) { k in
                if k.isHidden { return }
                seen += 1
                if k.isDirectory {
                    let path = dir + "/" + k.nameString
                    if path != library && !isPackage(path) { group.add { visit(path, group) } }
                    return
                }
                guard k.isRegularFile, k.size >= floor else { return }
                let path = dir + "/" + k.nameString
                let f = BigFile(id: path, url: DirSize.fileURL(path, isDirectory: false), size: k.size,
                                modified: k.modifiedDate, lastOpened: k.accessedDate)
                let isLarge = k.size >= minLarge
                let isOld = k.size >= minOld && (f.lastTouched ?? .distantPast) < oldBefore
                if isLarge || isOld { out.append(f) }
            }
            found.add(out, seen: seen)
        }

        WalkPool.shared.run { group in visit(home, group) }
        if cancel.isSet { return [] }
        progress(found.seen)
        return found.files.sorted { ($0.size, $1.id) > ($1.size, $0.id) }
    }

    /// Apps, photo libraries and other bundles: listed as one item, never opened (like `.skipsPackageDescendants`).
    private static func isPackage(_ path: String) -> Bool {
        (try? DirSize.fileURL(path, isDirectory: true).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// Results and the files-seen count, shared by the walker threads. Progress at most ~8 times a second.
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [BigFile] = []
        private var n = 0
        private var last = Date.distantPast
        private let progress: @Sendable (Int) -> Void
        init(_ progress: @escaping @Sendable (Int) -> Void) { self.progress = progress }

        var seen: Int { lock.lock(); defer { lock.unlock() }; return n }
        var files: [BigFile] { lock.lock(); defer { lock.unlock() }; return list }

        func add(_ files: [BigFile], seen k: Int) {
            lock.lock()
            list += files
            n += k
            var report: Int?
            let now = Date()
            if now.timeIntervalSince(last) > 0.12 { last = now; report = n }
            lock.unlock()
            if let report { progress(report) }
        }
    }
}

@MainActor @Observable
final class LargeFilesModel {
    enum Phase { case idle, scanning, done, trashing }
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", large = "Large", old = "Old"
        var id: String { rawValue }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", date = "Last used", name = "Name"
        var id: String { rawValue }
    }

    var phase: Phase = .idle
    var files: [BigFile] = []
    var minLargeMB = 500
    var oldMonths = 12
    var filter: Filter = .all
    var sort: Sort = .size
    var marked: Set<String> = []
    var seen = 0
    var confirming = false
    var message: (text: String, isError: Bool)?
    private var cancelFlag: LargeFileScanner.Cancel?

    var oldBefore: Date { Calendar.current.date(byAdding: .month, value: -oldMonths, to: Date()) ?? Date() }

    func isOld(_ f: BigFile) -> Bool { (f.lastTouched ?? .distantPast) < oldBefore }
    func isLarge(_ f: BigFile) -> Bool { f.size >= Int64(minLargeMB) * 1_000_000 }

    var visible: [BigFile] {
        var list = files.filter {
            switch filter {
            case .all: return isLarge($0) || isOld($0)
            case .large: return isLarge($0)
            case .old: return isOld($0)
            }
        }
        switch sort {
        case .size: list.sort { $0.size > $1.size }
        case .date: list.sort { ($0.lastTouched ?? .distantPast) < ($1.lastTouched ?? .distantPast) }
        case .name: list.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        }
        return list
    }

    var markedFiles: [BigFile] { files.filter { marked.contains($0.id) } }
    var markedBytes: Int64 { markedFiles.reduce(0) { $0 + $1.size } }

    func scan() {
        guard phase != .scanning else { return }
        phase = .scanning
        files = []; marked = []; seen = 0; message = nil
        let cancel = LargeFileScanner.Cancel()
        cancelFlag = cancel
        // Collect from 50 MB so the size filter can change without rescanning.
        let minLarge: Int64 = 50_000_000, minOld: Int64 = 10_000_000
        let before = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LargeFileScanner.scan(minLarge: minLarge, minOld: minOld, oldBefore: before, cancel: cancel) { n in
                    Task { @MainActor [weak self] in self?.seen = n }
                }
            }.value
            if cancel.isSet { phase = .idle; return }
            files = result
            phase = .done
        }
    }

    func cancel() { cancelFlag?.set() }

    func toggle(_ f: BigFile) {
        guard TrashGuard.canTrash(f.url) else { return }
        if marked.contains(f.id) { marked.remove(f.id) } else { marked.insert(f.id) }
    }

    func trashMarked() async {
        let items = markedFiles
        guard !items.isEmpty else { return }
        phase = .trashing
        var bytes: Int64 = 0, errors: [String] = []
        for f in items {
            if let why = TrashGuard.reason(f.url) { errors.append("\(f.url.lastPathComponent): \(why)"); continue }
            let u = f.url
            if let e = await Task.detached(operation: { AppEngine.trash(u, size: f.size, source: "Large & Old Files") }).value {
                errors.append("\(f.url.lastPathComponent): \(e)")
            } else {
                bytes += f.size
                files.removeAll { $0.id == f.id }
            }
        }
        marked = []
        HistoryStore.shared.add("Large & Old Files Moved to Trash", bytes: bytes, symbol: "folder", outcome: .trashed)
        message = errors.isEmpty
            ? ("Moved \(ByteText.string(bytes)) to the Trash. Empty the Trash to free it.", false)
            : ("Moved \(ByteText.string(bytes)). \(errors.count) problem(s): \(errors.prefix(2).joined(separator: "; "))", true)
        phase = .done
    }
}

struct LargeFilesView: View {
    @Environment(LargeFilesModel.self) private var m
    @Environment(ReviewCenter.self) private var review

    var body: some View {
        @Bindable var m = m
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                // Filters scroll sideways in narrow windows instead of widening the window.
                ScrollView(.horizontal) {
                HStack(spacing: 12) {
                Picker("", selection: $m.filter) { ForEach(LargeFilesModel.Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Large from", selection: $m.minLargeMB) {
                    Text("50 MB").tag(50); Text("100 MB").tag(100); Text("500 MB").tag(500); Text("1 GB").tag(1000)
                }
                .fixedSize()
                Picker("Old after", selection: $m.oldMonths) {
                    Text("6 months").tag(6); Text("1 year").tag(12); Text("2 years").tag(24)
                }
                .fixedSize()
                Picker("Sort", selection: $m.sort) { ForEach(LargeFilesModel.Sort.allCases) { Text($0.rawValue).tag($0) } }
                    .fixedSize()
                }
                }
                .scrollIndicators(.never)
                Spacer(minLength: Space.s)
                if m.phase == .scanning {
                    Button("Cancel") { m.cancel() }.buttonStyle(.bordered)
                } else {
                    Button { m.scan() } label: { Label(m.phase == .idle ? "Scan" : "Rescan", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                }
            }

            Group {
                switch m.phase {
                case .idle:
                    EmptyState(symbol: "folder", title: "Find large and forgotten files",
                               text: "Looks through your home folder (Documents, Downloads, Desktop, Movies, projects…) for big files and files you haven't touched in a long time. Nothing is removed until you choose.")
                case .scanning:
                    WorkingState(symbol: "doc.text.magnifyingglass", title: "Looking for large and old files…",
                                 detail: "checked \(m.seen.formatted()) files")
                case .done, .trashing:
                    if m.visible.isEmpty {
                        EmptyState(symbol: "checkmark.seal", title: "Nothing found", text: "No files match these filters.")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(m.visible) { f in BigFileRow(file: f) }
                            }
                            .padding(10)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()

            HStack {
                if let msg = m.message {
                    Label(msg.text, systemImage: msg.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(msg.isError ? Palette.warn : Palette.success)
                } else {
                    Text(m.phase == .done ? "\(m.visible.count) files · \(ByteText.string(m.visible.reduce(0) { $0 + $1.size }))" : " ")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                }
                Spacer()
                Button { review.present(ReviewBuild.largeFiles(m) { Task { await m.trashMarked() } }) } label: {
                    Label(m.marked.isEmpty ? "Move to Trash" : "Move \(ByteText.string(m.markedBytes)) to Trash", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.marked.isEmpty || m.phase != .done)
            }
        }
    }
}

private struct BigFileRow: View {
    @Environment(LargeFilesModel.self) private var m
    let file: BigFile
    @State private var hover = false

    var body: some View {
        let canTrash = TrashGuard.canTrash(file.url)
        HStack(spacing: 12) {
            if ProtectedPaths.isBlocked(file.url) {
                Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(Palette.accent).frame(width: 18)
            } else {
                Button { m.toggle(file) } label: { CheckSquare(on: m.marked.contains(file.id), color: Palette.accent) }
                    .buttonStyle(.plain).disabled(!canTrash).opacity(canTrash ? 1 : 0.3)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if m.isOld(file) { Tag(text: "OLD", color: Palette.warn) }
                    if m.isLarge(file) { Tag(text: "LARGE", color: Palette.accent) }
                }
                Text(Scanner.tilde(file.url.deletingLastPathComponent())).font(.system(size: 11)).foregroundStyle(Palette.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(file.lastTouched.map { "Used " + $0.formatted(.relative(presentation: .named)) } ?? "Never used")
                .font(.system(size: 11)).foregroundStyle(Palette.dim)
            Text(ByteText.string(file.size)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Palette.dim).help("Reveal in Finder")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hover ? Palette.fg.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { m.toggle(file) }
        .onHover { hover = $0 }
        .help(TrashGuard.reason(file.url).map { "\(file.url.path)\n🔒 \($0)" } ?? file.url.path)
        .contextMenu {
            Button("Protect this file") { ProtectedPaths.add([file.url]); m.marked.remove(file.id) }
            Button("Protect its folder") { ProtectedPaths.add([file.url.deletingLastPathComponent()]); m.marked.remove(file.id) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            IconTile(symbol: symbol, color: Palette.accent, size: 64)
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
