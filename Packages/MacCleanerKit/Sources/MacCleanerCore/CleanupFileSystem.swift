import Foundation

// What the cleanup executor needs from the disk and from the protection rules. Core only declares them;
// MacCleanerPlatform implements the file system, the app supplies the protection rules (its guards), and tests use
// fakes.

/// Why a file operation left an item alone: it isn't the item the caller expected any more.
public enum FileSystemRefusal: Error, Sendable, Hashable {
    case missing
    case changed(IdentityMismatch)
    /// Protected by the time it was reached (re-checked after it was moved out of reach, before deleting).
    case protected(String)
    /// The system refused the operation for lack of permission (e.g. an app owned by root). Not a safety refusal:
    /// a caller may offer an administrator step for it, under its own checks.
    case permissionDenied(String)
}

/// The protection rules for one removal, asked again for every entry right before it is deleted: nil when the path
/// (its original location, never a staging path) may go; otherwise why not. Must read the rules as they are now.
public typealias RemovalProtection = @Sendable (String) -> String?

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

/// What an overwrite-then-delete did to one reviewed item.
public struct OverwriteRemovalResult: Sendable, Hashable {
    /// An estimate: the space the deleted entries occupied on disk (each file's allocated blocks read through its
    /// open descriptor right before it was deleted, plus each removed folder's and link's own). APFS clones share
    /// blocks, snapshots keep them, and a file another app still has open frees them only when that app closes it,
    /// so less may come back to the disk.
    public var estimatedFreedBytes: Int64
    /// Files overwritten, flushed and deleted.
    public var filesOverwritten: Int
    /// What was left in place (or where it is now), and why. Empty when the item and the staging folder are gone.
    public var kept: [KeptEntry]
    /// Files kept after their overwrite had started: still there (at the path given), content partly zeroed.
    public var damaged: [String]
    /// Things that didn't stop the item but the person should know.
    public var warnings: [String]

    public init(estimatedFreedBytes: Int64 = 0, filesOverwritten: Int = 0, kept: [KeptEntry] = [],
                damaged: [String] = [], warnings: [String] = []) {
        self.estimatedFreedBytes = estimatedFreedBytes
        self.filesOverwritten = filesOverwritten
        self.kept = kept
        self.damaged = damaged
        self.warnings = warnings
    }

    /// Everything planned is gone and nothing was left behind.
    public var isComplete: Bool { kept.isEmpty && damaged.isEmpty }
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
    /// Removes the item permanently; a folder with everything in it, without crossing into other volumes. Every
    /// entry is checked with `protection` right before it is deleted; a refused entry is kept with everything in
    /// it, and so are the folders holding it (fail closed).
    func remove(_ item: FileIdentity, protection: RemovalProtection) throws -> RemovalResult
    /// Overwrites every file of a reviewed item with zeros, then deletes the item: exactly the `.tree` target's
    /// entries, never anything found on disk that isn't in it. Throws `FileSystemRefusal` (nothing changed) when the
    /// parent or the item isn't the reviewed one any more; otherwise stops at the first entry that changed, became
    /// protected (`protection`, asked right before each entry), or failed, and reports exactly what went and what
    /// stayed.
    func overwriteAndRemove(parent: FileIdentity, root: FileIdentity, entries: [FileIdentity],
                            protection: RemovalProtection) throws -> OverwriteRemovalResult
}

/// The protection rules as they are at execution time (something may have been protected after review).
public protocol ProtectionChecking: Sendable {
    /// nil when `path` may be handled with `disposition`; otherwise why not, in words for the person.
    func refusal(path: String, disposition: Disposition) -> String?
}
