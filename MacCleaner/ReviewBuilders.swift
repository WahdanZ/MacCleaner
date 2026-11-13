import MacCleanerCore
import Foundation

// Builds the Review Cleanup list for each feature. Blocked status comes from the same guard the
// engine uses when it acts (SafetyGuard, TrashGuard, AdminGuard, ProtectedPaths, ProjectEngine/SDKEngine).

@MainActor
enum ReviewBuild {
    // MARK: Caches (Junk Files, Overview)

    static func cacheItems(_ targets: [CleanTarget]) -> [ReviewItem] {
        targets.map { t in
            let command: Bool = {
                switch t.action { case .deleteSimRuntime, .deleteUnavailableSimulators: return true; default: return false }
            }()
            let urls = AutoClean.urls(t)
            let contents: Bool = { if case .removeContents = t.action { return true }; return false }()
            let refused = urls.first { !SafetyGuard.isAllowed($0, allowContainer: contents) }
            return ReviewItem(id: "cache:\(t.id)", name: t.name, location: t.revealURL?.path ?? t.path, size: t.sizeBytes,
                              action: command ? .command : .delete, risk: t.recommended ? .safe : .review, note: t.note,
                              blocked: refused.map { ProtectedPaths.reason($0) ?? "Outside the allowed cache folders (\($0.lastPathComponent))" })
        }
    }

    static func junk(_ m: CleanerModel, perform: @escaping ([CleanTarget]) -> Void) -> ReviewRequest {
        let targets = m.chosen
        return ReviewRequest(title: "Review Junk Cleanup",
                             explanation: "Caches, logs and build data are deleted permanently. Apps and build tools recreate them when needed. Your documents, Downloads, Desktop, media and iCloud Drive are never part of this cleanup.",
                             items: cacheItems(targets), verb: "Clean",
                             perform: { ok in perform(targets.filter { ok.contains("cache:\($0.id)") }) })
    }

    /// Caches stay on the legacy path; old downloads are approved-Trash items (snapshots taken now).
    static func overview(_ m: CleanerModel, downloads: [BigFile],
                         perform: @escaping ([CleanTarget], [BigFile], TrashApproval?) -> Void) -> ReviewRequest {
        let targets = m.chosen
        let dl = downloads.map { f -> ReviewItem in
            let snap = AppCleanup.snapshot(f.url)
            return ReviewItem(id: "dl:\(f.id)", name: f.url.lastPathComponent, location: f.url.path, size: f.size, action: .trash,
                              risk: .review, note: "not opened in 90+ days",
                              blocked: TrashGuard.reason(f.url) ?? (snap == nil ? "It's no longer there" : nil), snapshot: snap)
        }
        return ReviewRequest(title: "Review Recommended Cleanup",
                             explanation: "Caches and logs are deleted permanently and rebuild on their own. Old downloads go to the Trash, so you can put them back until you empty it.",
                             items: cacheItems(targets) + dl, verb: "Clean",
                             perform: { _ in },
                             trashPlan: AppCleanup.trashPlan(dl, module: "downloads"),
                             performApproved: { ok, approval in
                                 perform(targets.filter { ok.contains("cache:\($0.id)") },
                                         downloads.filter { ok.contains("dl:\($0.id)") }, approval)
                             })
    }

    // MARK: Files that go to the Trash

    /// Items going to the Trash on the approved path (row id = path). Each item's identity is captured now, when the
    /// sheet opens; the plan is built from exactly these snapshots. `perform` gets the reviewed, allowed URLs (the
    /// ones in the plan; blocked items are left out, as before) and the approval for them.
    static func trashFiles(title: String, explanation: String, module: String, _ files: [(URL, Int64, String?)],
                           perform: @escaping ([URL], TrashApproval?) -> Void) -> ReviewRequest {
        let urls = files.map(\.0)
        let items = files.map { u, size, note -> ReviewItem in
            let snap = AppCleanup.snapshot(u)
            return ReviewItem(id: u.path, name: u.lastPathComponent, location: u.path, size: size, action: .trash,
                              note: note, blocked: TrashGuard.reason(u) ?? (snap == nil ? "It's no longer there" : nil),
                              snapshot: snap)
        }
        return ReviewRequest(title: title, explanation: explanation, items: items, verb: "Move", perform: { _ in },
                             trashPlan: AppCleanup.trashPlan(items, module: module),
                             performApproved: { ok, approval in perform(urls.filter { ok.contains($0.path) }, approval) })
    }

    static func diskMap(_ m: DiskMapModel, perform: @escaping ([DiskNode], TrashApproval?) -> Void) -> ReviewRequest {
        let nodes = m.topLevelMarked
        return trashFiles(title: "Move to Trash",
                          explanation: "These go to the Trash. You can put them back until you empty it; space is freed only then.",
                          module: "storage",
                          nodes.map { ($0.url, $0.size, $0.isDirectory ? "folder" : nil) },
                          perform: { urls, approval in
                              let ok = Set(urls.map(\.path)); perform(nodes.filter { ok.contains($0.url.path) }, approval)
                          })
    }

