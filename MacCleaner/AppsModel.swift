import AppKit
import CoreServices
import Foundation
import Observation

struct AppLeftover: Identifiable, Sendable {
    let id: String
    let url: URL
    /// Where it lives, e.g. "Application Support", "Containers".
    let label: String
    var size: Int64
    /// Unchecked by default (e.g. shared group containers that other apps may use).
    var include: Bool
    let note: String?
    /// Lives outside your home folder; removed in one step after macOS asks for your password.
    var needsAdmin = false
    /// launchd job to stop before the file is removed.
    var launchLabel: String? = nil
    var launchSystem = false
    /// Installer receipt id (`pkgutil --forget`), no file.
    var receipt: String? = nil
}

struct AppInfo: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let isApple: Bool
    var appSize: Int64
    var lastUsed: Date?
    var leftovers: [AppLeftover]
    /// Disposable caches for "Clear cache" (cleared through the cache allow-list).
    var caches: [AppLeftover]

    var dataSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    var cacheSize: Int64 { caches.reduce(0) { $0 + $1.size } }
    var total: Int64 { appSize + dataSize }
    var isSelf: Bool { bundleID == Bundle.main.bundleIdentifier }
}

enum AppScanner {
    static let fm = FileManager.default
    static let lib = SafetyGuard.home.appendingPathComponent("Library")

    /// Folder listings and the installer-receipt list shared by every app in one scan. Without it each app
    /// re-lists the same ~/Library and /Library folders and starts its own `pkgutil --pkgs`.
    final class Batch: @unchecked Sendable {
        private let lock = NSLock()
        private var listings: [String: [String]] = [:]
        private var pkgs: String??

        func list(_ dir: URL) -> [String] {
            lock.lock()
            if let l = listings[dir.path] { lock.unlock(); return l }
            lock.unlock()
            let l = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            lock.lock(); listings[dir.path] = l; lock.unlock()
            return l
        }

        private var jobs: [String: (label: String?, program: String?)] = [:]
        private var pkgFiles: [String: [URL]] = [:]

        /// Label and program of a launch agent or daemon plist, read once per scan.
        func launchJob(_ u: URL) -> (label: String?, program: String?) {
            lock.lock()
            if let j = jobs[u.path] { lock.unlock(); return j }
            lock.unlock()
            let plist = NSDictionary(contentsOf: u)
            let j = (plist?["Label"] as? String,
                     (plist?["Program"] as? String) ?? ((plist?["ProgramArguments"] as? [String])?.first))
            lock.lock(); jobs[u.path] = j; lock.unlock()
            return j
        }

        /// `AppScanner.installedItems(pkg:)`, once per package per scan.
        func installedItems(_ pkg: String) -> [URL] {
            lock.lock()
            if let l = pkgFiles[pkg] { lock.unlock(); return l }
            lock.unlock()
            let l = AppScanner.installedItems(pkg: pkg)
            lock.lock(); pkgFiles[pkg] = l; lock.unlock()
            return l
        }

        func receipts() -> String? {
            lock.lock()
            if let p = pkgs { lock.unlock(); return p }
            lock.unlock()
            let p = Shell.run("/usr/sbin/pkgutil", ["--pkgs"]).output
            lock.lock(); pkgs = .some(p); lock.unlock()
            return p
        }
    }

