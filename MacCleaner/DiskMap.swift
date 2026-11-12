import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// One folder or file in the disk tree. Built off the main thread, then only touched on main.
final class DiskNode: Identifiable, @unchecked Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    var isAggregate = false
    var unreadable = false
    var size: Int64 = 0
    var fileCount = 0
    var modified: Date?
    var children: [DiskNode] = []
    weak var parent: DiskNode?
    /// Files under 1 MB directly in this folder, shown as one block (set while scanning).
    fileprivate var smallBytes: Int64 = 0
    fileprivate var smallCount = 0

    init(url: URL, name: String, isDirectory: Bool, id: String? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.id = id ?? url.path
    }

    var canOpen: Bool { isDirectory && !isAggregate && !children.isEmpty }
    var tildePath: String { Scanner.tilde(url) }

    enum Kind { case folder, app, video, image, audio, archive, document, code, other, small }

    var kind: Kind {
        if isAggregate { return .small }
        if url.pathExtension == "app" { return .app }
        if isDirectory { return .folder }
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .archive) || t.conforms(to: .diskImage) { return .archive }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) { return .code }
        if t.conforms(to: .content) { return .document }
        return .other
    }
}

enum DiskScanner {
    struct Progress: Sendable {
        var files = 0
        var bytes: Int64 = 0
        var current = ""
    }

    /// Shared, thread-safe progress + cancel flag for the parallel walk.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var p = Progress()
        private var last = Date.distantPast
        private var _cancelled = false
        let report: @Sendable (Progress) -> Void

        init(report: @escaping @Sendable (Progress) -> Void) { self.report = report }

        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

        func add(files: Int, bytes: Int64, current: String) {
            lock.lock()
            p.files += files
            p.bytes += bytes
            var snap: Progress?
            let now = Date()
            if now.timeIntervalSince(last) > 0.12 {
                last = now
                p.current = current
                snap = p
            }
            lock.unlock()
            if let snap { report(snap) }
        }
    }

    /// Files smaller than this are folded into one "N small files" block per folder.
    static let minFile: Int64 = 1_000_000
    /// Skipped when scanning the whole disk: other volumes, the firmlinked data volume (would double count), devices.
    static let skipPaths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/cores"]
    /// iCloud / File Provider roots. Their direct children are measured with a time limit,
    /// because a stale provider (e.g. a removed app's iCloud container) can block reads forever.
    static let cloudRoots: Set<String> = [
        SafetyGuard.home.appendingPathComponent("Library/Mobile Documents").path,
        SafetyGuard.home.appendingPathComponent("Library/CloudStorage").path,
    ]
    static let cloudTimeout: TimeInterval = 10

    static func scan(root: URL, counter: Counter) -> DiskNode {
        let node = DiskNode(url: root, name: root.path == "/" ? "Macintosh HD" : root.lastPathComponent, isDirectory: true)
        // Every folder is a WalkPool job, so all its threads share the work whatever shape the tree has.
        WalkPool.shared.run { group in visit(node, group, counter) }
        total(node)
        return node
    }

    private static func visit(_ node: DiskNode, _ group: WalkPool.Group, _ counter: Counter) {
        let dirs = list(node, counter)
        if cloudRoots.contains(node.url.path) {
            // iCloud containers one at a time, each with a time limit.
            for d in dirs { node.children.append(buildWithTimeout(d, counter: counter)) }
            return
        }
        node.children += dirs
        for d in dirs { group.add { visit(d, group, counter) } }
    }

    /// Lists one folder into `node`: its own files (big ones as children, the rest counted for the
    /// "N small files" block). Returns its sub-folders as new, empty nodes. One getattrlistbulk batch per folder.
    private static func list(_ node: DiskNode, _ counter: Counter) -> [DiskNode] {
        if counter.cancelled { return [] }
        let url = node.url
        var dirs: [DiskNode] = []
        var localFiles = 0
        var localBytes: Int64 = 0
        let base = url.path.hasSuffix("/") ? url.path : url.path + "/"

        // Names, URLs and nodes are made only for folders and big files; small files are just counted.
        // URLs come from the raw path bytes (DirSize.fileURL): appendingPathComponent (macOS 26) and
        // URL(fileURLWithPath:) (macOS 15) can both return a decomposed (NFD) path for non-ASCII names.
        let readable = DirSize.forEachEntry(atPath: url.path) { k in
            if k.isSymlink { return }
            if k.isDirectory {
                let name = k.nameString, path = base + name
                if skipPaths.contains(path) { return }
                let d = DiskNode(url: DirSize.fileURL(path, isDirectory: true), name: name, isDirectory: true)
                d.parent = node
                dirs.append(d)
                return
            }
            let sz = k.size
            node.size += sz
            node.fileCount += 1
            localFiles += 1
            localBytes += sz
            if sz >= minFile {
                let name = k.nameString
                let f = DiskNode(url: DirSize.fileURL(base + name, isDirectory: false), name: name, isDirectory: false)
                f.size = sz
                f.fileCount = 1
                f.modified = k.modifiedDate
                f.parent = node
                node.children.append(f)
            } else {
                node.smallBytes += sz
                node.smallCount += 1
            }
        }
        switch readable {
        case .complete: break
        case .unreadable:
            node.unreadable = true
            return []
        case .partial:
            node.unreadable = true      // keep what was read, but flag the folder as not fully read
        }
        counter.add(files: localFiles, bytes: localBytes, current: url.path)
        return dirs
    }

    /// After the walk: adds each folder's sub-folders into its size and file count, adds the
    /// "N small files" block and sorts children by size.
    private static func total(_ node: DiskNode) {
        for c in node.children where c.isDirectory {
            total(c)
            node.size += c.size
            node.fileCount += c.fileCount
        }
        if node.smallCount > 0 {
            let agg = DiskNode(url: node.url, name: "\(node.smallCount) small file\(node.smallCount == 1 ? "" : "s")",
                               isDirectory: false, id: node.url.path + "#small")
            agg.isAggregate = true
            agg.size = node.smallBytes
            agg.fileCount = node.smallCount
            agg.parent = node
            node.children.append(agg)
        }
        node.children.sort { $0.size > $1.size }
    }

    /// Builds a folder tree on the calling thread (used for iCloud containers, outside the pool).
    private static func buildSerial(_ node: DiskNode, _ counter: Counter) {
        let dirs = list(node, counter)
        for d in dirs { buildSerial(d, counter) }
        node.children += dirs
    }

    private static func buildWithTimeout(_ node: DiskNode, counter: Counter) -> DiskNode {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            buildSerial(node, counter)
            done.signal()
        }
        if done.wait(timeout: .now() + cloudTimeout) == .success { return node }
        // Left to finish on its own; the half-built node is dropped.
        let n = DiskNode(url: node.url, name: node.name + " (iCloud not responding)", isDirectory: true)
        n.unreadable = true
        n.parent = node.parent
        return n
    }
}

