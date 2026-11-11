import Foundation
import Observation

struct CleanupRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let title: String
    let bytes: Int64
    /// SF Symbol for the row.
    let symbol: String
}

/// Persistent list of completed cleanups (~/Library/Application Support/Mac Cleaner/history.json).
@MainActor @Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var records: [CleanupRecord] = []
    private let file: URL = {
        let dir = SafetyGuard.home.appendingPathComponent("Library/Application Support/Mac Cleaner")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: file),
           let r = try? JSONDecoder.iso.decode([CleanupRecord].self, from: d) {
            records = r
        }
    }

    var totalFreed: Int64 { records.reduce(0) { $0 + $1.bytes } }

    func add(_ title: String, bytes: Int64, symbol: String) {
        guard bytes > 0 else { return }
        records.insert(CleanupRecord(date: Date(), title: title, bytes: bytes, symbol: symbol), at: 0)
        if records.count > 300 { records.removeLast(records.count - 300) }
        save()
    }

    /// For the MCP server process (no window): append to the same history file.
    nonisolated static func add(title: String, bytes: Int64, symbol: String) {
        guard bytes > 0 else { return }
        let file = SafetyGuard.home.appendingPathComponent("Library/Application Support/Mac Cleaner/history.json")
        var list = (try? JSONDecoder.iso.decode([CleanupRecord].self, from: Data(contentsOf: file))) ?? []
        list.insert(CleanupRecord(date: Date(), title: title, bytes: bytes, symbol: symbol), at: 0)
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