    static func appURLs() -> [URL] {
        var out: [URL] = []
        for dir in [URL(fileURLWithPath: "/Applications"), SafetyGuard.home.appendingPathComponent("Applications")] {
            let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for k in kids {
                if k.pathExtension == "app" {
                    out.append(k)
                } else if Scanner.isDirectory(k) {
                    // One level of sub-folders, e.g. "/Applications/Microsoft Office/…"
                    let inner = (try? fm.contentsOfDirectory(at: k, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])) ?? []
                    out += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        return out
    }

    static func bundleID(_ url: URL) -> String { Bundle(url: url)?.bundleIdentifier ?? "" }

    /// "com.teamviewer.TeamViewer" → "com.teamviewer" (nil for short ids and Apple).
    static func vendor(_ id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let v = parts.prefix(2).joined(separator: ".")
        return v == "com.apple" ? nil : v
    }

    static func info(for url: URL, allIDs: Set<String> = [], batch: Batch = Batch()) -> AppInfo {
        let b = Bundle(url: url)
        let id = b?.bundleIdentifier ?? ""
        let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let fileName = url.deletingPathExtension().lastPathComponent
        let version = (b?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        var info = AppInfo(id: url.path, url: url, name: fileName, bundleID: id, version: version,
                           isApple: id.hasPrefix("com.apple."), appSize: Scanner.allocatedSize(url),
                           lastUsed: lastUsed(url), leftovers: [], caches: [])
        guard !id.isEmpty else { return info }
        let v = vendor(id)
        let vendorUnique = v.map { vv in !allIDs.contains { $0 != id && $0.hasPrefix(vv + ".") } } ?? false
        info.leftovers = leftovers(id: id, names: Array(Set([name, fileName])), appURL: url,
                                   vendor: v, vendorUnique: vendorUnique, batch: batch)
        info.caches = caches(id: id, names: Array(Set([name, fileName])))
        return info
    }

    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Everything the app left behind, matched by exact bundle id, "<id>.<helper>" prefix or exact app name:
    /// your ~/Library, crash reports, launch agents/daemons and helpers, /Library and installer receipts.
    static func leftovers(id: String, names: [String], appURL: URL,
                          vendor: String? = nil, vendorUnique: Bool = false, batch: Batch = Batch()) -> [AppLeftover] {
        var out: [AppLeftover] = []
        var seen = Set<String>()
        let sysLib = URL(fileURLWithPath: "/Library")

        func addURL(_ u: URL, _ label: String, include: Bool = true, note: String? = nil,
                    admin: Bool = false, launch: String? = nil, system: Bool = false) {
            guard !seen.contains(u.path), fm.fileExists(atPath: u.path) else { return }
            seen.insert(u.path)
            var l = AppLeftover(id: u.path, url: u, label: label, size: Scanner.allocatedSize(u),
                                include: include, note: note)
            l.needsAdmin = admin
            l.launchLabel = launch
            l.launchSystem = system
            out.append(l)
        }
        func add(_ rel: String, _ label: String, include: Bool = true, note: String? = nil) {
            addURL(lib.appendingPathComponent(rel), label, include: include, note: note)
        }
        func list(_ dir: URL) -> [String] { batch.list(dir) }
        /// "<id>", "<id>.anything" (helpers, ShipIt, extensions)
        func matchesID(_ name: String) -> Bool { name == id || name.hasPrefix(id + ".") }
        /// Same developer prefix but not this app's id (e.g. com.teamviewer.Helper for com.teamviewer.TeamViewer).
        func matchesVendor(_ name: String) -> Bool {
            guard let v = vendor else { return false }
            return !matchesID(name) && name.hasPrefix(v + ".")
        }
        let vendorNote = vendorUnique ? "Same developer (\(vendor ?? ""))"
                                      : "Other \(vendor ?? "") apps may use this; check first"

        // ~/Library — exact id / name
        for n in names {
            add("Application Support/\(n)", "Application Support")
            add("Caches/\(n)", "Caches")
            add("Logs/\(n)", "Logs")
        }
        // ~/Library — id and "<id>.helper" entries
        let byFolder: [(String, String)] = [
            ("Application Support", "Application Support"), ("Caches", "Caches"), ("Containers", "Container"),
            ("Preferences", "Preferences"), ("Preferences/ByHost", "Preferences"),
            ("Saved Application State", "Saved state"), ("HTTPStorages", "HTTP storage"), ("WebKit", "WebKit data"),
            ("Logs", "Logs"), ("Application Scripts", "Application Scripts"), ("Cookies", "Cookies"),
        ]
        for (folder, label) in byFolder {
            for k in list(lib.appendingPathComponent(folder)) where matchesID(k) {
                add("\(folder)/\(k)", label)
            }
        }
        // Group containers: "<team>.<id>" or "group.<id>" — shared, so unchecked by default.
        for g in list(lib.appendingPathComponent("Group Containers")) where g.hasSuffix("." + id) || g == "group." + id {
            add("Group Containers/\(g)", "Group container", include: false,
                note: "Shared; other apps from the same developer may use it.")
        }
        // Crash reports
        let reports = lib.appendingPathComponent("Logs/DiagnosticReports")
        for r in list(reports) where names.contains(where: { r.hasPrefix($0 + "_") || r.hasPrefix($0 + "-") }) {
            addURL(reports.appendingPathComponent(r), "Crash report")
        }

        // Launch agents / daemons (matched by file name, Label or the program they start)
        func launchJobs(in dir: URL, admin: Bool, system: Bool, label: String) {
            for f in list(dir) where f.hasSuffix(".plist") {
                let u = dir.appendingPathComponent(f)
                let job = batch.launchJob(u)
                let jobLabel = job.label ?? String(f.dropLast(6))
                let program = job.program ?? ""
                let base = String(f.dropLast(6))
                let exact = matchesID(base) || matchesID(jobLabel) || program.hasPrefix(appURL.path + "/")
                let byVendor = !exact && (matchesVendor(base) || matchesVendor(jobLabel))
                guard exact || byVendor else { continue }
                addURL(u, label, include: exact || vendorUnique, note: exact ? nil : vendorNote,
                       admin: admin, launch: jobLabel, system: system)
                // Helper binary the daemon runs
                if program.hasPrefix("/Library/PrivilegedHelperTools/") {
                    addURL(URL(fileURLWithPath: program), "Privileged helper", include: exact || vendorUnique,
                           note: exact ? nil : vendorNote, admin: true)
                }
            }
        }
        launchJobs(in: lib.appendingPathComponent("LaunchAgents"), admin: false, system: false, label: "Launch agent")
        launchJobs(in: sysLib.appendingPathComponent("LaunchAgents"), admin: true, system: false, label: "Launch agent (all users)")
        launchJobs(in: sysLib.appendingPathComponent("LaunchDaemons"), admin: true, system: true, label: "Launch daemon")
        let helpers = sysLib.appendingPathComponent("PrivilegedHelperTools")
        for h in list(helpers) where matchesID(h) || matchesVendor(h) {
            let exact = matchesID(h)
            addURL(helpers.appendingPathComponent(h), "Privileged helper", include: exact || vendorUnique,
                   note: exact ? nil : vendorNote, admin: true)
        }

        // /Library (all users)
        for (folder, label) in [("Application Support", "Application Support (all users)"),
                                ("Caches", "Caches (all users)"), ("Logs", "Logs (all users)")] {
            let dir = sysLib.appendingPathComponent(folder)
            for k in list(dir) where matchesID(k) || names.contains(k) {
                addURL(dir.appendingPathComponent(k), label, admin: true)
            }
        }
        let sysPrefs = sysLib.appendingPathComponent("Preferences")
        for k in list(sysPrefs) where matchesID(k.replacingOccurrences(of: ".plist", with: "")) {
            addURL(sysPrefs.appendingPathComponent(k), "Preferences (all users)", admin: true)
        }

        // Installer receipts
        if let pkgs = batch.receipts() {
            for p in pkgs.split(separator: "\n").map(String.init) where matchesID(p) || matchesVendor(p) {
                let exact = matchesID(p)
                var l = AppLeftover(id: "receipt:" + p, url: URL(fileURLWithPath: "/private/var/db/receipts/\(p).bom"),
                                    label: "Installer receipt", size: 0, include: exact || vendorUnique,
                                    note: exact ? p : "\(p) · \(vendorNote)")
                l.needsAdmin = true
                l.receipt = p
                out.append(l)
                // What the package installed outside the app (drivers, plug-ins, helpers…)
                for item in batch.installedItems(p) where item.path != appURL.path {
                    addURL(item, "Installed by \(p)", include: exact || vendorUnique,
                           note: exact ? nil : vendorNote, admin: true)
                }
            }
        }
        return out.sorted { ($0.needsAdmin ? 1 : 0, -$0.size) < ($1.needsAdmin ? 1 : 0, -$1.size) }
    }

    /// Top-level items a package installed into places the admin step may clean
    /// (e.g. an audio driver in /Library/Audio/Plug-Ins/HAL), from `pkgutil --files`.
    static func installedItems(pkg: String) -> [URL] {
        guard let info = Shell.run("/usr/sbin/pkgutil", ["--pkg-info", pkg]).output,
              let files = Shell.run("/usr/sbin/pkgutil", ["--files", pkg]).output else { return [] }
        var volume = "/", location = ""
        for line in info.split(separator: "\n") {
            if line.hasPrefix("volume: ") { volume = String(line.dropFirst(8)) }
            if line.hasPrefix("location: ") { location = String(line.dropFirst(10)) }
        }
        let base = URL(fileURLWithPath: volume).appendingPathComponent(location)
        var out: [URL] = []
        var seen = Set<String>()
        for rel in files.split(separator: "\n") {
            let u = base.appendingPathComponent(String(rel)).standardizedFileURL
            // Walk up to the first item whose parent is an allowed root.
            var c = u
            while c.path.count > 1 && !AdminGuard.roots.contains(c.deletingLastPathComponent().path) {
                c = c.deletingLastPathComponent()
            }
            guard c.path.count > 1, AdminGuard.isAllowed(c), !seen.contains(c.path),
                  fm.fileExists(atPath: c.path) else { continue }
            seen.insert(c.path)
            out.append(c)
        }
        return out
    }

    /// Disposable caches only (no settings, logins or documents).
    static func caches(id: String, names: [String]) -> [AppLeftover] {
        var out: [AppLeftover] = []
        var seen = Set<String>()

        func add(_ u: URL, _ label: String) {
            guard !seen.contains(u.path), fm.fileExists(atPath: u.path) else { return }
            seen.insert(u.path)
            let size = Scanner.allocatedSize(u)
            guard size > 0 else { return }
            out.append(AppLeftover(id: u.path, url: u, label: label, size: size, include: true, note: nil))
        }

        add(lib.appendingPathComponent("Caches/\(id)"), "Caches")
        for n in names { add(lib.appendingPathComponent("Caches/\(n)"), "Caches") }
        add(lib.appendingPathComponent("Containers/\(id)/Data/Library/Caches"), "Sandboxed cache")
        add(lib.appendingPathComponent("Logs/\(id)"), "Logs")
        for n in names { add(lib.appendingPathComponent("Logs/\(n)"), "Logs") }
        for folder in [id] + names {
            let top = lib.appendingPathComponent("Application Support/\(folder)")
            guard fm.fileExists(atPath: top.path) else { continue }
            var found: [URL] = []
            Scanner.collectWebCaches(top, depth: 0, into: &found)
            for f in found { add(f, "Web cache") }
        }
        return out.sorted { $0.size > $1.size }
    }
}

@MainActor @Observable
final class AppsModel {
    enum Phase { case idle, scanning, done, working }
    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name", lastUsed = "Last used", cache = "Cache"
        var id: String { rawValue }
    }

    var phase: Phase = .idle
    var apps: [AppInfo] = []
    /// App file name → Homebrew cask token, for apps installed with `brew install --cask`.
    var caskByApp: [String: String] = [:]

    func caskToken(_ a: AppInfo) -> String? { caskByApp[a.url.lastPathComponent] }

    /// Uninstalls through Homebrew so its records stay correct. brew deletes the app (it doesn't go to the Trash).
    func uninstallWithBrew(_ a: AppInfo) async {
        guard let token = caskToken(a) else { return }
        phase = .working
        if isRunning(a), !(await quit(a)) { phase = .done; return }
        let item = SDKItem(id: "brew.cask.\(token)", group: .homebrew, kind: "Homebrew apps (casks)", name: a.name,
                           detail: token, size: a.appSize, reveal: a.url, action: .brew(["uninstall", "--cask", token]),
                           regen: "brew install --cask \(token)")
        let r = await Task.detached { SDKEngine.remove([item]) }.value
        if r.errors.isEmpty {
            apps.removeAll { $0.id == a.id }
            caskByApp[a.url.lastPathComponent] = nil
            HistoryStore.shared.add("\(a.name) Uninstalled with Homebrew", bytes: a.appSize, symbol: "mug", outcome: .deleted)
            message = ("Uninstalled \(a.name) with Homebrew. Its leftovers in your Library are still listed under Uninstall if you want them gone too.", false)
            selectedID = visible.first?.id
        } else {
            message = ("Homebrew couldn't uninstall \(a.name): \(r.errors.joined(separator: "; "))", true)
        }
        phase = .done
    }
    var selectedID: String?
    var search = ""
    var sort: Sort = .size
    var progressDone = 0
    var progressTotal = 0
    var confirmUninstall = false
    var confirmClear = false
    var message: (text: String, isError: Bool)?

    var selected: AppInfo? { apps.first { $0.id == selectedID } }

    var visible: [AppInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? apps : apps.filter {
            $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
        }
        switch sort {
        case .size: return list.sorted { $0.total > $1.total }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .cache: return list.sorted { $0.cacheSize > $1.cacheSize }
        }
    }

    var totalCaches: Int64 { apps.reduce(0) { $0 + $1.cacheSize } }

    func scan() async {
        guard phase != .scanning else { return }
        phase = .scanning
        message = nil
        // Homebrew's cask list is independent of the app scan, so it runs alongside it.
        let casks = Task.detached(priority: .userInitiated) { SDKEngine.brewPath == nil ? [:] : SDKEngine.caskApps() }
        let urls = await Task.detached { AppScanner.appURLs() }.value
        let allIDs = await Task.detached { Set(urls.map(AppScanner.bundleID)) }.value
        progressTotal = urls.count
        progressDone = 0
        let batch = AppScanner.Batch()
        var found: [AppInfo] = []
        await withTaskGroup(of: AppInfo.self) { group in
            var queue = urls[...]
            for _ in 0..<DirSize.width {
                if let u = queue.popFirst() { group.addTask { AppScanner.info(for: u, allIDs: allIDs, batch: batch) } }
            }
            while let info = await group.next() {
                found.append(info)
                progressDone += 1
                if let u = queue.popFirst() { group.addTask { AppScanner.info(for: u, allIDs: allIDs, batch: batch) } }
            }
        }
        apps = found
        if selectedID == nil || selected == nil { selectedID = visible.first?.id }
        phase = .done
        caskByApp = await casks.value
    }

    /// Bumped whenever any app launches or quits, so running state redraws live.
    var runningTick = 0
    var quittingID: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runningTick += 1 }
            })
        }
    }

    func isRunning(_ a: AppInfo) -> Bool {
        _ = runningTick
        return !a.bundleID.isEmpty && !NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleID).isEmpty
    }

    /// Stops its launch agents (so nothing restarts it), asks it to quit, waits 5 s, then force-quits.
    @discardableResult
    func quit(_ a: AppInfo) async -> Bool {
        guard !a.isSelf, !a.isApple else { return false }
        quittingID = a.id
        defer { quittingID = nil; runningTick += 1 }
        let ok = await Task.detached { AppEngine.quit(a) }.value
        message = ok ? ("\(a.name) has quit.", false)
                     : ("\(a.name) did not quit. Quit it from its menu bar icon or Activity Monitor, then try again.", true)
        return ok
    }

    func toggleLeftover(_ leftoverID: String) {
        guard let ai = apps.firstIndex(where: { $0.id == selectedID }),
              let li = apps[ai].leftovers.firstIndex(where: { $0.id == leftoverID }) else { return }
        apps[ai].leftovers[li].include.toggle()
    }

    /// Text for the uninstall confirm dialog.
    var uninstallSummary: String {
        guard let a = selected else { return "" }
        let picked = a.leftovers.filter(\.include)
        var lines = ["• \(a.name).app — \(ByteText.string(a.appSize))"]
        for l in picked.prefix(12) {
            let where_ = l.receipt != nil ? "receipt \(l.receipt!)" : Scanner.tilde(l.url)
            lines.append("• \(l.label): \(where_) — \(ByteText.string(l.size))")
        }
        if picked.count > 12 { lines.append("• …and \(picked.count - 12) more") }
        var text = lines.joined(separator: "\n")
        let kept = a.leftovers.count - picked.count
        let admin = picked.filter(\.needsAdmin).count
        if kept > 0 { text += "\n\nKept (unchecked): \(kept) item(s)." }
        if admin > 0 { text += "\n\n\(admin) item(s) are outside your home folder; macOS will ask for your password once." }
        if isRunning(a) { text += "\n\n\(a.name) is running and will be quit first (force-quit after 5 seconds if it doesn't respond)." }
        text += "\nBackground jobs are stopped first. Everything goes to the Trash, so you can put it back."
        return text
    }

    /// Why this app can't be uninstalled right now, or nil.
    func uninstallBlock(_ a: AppInfo) -> String? {
        if a.isSelf { return "This is Mac Cleaner itself" }
        if a.isApple { return "Apple app, part of macOS" }
        if !TrashGuard.canTrash(a.url) { return TrashGuard.reason(a.url) }
        return nil
    }

    /// Full uninstall: stop background jobs, app + checked leftovers → Trash,
    /// then one password prompt (macOS's own) for items outside your home folder.
    func uninstall() async {
        guard let a = selected, uninstallBlock(a) == nil else { return }
        phase = .working
        if isRunning(a), !(await quit(a)) { phase = .done; return }
        let picked = a.leftovers.filter(\.include)
        let r = await Task.detached { AppEngine.uninstall(a, picked: picked) }.value
        if r.appRemoved {
            apps.removeAll { $0.id == a.id }
            HistoryStore.shared.add("\(a.name) Uninstalled", bytes: r.bytes, symbol: "square.grid.2x2", outcome: .trashed)
        }
        selectedID = visible.first?.id
        message = (r.summary(appName: a.name), !(r.errors.isEmpty && r.appRemoved))
        phase = .done
    }

    /// Deletes the app's disposable caches permanently (cache allow-list only).
    func clearCaches() async {
        guard let a = selected, !a.caches.isEmpty else { return }
        phase = .working
        let items = a.caches
        let errors: [String] = await Task.detached { AppEngine.clearCaches(items) }.value
        let ids = Set(apps.map(\.bundleID))
        let fresh = await Task.detached { AppScanner.info(for: a.url, allIDs: ids) }.value
        if let i = apps.firstIndex(where: { $0.id == a.id }) { apps[i] = fresh }
        let freed = max(0, a.cacheSize - fresh.cacheSize)
        HistoryStore.shared.add("\(a.name) Cache Cleared", bytes: freed, symbol: "wind", outcome: .deleted)
        message = errors.isEmpty
            ? ("Cleared \(ByteText.string(freed)) of \(a.name) caches.", false)
            : ("Cleared \(ByteText.string(freed)). \(errors.count) problem(s): \(errors.prefix(2).joined(separator: "; "))", true)
        phase = .done
    }

}


