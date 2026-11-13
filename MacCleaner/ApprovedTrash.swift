import Foundation
import MacCleanerCore
import MacCleanerFeatures
import MacCleanerPlatform

// The approved-Trash path (M01-04b). A Trash move that goes through here was reviewed item by item in the review
// sheet, which captured each item's identity when it opened; the person's confirmation became an approval for a
// plan built from exactly those identities (ReviewConfirmation); the cleanup executor re-checks protection and
// identity right before each move. Anything changed since review is left alone and reported.
//
// Callers not migrated yet still use AppEngine.trash (the legacy path). Remaining legacy callers move here in the
// next M01-04b pull requests; then AppEngine.trash's bypass is removed.

/// One cleanup executor for this process (the app, a `--cli` run or an `--mcp` server each have their own).
enum AppCleanup {
    /// Moves one item to the Trash and returns where it went: the system Trash (FileManager.trashItem) in the app,
    /// the CLI and the MCP server. Every Trash move goes through here (the executor's file system and the legacy
    /// AppEngine.trash). Only the self-test replaces it, at its start, with a folder in its throwaway home, so tests
    /// never touch the real Trash (trashItem ignores CFFIXED_USER_HOME).
    nonisolated(unsafe) static var trashMover: LocalFileSystem.TrashMover = LocalFileSystem.systemTrash

    static let executor = CleanupExecutor(fileSystem: LocalFileSystem(trashMover: { try AppCleanup.trashMover($0) }),
                                          protection: AppProtection())

    /// `url` with the symlinks in its parent folders resolved (realpath), the item itself not followed. The executor
    /// refuses a symlink anywhere in a path, and URL standardization turns /private/var back into /var.
    static func physicalPath(_ url: URL) -> String {
        let std = url.standardizedFileURL
        let parent = std.deletingLastPathComponent().path
        guard let r = realpath(parent, nil) else { return std.path }
        defer { free(r) }
        let p = String(cString: r)
        return (p == "/" ? "" : p) + "/" + std.lastPathComponent
    }

    /// What is at `url` now, as the review sheet shows it. nil when nothing is there or it can't be read.
    static func snapshot(_ url: URL) -> FileIdentity? {
        try? LocalFileSystem().identity(at: physicalPath(url))
    }

    /// A Trash plan from exactly the reviewed items that have a snapshot and aren't blocked. nil when there are none.
    static func trashPlan(_ items: [ReviewItem], module: String) -> CleanupPlan? {
        trashPlan(items.compactMap { i in
            guard i.blocked == nil, let s = i.snapshot else { return nil }
            return (i.id, i.name, s, i.size ?? 0, i.note ?? "")
        }, module: module)
    }

    /// A Trash plan from exactly these snapshots (id, title, identity, size, explanation). nil when there are none.
    static func trashPlan(_ snapshots: [(id: String, title: String, item: FileIdentity, size: Int64, explanation: String)],
                          module: String) -> CleanupPlan? {
        let entries = snapshots.map { s in
            CleanupPlan.Entry(CleanupCandidate(id: s.id, module: module, title: s.title, targets: [.file(s.item)],
                                               estimatedBytes: s.size, risk: .reviewRequired, recommended: false,
                                               explanation: s.explanation), .trash)
        }
        return entries.isEmpty ? nil : try? CleanupPlan(entries)
    }

    /// Records one Trash move for Put Back; true when it reached the disk. Replaced only by the self-test (to make
    /// the write fail).
    nonisolated(unsafe) static var recordMove: @Sendable (_ original: String, _ trashed: String, _ size: Int64,
                                                          _ source: String) -> Bool = { original, trashed, size, source in
        TrashLog.shared.record(original: original, trashed: trashed, size: size, source: source, restorable: true)
    }
    /// Test-only: runs after a move was recorded and before the next item is touched (the self-test interrupts or
    /// kills the process here). nil in the app.
    nonisolated(unsafe) static var afterRecording: (@Sendable (String) -> Void)?

    static let unrecordedStop = "An earlier item was moved to the Trash but couldn't be recorded for Put Back, so the rest were left alone"