@MainActor @Observable
final class DiskMapModel {
    enum RootChoice: String, CaseIterable, Identifiable {
        case home = "Home folder"
        case disk = "Whole disk"
        var id: String { rawValue }
        var url: URL { self == .home ? SafetyGuard.home : URL(fileURLWithPath: "/") }
    }
    enum Phase { case idle, scanning, done, trashing }

    var rootChoice: RootChoice = .home
    var phase: Phase = .idle
    var root: DiskNode?
    var current: DiskNode?
    var selected: DiskNode?
    var progress = DiskScanner.Progress()
    var marked: [String: DiskNode] = [:]
    var confirming = false
    var lastTrash: (count: Int, bytes: Int64, errors: [String])?
    /// Bumped whenever the (class-based) tree changes so views redraw.
    var revision = 0
    var expanded: Set<String> = []

    private var counter: DiskScanner.Counter?

    var markedBytes: Int64 { topLevelMarked.reduce(0) { $0 + $1.size } }
    var markedCount: Int { topLevelMarked.count }

    /// Marked nodes without a marked ancestor (trashing a folder covers what is inside it).
    var topLevelMarked: [DiskNode] {
        marked.values.filter { n in
            var a = n.parent
            while let p = a { if marked[p.id] != nil { return false }; a = p.parent }
            return true
        }
    }

    var breadcrumb: [DiskNode] {
        var out: [DiskNode] = []
        var n = current
        while let x = n { out.insert(x, at: 0); n = x.parent }
        return out
    }

    func start() {
        guard phase != .scanning else { return }
        phase = .scanning
        progress = .init()
        root = nil; current = nil; selected = nil; marked = [:]; expanded = []; lastTrash = nil
        let rootURL = rootChoice.url
        let counter = DiskScanner.Counter { p in
            Task { @MainActor [weak self] in
                if self?.phase == .scanning { self?.progress = p }
            }
        }
        self.counter = counter
        Task {
            let tree = await Task.detached(priority: .userInitiated) {
                DiskScanner.scan(root: rootURL, counter: counter)
            }.value
            if counter.cancelled { phase = .idle; return }
            root = tree
            current = tree
            phase = .done
            revision += 1
        }
    }

    func cancel() { counter?.cancel() }

    func open(_ node: DiskNode) {
        guard node.canOpen else { selected = node; return }
        current = node
        selected = nil
    }

    func up() {
        if let p = current?.parent { current = p; selected = nil }
    }

    func toggleMark(_ node: DiskNode) {
        guard !node.isAggregate, TrashGuard.canTrash(node.url) else { return }
        if marked[node.id] != nil { marked[node.id] = nil } else { marked[node.id] = node }
    }

    func toggleExpanded(_ node: DiskNode) {
        if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
    }

    func reveal(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    /// Moves marked items to the Trash (recoverable) and updates the tree.
    func trashMarked() async {
        let items = topLevelMarked
        guard !items.isEmpty else { return }
        phase = .trashing
        var errors: [String] = []
        var bytes: Int64 = 0
        var count = 0
        for n in items {
            if let why = TrashGuard.reason(n.url) { errors.append("\(n.name): \(why)"); continue }
            let url = n.url, sz = n.size
            let ok: String? = await Task.detached(priority: .userInitiated) {
                AppEngine.trash(url, size: sz, source: "Storage Analysis")
            }.value
            if let ok { errors.append("\(n.name): \(ok)"); continue }
            bytes += n.size
            count += 1
            remove(n)
        }
        marked = [:]
        lastTrash = (count, bytes, errors)
        HistoryStore.shared.add("Files Moved to Trash", bytes: bytes, symbol: "chart.bar.xaxis", outcome: .trashed)
        if let s = selected, s.parent == nil, s !== root { selected = nil }
        phase = .done
        revision += 1
    }

    private func remove(_ n: DiskNode) {
        var a = n.parent
        while let p = a {
            p.size -= n.size
            p.fileCount -= n.fileCount
            a = p.parent
        }
        n.parent?.children.removeAll { $0 === n }
        if current === n || isAncestor(n, of: current) { current = n.parent }
        if selected === n { selected = nil }
        n.parent = nil
    }

    private func isAncestor(_ a: DiskNode, of b: DiskNode?) -> Bool {
        var x = b?.parent
        while let p = x { if p === a { return true }; x = p.parent }
        return false
    }
}
