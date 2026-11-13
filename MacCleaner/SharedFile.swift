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
        locked(file, change).list
    }

    /// Like `update`, but says whether the change reached the disk: false when it couldn't be encoded or written.
    static func commit<T: Codable>(_ file: URL, _ change: (inout [T]) -> Bool) -> Bool {
        locked(file, change).written
    }

    private static func locked<T: Codable>(_ file: URL, _ change: (inout [T]) -> Bool) -> (list: [T], written: Bool) {
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        var list = read(file) as [T]
        guard change(&list) else { return (list, true) }
        guard let d = try? JSONEncoder.iso.encode(list) else { return (list, false) }
        do { try d.write(to: file, options: .atomic) } catch { return (list, false) }
        return (list, true)
    }

    static func read<T: Codable>(_ file: URL) -> [T] {
        (try? JSONDecoder.iso.decode([T].self, from: Data(contentsOf: file))) ?? []
    }
}
