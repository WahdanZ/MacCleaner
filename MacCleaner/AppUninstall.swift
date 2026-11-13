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
    static func uninstall(_ a: AppInfo, picked: [AppLeftover], trash approval: TrashApproval?, source: String? = nil,
                          adminStep: AdminStepRunner = defaultAdminStep,
                          adminAllowed: @escaping @Sendable (URL) -> Bool = { AdminGuard.isAllowed($0) }) -> UninstallResult {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        var r = UninstallResult()
        let uid = getuid()
        for l in picked where !l.needsAdmin {
            if let label = l.launchLabel { _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 15) }
        }
        var adminItems = picked.filter(\.needsAdmin)
        let home = picked.filter { !$0.needsAdmin && $0.receipt == nil }
        let bundleID = a.url.path, bundleURL = a.url
        let items: [AppCleanup.EngineTrashItem] = [(bundleID, "\(a.name).app", a.url, a.identity)]
            + home.map { ($0.id, $0.url.lastPathComponent, $0.url, $0.identity) }
        let allowed = adminAllowed
        // The app bundle comes first in the plan: unless it moved, or was refused only for permission in a folder the
        // password step may touch, the leftovers are left alone.
        let t = AppCleanup.engineTrash(items, module: "uninstall", approval, source: source ?? "Uninstall \(a.name)",
                                       stopAfter: { o in
            guard o.candidateID == bundleID else { return nil }
            switch o.result {
            case .trashed: return nil
            case .permissionDenied where allowed(bundleURL): return nil
            default: return "\(a.name).app couldn't be removed, so its leftovers were kept"
            }
        })
        let bundleOutcome = t.outcomes[bundleID]
        if t.moved[bundleID] != nil {
            r.appRemoved = true
            r.bytes += a.appSize
        } else {
            let why = adminFallbackRefusal(outcome: bundleOutcome, reviewed: a.identity, current: AppCleanup.snapshot(a.url),
                                           protection: AppProtection().refusal(path: AppCleanup.physicalPath(a.url), disposition: .trash),
                                           adminAllowed: allowed(a.url))
            if why == nil {
                var item = AppLeftover(id: bundleID, url: a.url, label: "App", size: a.appSize, include: true, note: nil, needsAdmin: true)
                item.identity = a.identity
                adminItems.insert(item, at: 0)
            } else if case .permissionDenied? = bundleOutcome, let why {
                r.errors.append("\(a.name).app: the system refused permission, and the password step can't be used: \(why)")
            }
        }
        // The bundle's permission refusal is reported once: not at all when it goes to the password step, or by the
        // line above when it can't.
        let bundleToAdmin = adminItems.first?.id == bundleID
        let bundleDenied: Bool = { if case .permissionDenied? = bundleOutcome { return true }; return false }()
        r.errors += t.errors.filter { !(bundleDenied && $0.id == bundleID) }.map(\.text)
        r.bytes += home.filter { t.moved[$0.id] != nil }.reduce(0) { $0 + $1.size }
        guard !adminItems.isEmpty, r.appRemoved || bundleToAdmin else { return r }
        switch adminStep(adminItems, uid) {
        case .ok(let staging, let report):
            let staged = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            if !report.keptInStaging.isEmpty {
                r.errors.append("Something that wasn't reviewed ended up in \(Scanner.tilde(staging)), so it was not sent to the Trash; look there")
            } else if staged.isEmpty {
                try? FileManager.default.removeItem(at: staging)
            } else if let e = trash(staging, source: "Uninstall (system items)", restorable: false) {
                r.errors.append("Moved system items to \(Scanner.tilde(staging)) but could not send it to the Trash: \(e)")
            }
            let refused = report.changed.union(report.keptInStaging).union(report.unidentified).union(report.otherVolume)
            let still = adminItems.enumerated().filter { i, l in
                l.receipt == nil && (refused.contains(i) || FileManager.default.fileExists(atPath: l.url.path))
            }.map(\.element)
            r.bytes += adminItems.filter { i in !still.contains { $0.id == i.id } && i.receipt == nil }.reduce(0) { $0 + $1.size }
            if !still.contains(where: { $0.url == a.url }) { r.appRemoved = true }
            for (i, l) in adminItems.enumerated() where l.receipt == nil {
                if report.changed.contains(i) || report.keptInStaging.contains(i) {
                    r.errors.append("\(l.url.lastPathComponent): it changed after you reviewed it, so it was left alone")
                } else if report.unidentified.contains(i) {
                    r.errors.append("\(l.url.lastPathComponent): it couldn't be identified when it was found, so it was left alone")
                } else if report.otherVolume.contains(i) {
                    r.errors.append("\(l.url.lastPathComponent): it's on another volume, so it was left alone")
                } else if FileManager.default.fileExists(atPath: l.url.path) {
                    r.errors.append("\(l.url.lastPathComponent): still there after admin step")
                }
            }
            r.adminNote = " Includes \(adminItems.count - still.count) system item(s)."
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
        -> (removed: [URL], errors: [String], cancelled: Bool) {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        guard !items.isEmpty else { return ([], [], false) }
        switch adminStep(items, getuid()) {
        case .ok(let staging, let report):
            var errors: [String] = []
            let staged = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            if !report.keptInStaging.isEmpty {
                errors.append("Something that wasn't reviewed ended up in \(Scanner.tilde(staging)), so it was not sent to the Trash; look there")
            } else if staged.isEmpty { try? FileManager.default.removeItem(at: staging) }
            else if let e = trash(staging, source: "System items", restorable: false) { errors.append("Staging folder \(Scanner.tilde(staging)): \(e)") }
            let fm = FileManager.default
            let refused = report.changed.union(report.keptInStaging).union(report.unidentified).union(report.otherVolume)
            var removed: [URL] = []
            for (i, it) in items.enumerated() where it.receipt == nil {
                if report.changed.contains(i) || report.keptInStaging.contains(i) {
                    errors.append("\(it.url.lastPathComponent): it changed after you reviewed it, so it was left alone")
                } else if report.unidentified.contains(i) {
                    errors.append("\(it.url.lastPathComponent): it couldn't be identified when it was found, so it was left alone")
                } else if report.otherVolume.contains(i) {
                    errors.append("\(it.url.lastPathComponent): it's on another volume, so it was left alone")
                } else if fm.fileExists(atPath: it.url.path) {
                    errors.append("\(it.url.lastPathComponent): still there")
                } else if !refused.contains(i) {
                    removed.append(it.url)
                }
            }
            return (removed, errors, false)
        case .cancelled:
            return ([], [], true)
        case .failed(let msg):
            return ([], [msg], false)
        }
    }
}
