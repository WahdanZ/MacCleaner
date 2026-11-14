import Foundation
import Testing
@testable import MacCleanerCore

// The M01-03 contracts: pure values, made-up identities, no file system.

private func ident(_ path: String = "/Users/tester/Library/Caches/x", device: UInt64 = 1, inode: UInt64 = 100,
                   kind: FileIdentity.Kind = .directory, size: Int64 = 4096, mtime: Int64 = 1_700_000_000_000_000_000) -> FileIdentity {
    FileIdentity(path: path, device: device, inode: inode, kind: kind, size: size, modificationNanos: mtime)
}

private func candidate(_ id: String = "c1", targets: [CleanupTarget]? = nil, risk: CleanupRisk = .safeRegenerable,
                       title: String = "Caches", bytes: Int64 = 10) -> CleanupCandidate {
    CleanupCandidate(id: id, module: "caches", title: title, targets: targets ?? [.file(ident())],
                     estimatedBytes: bytes, risk: risk, recommended: true, explanation: "Rebuilt by the app.")
}

private func plan(_ entries: [CleanupPlan.Entry]) -> CleanupPlan {
    do { return try CleanupPlan(entries) } catch { fatalError("plan refused: \(error)") }
}

private func entry(_ name: String, inode: UInt64 = 200) -> FileIdentity {
    ident(ident().path + "/" + name, inode: inode + UInt64(name.unicodeScalars.first!.value), kind: .file)
}

private func contents(_ names: [String] = ["a"]) -> CleanupTarget {
    .directoryContents(folder: ident(), entries: names.map { entry($0) })
}

private let simctl = ToolCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", "X"],
                                 consequence: "The iOS 17.2 simulator runtime")

@Suite("FileIdentity")
struct FileIdentityTests {
    @Test func sameItemMatches() {
        #expect(ident().mismatch(against: ident()) == nil)
    }

    @Test func anotherInodeOrVolumeIsAReplacement() {
        #expect(ident().mismatch(against: ident(inode: 101)) == .replaced)
        #expect(ident().mismatch(against: ident(device: 2)) == .replaced)
        #expect(ident().mismatch(against: ident("/Users/tester/Library/Caches/y")) == .replaced)
    }

    @Test func folderSwappedForSymlinkIsCaught() {
        #expect(ident().mismatch(against: ident(inode: 999, kind: .symlink)) == .kindChanged(from: .directory, to: .symlink))
    }

    @Test func fileWrittenSinceReviewIsCaught() {
        let f = ident(kind: .file, size: 10)
        #expect(f.mismatch(against: ident(kind: .file, size: 11)) == .contentChanged)
        #expect(f.mismatch(against: ident(kind: .file, size: 10, mtime: 1)) == .contentChanged)
    }

    @Test func folderSizeAndTimeAreNotCompared() {
        #expect(ident().mismatch(against: ident(size: 8192, mtime: 1)) == nil)
    }

    @Test func flagsAndLinkCountAreNotCompared() {
        let a = ident(kind: .file)
        let b = FileIdentity(path: a.path, device: a.device, inode: a.inode, kind: .file, size: a.size,
                             modificationNanos: a.modificationNanos, linkCount: 3, flags: 0x2)
        #expect(a.mismatch(against: b) == nil)
    }
}

