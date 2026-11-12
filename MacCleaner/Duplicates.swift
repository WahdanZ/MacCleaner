import AppKit
import CryptoKit
import Foundation
import Observation

struct DupGroup: Identifiable, Sendable {
    let id: String
    let size: Int64
    var files: [URL]
    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

enum DupEngine {
    struct Progress: Sendable {
        var files = 0
        var candidates = 0
        var hashed = 0
        var current = ""
    }

    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// Size → first/last 64 KB hash → full SHA-256. Skips hidden files, package internals,
    /// symlinks, hard-link twins and iCloud files that are not downloaded (reading would download them).
    /// Thread-safe progress that reaches `report` at most ~8 times a second (each report is a main-actor hop).
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var p = Progress()
        private var last = Date.distantPast
        private let report: (Progress) -> Void
        init(_ report: @escaping (Progress) -> Void) { self.report = report }

        func update(force: Bool = false, current: String? = nil, _ change: (inout Progress) -> Void) {
            lock.lock()
            change(&p)
            var snap: Progress?
            let now = Date()
            if force || now.timeIntervalSince(last) > 0.12 {
                last = now
                if let current { p.current = current }
                snap = p
            }
            lock.unlock()
            if let snap { report(snap) }
        }
    }

    static func run(roots: [URL], minSize: Int64, cancel: Cancel,
                    report: @Sendable (Progress) -> Void) -> [DupGroup] {
        withoutActuallyEscaping(report) { report in run(roots: roots, minSize: minSize, cancel: cancel, meter: Meter(report)) }
    }

    private static func run(roots: [URL], minSize: Int64, cancel: Cancel, meter: Meter) -> [DupGroup] {
        // 1. Group by size. Each root is listed on its own thread; merged in root order.
        var perRoot = [[Int64: [URL]]](repeating: [:], count: roots.count)
        perRoot.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: roots.count) { i in
                buf[i] = list(roots[i], minSize: minSize, cancel: cancel, meter: meter)
            }
        }
        if cancel.isSet { return [] }
        var bySize: [Int64: [URL]] = [:]
        for part in perRoot { for (s, fs) in part { bySize[s, default: []] += fs } }

        let sizeGroups = bySize.filter { $0.value.count > 1 }.sorted { $0.key > $1.key }
        meter.update(force: true) { $0.candidates = sizeGroups.reduce(0) { $0 + $1.value.count } }

        // 2. Hash. Same-size groups are independent, so they run in parallel.
        var found = [[DupGroup]](repeating: [], count: sizeGroups.count)
        found.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: sizeGroups.count) { i in
                if cancel.isSet { return }
                buf[i] = hashGroup(size: sizeGroups[i].key, files: sizeGroups[i].value, cancel: cancel, meter: meter)
            }
        }
        if cancel.isSet { return [] }
        meter.update(force: true) { _ in }
        return found.flatMap { $0 }.sorted { $0.wasted > $1.wasted }
    }

    private static func list(_ root: URL, minSize: Int64, cancel: Cancel, meter: Meter) -> [Int64: [URL]] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        let keySet = Set(keys)
        var bySize: [Int64: [URL]] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return [:] }
        var pending = 0
        for case let f as URL in e {
            if cancel.isSet { return [:] }
            guard let v = try? f.resourceValues(forKeys: keySet), v.isRegularFile == true,
                  v.isSymbolicLink != true, let s = v.fileSize, Int64(s) >= minSize else { continue }
            bySize[Int64(s), default: []].append(f)
            pending += 1
            if pending == 200 { let n = pending; pending = 0; meter.update(current: f.path) { $0.files += n } }
        }
        let n = pending
        meter.update { $0.files += n }
        return bySize
    }

    private static func hashGroup(size: Int64, files: [URL], cancel: Cancel, meter: Meter) -> [DupGroup] {
        let unique = uniqueLocalFiles(files)
        guard unique.count > 1 else { meter.update { $0.hashed += files.count }; return [] }
        var out: [DupGroup] = []
        var byPartial: [String: [URL]] = [:]
        for f in unique {
            if cancel.isSet { return [] }
            if let h = partialHash(f, size: size) { byPartial[h, default: []].append(f) }
            meter.update(current: f.path) { $0.hashed += 1 }
        }
        for (ph, same) in byPartial where same.count > 1 {
            if size <= 128 * 1024 {
                out.append(DupGroup(id: "\(size)-\(ph)", size: size, files: same.sorted { $0.path < $1.path }))
                continue
            }
            var byFull: [String: [URL]] = [:]
            for f in same {
                if cancel.isSet { return [] }
                meter.update(current: f.path) { _ in }
                if let h = fullHash(f, cancel: cancel) { byFull[h, default: []].append(f) }
            }
            for (h, dup) in byFull where dup.count > 1 {
                out.append(DupGroup(id: "\(size)-\(h)", size: size, files: dup.sorted { $0.path < $1.path }))
            }
        }
        return out
    }

    /// Drops hard-link twins and iCloud placeholders.
    private static func uniqueLocalFiles(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        return files.filter { f in
            var st = stat()
            guard lstat(f.path, &st) == 0 else { return false }
            if st.st_flags & 0x4000_0000 != 0 { return false }      // SF_DATALESS: not downloaded
            return seen.insert("\(st.st_dev):\(st.st_ino)").inserted
        }
    }

    private static func partialHash(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        let chunk = 64 * 1024
        if let d = try? h.read(upToCount: chunk) { hasher.update(data: d) }
        if size > Int64(chunk * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let d = try? h.read(upToCount: chunk) { hasher.update(data: d) }
        } else if let d = try? h.readToEnd() {
            hasher.update(data: d)
        }
        return hex(hasher.finalize())
    }

    private static func fullHash(_ url: URL, cancel: Cancel) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try? h.read(upToCount: 4 << 20), !d.isEmpty {
            if cancel.isSet { return nil }
            hasher.update(data: d)
        }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for b in d { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }
}

