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

    @Test func digestCoversDispositionTargetFormAndOrder() {
        let x = candidate("x"), y = candidate("y", targets: [.file(ident(inode: 7))])
        let base = plan([.init(x, .permanentDelete), .init(y, .permanentDelete)])
        #expect(base.digest != plan([.init(x, .trash), .init(y, .permanentDelete)]).digest)
        #expect(base.digest != plan([.init(y, .permanentDelete), .init(x, .permanentDelete)]).digest)
        let contents = plan([.init(candidate("x", targets: [.directoryContents(ident())]), .permanentDelete),
                             .init(y, .permanentDelete)])
        #expect(base.digest != contents.digest)
    }

    @Test func digestIgnoresDisplayText() {
        let a = plan([.init(candidate(title: "Caches", bytes: 10), .trash)])
        let b = plan([.init(candidate(title: "App caches", bytes: 99), .trash)])
        #expect(a.digest == b.digest)
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

@Suite("CleanupApproval")
struct CleanupApprovalTests {
    let p = plan([.init(candidate(), .permanentDelete)])
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func authorizesTheApprovedPlanWithinItsLifetime() {
        let a = CleanupApproval(plan: p, approvedBy: .userInApp, issued: t0, lifetime: 60)
        #expect(a.refusal(for: p, at: t0) == nil)
        #expect(a.refusal(for: p, at: t0 + 59) == nil)
        #expect(a.refusal(for: p, at: t0 + 60) == .expired)
        #expect(a.refusal(for: p, at: t0 - 1) == .expired)
    }

    @Test func aChangedPlanIsRefused() {
        let a = CleanupApproval(plan: p, approvedBy: .userInTerminal, issued: t0, lifetime: 60)
        let swapped = plan([.init(candidate(targets: [.file(ident(inode: 101))]), .permanentDelete)])
        #expect(a.refusal(for: swapped, at: t0) == .planChanged)
    }

    @Test func zeroLifetimeNeverAuthorizes() {
        #expect(CleanupApproval(plan: p, approvedBy: .userViaMCPPrompt, issued: t0, lifetime: 0).refusal(for: p, at: t0) == .expired)
        #expect(CleanupApproval(plan: p, approvedBy: .userInApp, issued: t0, lifetime: -5).refusal(for: p, at: t0) == .expired)
    }

    @Test func eachApprovalHasItsOwnNonce() {
        let a = CleanupApproval(plan: p, approvedBy: .standingPolicy(id: "safe-clean", version: 1), issued: t0, lifetime: 60)
        let b = CleanupApproval(plan: p, approvedBy: .standingPolicy(id: "safe-clean", version: 1), issued: t0, lifetime: 60)
        #expect(a.nonce != b.nonce)
        #expect(a.approvedBy != CleanupApproval.Approver.standingPolicy(id: "safe-clean", version: 2))
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
                                                         outcome(.partiallyDone(freedBytes: 30, kept: ["/a"], damaged: []))],
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