@Suite("CleanupPlan")
struct CleanupPlanTests {
    @Test func refusesPlansThatCantBeCarriedOutAsShown() {
        #expect(throws: CleanupPlan.Problem.empty) { try CleanupPlan([]) }
        #expect(throws: CleanupPlan.Problem.duplicateCandidate("c1")) {
            try CleanupPlan([.init(candidate(), .permanentDelete), .init(candidate(), .trash)])
        }
        #expect(throws: CleanupPlan.Problem.noTargets("c1")) { try CleanupPlan([.init(candidate(targets: []), .trash)]) }
        #expect(throws: CleanupPlan.Problem.protectedCandidate("c1")) {
            try CleanupPlan([.init(candidate(risk: .protected), .trash)])
        }
    }

    @Test func commandTargetsNeedTheCommandDisposition() {
        #expect(throws: CleanupPlan.Problem.dispositionMismatch("c1")) {
            try CleanupPlan([.init(candidate(targets: [.command(simctl)]), .permanentDelete)])
        }
        #expect(throws: CleanupPlan.Problem.dispositionMismatch("c1")) {
            try CleanupPlan([.init(candidate(), .command)])
        }
        #expect(throws: CleanupPlan.Problem.dispositionMismatch("c1")) {
            try CleanupPlan([.init(candidate(targets: [.command(simctl), .file(ident())]), .command)])
        }
        #expect(throws: Never.self) { try CleanupPlan([.init(candidate(targets: [.command(simctl)]), .command)]) }
    }

    @Test func digestIsStableAndHex() {
        let a = plan([.init(candidate(), .permanentDelete)])
        let b = plan([.init(candidate(), .permanentDelete)])
        #expect(a.digest == b.digest)
        #expect(a.digest.count == 64)
        #expect(a.digest.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func digestFollowsIdentityNotJustPath() {
        let a = plan([.init(candidate(targets: [.file(ident())]), .permanentDelete)])
        let swapped = plan([.init(candidate(targets: [.file(ident(inode: 101))]), .permanentDelete)])
        let relinked = plan([.init(candidate(targets: [.file(ident(kind: .symlink))]), .permanentDelete)])
        #expect(a.digest != swapped.digest)
        #expect(a.digest != relinked.digest)
    }

    @Test func digestCoversTheSnapshotTime() {
        func at(_ t: Int64) -> CleanupPlan {
            let f = ident()
            return plan([.init(candidate(targets: [.file(FileIdentity(path: f.path, device: f.device, inode: f.inode, kind: f.kind,
                                                                       size: f.size, modificationNanos: f.modificationNanos,
                                                                       capturedAtNanos: t))]), .permanentDelete)])
        }
        #expect(at(1).digest != at(2).digest)
    }


    @Test func digestCoversDispositionTargetFormAndOrder() {
        let x = candidate("x"), y = candidate("y", targets: [.file(ident(inode: 7))])
        let base = plan([.init(x, .permanentDelete), .init(y, .permanentDelete)])
        #expect(base.digest != plan([.init(x, .trash), .init(y, .permanentDelete)]).digest)
        #expect(base.digest != plan([.init(y, .permanentDelete), .init(x, .permanentDelete)]).digest)
        let contents = plan([.init(candidate("x", targets: [contents()]), .permanentDelete), .init(y, .permanentDelete)])
        #expect(base.digest != contents.digest)
    }

    @Test func digestIgnoresDisplayText() {
        let a = plan([.init(candidate(title: "Caches", bytes: 10), .trash)])
        let b = plan([.init(candidate(title: "App caches", bytes: 99), .trash)])
        #expect(a.digest == b.digest)
    }

    @Test func digestCoversWhatThePersonWasWarnedAbout() {
        let safe = plan([.init(candidate(risk: .safeRegenerable), .trash)])
        #expect(safe.digest != plan([.init(candidate(risk: .potentialUserData), .trash)]).digest)
        func cmd(_ consequence: String) -> CleanupPlan {
            plan([.init(candidate(targets: [.command(ToolCommand(executable: simctl.executable, arguments: simctl.arguments,
                                                                 consequence: consequence))]), .command)])
        }
        #expect(cmd("The iOS 17.2 runtime; Xcode downloads it again").digest != cmd("Nothing").digest)
    }

    @Test func commandArgumentsAreLengthPrefixed() {
        func p(_ args: [String]) -> CleanupPlan {
            plan([.init(candidate(targets: [.command(ToolCommand(executable: "/bin/x", arguments: args, consequence: ""))]), .command)])
        }
        #expect(p(["a b"]).digest != p(["a", "b"]).digest)
        #expect(p(["ab", ""]).digest != p(["a", "b"]).digest)
    }

    @Test func totals() {
        let p = plan([.init(candidate("a", bytes: 5), .trash), .init(candidate("b", bytes: 7), .trash)])
        #expect(p.estimatedBytes == 12)
        #expect(p.candidates.map(\.id) == ["a", "b"])
    }

    @Test func riskOrder() {
        #expect(CleanupRisk.allCases.sorted() == [.safeRegenerable, .reviewRequired, .potentialUserData, .privileged, .protected])
    }
}