    static func largeFiles(_ m: LargeFilesModel, perform: @escaping ([BigFile], TrashApproval?) -> Void) -> ReviewRequest {
        let files = m.markedFiles
        return trashFiles(title: "Move Large & Old Files to Trash",
                          explanation: "These go to the Trash. You can put them back until you empty it; space is freed only then.",
                          module: "large-files",
                          files.map { ($0.url, $0.size, $0.lastOpened.map { "last opened " + $0.formatted(date: .abbreviated, time: .omitted) }) },
                          perform: { urls, approval in
                              let ok = Set(urls.map(\.path)); perform(files.filter { ok.contains($0.url.path) }, approval)
                          })
    }

    static func duplicates(_ m: DupFinder, perform: @escaping ([URL], TrashApproval?) -> Void) -> ReviewRequest {
        var files: [(URL, Int64, String?)] = []
        for g in m.groups {
            let marked = g.files.filter { m.marked.contains($0) }
            guard !marked.isEmpty else { continue }
            let kept = g.files.first { !m.marked.contains($0) }
            for u in marked { files.append((u, g.size, kept.map { "keeps " + Scanner.tilde($0) })) }
        }
        return trashFiles(title: "Move Duplicates to Trash",
                          explanation: "At least one copy of every file stays (shown in Status). The copies below go to the Trash and can be put back.",
                          module: "duplicates", files, perform: perform)
    }

    // MARK: Apps

    /// `perform` gets the reviewed leftovers to remove with the app, or is not called if the app row was blocked.
    static func uninstall(_ a: AppInfo, running: Bool, perform: @escaping ([AppLeftover]) -> Void) -> ReviewRequest {
        var items = [ReviewItem(id: a.url.path, name: "\(a.name).app", location: a.url.path, size: a.appSize,
                                action: a.url.path.hasPrefix("/Applications/") ? .adminTrash : .trash,
                                note: running ? "will be quit first" : nil, blocked: ProtectedPaths.reason(a.url))]
        for l in a.leftovers where l.include {
            if let pkg = l.receipt {
                items.append(ReviewItem(id: "receipt:\(pkg)", name: "Installer receipt", location: pkg, size: nil,
                                        action: .command, note: "pkgutil --forget"))
                continue
            }
            let blocked = l.needsAdmin ? (AdminGuard.isAllowed(l.url) ? nil : "Not in an allowed system folder")
                                       : TrashGuard.reason(l.url)
            items.append(ReviewItem(id: l.id, name: l.label, location: l.url.path, size: l.size,
                                    action: l.needsAdmin ? .adminTrash : .trash, risk: l.note == nil ? .safe : .review,
                                    note: l.note ?? (l.launchLabel != nil ? "background job is stopped first" : nil), blocked: blocked))
        }
        let admin = items.contains { $0.action == .adminTrash && $0.blocked == nil }
        return ReviewRequest(title: "Uninstall \(a.name)",
                             explanation: "Everything below goes to the Trash, so you can put it back."
                                + (admin ? " Items outside your home folder need your password once." : "")
                                + (running ? " \(a.name) is running and will be quit first." : ""),
                             items: items, verb: "Uninstall",
                             perform: { ok in
                                 guard ok.contains(a.url.path) else { return }
                                 perform(a.leftovers.filter { $0.include && ok.contains($0.id) })
                             })
    }

    static func appCache(_ a: AppInfo, perform: @escaping ([AppLeftover]) -> Void) -> ReviewRequest {
        let caches = a.caches
        return ReviewRequest(title: "Clear \(a.name) Cache",
                      explanation: "Caches are deleted permanently; \(a.name) rebuilds them. Quit the app first for the cleanest result.",
                      items: a.caches.map {
                          let d = AppEngine.cacheDecision($0.url)
                          return ReviewItem(id: $0.id, name: $0.url.lastPathComponent, location: $0.url.path, size: $0.size,
                                            action: .delete, note: d.contentsOnly ? AppEngine.contentsOnlyNote : nil, blocked: d.blocked)
                      },
                      verb: "Clear", perform: { ok in perform(caches.filter { ok.contains($0.id) }) })
    }

    // MARK: Developer tools

