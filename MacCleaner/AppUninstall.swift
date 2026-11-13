import Foundation
import MacCleanerCore

// Uninstalling an app and removing system items: the Trash part through the cleanup executor (approved at the review
// sheet, an MCP/CLI confirm or a Remove alert), the part outside your home folder through the password step
// (AdminStep), which checks each item's reviewed identity at the privileged move.

extension AppEngine {
    /// The password step (macOS's prompt, then the root script). Callers pass it only in the self-test, to watch when
    /// it would run without a prompt.
    typealias AdminStepRunner = ([AppLeftover], uid_t) -> AdminStep.Result
    static let defaultAdminStep: AdminStepRunner = { AdminStep.run($0, uid: $1) }

    /// nil when the app bundle may go through the password step after its Trash move failed; otherwise why not.
    /// Only a real permission refusal qualifies (never a protection, identity, approval or other refusal), and only
    /// for an item in a folder the password step may touch, still allowed by the protection rules, and still the
    /// reviewed item right now. The privileged move checks the identity again itself (AdminStep.script).
    static func adminFallbackRefusal(outcome: ItemOutcome.Result?, reviewed: FileIdentity?, current: FileIdentity?,
                                     protection: String?, adminAllowed: Bool) -> String? {
        guard case .permissionDenied? = outcome else { return "its Trash move wasn't refused for permission" }
        guard adminAllowed else { return "it isn't in a folder Mac Cleaner may remove with your password" }
        if let protection { return protection }
        guard let reviewed, let current, reviewed.path == current.path, reviewed.mismatch(against: current) == nil else {
            return "it changed after you reviewed it, so it was left alone"
        }
        return nil
    }

    /// The reviewed app + picked leftovers. The app bundle and the leftovers in your home folder go to the Trash
    /// through `trash`, the approval given at the review sheet or the MCP/CLI confirm for exactly those items (never
    /// made here). If the app bundle's Trash move is refused for lack of permission (e.g. owned by root) and it
    /// qualifies (`adminFallbackRefusal`), it joins the leftovers outside your home folder in one macOS password
    /// step, which checks each item's reviewed identity at the privileged move. If the app can't be removed and
    /// doesn't qualify, its leftovers are kept.
    /// Stops one of your launch jobs (launchctl bootout gui/<uid>/<label>). Callers pass it only in the self-test.
    static let defaultStopUserJob: @Sendable (String) -> Void = { label in
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)
    }

    static func uninstall(_ a: AppInfo, picked: [AppLeftover], trash approval: TrashApproval?, source: String? = nil,
                          adminStep: AdminStepRunner = defaultAdminStep,
                          adminAllowed: @escaping @Sendable (URL) -> Bool = { AdminGuard.isAllowed($0) },
                          stopUserJob: @Sendable (String) -> Void = defaultStopUserJob) -> UninstallResult {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        var r = UninstallResult()
        let uid = getuid()
        var adminItems = picked.filter(\.needsAdmin)
        let home = picked.filter { !$0.needsAdmin && $0.receipt == nil }
        let bundleID = a.url.path, bundleURL = a.url
        let items: [AppCleanup.EngineTrashItem] = [(bundleID, "\(a.name).app", a.url, a.identity)]
            + home.map { ($0.id, $0.url.lastPathComponent, $0.url, $0.identity) }
        // The app bundle comes first in the plan. The executor finishes it before touching any leftover, and this decides
        // there and then, completely: it moved, or it qualifies for the password step (permission refusal, allowed
        // folder, protection and identity checked now). Otherwise the leftovers are left alone.
        let reviewed = a.identity
        let decision = FallbackDecision()
        let t = AppCleanup.engineTrash(items, module: "uninstall", approval, source: source ?? "Uninstall \(a.name)",
                                       stopAfter: { o in
            guard o.candidateID == bundleID else { return nil }
            if case .trashed = o.result { return nil }
            let why = adminFallbackRefusal(outcome: o.result, reviewed: reviewed, current: AppCleanup.snapshot(bundleURL),
                                           protection: AppProtection().refusal(path: AppCleanup.physicalPath(bundleURL), disposition: .trash),
                                           adminAllowed: adminAllowed(bundleURL))
            decision.set(why)
            return why == nil ? nil : "\(a.name).app couldn't be removed, so its leftovers were kept"
        })
        let bundleOutcome = t.outcomes[bundleID]
        if t.moved[bundleID] != nil {
            r.appRemoved = true
            r.bytes += a.appSize
        } else {
            let why = decision.refusal ?? "it wasn't handled"   // decided above, before any leftover moved
            if decision.decided && decision.refusal == nil {
                var item = AppLeftover(id: bundleID, url: a.url, label: "App", size: a.appSize, include: true, note: nil, needsAdmin: true)
                item.identity = a.identity
                adminItems.insert(item, at: 0)
            } else if case .permissionDenied? = bundleOutcome {
                r.errors.append("\(a.name).app: the system refused permission, and the password step can't be used: \(why)")
            }
        }
        // The bundle's permission refusal is reported once: not at all when it goes to the password step, or by the
        // line above when it can't.
        let bundleToAdmin = adminItems.first?.id == bundleID
        let bundleDenied: Bool = { if case .permissionDenied? = bundleOutcome { return true }; return false }()
        r.errors += t.errors.filter { !(bundleDenied && $0.id == bundleID) }.map(\.text)
        r.bytes += home.filter { t.moved[$0.id] != nil }.reduce(0) { $0 + $1.size }
        // A leftover's launch job is stopped only after its own (reviewed, unchanged) file went to the Trash.
        for l in home where t.moved[l.id] != nil { if let label = l.launchLabel { stopUserJob(label) } }
        guard !adminItems.isEmpty, r.appRemoved || bundleToAdmin else { return r }
        switch adminStep(adminItems, uid) {
        case .ok(let staging, let report):
            // Only items the privileged step reported as moved and verified count; nothing is inferred from a missing
            // original. Staged is not yet the Trash: the note says which.
            let toTrash = sendStagingToTrash(staging, report, source: "Uninstall (system items)")
            let movedFiles = adminItems.enumerated().filter { report.moved.contains($0.offset) && $0.element.receipt == nil }
            if toTrash.inTrash { r.bytes += movedFiles.reduce(0) { $0 + $1.element.size } }
            if let i = adminItems.firstIndex(where: { $0.url == a.url }), report.moved.contains(i) { r.appRemoved = true }
            for (i, l) in adminItems.enumerated() where l.receipt == nil {
                if let why = report.notMovedReason(i) { r.errors.append("\(l.url.lastPathComponent): \(why)") }
            }
            if let e = toTrash.error { r.errors.append(e) }
            r.adminNote = movedFiles.isEmpty ? " No system item was moved."
                : toTrash.inTrash ? " Includes \(movedFiles.count) system item(s) moved to the Trash."
                : " \(movedFiles.count) system item(s) were moved out of place into \(Scanner.tilde(staging)), not yet the Trash."
        case .cancelled:
            r.adminNote = " System items were kept (password prompt cancelled)."
        case .failed(let msg):
            r.errors.append("System items: \(msg)")
        }
        return r
    }

    /// Moves items outside your home folder to the Trash via one macOS password prompt
    /// (stopping any launch jobs first). Each item's reviewed identity is checked at the privileged move.
    static func removeSystemItems(_ items: [AppLeftover], adminStep: AdminStepRunner = defaultAdminStep)
        -> (removed: [URL], errors: [String], cancelled: Bool, inTrash: Bool) {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        guard !items.isEmpty else { return ([], [], false, true) }
        switch adminStep(items, getuid()) {
        case .ok(let staging, let report):
            // `removed`: only items the privileged step reported as moved and verified (never inferred from a missing
            // original). `inTrash`: whether they then reached the Trash, or are still in the staging folder.
            let toTrash = sendStagingToTrash(staging, report, source: "System items")
            var errors: [String] = []
            var removed: [URL] = []
            for (i, it) in items.enumerated() where it.receipt == nil {
                if let why = report.notMovedReason(i) { errors.append("\(it.url.lastPathComponent): \(why)") }
                else { removed.append(it.url) }
            }
            if let e = toTrash.error { errors.append(e) }
            return (removed, errors, false, toTrash.inTrash)
        case .cancelled:
            return ([], [], true, true)
        case .failed(let msg):
            return ([], [msg], false, true)
        }
    }
}