    /// Moves an approved Trash plan's items to the Trash. Each move is recorded in the Trash log (for Put Back) as
    /// soon as it happens, before the executor touches the next item, so an interruption or crash never loses the
    /// record of a move that was made. If a record can't be written, the run stops there and says so. `precondition`
    /// can refuse single items right before they move.
    static func moveToTrash(_ decision: TrashApproval, source: String,
                            precondition: CleanupExecutor.Precondition? = nil) async -> TrashRun {
        let approved: ApprovedTrash
        switch decision {
        case .approved(let a): approved = a
        case .refused(let plan, let reason): return TrashRun(problems: plan.candidates.map { ($0.id, reason) })
        }
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        let sizes = Dictionary(approved.plan.candidates.map { ($0.id, $0.estimatedBytes) }, uniquingKeysWith: { a, _ in a })
        let record = recordMove, after = afterRecording
        let unrecorded = IDSet()
        var run = TrashRun()
        do {
            let report = try await executor.execute(
                approved.plan, approval: approved.approval, precondition: precondition,
                onItemFinished: { o in
                    guard case .file(let item) = o.target, case .trashed(_, let recovery) = o.result else { return nil }
                    guard record(item.path, recovery, sizes[o.candidateID] ?? 0, source) else {
                        unrecorded.insert(o.candidateID)
                        return unrecordedStop
                    }
                    after?(o.candidateID)
                    return nil
                })
            for o in report.outcomes {
                guard case .file = o.target else { continue }
                if case .trashed(_, let recovery) = o.result {
                    run.moved[o.candidateID] = sizes[o.candidateID] ?? 0
                    if unrecorded.contains(o.candidateID) {
                        run.problems.append((o.candidateID, "moved to the Trash (\(recovery)), but it couldn't be recorded "
                                             + "for Put Back; drag it out of the Trash in Finder to restore it"))
                    }
                } else {
                    run.problems.append((o.candidateID, Self.text(o.result)))
                }
            }
            run.report = report
        } catch {
            let why = Self.text(error)
            run.problems = approved.plan.candidates.map { ($0.id, why) }
        }
        return run
    }

    /// `moveToTrash` for synchronous code (the engines, the MCP server, the CLI): waits for it. Nothing on this path
    /// needs the main thread, so it may be called on it.
    static func moveToTrashBlocking(_ decision: TrashApproval, source: String,
                                    precondition: CleanupExecutor.Precondition? = nil) -> TrashRun {
        let slot = RunSlot()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            slot.run = await moveToTrash(decision, source: source, precondition: precondition)
            done.signal()
        }
        done.wait()
        return slot.run ?? TrashRun()
    }

    /// For an item a scan found and a screen describes (name, size, risk from the scan): the identity to approve
    /// — the scan's own — or why it can't be approved. If what is at `url` now isn't the item the scan found, the
    /// selection is stale: it is refused and needs a rescan, never re-captured under the old description.
    static func scannedSnapshot(_ url: URL, scanned: FileIdentity?) -> (identity: FileIdentity?, refusal: String?) {
        guard let scanned else { return (nil, "It wasn't identified when it was found. Scan again to review it") }
        guard let now = snapshot(url) else { return (nil, "It's no longer there") }
        if scanned.path != now.path || scanned.mismatch(against: now) != nil {
            return (nil, "It changed since the scan. Scan again to review it")
        }
        return (scanned, nil)
    }

    /// One reviewed Trash item of an engine: its id, display name, the URL its `.trash` action names, and the
    /// identity its scan captured.
    typealias EngineTrashItem = (id: String, name: String, url: URL, identity: FileIdentity?)

    /// The Trash part of an engine's run (SDK archives, System Data): moves exactly the approved items among the
    /// engine's reviewed Trash items. It never makes an approval and never re-captures or rebuilds the plan; it uses
    /// the one given, unchanged. Nothing at all moves (every item says why) when there is no approval, or the plan
    /// isn't exactly a set of this engine's reviewed Trash items: each entry must be a `.trash` of `module`, name one
    /// of `items` by id, have exactly one target whose path is that item's `.trash` URL and whose identity is the
    /// item's scanned identity, and no two entries may name the same target. A reviewed item not in the plan is
    /// reported and left alone.
    static func engineTrash(_ items: [EngineTrashItem], module: String, _ decision: TrashApproval?,
                            source: String) -> (moved: [String: Int64], errors: [String]) {
        guard !items.isEmpty else { return ([:], []) }
        guard let decision else {
            return ([:], items.map { "\($0.name): it wasn't approved for the Trash, so it was left alone" })
        }
        let plan: CleanupPlan
        switch decision { case .approved(let a): plan = a.plan; case .refused(let p, _): plan = p }
        if let why = planMismatch(plan, items, module: module) {
            return ([:], items.map { "\($0.name): the approved list doesn't match the items (\(why)), so nothing was moved" })
        }
        let planned = Set(plan.candidates.map(\.id))
        var errors = items.filter { !planned.contains($0.id) }.map {
            "\($0.name): it wasn't in the reviewed list for the Trash, so it was left alone"
        }
        let run = moveToTrashBlocking(decision, source: source)
        let names = Dictionary(items.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for p in run.problems { errors.append("\(names[p.id] ?? p.id): \(p.message)") }
        return (run.moved, errors)
    }

    /// nil when every plan entry is exactly one of `items`' Trash actions, as reviewed; otherwise what doesn't fit.
    static func planMismatch(_ plan: CleanupPlan, _ items: [EngineTrashItem], module: String) -> String? {
        var byID: [String: EngineTrashItem] = [:]
        for i in items {
            guard byID[i.id] == nil else { return "item \(i.id) is listed twice" }
            byID[i.id] = i
        }
        var targets = Set<String>()
        for e in plan.entries {
            let c = e.candidate
            guard e.disposition == .trash else { return "\(c.id) isn't a Trash move" }
            guard c.module == module else { return "\(c.id) belongs to \(c.module), not \(module)" }
            guard let item = byID[c.id] else { return "\(c.id) isn't one of the reviewed items" }
            guard c.targets.count == 1, case .file(let f) = c.targets[0] else { return "\(c.id) doesn't name exactly one item" }
            guard f.path == physicalPath(item.url) else { return "\(c.id) names a different path than its item" }
            guard let scanned = item.identity, f == scanned else { return "\(c.id) isn't the item the scan found" }
            guard targets.insert(f.path).inserted else { return "\(f.path) is named twice" }
        }
        return nil
    }

    static func text(_ r: ItemOutcome.Result) -> String {
        switch r {
        case .trashed, .removed: return "done"
        case .skipped(.changed): return "it changed after you reviewed it, so it was left alone"
        case .skipped(.missing): return "it's no longer there"
        case .skipped(.protected(let why)): return why
        case .skipped(.preconditionFailed(let why)): return why
        case .skipped(.addedAfterReview): return "it appeared after you reviewed the list, so it was left alone"
        case .skipped(.cancelled): return "cancelled"
        case .failed(let why): return why
        case .partiallyDone: return "only partly done"
        }
    }

    static func text(_ e: Error) -> String {
        switch e {
        case CleanupApproval.Refusal.alreadyUsed: return "this approval was already used; review the items again"
        case CleanupApproval.Refusal.expired: return "the approval expired; review the items again"
        case CleanupApproval.Refusal.planChanged, CleanupApproval.Refusal.notIssued:
            return "the items don't match what was approved; review them again"
        default: return "\(e)"
        }
    }
}

