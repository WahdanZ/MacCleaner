import AppKit
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

/// Thread-safe, persisted log (~/Library/Application Support/Mac Cleaner/trash-log.json).
/// Written from background threads by AppEngine.trash.
final class TrashLog: @unchecked Sendable {
    static let shared = TrashLog()
    private let lock = NSLock()
    private var items: [TrashedItem] = []
    private let file: URL = {
        let dir = SafetyGuard.home.appendingPathComponent("Library/Application Support/Mac Cleaner")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trash-log.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder.iso.decode([TrashedItem].self, from: d) { items = r }
    }

    func record(original: String, trashed: String, size: Int64, source: String, restorable: Bool) {
        lock.lock(); defer { lock.unlock() }
        items.insert(TrashedItem(original: original, trashed: trashed, size: size, date: Date(),
                                 source: source, restorable: restorable), at: 0)
        if items.count > 2000 { items.removeLast(items.count - 2000) }
        save()
    }

    /// Entries whose file is still in the Trash (drops the rest: emptied or put back elsewhere).
    func present() -> [TrashedItem] {
        lock.lock(); defer { lock.unlock() }
        let before = items.count
        items.removeAll { !$0.stillInTrash }
        if items.count != before { save() }
        return items
    }

    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        items = []
        save()
    }

    private func save() {
        if let d = try? JSONEncoder.iso.encode(items) { try? d.write(to: file, options: .atomic) }
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
    static func finderTrashPaths() -> [String]? {
        let js = """
        var t = Application("Finder").trash.items();
        t.map(function (i) { return decodeURIComponent(i.url().replace(/^file:\\/\\//, "")).replace(/\\/$/, ""); }).join("\\n");
        """
        let r = Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", js])
        guard r.status == 0, let out = r.output else { return nil }
        return out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }

    /// Empties the Trash through Finder. Returns nil on success.
    static func empty() -> String? {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        let r = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
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