    static func projects(_ m: ProjectsModel, perform: @escaping ([(ProjectArtifact, DevProject)]) -> Void) -> ReviewRequest {
        let pairs = m.selectedPairs
        return ReviewRequest(title: "Review Build Files",
                      explanation: "Build output is deleted permanently. Your build tools recreate it (npm install, flutter pub get, the next Gradle or Xcode build). Source code, .git and settings are not touched.",
                      items: pairs.map { a, p in
                          ReviewItem(id: a.id, name: "\(p.name) › \(a.rel)", location: a.url.path, size: a.size, action: .delete,
                                     risk: a.review ? .review : .safe, note: "comes back with \(a.regen)",
                                     blocked: ProjectEngine.reason(a, in: p))
                      },
                      verb: "Clean", perform: { ok in perform(pairs.filter { ok.contains($0.0.id) }) })
    }

    static func sdks(_ m: SDKModel, perform: @escaping ([SDKItem], TrashApproval?) -> Void) -> ReviewRequest {
        sdks(m.chosen, perform: perform)
    }

    /// Archives (`.trash`) are approved-Trash items: the plan holds the identity the scan captured (what the sheet
    /// describes), and only if the same item is still there when the sheet opens; otherwise the row is blocked and
    /// needs a rescan. Everything else keeps its own flow.
    static func sdks(_ chosen: [SDKItem], perform: @escaping ([SDKItem], TrashApproval?) -> Void) -> ReviewRequest {
        let items = chosen.map { i -> ReviewItem in
            let action: ReviewItem.Action = {
                switch i.action {
                case .simRuntime, .docker, .brew: return .command
                case .delete: return .delete
                case .trash: return .trash
                }
            }()
            var snap: FileIdentity?
            var blocked = SDKEngine.reason(i)
            if case .trash(let u) = i.action, blocked == nil {
                (snap, blocked) = AppCleanup.scannedSnapshot(u, scanned: i.identity)
            }
            return ReviewItem(id: i.id, name: i.name, location: i.reveal?.path ?? "\(i.group.rawValue) · \(i.detail)",
                              size: i.size, action: action,
                              risk: i.inUse != nil ? .inUse : i.review ? .review : .safe,
                              note: i.inUse ?? "comes back with \(i.regen)", blocked: blocked, snapshot: snap)
        }
        return ReviewRequest(title: "Review Developer SDKs",
                      explanation: "Runtimes and SDK parts are deleted permanently and can be downloaded again, which takes time and bandwidth. Xcode archives go to the Trash. Docker volumes and stopped containers hold data that can't be rebuilt.",
                      items: items, verb: "Remove", perform: { _ in },
                      trashPlan: AppCleanup.trashPlan(items, module: "sdks"),
                      performApproved: { ok, approval in perform(chosen.filter { ok.contains($0.id) }, approval) })
    }

    // MARK: System Data, Shredder

    static func systemData(_ m: SystemDataModel, perform: @escaping ([SysItem], TrashApproval?) -> Void) -> ReviewRequest {
        systemData(m.chosen, perform: perform)
    }

    /// Trash items are approved-Trash items: the plan holds the scan's identity, only if the same item is still
    /// there when the sheet opens (otherwise blocked, rescan). Snapshots keep their password flow.
    static func systemData(_ chosen: [SysItem], perform: @escaping ([SysItem], TrashApproval?) -> Void) -> ReviewRequest {
        let items = chosen.map { i -> ReviewItem in
            let snapshot: Bool = { if case .snapshot = i.action { return true }; return false }()
            var snap: FileIdentity?
            var blocked = SystemDataEngine.reason(i)
            if case .trash(let u) = i.action, blocked == nil {
                (snap, blocked) = AppCleanup.scannedSnapshot(u, scanned: i.identity)
            }
            return ReviewItem(id: i.id, name: i.name, location: i.reveal?.path ?? i.section.rawValue, size: i.size,
                              action: snapshot ? .command : .trash, risk: i.review ? .review : .safe,
                              note: snapshot ? "tmutil, needs your password" : i.detail, blocked: blocked, snapshot: snap)
        }
        return ReviewRequest(title: "Review System Data",
                      explanation: "Device backups and attachments go to the Trash; they can't be recreated without the device or the sender. Time Machine snapshots are deleted permanently after you enter your password.",
                      items: items, verb: "Remove", perform: { _ in },
                      trashPlan: AppCleanup.trashPlan(items, module: "system-data"),
                      performApproved: { ok, approval in perform(chosen.filter { ok.contains($0.id) }, approval) })
    }

    static func shred(_ items: [ShredderModel.Item], perform: @escaping ([ShredderModel.Item]) -> Void) -> ReviewRequest {
        ReviewRequest(title: "Shred Permanently",
                      explanation: "Shredding skips the Trash and cannot be undone.",
                      items: items.map {
                          ReviewItem(id: $0.id, name: $0.url.lastPathComponent, location: $0.url.path, size: $0.size,
                                     action: .delete, risk: .review, note: "cannot be recovered", blocked: $0.blocked)
                      },
                      verb: "Shred", perform: { ok in perform(items.filter { ok.contains($0.id) }) })
    }
}