extension AppEngine {
    /// Sends the privileged step's staging folder to the Trash (not restorable item by item), unless it may hold
    /// something that wasn't reviewed. `inTrash` is true only when the moved items reached the Trash (or nothing was
    /// moved); a staging folder that can't be read, removed or sent to the Trash is reported, never treated as done.
    /// The file operations are parameters only so the self-test can make them fail.
    static func sendStagingToTrash(_ staging: URL, _ report: AdminStep.Report, source: String,
                                   list: (URL) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0.path) },
                                   removeEmpty: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                                   moveToTrash: (URL, String) -> String? = { trash($0, source: $1, restorable: false) })
        -> (inTrash: Bool, error: String?) {
        let place = Scanner.tilde(staging)
        if !report.keptInStaging.isEmpty {
            return (false, "Something that wasn't reviewed ended up in \(place), so that folder was not sent to the Trash; look there")
        }
        let staged: [String]
        do { staged = try list(staging) } catch {
            return (false, "The staging folder \(place) couldn't be checked (\(error.localizedDescription)), so it was not sent to the Trash; look there")
        }
        if staged.isEmpty {
            if !report.moved.isEmpty {
                return (false, "The moved system items weren't found in the staging folder \(place); look there")
            }
            do { try removeEmpty(staging) } catch {
                return (true, "The empty staging folder \(place) couldn't be removed (\(error.localizedDescription))")
            }
            return (true, nil)
        }
        if let e = moveToTrash(staging, source) {
            return (false, "The moved system items are in \(place), but that folder couldn't be sent to the Trash: \(e)")
        }
        return (true, nil)
    }
}

/// The app bundle's fallback decision, made inside the executor's per-item callback (before any leftover is touched)
/// and read after the run.
private final class FallbackDecision: @unchecked Sendable {   // written once, from the executor, behind `lock`
    private let lock = NSLock()
    private var made = false
    private var why: String?
    func set(_ refusal: String?) { lock.lock(); made = true; why = refusal; lock.unlock() }
    var decided: Bool { lock.lock(); defer { lock.unlock() }; return made }
    var refusal: String? { lock.lock(); defer { lock.unlock() }; return why }
}
