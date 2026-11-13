import Foundation

// What the cleanup executor needs from the disk and from the protection rules. Core only declares them;
// MacCleanerPlatform implements the file system, the app supplies the protection rules (its guards), and tests use
// fakes.

/// Why a file operation left an item alone: it isn't the item the caller expected any more.
public enum FileSystemRefusal: Error, Sendable, Hashable {
    case missing
    case changed(IdentityMismatch)
}

public struct TrashResult: Sendable, Hashable {
    /// Space it took on disk, measured right before the move.
    public let bytes: Int64
    /// Where it went, for putting it back.
    public let recoveryPath: String

    public init(bytes: Int64, recoveryPath: String) {
        self.bytes = bytes
        self.recoveryPath = recoveryPath
    }
}

public struct RemovalResult: Sendable, Hashable {
    /// Space actually freed (a hard-linked file frees nothing while another link remains).
    public var freedBytes: Int64
    /// What was left in place, and why. Empty when the item is completely gone.
    public var kept: [KeptEntry]

    public init(freedBytes: Int64 = 0, kept: [KeptEntry] = []) {
        self.freedBytes = freedBytes
        self.kept = kept
    }
}

/// File operations for the executor. Every operation that changes something takes the identity the caller
/// expects and checks it again at the last moment, throwing `FileSystemRefusal` when the item is gone or isn't
/// that item any more. Nothing follows a symlink: a link is handled as the link itself.
public protocol CleanupFileSystem: Sendable {
    /// The item at `path` now (lstat), or nil when nothing is there.
    func identity(at path: String) throws -> FileIdentity?
    /// The folder's direct entries now. Throws `FileSystemRefusal` when the folder isn't `folder` any more.
    func entries(of folder: FileIdentity) throws -> [FileIdentity]
    func moveToTrash(_ item: FileIdentity) throws -> TrashResult
    /// Removes the item permanently; a folder with everything in it, without crossing into other volumes.
    func remove(_ item: FileIdentity) throws -> RemovalResult
}

/// The protection rules as they are at execution time (something may have been protected after review).
public protocol ProtectionChecking: Sendable {
    /// nil when `path` may be handled with `disposition`; otherwise why not, in words for the person.
    func refusal(path: String, disposition: Disposition) -> String?
}
