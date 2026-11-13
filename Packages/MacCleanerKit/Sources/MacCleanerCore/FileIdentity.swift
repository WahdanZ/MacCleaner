import Foundation

// What an item on disk *is*, not just where it is. Captured when a scan finds the item and captured again right
// before anything is removed: if the two differ, the item was replaced (a folder swapped for a symlink, a file
// swapped for another one at the same path, a file that changed since the person reviewed it) and the cleanup
// skips it. Capturing touches the file system, so it lives outside Core; this is only the value and the rule.

public struct FileIdentity: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case file, directory, symlink, other
    }

    /// Absolute, standardized path. A symlink is identified as the link itself (lstat), never its target.
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let kind: Kind
    /// Logical size in bytes (lstat st_size).
    public let size: Int64
    /// Modification time in nanoseconds since 1970, kept as an integer so two captures compare exactly.
    public let modificationNanos: Int64
    public let linkCount: UInt32
    /// st_flags (uchg, restricted, …). Recorded for the executor; not part of the match.
    public let flags: UInt32

    public init(path: String, device: UInt64, inode: UInt64, kind: Kind, size: Int64, modificationNanos: Int64,
                linkCount: UInt32 = 1, flags: UInt32 = 0) {
        self.path = path
        self.device = device
        self.inode = inode
        self.kind = kind
        self.size = size
        self.modificationNanos = modificationNanos
        self.linkCount = linkCount
        self.flags = flags
    }

    /// nil when `current` (captured again at execution time) is the same item that was planned; otherwise how it
    /// differs. Same item = same path, kind, device and inode; for a file also the same size and modification time.
    /// A folder's size and time change whenever something inside it changes, so they are not compared.
    public func mismatch(against current: FileIdentity) -> IdentityMismatch? {
        if current.kind != kind { return .kindChanged(from: kind, to: current.kind) }
        if current.path != path || current.device != device || current.inode != inode { return .replaced }
        if kind == .file, current.size != size || current.modificationNanos != modificationNanos { return .contentChanged }
        return nil
    }

    /// Directly inside `folder` ("/a/b/c" in "/a/b", not "/a/b/c/d") and on the same volume: a mount point inside a
    /// folder is another volume and never counts as one of its entries.
    public func isDirectChild(of folder: FileIdentity) -> Bool {
        guard device == folder.device, folder.kind == .directory else { return false }
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let name = path.dropFirst(prefix.count)
        return !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
}

/// Why a re-captured item no longer matches the plan. Each one means: skip it and say so.
public enum IdentityMismatch: Sendable, Hashable {
    /// A different item now sits at the path (another inode or volume).
    case replaced
    /// Same path, different kind: e.g. a folder replaced by a symlink.
    case kindChanged(from: FileIdentity.Kind, to: FileIdentity.Kind)
    /// The same file, but written to since it was reviewed.
    case contentChanged
}