@Suite("Folder contents")
struct DirectoryContentsTests {
    @Test func directChildrenOnTheSameVolumeOnly() {
        let folder = ident()
        #expect(entry("a").isDirectChild(of: folder))
        #expect(!ident(folder.path + "/a/b", inode: 5).isDirectChild(of: folder))       // nested
        #expect(!ident(folder.path + "x/a", inode: 5).isDirectChild(of: folder))        // sibling prefix
        #expect(!ident(folder.path + "/m", device: 9, inode: 5).isDirectChild(of: folder))  // mount point
        #expect(!ident(folder.path, inode: 5).isDirectChild(of: folder))                 // itself
        #expect(!entry("a").isDirectChild(of: ident(kind: .file)))                       // not a folder
    }

    @Test func planRefusesUnreviewedOrForeignEntries() {
        let folder = ident()
        #expect(throws: CleanupPlan.Problem.emptyContents("c1")) {
            try CleanupPlan([.init(candidate(targets: [.directoryContents(folder: folder, entries: [])]), .permanentDelete)])
        }
        #expect(throws: CleanupPlan.Problem.entryOutsideFolder("c1")) {
            try CleanupPlan([.init(candidate(targets: [.directoryContents(folder: folder, entries: [
                entry("a"), ident("/Users/tester/Documents/x", inode: 6)])]), .permanentDelete)])
        }
        #expect(throws: CleanupPlan.Problem.entryOutsideFolder("c1")) {
            try CleanupPlan([.init(candidate(targets: [.directoryContents(folder: folder, entries: [
                ident(folder.path + "/m", device: 9, inode: 5)])]), .permanentDelete)])
        }
    }

    @Test func anEntryAddedAfterReviewChangesTheDigest() {
        let reviewed = plan([.init(candidate(targets: [contents(["a", "b"])]), .permanentDelete)])
        let grown = plan([.init(candidate(targets: [contents(["a", "b", "c"])]), .permanentDelete)])
        let swapped = plan([.init(candidate(targets: [.directoryContents(folder: ident(), entries: [
            entry("a"), ident(ident().path + "/b", inode: 999)])]), .permanentDelete)])
        #expect(reviewed.digest != grown.digest)
        #expect(reviewed.digest != swapped.digest)
    }

    @Test func theExecutorReportsNewEntriesAsSkipped() {
        let added = ItemOutcome(candidateID: "c1", target: .file(entry("new")), result: .skipped(.addedAfterReview))
        #expect(!added.succeeded)
    }
}

@Suite("Approval ledger")
struct ApprovalLedgerTests {
    let p = plan([.init(candidate(), .permanentDelete)])
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func anIssuedApprovalWorksOnceForItsPlan() throws {
        var ledger = ApprovalLedger()
        let a = try ledger.issue(for: p, approvedBy: .userInApp, at: t0, lifetime: 60)
        #expect(a.planDigest == p.digest && a.expires == t0 + 60)
        #expect(ledger.redeem(a, for: p, at: t0 + 59) == nil)
        #expect(ledger.redeem(a, for: p, at: t0 + 59) == .alreadyUsed)
        #expect(ledger.outstandingCount == 0)
    }

