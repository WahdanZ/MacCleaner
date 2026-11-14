import Foundation
import MacCleanerCore
import MacCleanerPlatform

// What the Shredder's review does before an approval: one snapshot per item, the app's protection rules over every
// entry of that same snapshot, and a check that rows don't overlap. Also how an executor outcome is told back
// (M01-04c-2). No UI, History or approval here.

/// One item of the review: blocked (with why) or ready with the snapshot that would be approved.
struct ShredReviewRow: Sendable {
    enum State: Sendable {
        case ready(ShredSnapshot)
        case blocked(reason: String)
    }

    let id: String
    let url: URL
    let state: State

    fileprivate init(id: String, url: URL, state: State) {
        self.id = id
        self.url = url
        self.state = state
    }

    var snapshot: ShredSnapshot? { if case .ready(let s) = state { return s } else { return nil } }
    var blockedReason: String? { if case .blocked(let r) = state { return r } else { return nil } }
    /// The space the item takes on disk, for display.
    var allocatedBytes: Int64? { snapshot?.allocatedBytes }

    /// The item's root, as snapshotted.
    var root: FileIdentity? {
        if let s = snapshot, case .tree(_, let root, _) = s.target { return root }
        return nil
    }

    /// The candidate to review and approve: exactly the snapshot's `.tree` target. nil for a blocked row.
    var candidate: CleanupCandidate? {
        guard let s = snapshot, let root else { return nil }
        return CleanupCandidate(id: id, module: "shredder", title: url.lastPathComponent, targets: [s.target],
                                estimatedBytes: s.logicalBytes, allocatedBytes: s.allocatedBytes,
                                risk: .potentialUserData, recommended: false,
                                explanation: "Overwritten with zeros, then deleted for good: \(root.path)")
    }

    fileprivate func blocked(_ reason: String) -> ShredReviewRow { ShredReviewRow(id: id, url: url, state: .blocked(reason: reason)) }
}

enum ShredReview {
    typealias Snapshotter = (String) -> Result<ShredSnapshot, ShredRefusal>

    /// Snapshots each item once and applies the app's rules to everything that snapshot lists. Does file I/O: run it
    /// off the main thread. `snapshot` is replaceable only so the self-test can count calls.
    nonisolated static func snapshots(_ items: [(id: String, url: URL)],
                                      shredSnapshotter: Snapshotter = { LocalFileSystem().shredSnapshot(at: $0) }) -> [ShredReviewRow] {
        var rows = items.map { row($0.id, $0.url, shredSnapshotter) }
        // Overlap: the inner row of a nested pair, and the later of two rows for the same object, is already included.
        let readyRoots: [(index: Int, root: FileIdentity, key: String)] = rows.enumerated().compactMap { i, r in
            r.root.map { (i, $0, TrashGuard.key(URL(fileURLWithPath: $0.path))) }
        }
        for a in readyRoots {
            for b in readyRoots where b.index != a.index {
                let same = a.root.device == b.root.device && a.root.inode == b.root.inode
                let inside = a.key != b.key && SafetyGuard.isInside(a.key, b.key)
                if (same && b.index < a.index) || inside || (a.key == b.key && b.index < a.index) {
                    rows[a.index] = rows[a.index].blocked("Already included in \(rows[b.index].url.lastPathComponent)")
                    break
                }
            }
        }
        return rows
    }

    private nonisolated static func row(_ id: String, _ url: URL, _ snapshot: Snapshotter) -> ShredReviewRow {
        let path = AppCleanup.physicalPath(url)
        let protection = AppProtection()
        if let why = protection.refusal(path: path, disposition: .overwriteThenDelete) {
            return ShredReviewRow(id: id, url: url, state: .blocked(reason: why))
        }
        let snap: ShredSnapshot
        switch snapshot(path) {
        case .failure(let refusal): return ShredReviewRow(id: id, url: url, state: .blocked(reason: refusal.reason))
        case .success(let s): snap = s
        }
        guard case .tree(_, let root, let entries) = snap.target else {
            return ShredReviewRow(id: id, url: url, state: .blocked(reason: "Not something that can be shredded"))
        }
        for e in [root] + entries {
            if let why = protection.refusal(path: e.path, disposition: .overwriteThenDelete) {
                return ShredReviewRow(id: id, url: url, state: .blocked(reason: why))
            }
            // Strict: a link inside is blocked too when what it points at is protected (normalize follows the link).
            if e.kind == .symlink, let why = ProtectedPaths.reason(URL(fileURLWithPath: e.path)) {
                return ShredReviewRow(id: id, url: url, state: .blocked(reason: "\(URL(fileURLWithPath: e.path).lastPathComponent) is a link to a protected item: \(why)"))
            }
        }
        return ShredReviewRow(id: id, url: url, state: .ready(snap))
    }

    // MARK: - What is at the planned path now

    enum RootState: Sendable, Equatable { case gone, same, other, unknown }

    /// Looks at the planned root's path. "Same" is device, inode and kind (not the modification time: a damaged
    /// file is still the same file).
    nonisolated static func rootState(_ root: FileIdentity) -> RootState {
        do {
            guard let now = try LocalFileSystem().identity(at: root.path) else { return .gone }
            return now.device == root.device && now.inode == root.inode && now.kind == root.kind ? .same : .other
        } catch {
            return .unknown
        }
    }

    // MARK: - Telling an outcome

