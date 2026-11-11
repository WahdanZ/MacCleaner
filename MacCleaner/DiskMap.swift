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

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                         .fileAllocatedSizeKey, .contentModificationDateKey]

    static func scan(root: URL, counter: Counter) -> DiskNode {
        build(root, name: root.path == "/" ? "Macintosh HD" : root.lastPathComponent, depth: 0, counter: counter)
    }

    private static func build(_ url: URL, name: String, depth: Int, counter: Counter) -> DiskNode {
        let node = DiskNode(url: url, name: name, isDirectory: true)
        if counter.cancelled { return node }
        guard let kids = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                       options: []) else {
            node.unreadable = true
            return node
        }
        var dirs: [URL] = []
        var smallBytes: Int64 = 0
        var smallCount = 0
        var localFiles = 0
        var localBytes: Int64 = 0
        let keySet = Set(keys)

        for k in kids {
            if skipPaths.contains(k.path) { continue }
            guard let v = try? k.resourceValues(forKeys: keySet), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                dirs.append(k)
            } else {
                let sz = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                node.size += sz
                node.fileCount += 1
                localFiles += 1
                localBytes += sz
                if sz >= minFile {
                    let f = DiskNode(url: k, name: k.lastPathComponent, isDirectory: false)
                    f.size = sz
                    f.fileCount = 1
                    f.modified = v.contentModificationDate
                    f.parent = node
                    node.children.append(f)
                } else {
                    smallBytes += sz
                    smallCount += 1
                }
            }
        }
        counter.add(files: localFiles, bytes: localBytes, current: url.path)

        // Walk sub-folders; the top two levels in parallel. iCloud containers get a time limit.
        var built = [DiskNode?](repeating: nil, count: dirs.count)
        if cloudRoots.contains(url.path) {
            for (i, d) in dirs.enumerated() {
                built[i] = buildWithTimeout(d, depth: depth + 1, counter: counter)
            }
        } else if depth <= 1 && dirs.count > 1 {
            built.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
                    buf[i] = build(dirs[i], name: dirs[i].lastPathComponent, depth: depth + 1, counter: counter)
                }
            }
        } else {
            for (i, d) in dirs.enumerated() {
                built[i] = build(d, name: d.lastPathComponent, depth: depth + 1, counter: counter)
            }
        }
        for case let child? in built {
            child.parent = node
            node.size += child.size
            node.fileCount += child.fileCount
            node.children.append(child)
        }

        if smallCount > 0 {
            let agg = DiskNode(url: url, name: "\(smallCount) small file\(smallCount == 1 ? "" : "s")",
                               isDirectory: false, id: url.path + "#small")
            agg.isAggregate = true
            agg.size = smallBytes
            agg.fileCount = smallCount
            agg.parent = node
            node.children.append(agg)
        }
        node.children.sort { $0.size > $1.size }
        return node
    }

    private final class Box: @unchecked Sendable { var node: DiskNode? }

    private static func buildWithTimeout(_ url: URL, depth: Int, counter: Counter) -> DiskNode {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.node = build(url, name: url.lastPathComponent, depth: depth, counter: counter)
            done.signal()
        }
        if done.wait(timeout: .now() + cloudTimeout) == .success, let n = box.node { return n }
        let n = DiskNode(url: url, name: url.lastPathComponent + " (iCloud not responding)", isDirectory: true)
        n.unreadable = true
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
        HistoryStore.shared.add("Files Moved to Trash", bytes: bytes, symbol: "chart.bar.xaxis")
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