/// A plan built from what the review sheet showed, and the approval the person gave for exactly that plan.
/// Made only by ReviewConfirmation.
struct ApprovedTrash: Sendable {
    let plan: CleanupPlan
    let approval: CleanupApproval
}

/// A thread-safe set of review-item ids (written from the executor's per-item callback).
final class IDSet: @unchecked Sendable {   // `ids` behind `lock`
    private let lock = NSLock()
    private var ids: Set<String> = []
    func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}

/// The outcome of a confirmation for the Trash part of a review.
enum TrashApproval: Sendable {
    case approved(ApprovedTrash)
    /// The executor wouldn't issue an approval; nothing is moved, and every item says why.
    case refused(plan: CleanupPlan, reason: String)
}

/// What an approved Trash run did, by review-item id.
struct TrashRun: Sendable {
    /// Moved to the Trash, with the reviewed size.
    var moved: [String: Int64] = [:]
    /// Not moved, with why.
    var problems: [(id: String, message: String)] = []
    var report: CleanupReport?
}

/// The app's protection rules for the executor, read as they are when asked.
struct AppProtection: ProtectionChecking {
    func refusal(path: String, disposition: Disposition) -> String? {
        let url = URL(fileURLWithPath: path)
        switch disposition {
        case .trash:
            return TrashGuard.reason(url)
        case .permanentDelete:
            if let why = ProtectedPaths.reason(url) { return why }
            return SafetyGuard.isAllowed(url, allowContainer: true) ? nil : "Outside the folders Mac Cleaner may delete"
        case .overwriteThenDelete, .quarantine, .command:
            return "Not handled by the cleanup executor yet"
        }
    }
}

/// Carries a run's result out of a detached task (written once before the semaphore is signalled).
final class RunSlot: @unchecked Sendable {
    var run: TrashRun?
}
