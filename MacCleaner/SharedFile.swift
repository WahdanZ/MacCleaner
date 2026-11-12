import Darwin
import Foundation

/// A JSON list on disk that more than one process writes: the window app, and the CLI or MCP server run as
/// separate processes. Every change takes an exclusive lock on `<file>.lock`, re-reads the file, applies the
/// change and writes it back, so one process never overwrites what another just added.
enum SharedFile {
    /// Applies `change` to the list stored in `file` and returns the result. `change` returns false when it
    /// changed nothing, and then the file is not rewritten.
    @discardableResult
    static func update<T: Codable>(_ file: URL, _ change: (inout [T]) -> Bool) -> [T] {
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        var list = read(file) as [T]
        if change(&list), let d = try? JSONEncoder.iso.encode(list) { try? d.write(to: file, options: .atomic) }
        return list
    }

    static func read<T: Codable>(_ file: URL) -> [T] {
        (try? JSONDecoder.iso.decode([T].self, from: Data(contentsOf: file))) ?? []
    }
}
