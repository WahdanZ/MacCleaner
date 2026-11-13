import Foundation
import MacCleanerCore
import MacCleanerFeatures
import MacCleanerPlatform

/// Moves to the Trash the two folders Mac Cleaner makes itself, as the last step of an operation the person already
/// started, through the cleanup executor like every other Trash move:
///
/// * the uninstall password step's staging folder (`trashStaging`), proven by the `AdminStep.Staging` that only
///   that step's result makes, and
/// * an installed usage skill (`trashSkill`), proven by the `InstalledSkills.Verified` that only the ownership
///   check makes.
///
/// It is not a general way around confirmation. Each move gets its own executor whose protection allows exactly the
/// one folder the proof names (nothing else can be moved through it), an approval labelled `.appOwned(kind)` that the
/// ledger limits to one Trash move of one folder in that kind's module, and the folder's contents are checked again
/// right before the move (the executor's precondition) after its identity was checked. Anything unexpected leaves
/// the folder where it is, and the report says where that is. scripts/check-approval-sites.sh allows `.appOwned`
/// and these calls only here and where each operation finishes.
enum AppOwnedTrash {
    // MARK: - The password step's staging folder

    /// Sends the privileged step's staging folder to the Trash (logged, but put back by dragging it out of the Trash in
    /// Finder: its items belong to the system), only if it still holds exactly the items the step reported moved,
    /// each still the reviewed item. An empty folder (nothing moved) is removed instead. `inTrash` is true only when
    /// the moved items reached the Trash, or nothing was moved; otherwise the folder is left untouched and `error`
    /// says where it is.
    static func trashStaging(_ staging: AdminStep.Staging, source: String) -> (inTrash: Bool, error: String?) {
        let place = staging.folder.path
        if !staging.report.keptInStaging.isEmpty {
            return (false, "Something that wasn't reviewed ended up in \(place), so that folder was not sent to the Trash; look there")
        }
        let current: FileIdentity
        switch check(staging) {
        case .failure(let why): return (false, "The moved system items are in \(place), which was not sent to the Trash: \(why.text); look there")
        case .success(let c): current = c
        }
        if staging.expected.isEmpty {   // nothing was moved, and the check found the folder empty
            guard rmdir(place) == 0 else {
                return (true, "The empty staging folder \(place) couldn't be removed (\(String(cString: strerror(errno))))")
            }
            return (true, nil)
        }
        let kind = CleanupApproval.AppOwnedKind.adminStaging
        guard let plan = plan(kind, current, title: "Uninstall staging folder", bytes: Scanner.allocatedSize(staging.url)) else {
            return (false, "The moved system items are in \(place), but that folder couldn't be planned for the Trash; look there")
        }
        let run = run(plan, kind, protection: OneFolder(path: place, rules: { ProtectedPaths.reason(URL(fileURLWithPath: $0)) }),
                      source: source, restorable: false,
                      precondition: { _, _ in if case .failure(let why) = check(staging) { return why.text }; return nil })
        if run.moved.isEmpty {
            let why = run.problems.first?.message ?? "it wasn't moved"
            return (false, "The moved system items are in \(place), but that folder couldn't be sent to the Trash: \(why)")
        }
        return (true, nil)
    }

    struct Refusal: Error { let text: String }