    @Test func anApprovalNotIssuedHereIsRefused() throws {
        var mine = ApprovalLedger(), other = ApprovalLedger()
        let foreign = try other.issue(for: p, approvedBy: .userInApp, at: t0, lifetime: 60)
        #expect(mine.redeem(foreign, for: p, at: t0) == .notIssued)
        // Made outside a ledger (only possible inside Core; the initializer isn't public).
        let forged = CleanupApproval(plan: p, approvedBy: .userInApp, issued: t0, lifetime: 60, nonce: UUID())
        #expect(mine.redeem(forged, for: p, at: t0) == .notIssued)
    }

    @Test func aTamperedCopyIsRefused() throws {
        var ledger = ApprovalLedger()
        let a = try ledger.issue(for: p, approvedBy: .userViaMCPPrompt, at: t0, lifetime: 60)
        let copy = CleanupApproval(plan: p, approvedBy: .userInApp, issued: t0, lifetime: 600, nonce: a.nonce)
        #expect(ledger.redeem(copy, for: p, at: t0) == .notIssued)
    }

    @Test func aChangedPlanOrLateUseIsRefusedAndUsesItUp() throws {
        var ledger = ApprovalLedger()
        let swapped = plan([.init(candidate(targets: [.file(ident(inode: 101))]), .permanentDelete)])
        let a = try ledger.issue(for: p, approvedBy: .userInTerminal, at: t0, lifetime: 60)
        #expect(ledger.redeem(a, for: swapped, at: t0) == .planChanged)
        #expect(ledger.redeem(a, for: p, at: t0) == .alreadyUsed)       // fail closed: approve again

        let b = try ledger.issue(for: p, approvedBy: .userInTerminal, at: t0, lifetime: 60)
        #expect(ledger.redeem(b, for: p, at: t0 + 60) == .expired)
        #expect(ledger.redeem(b, for: p, at: t0 + 60) == .notIssued)    // used up and past expiry: forgotten

        let c = try ledger.issue(for: p, approvedBy: .userInTerminal, at: t0, lifetime: 60)
        ledger.prune(at: t0 + 61)
        #expect(ledger.redeem(c, for: p, at: t0 + 61) == .notIssued)    // expired unused approvals are dropped
    }

