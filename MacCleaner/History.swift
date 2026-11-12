import Foundation
import Observation

/// One finished cleanup. Keeps "moved to the Trash" apart from "deleted", because only the second frees space.
struct CleanupRecord: Codable, Identifiable {
    enum Outcome: String, Codable {
        /// Removed permanently (caches, build files, SDK downloads, shredded files, emptied Trash).
        case deleted
        /// Moved to the Trash: recoverable, and not freed until the Trash is emptied.
        case trashed
    }

    var id = UUID()
    let date: Date
    let title: String
    /// Size of what was removed, as measured before removing it.
    let bytes: Int64
    /// SF Symbol for the row.
    let symbol: String
    /// nil for records saved before this field existed.
    var outcome: Outcome? = nil
    /// Change in the disk's free space measured right after a permanent removal, when it was measured.
    /// APFS and other apps also change free space, so this is shown as a measurement, not a promise.
    var measuredFreeChange: Int64? = nil

    /// Short phrase for the row: "Freed 2.1 GB", "Moved 1.4 GB to Trash".
    var resultText: String {
        switch outcome {
        case .deleted: return "Deleted \(ByteText.string(bytes))"
        case .trashed: return "Moved \(ByteText.string(bytes)) to Trash"
        case nil: return ByteText.string(bytes)
        }
    }
}

/// Persistent list of completed cleanups (~/Library/Application Support/Mac Cleaner/history.json).
@MainActor @Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var records: [CleanupRecord] = []
    private let file: URL = HistoryStore.fileURL

    nonisolated static var fileURL: URL {
        let dir = SafetyGuard.home.appendingPathComponent("Library/Application Support/Mac Cleaner")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() { records = SharedFile.read(file) }

    /// Picks up records the CLI or MCP server added since.
    func reload() { records = SharedFile.read(file) }

    /// Bytes removed permanently.
    var totalDeleted: Int64 { records.filter { $0.outcome == .deleted }.reduce(0) { $0 + $1.bytes } }
    /// Records saved before outcomes were tracked: we don't know whether they were deleted or trashed.
    var totalUnclassified: Int64 { records.filter { $0.outcome == nil }.reduce(0) { $0 + $1.bytes } }
    /// Bytes moved to the Trash.
    var totalTrashed: Int64 { records.filter { $0.outcome == .trashed }.reduce(0) { $0 + $1.bytes } }
    /// Kept for older call sites: everything recorded.
    var totalFreed: Int64 { records.reduce(0) { $0 + $1.bytes } }

    func add(_ title: String, bytes: Int64, symbol: String, outcome: CleanupRecord.Outcome, measuredFreeChange: Int64? = nil) {
        guard bytes > 0 else { return }
        records = Self.insert(CleanupRecord(date: Date(), title: title, bytes: bytes, symbol: symbol,
                                            outcome: outcome, measuredFreeChange: measuredFreeChange), into: file)
    }

    /// For the MCP server process (no window): append to the same history file.
    nonisolated static func add(title: String, bytes: Int64, symbol: String, outcome: CleanupRecord.Outcome,
                                measuredFreeChange: Int64? = nil) {
        guard bytes > 0 else { return }
        insert(CleanupRecord(date: Date(), title: title, bytes: bytes, symbol: symbol,
                             outcome: outcome, measuredFreeChange: measuredFreeChange), into: fileURL)
    }

    /// Adds a record to the file under its lock (see `SharedFile`) and returns the whole list.
    @discardableResult
    nonisolated static func insert(_ r: CleanupRecord, into file: URL) -> [CleanupRecord] {
        SharedFile.update(file) { (list: inout [CleanupRecord]) in
            list.insert(r, at: 0)
            if list.count > 300 { list.removeLast(list.count - 300) }
            return true
        }
    }

    func clear() {
        records = SharedFile.update(file) { (list: inout [CleanupRecord]) in list = []; return true }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