    /// The staging folder as it is now, if it is still the one the step made — the `mktemp` name, a real folder you
    /// own closed to everyone else, the same folder (device, inode) — holding exactly the expected entries, each the
    /// reviewed item that was moved there (no other, added, missing, replaced or changed entry; links are never
    /// followed). Otherwise why not.
    static func check(_ s: AdminStep.Staging) -> Result<FileIdentity, Refusal> {
        let fs = LocalFileSystem()
        guard AdminStep.parseStaging(s.folder.path)?.path == s.folder.path, AdminStep.isTrustedStaging(s.url, uid: s.uid) else {
            return .failure(Refusal(text: "it is no longer the private folder the password step made"))
        }
        guard let now = try? fs.identity(at: s.folder.path), now.kind == .directory, s.folder.mismatch(against: now) == nil else {
            return .failure(Refusal(text: "it was replaced after the password step"))
        }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: s.folder.path) } catch {
            return .failure(Refusal(text: "it couldn't be checked (\(error.localizedDescription))"))
        }
        if names.isEmpty && !s.expected.isEmpty { return .failure(Refusal(text: "the moved items weren't found in it")) }
        guard Set(names) == Set(s.expected.keys), names.count == s.expected.count else {
            return .failure(Refusal(text: "it holds something other than the items that were moved there"))
        }
        for (name, reviewed) in s.expected {
            guard let entry = try? fs.identity(at: s.folder.path + "/" + name), sameItem(entry, reviewed) else {
                return .failure(Refusal(text: "\(name) isn't the item that was moved there"))
            }
        }
        return .success(now)
    }

    /// `staged` is the same item as `reviewed` after a rename: same volume, inode and kind, and for a regular file the
    /// same size and modification time (a rename changes neither; the path differs by design).
    static func sameItem(_ staged: FileIdentity, _ reviewed: FileIdentity) -> Bool {
        guard staged.kind == reviewed.kind, staged.device == reviewed.device, staged.inode == reviewed.inode else { return false }
        return reviewed.kind != .file || (staged.size == reviewed.size && staged.modificationNanos == reviewed.modificationNanos)
    }

    // MARK: - An installed usage skill

    /// Moves a verified, unchanged Mac Cleaner-installed skill folder to the Trash (restorable with Put Back). nil when
    /// it moved; otherwise why it was kept (it stays where it is).
    static func trashSkill(_ skill: InstalledSkills.Verified, source: String) -> String? {
        let kind = CleanupApproval.AppOwnedKind.installedSkill
        guard let plan = plan(kind, skill.folder, title: "Mac Cleaner usage skill", bytes: Scanner.allocatedSize(skill.url)) else {
            return "it couldn't be planned for the Trash"
        }
        let run = run(plan, kind, protection: OneFolder(path: skill.folder.path, rules: { TrashGuard.reason(URL(fileURLWithPath: $0)) }),
                      source: source, restorable: true,
                      precondition: { _, _ in InstalledSkills.recheck(skill) })
        return run.moved.isEmpty ? (run.problems.first?.message ?? "it wasn't moved") : nil
    }

    // MARK: - Shared

    /// The one-entry plan the ledger accepts for `.appOwned(kind)`: a Trash move of exactly `folder`.
    private static func plan(_ kind: CleanupApproval.AppOwnedKind, _ folder: FileIdentity, title: String, bytes: Int64) -> CleanupPlan? {
        let c = CleanupCandidate(id: kind.rawValue + ":" + folder.path, module: kind.rawValue, title: title, targets: [.file(folder)],
                                 estimatedBytes: bytes, risk: .reviewRequired, recommended: false,
                                 explanation: "Made by Mac Cleaner during this operation")
        return try? CleanupPlan([.init(c, .trash)])
    }

    /// Approves `plan` as `.appOwned(kind)` on an executor made for this one move and runs it, waiting (the callers are
    /// synchronous). The executor is dropped afterwards, with its ledger.
    private static func run(_ plan: CleanupPlan, _ kind: CleanupApproval.AppOwnedKind, protection: OneFolder, source: String,
                            restorable: Bool, precondition: @escaping CleanupExecutor.Precondition) -> TrashRun {
        let executor = CleanupExecutor(fileSystem: LocalFileSystem(trashMover: { try AppCleanup.trashMover($0) }), protection: protection)
        let slot = RunSlot()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let approval = try await executor.approve(plan, by: .appOwned(kind))
                slot.run = await AppCleanup.moveToTrash(.approved(ApprovedTrash(plan: plan, approval: approval)), source: source,
                                                        precondition: precondition, executor: executor, restorable: restorable)
            } catch {
                slot.run = TrashRun(problems: plan.candidates.map { ($0.id, "No approval was issued (\(error)); nothing was moved") })
            }
            done.signal()
        }
        done.wait()
        return slot.run ?? TrashRun()
    }

    /// Protection for one app-owned move: only `path` itself, as a Trash move, and only while `rules` (the app's own
    /// protection for that place) allow it. Every other path is refused.
    struct OneFolder: ProtectionChecking {
        let path: String
        let rules: @Sendable (String) -> String?
        func refusal(path p: String, disposition: Disposition) -> String? {
            guard disposition == .trash, p == path else { return "Only the folder Mac Cleaner made may be moved here" }
            return rules(p)
        }
    }
}