    @Test func lifetimeMustBePositiveAndBounded() {
        var ledger = ApprovalLedger()
        #expect(throws: ApprovalLedger.IssueRefusal.invalidLifetime) { try ledger.issue(for: p, approvedBy: .userInApp, at: t0, lifetime: 0) }
        #expect(throws: ApprovalLedger.IssueRefusal.invalidLifetime) { try ledger.issue(for: p, approvedBy: .userInApp, at: t0, lifetime: -5) }
        #expect(throws: ApprovalLedger.IssueRefusal.invalidLifetime) {
            try ledger.issue(for: p, approvedBy: .userInApp, at: t0, lifetime: ApprovalLedger.maxLifetime + 1)
        }
        #expect(ledger.outstandingCount == 0)
    }

    @Test func aStandingPolicyCoversOnlyRegenerablePermanentDeletes() throws {
        var ledger = ApprovalLedger()
        let policy = CleanupApproval.Approver.standingPolicy(id: "safe-clean", version: 1)
        _ = try ledger.issue(for: p, approvedBy: policy, at: t0, lifetime: 60)
        let refused: [(CleanupPlan, String)] = [
            (plan([.init(candidate("r", risk: .reviewRequired), .permanentDelete)]), "r"),
            (plan([.init(candidate("t"), .trash)]), "t"),
            (plan([.init(candidate("o", targets: [.file(ident(kind: .file))]), .overwriteThenDelete)]), "o"),
            (plan([.init(candidate("c", targets: [.command(simctl)]), .command)]), "c"),
        ]
        for (q, id) in refused {
            #expect(throws: ApprovalLedger.IssueRefusal.outsidePolicyScope(candidateID: id)) {
                try ledger.issue(for: q, approvedBy: policy, at: t0, lifetime: 60)
            }
        }
        // A person may approve the same plans.
        for (q, _) in refused { _ = try ledger.issue(for: q, approvedBy: .userInApp, at: t0, lifetime: 60) }
    }

    @Test func anAppOwnedApprovalCoversOnlyOneTrashMoveOfOneFolderOfItsKind() throws {
        func owned(_ id: String, module: String, targets: [CleanupTarget]) -> CleanupCandidate {
            CleanupCandidate(id: id, module: module, title: id, targets: targets, estimatedBytes: 1, risk: .reviewRequired,
                             recommended: false, explanation: "")
        }
        let folder = ident("/private/var/tmp/MacCleaner-uninstall.AbCdEf1234")
        var ledger = ApprovalLedger()
        for kind in CleanupApproval.AppOwnedKind.allCases {
            let ok = plan([.init(owned("s", module: kind.rawValue, targets: [.file(folder)]), .trash)])
            let a = try ledger.issue(for: ok, approvedBy: .appOwned(kind), at: t0, lifetime: 60)
            #expect(a.approvedBy == .appOwned(kind) && ledger.redeem(a, for: ok, at: t0) == nil)
        }
        let staging = CleanupApproval.Approver.appOwned(.adminStaging)
        let refused: [CleanupPlan] = [
            // The other kind's module, or any other module.
            plan([.init(owned("s", module: "installed-skill", targets: [.file(folder)]), .trash)]),
            plan([.init(owned("s", module: "uninstall", targets: [.file(folder)]), .trash)]),
            // Not a Trash move.
            plan([.init(owned("s", module: "admin-staging", targets: [.file(folder)]), .permanentDelete)]),
            // Not exactly one folder: a file, two targets, a folder's contents, a command.
            plan([.init(owned("s", module: "admin-staging", targets: [.file(ident(kind: .file))]), .trash)]),
            plan([.init(owned("s", module: "admin-staging", targets: [.file(folder), .file(ident("/b", inode: 7))]), .trash)]),
            plan([.init(owned("s", module: "admin-staging", targets: [contents()]), .trash)]),
            plan([.init(owned("s", module: "admin-staging", targets: [.command(simctl)]), .command)]),
            // More than one entry.
            plan([.init(owned("s", module: "admin-staging", targets: [.file(folder)]), .trash),
                  .init(owned("t", module: "admin-staging", targets: [.file(ident("/c", inode: 9))]), .trash)]),
        ]
        for q in refused {
            #expect(throws: ApprovalLedger.IssueRefusal.self) { try ledger.issue(for: q, approvedBy: staging, at: t0, lifetime: 60) }
        }
        #expect(ledger.outstandingCount == 0)
        // An app-owned approval names who approved it; it is never a person's confirmation.
        let ok = plan([.init(owned("s", module: "admin-staging", targets: [.file(folder)]), .trash)])
        let a = try ledger.issue(for: ok, approvedBy: staging, at: t0, lifetime: 60)
        #expect(a.approvedBy != .userInApp && a.approvedBy != .appOwned(.installedSkill))
    }

    @Test func aNonInteractiveOverrideIsRecordedAsSuch() throws {
        var ledger = ApprovalLedger()
        let a = try ledger.issue(for: p, approvedBy: .nonInteractiveOverride, at: t0, lifetime: 60)
        #expect(a.approvedBy == .nonInteractiveOverride && a.approvedBy != .userInTerminal)
        #expect(ledger.redeem(a, for: p, at: t0) == nil && ledger.redeem(a, for: p, at: t0) == .alreadyUsed)
    }

    @Test func validityWindowIsHalfOpen() {
        let a = CleanupApproval(plan: p, approvedBy: .userInApp, issued: t0, lifetime: 60, nonce: UUID())
        #expect(a.refusal(for: p, at: t0) == nil)
        #expect(a.refusal(for: p, at: t0 + 60) == .expired)
        #expect(a.refusal(for: p, at: t0 - 1) == .expired)
    }

    @Test func eachApprovalHasItsOwnNonceAndApprover() throws {
        var ledger = ApprovalLedger()
        let a = try ledger.issue(for: p, approvedBy: .standingPolicy(id: "safe-clean", version: 1), at: t0, lifetime: 60)
        let b = try ledger.issue(for: p, approvedBy: .standingPolicy(id: "safe-clean", version: 1), at: t0, lifetime: 60)
        #expect(a.nonce != b.nonce)
        #expect(a.approvedBy != .standingPolicy(id: "safe-clean", version: 2))
        #expect(ledger.outstandingCount == 2)
        ledger.prune(at: t0 + 60)
        #expect(ledger.outstandingCount == 0)
    }
}

