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

    private init() {
        if let d = try? Data(contentsOf: file),
           let r = try? JSONDecoder.iso.decode([CleanupRecord].self, from: d) {
            records = r
        }
    }

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
        records.insert(CleanupRecord(date: Date(), title: title, bytes: bytes, symbol: symbol,
                                     outcome: outcome, measuredFreeChange: measuredFreeChange), at: 0)
        if records.count > 300 { records.removeLast(records.count - 300) }
        save()
    }

    /// For the MCP server process (no window): append to the same history file.
    nonisolated static func add(title: String, bytes: Int64, symbol: String, outcome: CleanupRecord.Outcome,
                                measuredFreeChange: Int64? = nil) {
        guard bytes > 0 else { return }
        let file = fileURL
        var list = (try? JSONDecoder.iso.decode([CleanupRecord].self, from: Data(contentsOf: file))) ?? []
        list.insert(CleanupRecord(date: Date(), title: title, bytes: bytes, symbol: symbol,
                                  outcome: outcome, measuredFreeChange: measuredFreeChange), at: 0)
        if let d = try? JSONEncoder.iso.encode(Array(list.prefix(300))) { try? d.write(to: file, options: .atomic) }
    }

    func clear() {
        records = []
        save()
    }

    private func save() {
        if let d = try? JSONEncoder.iso.encode(records) { try? d.write(to: file, options: .atomic) }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
