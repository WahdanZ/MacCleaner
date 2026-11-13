import Foundation
import MacCleanerCore

/// The one code path that removes or trashes anything (once the app is moved onto it, M01-04b and later).
///
/// For each target of an approved plan, in order:
/// 1. the protection rules as they are now (something may have been protected after review),
/// 2. the identity captured at scan time against what is there now,
/// 3. the file operation, which checks the identity again at the last moment (see `CleanupFileSystem`),
/// 4. an `itemFinished` event with the true outcome.
///
/// Folder-contents targets act only on the reviewed entries; anything that appeared in the folder after review is
/// left alone and reported. Cancellation is checked between targets. The report is truthful, not atomic: what was
/// already removed stays removed, and every target says what happened to it.
public actor CleanupExecutor {
    public static let defaultLifetime: TimeInterval = 600

    private let fileSystem: any CleanupFileSystem
    private let protection: any ProtectionChecking
    private let now: @Sendable () -> Date
    private var ledger = ApprovalLedger()

    /// `now` is replaced only by tests.
    public init(fileSystem: any CleanupFileSystem, protection: any ProtectionChecking,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileSystem = fileSystem
        self.protection = protection
        self.now = now
    }

    /// Records an approval of exactly `plan`, attributed to `approver`. It does not check that the approval happened:
    /// the caller must call it only from the flow where it did, right after the person confirmed this plan — the
    /// review sheet (`.userInApp`), the terminal prompt on a TTY (`.userInTerminal`), Mac Cleaner's own confirmation
    /// window for an MCP request (`.userViaMCPPrompt`) — or from the scheduler for an enabled policy whose scope
    /// covers the plan (`.standingPolicy`), or for one folder Mac Cleaner made itself, with that operation's own
    /// proof (`.appOwned`, which the ledger limits to one Trash move of one folder). The approval works once, in this
    /// process, until it expires.
    public func approve(_ plan: CleanupPlan, by approver: CleanupApproval.Approver,
                        lifetime: TimeInterval = CleanupExecutor.defaultLifetime) throws(CleanupApproval.IssueRefusal) -> CleanupApproval {
        try ledger.issue(for: plan, approvedBy: approver, at: now(), lifetime: lifetime)
    }

    /// A caller's own check for one item, run right before it is handled (after protection, before the identity
    /// check): nil to go ahead, otherwise why not. Gets the candidate's id and the item's identity.
    public typealias Precondition = @Sendable (_ candidateID: String, _ item: FileIdentity) -> String?

    /// Approvals issued and not yet used (for tests and diagnostics).
    public var outstandingApprovals: Int { ledger.outstandingCount }

    /// Runs on the executor right after one item's outcome is known and before the next item is touched (a durable
    /// per-item boundary: e.g. the app records a Trash move for Put Back here). nil to go on; otherwise why to stop,
    /// and every later item is skipped untouched with that reason.
    public typealias ItemCompletion = @Sendable (ItemOutcome) -> String?

    /// Carries out `plan`. Throws, changing nothing, unless `approval` was issued by this executor for this exact
    /// plan, hasn't expired and hasn't been used. `precondition`, when given, can refuse single items right before
    /// they are handled; `onItemFinished` runs after each item, before the next. `progress` receives every event and
    /// is finished at the end.
    public func execute(_ plan: CleanupPlan, approval: CleanupApproval, precondition: Precondition? = nil,
                        onItemFinished: ItemCompletion? = nil,
                        progress: AsyncStream<ProgressEvent>.Continuation? = nil) throws(CleanupApproval.Refusal) -> CleanupReport {
        if let refusal = ledger.redeem(approval, for: plan, at: now()) {
            progress?.finish()
            throw refusal
        }
        let targetCount = plan.entries.reduce(0) { $0 + $1.candidate.targets.count }
        progress?.yield(.cleanupStarted(planDigest: plan.digest, targetCount: targetCount))

        var outcomes: [ItemOutcome] = []
        var cancelled = false
        var stopped: String?
        /// Why the next item must not be touched, if it mustn't.
        func halt() -> SkipReason? {
            if let why = stopped { return .preconditionFailed(why) }
            if cancelled || Task.isCancelled { cancelled = true; return .cancelled }
            return nil
        }
        func finish(_ r: ItemOutcome) {
            outcomes.append(r)
            progress?.yield(.itemFinished(r))
            if r.result == .skipped(.cancelled) { cancelled = true }
            if stopped == nil, let why = onItemFinished?(r) { stopped = why }
        }
        for entry in plan.entries {
            let id = entry.candidate.id
            for target in entry.candidate.targets {
                if let reason = halt() {
                    finish(ItemOutcome(candidateID: id, target: target, result: .skipped(reason)))
                } else {
                    perform(target, entry.disposition, candidate: id, precondition: precondition, halt: halt, finish: finish)
                }
            }
        }
        let report = CleanupReport(planDigest: plan.digest, outcomes: outcomes, wasCancelled: cancelled)
        progress?.yield(cancelled ? .cancelled : .finished(report))
        progress?.finish()
        return report
    }

    // MARK: - Targets

    private func perform(_ target: CleanupTarget, _ disposition: Disposition, candidate: String,
                         precondition: Precondition?, halt: () -> SkipReason?, finish: (ItemOutcome) -> Void) {
        switch target {
        case .file(let item):
            finish(handle(item, disposition, candidate: candidate, precondition: precondition))
        case .directoryContents(let folder, let reviewed):
            contents(folder, reviewed, disposition, candidate: candidate, precondition: precondition, halt: halt, finish: finish)
        case .command:
            finish(ItemOutcome(candidateID: candidate, target: target,
                               result: .failed("Tool commands don't run through the cleanup executor yet; nothing was run")))
        }
    }

    /// The reviewed entries of a folder, each revalidated on its own; entries added since review are left alone.
    /// Each entry's outcome is finished before the next entry is touched.
    private func contents(_ folder: FileIdentity, _ reviewed: [FileIdentity], _ disposition: Disposition,
                          candidate: String, precondition: Precondition?,
                          halt: () -> SkipReason?, finish: (ItemOutcome) -> Void) {
        func skipAll(_ reason: SkipReason) {
            for r in reviewed { finish(ItemOutcome(candidateID: candidate, target: .file(r), result: .skipped(reason))) }
        }
        let current: [FileIdentity]
        do {
            current = try fileSystem.entries(of: folder)
        } catch let refusal as FileSystemRefusal {
            switch refusal {
            case .missing: return skipAll(.missing)
            case .changed(let m): return skipAll(.changed(m))
            case .protected(let why): return skipAll(.protected(why))
            case .permissionDenied(let why):
                for r in reviewed { finish(ItemOutcome(candidateID: candidate, target: .file(r), result: .permissionDenied(why))) }
                return
            }
        } catch {
            for r in reviewed { finish(ItemOutcome(candidateID: candidate, target: .file(r), result: .failed("\(error)"))) }
            return
        }
        let reviewedPaths = Set(reviewed.map(\.path))
        for added in current where !reviewedPaths.contains(added.path) {
            finish(ItemOutcome(candidateID: candidate, target: .file(added), result: .skipped(.addedAfterReview)))
        }
        for item in reviewed {
            if let reason = halt() {
                finish(ItemOutcome(candidateID: candidate, target: .file(item), result: .skipped(reason)))
            } else {
                finish(handle(item, disposition, candidate: candidate, precondition: precondition))
            }
        }
    }

    private func handle(_ item: FileIdentity, _ disposition: Disposition, candidate: String,
                        precondition: Precondition?) -> ItemOutcome {
        func outcome(_ r: ItemOutcome.Result) -> ItemOutcome { ItemOutcome(candidateID: candidate, target: .file(item), result: r) }
        switch disposition {
        case .trash, .permanentDelete: break
        case .overwriteThenDelete, .quarantine, .command:
            return outcome(.failed("\(disposition.rawValue) isn't done by the cleanup executor yet; nothing was changed"))
        }
        if let why = protection.refusal(path: item.path, disposition: disposition) { return outcome(.skipped(.protected(why))) }
        if let why = precondition?(candidate, item) { return outcome(.skipped(.preconditionFailed(why))) }
        do {
            guard let current = try fileSystem.identity(at: item.path) else { return outcome(.skipped(.missing)) }
            if let m = item.mismatch(against: current) { return outcome(.skipped(.changed(m))) }
            if disposition == .trash {
                let r = try fileSystem.moveToTrash(item)
                return outcome(.trashed(bytes: r.bytes, recoveryPath: r.recoveryPath))
            }
            let rules = protection
            let r = try fileSystem.remove(item, protection: { rules.refusal(path: $0, disposition: .permanentDelete) })
            return outcome(r.kept.isEmpty ? .removed(bytes: r.freedBytes)
                                          : .partiallyDone(freedBytes: r.freedBytes, kept: r.kept, damaged: []))
        } catch let refusal as FileSystemRefusal {
            switch refusal {
            case .missing: return outcome(.skipped(.missing))
            case .changed(let m): return outcome(.skipped(.changed(m)))
            case .protected(let why): return outcome(.skipped(.protected(why)))
            case .permissionDenied(let why): return outcome(.permissionDenied(why))
            }
        } catch {
            return outcome(.failed("\(error)"))
        }
    }
}
