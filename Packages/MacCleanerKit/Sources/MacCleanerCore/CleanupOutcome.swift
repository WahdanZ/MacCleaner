import Foundation

// What a scan found and what a cleanup did, told truthfully: a scan that couldn't read some folders says which,
// and a cleanup that stopped part-way says exactly what was removed and what was kept.

/// A place a scan couldn't read.
public struct AccessProblem: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case permissionDenied
        /// macOS needs Full Disk Access for Mac Cleaner to read it.
        case needsFullDiskAccess
        case other
    }

    public let path: String
    public let kind: Kind
    public let detail: String?

    public init(path: String, kind: Kind, detail: String? = nil) {
        self.path = path
        self.kind = kind
        self.detail = detail
    }
}

/// The result of a scan, including what it couldn't see.
public struct ScanOutcome<Item: Sendable>: Sendable {
    public var items: [Item]
    public var inaccessible: [AccessProblem]
    /// Errors that skipped part of the scan without stopping it.
    public var partialErrors: [String]
    public var wasCancelled: Bool
    /// Things worth telling the person that are not errors.
    public var warnings: [String]

    public init(items: [Item] = [], inaccessible: [AccessProblem] = [], partialErrors: [String] = [],
                wasCancelled: Bool = false, warnings: [String] = []) {
        self.items = items
        self.inaccessible = inaccessible
        self.partialErrors = partialErrors
        self.wasCancelled = wasCancelled
        self.warnings = warnings
    }

    /// True only when the scan ran to the end and read everything it tried to. Warnings don't count.
    public var isComplete: Bool { !wasCancelled && inaccessible.isEmpty && partialErrors.isEmpty }
}

extension ScanOutcome: Equatable where Item: Equatable {}

/// Why the executor left a target alone.
public enum SkipReason: Sendable, Hashable {
    /// Protected now (it may have become protected after the plan was made).
    case protected(String)
    /// It isn't the item that was reviewed any more.
    case changed(IdentityMismatch)
    case missing
    /// An entry that appeared in a reviewed folder after review. Left alone: the person never saw it.
    case addedAfterReview
    /// The person cancelled before this item.
    case cancelled
}

/// What happened to one target.
public struct ItemOutcome: Sendable, Hashable {
    public enum Result: Sendable, Hashable {
        case removed(bytes: Int64)
        /// Moved, recoverable from `recoveryPath`; not freed until the Trash is emptied.
        case trashed(bytes: Int64, recoveryPath: String)
        case skipped(SkipReason)
        case failed(String)
        /// Stopped part-way: `freedBytes` are gone, the `kept` paths are untouched, the `damaged` paths are still
        /// there but changed (an overwrite that failed part-way). Never reported as success or as nothing done.
        case partiallyDone(freedBytes: Int64, kept: [String], damaged: [String])
    }

    public let candidateID: String
    public let target: CleanupTarget
    public let result: Result

    public init(candidateID: String, target: CleanupTarget, result: Result) {
        self.candidateID = candidateID
        self.target = target
        self.result = result
    }

    public var succeeded: Bool {
        switch result {
        case .removed, .trashed: return true
        case .skipped, .failed, .partiallyDone: return false
        }
    }
}

/// The whole cleanup, item by item.
public struct CleanupReport: Sendable, Hashable {
    public let planDigest: String
    public let outcomes: [ItemOutcome]
    public let wasCancelled: Bool

    public init(planDigest: String, outcomes: [ItemOutcome], wasCancelled: Bool) {
        self.planDigest = planDigest
        self.outcomes = outcomes
        self.wasCancelled = wasCancelled
    }

    /// Permanently removed, including what a partial removal already freed.
    public var freedBytes: Int64 {
        outcomes.reduce(0) {
            switch $1.result {
            case .removed(let b): return $0 + b
            case .partiallyDone(let b, _, _): return $0 + b
            default: return $0
            }
        }
    }

    /// Moved to the Trash: recoverable, and not freed yet.
    public var movedToTrashBytes: Int64 {
        outcomes.reduce(0) { if case .trashed(let b, _) = $1.result { return $0 + b }; return $0 }
    }

    /// True only when there was something to do, nothing was cancelled, and every target succeeded.
    public var allSucceeded: Bool { !wasCancelled && !outcomes.isEmpty && outcomes.allSatisfy(\.succeeded) }
}

/// What scans and cleanups report as they go, delivered as an `AsyncStream<ProgressEvent>`.
public enum ProgressEvent: Sendable, Hashable {
    case scanStarted(module: String)
    case moduleProgress(module: String, completed: Int, total: Int?)
    case itemsDiscovered(module: String, count: Int, bytes: Int64)
    case accessProblem(AccessProblem)
    case cleanupStarted(planDigest: String, targetCount: Int)
    case itemFinished(ItemOutcome)
    case finished(CleanupReport)
    case cancelled

    /// The last event of a stream.
    public var isTerminal: Bool {
        switch self {
        case .finished, .cancelled: return true
        default: return false
        }
    }
}
