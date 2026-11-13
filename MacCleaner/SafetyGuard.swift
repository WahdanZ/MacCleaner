import Foundation
import MacCleanerCore

// The rules themselves live in MacCleanerCore (pure, tested with `swift test` in Packages/MacCleanerKit).
// These wrappers resolve paths on this Mac (symlinks, letter case, the real home folder) and ask the rules.

/// Hard allow-list for the permanent cache sweep. Every path is resolved (symlinks followed)
/// before checking, so a cache folder that is really a link somewhere else is refused.
enum SafetyGuard {
    static let home = FileManager.default.homeDirectoryForCurrentUser
        .resolvingSymlinksInPath().standardizedFileURL

    static let rules = PermanentDeleteRules(home: home.path)

    static let editorApps = PermanentDeleteRules.editorApps.map { ($0.folder, $0.name) }
    static let editorCacheFolders = PermanentDeleteRules.editorCacheFolders
    static let deviceSupportOSes = PermanentDeleteRules.deviceSupportOSes
    static let webCacheNames = PermanentDeleteRules.webCacheNames

    static var appSupport: String { rules.appSupport }
    static var containersRoot: String { rules.containersRoot }
    static var allowedRoots: [String] { rules.allowedRoots }
    static var containerRoots: [String] { rules.containerRoots }
    static var protectedRoots: [String] { rules.protectedRoots }

    static func isAllowed(_ url: URL, allowContainer: Bool = false) -> Bool {
        if ProtectedPaths.isBlocked(url) { return false }
        return rules.allows(resolvedPath: url.resolvingSymlinksInPath().standardizedFileURL.path, allowContainer: allowContainer)
    }

    static func containerCacheDepth(_ path: String) -> Int? { rules.containerCacheDepth(path) }
    static func isWebCache(_ path: String) -> Bool { rules.isWebCache(path) }
    static func isInside(_ path: String, _ root: String) -> Bool { PathRules.isInside(path, root) }
}

/// Rules for "Move to Trash" in Disk Map and Duplicates. Recoverable, so it may reach personal
/// folders, but never the structural folders macOS or your account depend on.
enum TrashGuard {
    static let home = SafetyGuard.home.path
    static let rules = TrashRules(home: home)
    static var structural: Set<String> { rules.structural }
    static var sensitive: [String] { rules.sensitive }

    static func canTrash(_ url: URL) -> Bool { reason(url) == nil }

    /// The path compared by the rules: symlinks in its parent folders resolved (the item itself is not
    /// followed: trashing a link moves the link), and lower-cased, because the Mac's disk ignores case.
    /// Without this, ~/documents or ~/link-to-ssh/key would pass an exact comparison.
    static func key(_ url: URL) -> String {
        let std = url.standardizedFileURL
        guard std.path != "/" else { return "/" }
        let parent = std.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(std.lastPathComponent).standardizedFileURL.path.lowercased()
    }

    /// nil when allowed; otherwise why not.
    static func reason(_ url: URL) -> String? {
        if let why = ProtectedPaths.reason(url) { return why }
        return rules.refusal(key: key(url))
    }
}

/// Folders and files the user never wants touched. Checked by every guard (cache sweep, Trash,
/// admin step, Shredder, MCP). Stored in the app's defaults so the MCP server sees the same list.
enum ProtectedPaths {
    static let key = "protectedPaths"

    /// Where the list is kept. Only the self-test changes it, once at start and back at the end, to an
    /// in-memory store so it never writes the user's settings; nothing else runs concurrently at that point.
    nonisolated(unsafe) static var store: SettingsStore = UserDefaults.standard

    static var all: [String] { store.stringArray(forKey: key) ?? [] }
    static var protection: UserProtection { UserProtection(paths: all) }

    static func set(_ paths: [String]) {
        store.set(UserProtection.cleaned(paths.map(normalize)), forKey: key)
    }

    static func add(_ urls: [URL]) { set(all + urls.map(\.path)) }
    static func remove(_ path: String) { set(all.filter { $0 != normalize(path) }) }

    static func normalize(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// nil if fine; otherwise why it's blocked (protected, inside a protected folder, or containing one).
    /// Letter case is ignored: the Mac's disk ignores it, so ~/documents is ~/Documents.
    static func reason(_ url: URL) -> String? { protection.refusal(normalizedPath: normalize(url.path)) }

    static func isBlocked(_ url: URL) -> Bool { reason(url) != nil }

    /// Protected itself or inside a protected folder (ignores "contains a protected item"). Ignores case.
    static func isInsideProtected(_ url: URL) -> Bool { protection.covers(normalizedPath: normalize(url.path)) }
}

/// The few settings calls the Protected list and the settings migration need. `UserDefaults` provides them;
/// the self-test uses `MemorySettings`, so it never writes the user's preferences.
protocol SettingsStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func stringArray(forKey defaultName: String) -> [String]?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
    func set(_ value: Bool, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: SettingsStore {}

/// Settings kept in memory only (self-test). Not shared between processes and gone when the process ends.
final class MemorySettings: SettingsStore {
    private var values: [String: Any]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(forKey k: String) -> Any? { values[k] }
    func string(forKey k: String) -> String? { values[k] as? String }
    func stringArray(forKey k: String) -> [String]? { values[k] as? [String] }
    func bool(forKey k: String) -> Bool { values[k] as? Bool ?? false }
    func set(_ v: Any?, forKey k: String) { values[k] = v }
    func set(_ v: Bool, forKey k: String) { values[k] = v }
    func removeObject(forKey k: String) { values[k] = nil }
}
