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

    /// Records that a person (or an enabled policy) approved exactly `plan`. Call it only from the flow where that
    /// approval happened: the review sheet (`.userInApp`), the terminal prompt on a TTY (`.userInTerminal`), Mac
    /// Cleaner's own confirmation window for an MCP request (`.userViaMCPPrompt`), or the scheduler running an
    /// enabled policy (`.standingPolicy`). The approval works once, in this process, until it expires.
    public func approve(_ plan: CleanupPlan, by approver: CleanupApproval.Approver,
                        lifetime: TimeInterval = CleanupExecutor.defaultLifetime) throws(CleanupApproval.IssueRefusal) -> CleanupApproval {
        try ledger.issue(for: plan, approvedBy: approver, at: now(), lifetime: lifetime)
    }

    /// Carries out `plan`. Throws, changing nothing, unless `approval` was issued by this executor for this exact
    /// plan, hasn't expired and hasn't been used. `progress` receives every event and is finished at the end.
    public func execute(_ plan: CleanupPlan, approval: CleanupApproval,
                        progress: AsyncStream<ProgressEvent>.Continuation? = nil) throws(CleanupApproval.Refusal) -> CleanupReport {
        if let refusal = ledger.redeem(approval, for: plan, at: now()) {
            progress?.finish()
            throw refusal
        }
        let targetCount = plan.entries.reduce(0) { $0 + $1.candidate.targets.count }
        progress?.yield(.cleanupStarted(planDigest: plan.digest, targetCount: targetCount))

        var outcomes: [ItemOutcome] = []
        var cancelled = false
        for entry in plan.entries {
            let id = entry.candidate.id
            for target in entry.candidate.targets {
                if !cancelled, Task.isCancelled { cancelled = true }
                let results: [ItemOutcome]
                if cancelled {
                    results = [ItemOutcome(candidateID: id, target: target, result: .skipped(.cancelled))]
                } else {
                    results = perform(target, entry.disposition, candidate: id)
                }
                for r in results {
                    outcomes.append(r)
                    progress?.yield(.itemFinished(r))
                }
            }
        }
        let report = CleanupReport(planDigest: plan.digest, outcomes: outcomes, wasCancelled: cancelled)
        progress?.yield(cancelled ? .cancelled : .finished(report))
        progress?.finish()
        return report
    }

    // MARK: - Targets

    private func perform(_ target: CleanupTarget, _ disposition: Disposition, candidate: String) -> [ItemOutcome] {
        switch target {
        case .file(let item):
            return [handle(item, disposition, candidate: candidate)]
        case .directoryContents(let folder, let reviewed):
            return contents(folder, reviewed, disposition, candidate: candidate)
        case .command:
            return [ItemOutcome(candidateID: candidate, target: target,
                                result: .failed("Tool commands don't run through the cleanup executor yet; nothing was run"))]
        }
    }

    /// The reviewed entries of a folder, each revalidated on its own; entries added since review are left alone.
    private func contents(_ folder: FileIdentity, _ reviewed: [FileIdentity], _ disposition: Disposition,
                          candidate: String) -> [ItemOutcome] {
        func skipAll(_ reason: SkipReason) -> [ItemOutcome] {
            reviewed.map { ItemOutcome(candidateID: candidate, target: .file($0), result: .skipped(reason)) }
        }
        let current: [FileIdentity]
        do {
            current = try fileSystem.entries(of: folder)
        } catch let refusal as FileSystemRefusal {
            switch refusal {
            case .missing: return skipAll(.missing)
            case .changed(let m): return skipAll(.changed(m))
            }
        } catch {
            return reviewed.map { ItemOutcome(candidateID: candidate, target: .file($0), result: .failed("\(error)")) }
        }
        let reviewedPaths = Set(reviewed.map(\.path))
        var out = current.filter { !reviewedPaths.contains($0.path) }.map {
            ItemOutcome(candidateID: candidate, target: .file($0), result: .skipped(.addedAfterReview))
        }
        for item in reviewed {
            if Task.isCancelled {
                out.append(ItemOutcome(candidateID: candidate, target: .file(item), result: .skipped(.cancelled)))
            } else {
                out.append(handle(item, disposition, candidate: candidate))
            }
        }
        return out
    }

    private func handle(_ item: FileIdentity, _ disposition: Disposition, candidate: String) -> ItemOutcome {
        func outcome(_ r: ItemOutcome.Result) -> ItemOutcome { ItemOutcome(candidateID: candidate, target: .file(item), result: r) }
        switch disposition {
        case .trash, .permanentDelete: break
        case .overwriteThenDelete, .quarantine, .command:
            return outcome(.failed("\(disposition.rawValue) isn't done by the cleanup executor yet; nothing was changed"))
        }
        if let why = protection.refusal(path: item.path, disposition: disposition) { return outcome(.skipped(.protected(why))) }
        do {
            guard let current = try fileSystem.identity(at: item.path) else { return outcome(.skipped(.missing)) }
            if let m = item.mismatch(against: current) { return outcome(.skipped(.changed(m))) }
            if disposition == .trash {
                let r = try fileSystem.moveToTrash(item)
                return outcome(.trashed(bytes: r.bytes, recoveryPath: r.recoveryPath))
            }
            let r = try fileSystem.remove(item)
            return outcome(r.kept.isEmpty ? .removed(bytes: r.freedBytes)
                                          : .partiallyDone(freedBytes: r.freedBytes, kept: r.kept, damaged: []))
        } catch let refusal as FileSystemRefusal {
            switch refusal {
            case .missing: return outcome(.skipped(.missing))
            case .changed(let m): return outcome(.skipped(.changed(m)))
            }
        } catch {
            return outcome(.failed("\(error)"))
        }
    }
}