/// Paths the admin step may move: direct children of these system folders, nothing else.
enum AdminGuard {
    static let roots = [
        "/Applications", "/Library/Application Support", "/Library/Caches", "/Library/Logs",
        "/Library/Preferences", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
        "/Library/Audio/Plug-Ins/HAL", "/Library/Audio/Plug-Ins/Components", "/Library/Internet Plug-Ins",
        "/Library/QuickLook", "/Library/Spotlight", "/Library/PreferencePanes", "/Library/Screen Savers",
        "/Library/Input Methods", "/Library/Services",
    ]

    static func isAllowed(_ url: URL) -> Bool {
        if ProtectedPaths.isBlocked(url) { return false }
        let p = url.standardizedFileURL.path
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        guard roots.contains(parent), !roots.contains(p) else { return false }
        if parent == "/Applications" { return url.pathExtension == "app" }
        return !url.lastPathComponent.hasPrefix("com.apple.")
    }
}

/// Runs the system part of an uninstall through macOS's own administrator prompt
/// (`osascript … with administrator privileges`). Files go to a folder in your Trash.
enum AdminStep {
    enum Result { case ok(staging: URL), cancelled, failed(String) }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func run(_ items: [AppLeftover], uid: uid_t) -> Result {
        let stamp = Int(Date().timeIntervalSince1970)
        // Staging folder in your home (the Trash itself is privacy-protected even for admin);
        // the app then moves this folder to the Trash with the normal API.
        let staging = SafetyGuard.home.appendingPathComponent(".MacCleaner-uninstalled-\(stamp)")
        let trashDir = staging.path
        var lines = ["set -u", "mkdir -p \(q(trashDir))"]
        for (i, l) in items.enumerated() {
            if let label = l.launchLabel, label.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil {
                let domain = l.launchSystem ? "system" : "gui/\(uid)"
                lines.append("launchctl bootout \(domain)/\(label) 2>/dev/null || true")
            }
            if let pkg = l.receipt {
                guard pkg.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { continue }
                lines.append("pkgutil --forget \(pkg) >/dev/null 2>&1 || true")
                continue
            }
            guard AdminGuard.isAllowed(l.url) else { continue }
            let dest = trashDir + "/\(i)-" + l.url.lastPathComponent
            lines.append("[ -e \(q(l.url.path)) ] && mv -f \(q(l.url.path)) \(q(dest))")
        }
        if items.contains(where: { $0.url.path.hasPrefix("/Library/Audio/Plug-Ins/HAL/") }) {
            lines.append("killall coreaudiod 2>/dev/null || true")
        }
        lines.append("chown -R \(uid) \(q(trashDir)) 2>/dev/null || true")
        lines.append("true")
        let script = lines.joined(separator: "; ")
        let apple = "do shell script \"" + script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
        let r = Shell.run("/usr/bin/osascript", ["-e", apple])
        if r.status == 0 { return .ok(staging: staging) }
        let out = r.output ?? ""
        if out.contains("-128") || out.lowercased().contains("cancel") { return .cancelled }
        return .failed(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}


/// Synchronous app actions shared by the window and the MCP server. Call off the main thread.
enum AppEngine {
    struct UninstallResult: Sendable {
        var appRemoved = false
        var bytes: Int64 = 0
        var errors: [String] = []
        var adminNote = ""