@MainActor @Observable
final class DupFinder {
    enum Phase { case idle, scanning, done, trashing }

    struct Root: Identifiable {
        let id: String
        let url: URL
        var on: Bool
    }

    var phase: Phase = .idle
    var roots: [Root]
    var minSize: Int64 = 1_000_000
    var progress = DupEngine.Progress()
    var groups: [DupGroup] = []
    var marked: Set<URL> = []
    var expanded: Set<String> = []
    var confirming = false
    var lastTrash: (count: Int, bytes: Int64, errors: [String])?
    private var cancelFlag: DupEngine.Cancel?

    init() {
        let home = SafetyGuard.home
        roots = ["Documents", "Downloads", "Desktop", "Movies", "Pictures", "Music"].map {
            Root(id: $0, url: home.appendingPathComponent($0), on: true)
        }
    }

    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var markedBytes: Int64 {
        groups.reduce(0) { sum, g in sum + Int64(g.files.filter { marked.contains($0) }.count) * g.size }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for u in panel.urls where !roots.contains(where: { $0.url == u }) {
            roots.append(Root(id: u.path, url: u, on: true))
        }
    }

    func start() {
        guard phase != .scanning else { return }
        let urls = roots.filter(\.on).map(\.url)
        guard !urls.isEmpty else { return }
        phase = .scanning
        groups = []; marked = []; expanded = []; lastTrash = nil
        progress = .init()
        let min = minSize
        let cancel = DupEngine.Cancel()
        cancelFlag = cancel
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DupEngine.run(roots: urls, minSize: min, cancel: cancel) { p in
                    Task { @MainActor [weak self] in
                        if self?.phase == .scanning { self?.progress = p }
                    }
                }
            }.value
            if cancel.isSet { phase = .idle; return }
            groups = result
            phase = .done
        }
    }

    func cancel() { cancelFlag?.set() }

    func toggle(_ url: URL, in g: DupGroup) {
        if marked.contains(url) {
            marked.remove(url)
        } else {
            // Always keep at least one copy.
            let others = g.files.filter { $0 != url && !marked.contains($0) }
            guard !others.isEmpty, TrashGuard.canTrash(url) else { return }
            marked.insert(url)
        }
    }

    /// In every group keep the oldest copy and mark the rest.
    func markExtraCopies() {
        marked = []
        for g in groups {
            let keep = g.files.min { modDate($0) < modDate($1) } ?? g.files[0]
            for f in g.files where f != keep && TrashGuard.canTrash(f) { marked.insert(f) }
        }
    }

    func trashMarked() async {
        guard !marked.isEmpty else { return }
        phase = .trashing
        var errors: [String] = []
        var bytes: Int64 = 0
        var count = 0
        for gi in groups.indices {
            for f in groups[gi].files where marked.contains(f) {
                // Re-check: never trash the last remaining copy.
                guard groups[gi].files.count > 1 else { break }
                if let why = TrashGuard.reason(f) { errors.append("\(f.lastPathComponent): \(why)"); continue }
                let size = groups[gi].size
                let r: String? = await Task.detached {
                    AppEngine.trash(f, size: size, source: "Duplicates")
                }.value
                if let r { errors.append("\(f.lastPathComponent): \(r)"); continue }
                groups[gi].files.removeAll { $0 == f }
                bytes += groups[gi].size
                count += 1
            }
        }
        groups.removeAll { $0.files.count < 2 }
        marked = []
        lastTrash = (count, bytes, errors)
        HistoryStore.shared.add("Duplicates Moved to Trash", bytes: bytes, symbol: "plus.square.on.square", outcome: .trashed)
        phase = .done
    }

    private func modDate(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
    }
}