@Suite("ScanOutcome")
struct ScanOutcomeTests {
    @Test func completeOnlyWhenNothingWasMissed() {
        #expect(ScanOutcome(items: [1, 2]).isComplete)
        #expect(ScanOutcome(items: [1], warnings: ["slow disk"]).isComplete)
        #expect(!ScanOutcome<Int>(inaccessible: [AccessProblem(path: "/x", kind: .needsFullDiskAccess)]).isComplete)
        #expect(!ScanOutcome<Int>(partialErrors: ["read failed"]).isComplete)
        #expect(!ScanOutcome<Int>(wasCancelled: true).isComplete)
    }
}

@Suite("CleanupReport")
struct CleanupReportTests {
    let target = CleanupTarget.file(ident())
    func outcome(_ r: ItemOutcome.Result) -> ItemOutcome { ItemOutcome(candidateID: "c1", target: target, result: r) }

    @Test func freedAndTrashedAreCountedSeparately() {
        let r = CleanupReport(planDigest: "d", outcomes: [outcome(.removed(bytes: 100)),
                                                         outcome(.trashed(bytes: 40, recoveryPath: "/Users/tester/.Trash/x"))],
                              wasCancelled: false)
        #expect(r.freedBytes == 100)
        #expect(r.movedToTrashBytes == 40)
        #expect(r.allSucceeded)
    }

    @Test func aPartialRemovalIsNeitherSuccessNorNothing() {
        let r = CleanupReport(planDigest: "d", outcomes: [outcome(.removed(bytes: 100)),
                                                         outcome(.partiallyDone(freedBytes: 30, kept: [KeptEntry(path: "/a", reason: .changedAfterReview)], damaged: []))],
                              wasCancelled: false)
        #expect(!r.allSucceeded)
        #expect(r.freedBytes == 130)
    }

    @Test func skippedFailedCancelledOrEmptyIsNotSuccess() {
        #expect(!CleanupReport(planDigest: "d", outcomes: [outcome(.skipped(.changed(.replaced)))], wasCancelled: false).allSucceeded)
        #expect(!CleanupReport(planDigest: "d", outcomes: [outcome(.failed("busy"))], wasCancelled: false).allSucceeded)
        #expect(!CleanupReport(planDigest: "d", outcomes: [outcome(.removed(bytes: 1))], wasCancelled: true).allSucceeded)
        #expect(!CleanupReport(planDigest: "d", outcomes: [], wasCancelled: false).allSucceeded)
    }
}

@Suite("ProgressEvent")
struct ProgressEventTests {
    @Test func streamsInOrderAndEndsOnATerminalEvent() async {
        let report = CleanupReport(planDigest: "d", outcomes: [], wasCancelled: false)
        let sent: [ProgressEvent] = [.scanStarted(module: "caches"), .moduleProgress(module: "caches", completed: 1, total: nil),
                                     .itemsDiscovered(module: "caches", count: 3, bytes: 30),
                                     .accessProblem(AccessProblem(path: "/x", kind: .permissionDenied)),
                                     .cleanupStarted(planDigest: "d", targetCount: 0), .finished(report)]
        let stream = AsyncStream<ProgressEvent> { c in
            Task.detached { for e in sent { c.yield(e) }; c.finish() }   // crosses an isolation boundary: needs Sendable
        }
        var got: [ProgressEvent] = []
        for await e in stream { got.append(e) }
        #expect(got == sent)
        #expect(got.filter(\.isTerminal) == [.finished(report)])
        #expect(ProgressEvent.cancelled.isTerminal)
    }
}