        func summary(appName: String) -> String {
            if errors.isEmpty && appRemoved {
                return "Uninstalled \(appName): \(ByteText.string(bytes)) moved to the Trash.\(adminNote) Empty the Trash to free it."
            }
            return "\(appRemoved ? "Uninstalled" : "Could not uninstall") \(appName) (\(ByteText.string(bytes)) to Trash).\(adminNote) \(errors.count) problem(s): \(errors.prefix(2).joined(separator: "; "))"
        }
    }

    static func isRunning(_ a: AppInfo) -> Bool {
        !a.bundleID.isEmpty && !NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleID).isEmpty
    }

    private static func alive(_ pids: [pid_t]) -> Bool {
        pids.contains { kill($0, 0) == 0 || errno != ESRCH }
    }

    /// Stops the app's launch agents, asks it to quit, waits 5 s, then force-quits. Blocks up to ~8 s.
    static func quit(_ a: AppInfo) -> Bool {
        guard !a.isSelf, !a.isApple else { return false }
        let uid = getuid()
        for l in a.leftovers where !l.needsAdmin {
            if let label = l.launchLabel { _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"]) }
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleID)
        let pids = running.map(\.processIdentifier)
        guard !pids.isEmpty else { return true }
        running.forEach { $0.terminate() }
        for _ in 0..<25 where alive(pids) { Thread.sleep(forTimeInterval: 0.2) }
        if alive(pids) {
            running.forEach { $0.forceTerminate() }
            for _ in 0..<15 where alive(pids) { Thread.sleep(forTimeInterval: 0.2) }
        }
        return !alive(pids)
    }

    /// Every "Move to Trash" in the app goes through here: re-checks protection, moves the item,
    /// and logs where it came from so it can be put back.
    @discardableResult
    static func trash(_ url: URL, size: Int64? = nil, source: String = "Mac Cleaner", restorable: Bool = true) -> String? {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        if let why = ProtectedPaths.reason(url) { return why }
        let bytes = size ?? Scanner.allocatedSize(url)
        var out: NSURL?
        do { try FileManager.default.trashItem(at: url, resultingItemURL: &out) }
        catch { return error.localizedDescription }
        if let dest = out as URL? {
            TrashLog.shared.record(original: url.path, trashed: dest.path, size: bytes, source: source, restorable: restorable)
        }
        return nil
    }

    /// App + picked leftovers → Trash; items outside home through one macOS password prompt.
    static func uninstall(_ a: AppInfo, picked: [AppLeftover]) -> UninstallResult {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        var r = UninstallResult()
        let uid = getuid()
        for l in picked where !l.needsAdmin {
            if let label = l.launchLabel { _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"]) }
        }
        var adminItems = picked.filter(\.needsAdmin)
        if let e = trash(a.url, size: a.appSize, source: "Uninstall \(a.name)") {
            guard AdminGuard.isAllowed(a.url) else {
                r.errors.append("\(a.name).app: \(e)")
                return r
            }
            adminItems.insert(AppLeftover(id: a.url.path, url: a.url, label: "App", size: a.appSize,
                                          include: true, note: nil, needsAdmin: true), at: 0)
        } else {
            r.appRemoved = true
            r.bytes += a.appSize
        }
        for l in picked where !l.needsAdmin {
            if let why = TrashGuard.reason(l.url) { r.errors.append("\(l.url.lastPathComponent): \(why)"); continue }
            if let e = trash(l.url, size: l.size, source: "Uninstall \(a.name)") { r.errors.append("\(l.url.lastPathComponent): \(e)") } else { r.bytes += l.size }
        }
        guard !adminItems.isEmpty else { return r }
        switch AdminStep.run(adminItems, uid: uid) {
        case .ok(let staging):
            let staged = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            if staged.isEmpty {
                try? FileManager.default.removeItem(at: staging)
            } else if let e = trash(staging, source: "Uninstall (system items)", restorable: false) {
                r.errors.append("Moved system items to \(Scanner.tilde(staging)) but could not send it to the Trash: \(e)")
            }
            let still = adminItems.filter { $0.receipt == nil && FileManager.default.fileExists(atPath: $0.url.path) }
            r.bytes += adminItems.filter { i in !still.contains { $0.id == i.id } }.reduce(0) { $0 + $1.size }
            if !still.contains(where: { $0.url == a.url }) { r.appRemoved = true }
            for l in still { r.errors.append("\(l.url.lastPathComponent): still there after admin step") }
            r.adminNote = " Includes \(adminItems.count - still.count) system item(s)."
        case .cancelled:
            r.adminNote = " System items were kept (password prompt cancelled)."
        case .failed(let msg):
            r.errors.append("System items: \(msg)")
        }
        return r
    }

    /// Moves items outside your home folder to the Trash via one macOS password prompt
    /// (stopping any launch jobs first). Returns removed paths and errors.
    static func removeSystemItems(_ items: [AppLeftover]) -> (removed: [URL], errors: [String], cancelled: Bool) {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        guard !items.isEmpty else { return ([], [], false) }
        switch AdminStep.run(items, uid: getuid()) {
        case .ok(let staging):
            var errors: [String] = []
            let staged = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            if staged.isEmpty { try? FileManager.default.removeItem(at: staging) }
            else if let e = trash(staging, source: "System items", restorable: false) { errors.append("Staging folder \(Scanner.tilde(staging)): \(e)") }
            let fm = FileManager.default
            let removed = items.filter { $0.receipt == nil && !fm.fileExists(atPath: $0.url.path) }.map(\.url)
            for i in items where i.receipt == nil && fm.fileExists(atPath: i.url.path) {
                errors.append("\(i.url.lastPathComponent): still there")
            }
            return (removed, errors, false)
        case .cancelled:
            return ([], [], true)
        case .failed(let msg):
            return ([], [msg], false)
        }
    }

    /// Permanently deletes an app's disposable caches (cache allow-list only).
    static func clearCaches(_ items: [AppLeftover]) -> [String] {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        var errs: [String] = []
        let fm = FileManager.default
        for c in items {
            if SafetyGuard.containerCacheDepth(c.url.resolvingSymlinksInPath().path) == 4 {
                let kids = (try? fm.contentsOfDirectory(at: c.url, includingPropertiesForKeys: nil)) ?? []
                for k in kids where SafetyGuard.isAllowed(k) {
                    do { try fm.removeItem(at: k) } catch { errs.append("\(k.lastPathComponent): \(error.localizedDescription)") }
                }
            } else if SafetyGuard.isAllowed(c.url) {
                do { try fm.removeItem(at: c.url) } catch { errs.append("\(c.url.lastPathComponent): \(error.localizedDescription)") }
            } else {
                errs.append("\(c.url.lastPathComponent): outside the cache allow-list, skipped")
            }
        }
        return errs
    }

    /// Finds an app by bundle id, name or path.
    static func find(_ query: String, in apps: [AppInfo]) -> AppInfo? {
        let q = query.lowercased()
        return apps.first { $0.bundleID.lowercased() == q || $0.url.path.lowercased() == q }
            ?? apps.first { $0.name.lowercased() == q }
            ?? apps.first { $0.name.lowercased().contains(q) }
    }

    /// Full scan of installed apps (blocking).
    static func scanAll() -> [AppInfo] {
        let urls = AppScanner.appURLs()
        let ids = Set(urls.map(AppScanner.bundleID))
        let batch = AppScanner.Batch()
        var out = [AppInfo?](repeating: nil, count: urls.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                buf[i] = AppScanner.info(for: urls[i], allIDs: ids, batch: batch)
            }
        }
        return out.compactMap { $0 }
    }
}