    struct ShredItemResult: Sendable, Equatable {
        enum Disposition: Sendable, Equatable {
            /// Take the row off the list.
            case remove
            /// Leave the row; it is re-snapshotted at the next review.
            case keep
            /// Leave the row, blocked, with why.
            case block(String)
        }
        /// Bytes to count as freed: always the outcome's own estimate.
        var countedBytes: Int64
        var disposition: Disposition
        var message: String
        /// Something was overwritten or deleted.
        var removedAnything: Bool
        var warnings: [String]
        /// Not a clean success: worth listing as a problem.
        var isProblem = true
        /// Stopped part-way (some of it may be gone).
        var isPartial = false
    }

    static let otherItemNote = "A different item is now at this path; it was not touched"
    static let unknownItemNote = "Couldn't check what is at this path now; it was not touched"
    /// The note for a row that must not be treated as the planned item.
    static func note(for state: RootState) -> String { state == .unknown ? unknownItemNote : otherItemNote }

    nonisolated static func classify(outcome: ItemOutcome, planned target: CleanupTarget, rootState: RootState) -> ShredItemResult {
        let name: String, rootPath: String
        var plannedFiles = 0
        if case .tree(_, let root, let entries) = target {
            name = (root.path as NSString).lastPathComponent
            rootPath = root.path
            plannedFiles = ([root] + entries).filter { $0.kind == .file }.count
        } else { name = outcome.candidateID; rootPath = outcome.candidateID }
        func make(_ bytes: Int64, _ d: ShredItemResult.Disposition, _ message: String, _ removed: Bool) -> ShredItemResult {
            ShredItemResult(countedBytes: bytes, disposition: d, message: message, removedAnything: removed, warnings: outcome.warnings)
        }
        func notShredded(_ text: String, _ d: ShredItemResult.Disposition) -> ShredItemResult {
            let sentence = text.lowercased().contains("nothing was changed") ? text : text + ". Nothing was changed."
            return make(0, d, "\(name): \(sentence)", false)
        }

        switch outcome.result {
        case .removed(let bytes):
            if rootState == .gone {
                var r = make(bytes, .remove, "\(name) shredded", true)
                r.isProblem = false
                return r
            }
            return make(bytes, .block(note(for: rootState)), "\(name) shredded. \(note(for: rootState))", true)

        case .trashed:
            // Never expected for an overwrite-then-delete plan: count nothing, leave the row, say where to look.
            return make(0, .keep, "Unexpected result; check \(rootPath)", false)

        case .partiallyDone(let freed, let kept, let damaged):
            let removedAny = freed > 0 || (outcome.removedFiles ?? 0) > 0
            let stagingOnly = !kept.isEmpty && damaged.isEmpty && outcome.removedFiles == plannedFiles
                && kept.allSatisfy { $0.reason == .stagingLeftBehind }
            if stagingOnly && rootState == .gone {
                let where_ = kept.map(\.path).joined(separator: ", ")
                return make(freed, .remove, "\(name) shredded, but its work folder couldn't be removed and may still hold items: \(where_)", true)
            }
            let listed = kept.map { "\($0.path) (\(keptText($0.reason)))" } + damaged.map { "\($0) (partly overwritten)" }
            var text = "\(name) was only partly shredded"
            if let done = outcome.removedFiles { text += " (stopped after \(done) of \(plannedFiles) file(s))" }
            if !listed.isEmpty {
                text += ". Left: " + listed.prefix(3).joined(separator: ", ")
                if listed.count > 3 { text += " and \(listed.count - 3) more" }
            }
            var r: ShredItemResult
            switch rootState {
            case .same: r = make(freed, .keep, text, removedAny)
            case .gone: r = make(freed, .remove, text, removedAny)
            case .other, .unknown: r = make(freed, .block(note(for: rootState)), "\(text). \(note(for: rootState))", removedAny)
            }
            r.isPartial = true
            return r

        case .skipped(let why):
            switch why {
            case .missing: return notShredded("no longer there", .remove)
            case .changed: return notShredded("it changed since it was reviewed", .keep)
            case .protected(let r): return notShredded("protected now: \(r)", .keep)
            case .addedAfterReview: return notShredded("it changed since it was reviewed", .keep)
            case .preconditionFailed(let r): return notShredded(r, .keep)
            case .cancelled: return notShredded("cancelled", .keep)
            }

        case .failed(let text), .permissionDenied(let text):
            return notShredded(text, .keep)
        }
    }

    private nonisolated static func keptText(_ r: KeptEntry.Reason) -> String {
        switch r {
        case .changedAfterReview: return "changed after review"
        case .otherVolume: return "another volume"
        case .protected(let why): return "protected: \(why)"
        case .notEmpty: return "holds kept items"
        case .stagingLeftBehind: return "work folder left behind"
        case .failed(let why): return why
        }
    }
}

extension ReviewBuild {
    /// The Shredder's review, built only from the rows the review made (no file access here). `perform` is unused;
    /// the confirmed approval goes to `performApproved` with the same rows the sheet shows.
    static func shred(rows: [ShredReviewRow], perform: @escaping ([ShredReviewRow], TrashApproval?) -> Void) -> ReviewRequest {
        let entries = rows.compactMap { r in r.candidate.map { CleanupPlan.Entry($0, .overwriteThenDelete) } }
        return ReviewRequest(title: "Shred Permanently",
                             explanation: "Shredding skips the Trash and cannot be undone.",
                             items: rows.map {
                                 ReviewItem(id: $0.id, name: $0.url.lastPathComponent, location: $0.url.path, size: $0.allocatedBytes,
                                            action: .delete, risk: .review, note: "cannot be recovered", blocked: $0.blockedReason)
                             },
                             verb: "Shred", perform: { _ in },
                             trashPlan: entries.isEmpty ? nil : try? CleanupPlan(entries),
                             performApproved: { _, approval in perform(rows, approval) })
    }
}
