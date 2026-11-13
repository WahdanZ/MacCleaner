import Darwin
import Foundation

/// A JSON list on disk that more than one process writes: the window app, and the CLI or MCP server run as
/// separate processes. Every change takes an exclusive lock on `<file>.lock`, re-reads the file, applies the
/// change and writes it back, so one process never overwrites what another just added.
enum SharedFile {
    /// Applies `change` to the list stored in `file` and returns the result. `change` returns false when it
    /// changed nothing, and then the file is not rewritten.
    /// The lock call (flock). Replaced only by the self-test, to make taking the lock fail.
    nonisolated(unsafe) static var lockCall: (Int32, Int32) -> Int32 = { flock($0, $1) }

    /// Existing callers' behavior: if the lock can't be taken, the change is still applied (unlocked).
    @discardableResult
    static func update<T: Codable>(_ file: URL, _ change: (inout [T]) -> Bool) -> [T] {
        locked(file, requireLock: false, change).list
    }

    /// Like `update`, but fails closed: true only when the exclusive cross-process lock was held and the change was
    /// written. If the lock file can't be opened or the lock can't be taken, nothing is written and it returns false.
    static func commit<T: Codable>(_ file: URL, _ change: (inout [T]) -> Bool) -> Bool {
        locked(file, requireLock: true, change).written
    }

    private static func locked<T: Codable>(_ file: URL, requireLock: Bool,
                                           _ change: (inout [T]) -> Bool) -> (list: [T], written: Bool) {
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        var held = false
        if lock >= 0 {
            var r: Int32
            repeat { r = lockCall(lock, LOCK_EX) } while r != 0 && errno == EINTR
            held = r == 0
        }
        defer {
            if lock >= 0 {
                if held { _ = lockCall(lock, LOCK_UN) }
                close(lock)
            }
        }
        if requireLock && !held { return (read(file), false) }
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
