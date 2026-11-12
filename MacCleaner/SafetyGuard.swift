import Foundation

/// Hard allow-list for the permanent cache sweep. Every path is resolved (symlinks followed)
/// before checking, so a cache folder that is really a link somewhere else is refused.
enum SafetyGuard {
    static let home = FileManager.default.homeDirectoryForCurrentUser
        .resolvingSymlinksInPath().standardizedFileURL

    static let editorApps = [("Code", "VS Code"), ("Cursor", "Cursor"), ("Antigravity", "Antigravity")]
    static let editorCacheFolders = ["Cache", "CachedData", "Code Cache", "CachedExtensionVSIXs", "GPUCache", "logs"]
    static let deviceSupportOSes = ["iOS", "watchOS", "tvOS", "macOS", "visionOS"]
    /// Folder names that browsers and Electron apps use for disposable caches.
    static let webCacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "ShaderCache", "GrShaderCache",
    ]

    static let appSupport = home.appendingPathComponent("Library/Application Support").path
    static let containersRoot = home.appendingPathComponent("Library/Containers").path

    /// Only paths at or inside these may be swept.
    static let allowedRoots: [String] = {
        var r = [
            "Library/Developer/Xcode/DerivedData",
            "Library/Developer/Xcode/Archives",
            "Library/Developer/Xcode/UserData/Previews",
            "Library/Developer/CoreSimulator/Caches",
            "Library/Caches",
            "Library/Logs",
            ".gradle/caches", ".gradle/daemon", ".gradle/wrapper/dists",
            ".android/cache", ".android/avd",
            "Library/Android/sdk/system-images",
            "Library/Android/sdk/platforms", "Library/Android/sdk/ndk", "Library/Android/sdk/build-tools",
            ".pub-cache/hosted", ".pub-cache/git",
            ".dartServer",
            ".npm/_cacache", "Library/pnpm/store", ".bun/install/cache",
            // Other package managers (download caches; re-fetched on the next build)
            ".cargo/registry", ".cargo/git", "go/pkg/mod", ".m2/repository", ".ivy2/cache", ".gem/specs",
            ".bundle/cache", ".nuget/packages", ".local/share/NuGet", ".hex/packages", ".cabal/packages",
            ".composer/cache", ".cocoapods/repos",
            "miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs", "opt/miniconda3/pkgs", "opt/anaconda3/pkgs", ".conda/pkgs",
            // Language versions installed by version managers (one folder per version)
            ".nvm/versions/node", "Library/Application Support/fnm/node-versions", ".volta/tools/image/node",
            ".pyenv/versions", ".rbenv/versions", ".rustup/toolchains", ".sdkman/candidates", ".asdf/installs",
            "Library/Java/JavaVirtualMachines",
            ".cache",
            ".Trash",
        ]
        r += deviceSupportOSes.map { "Library/Developer/Xcode/\($0) DeviceSupport" }
        for (folder, _) in editorApps {
            r += editorCacheFolders.map { "Library/Application Support/\(folder)/\($0)" }
        }
        return r.map { home.appendingPathComponent($0).path }
    }()

    /// Folders that hold many things. Their contents may go, the folder itself never.
    static let containerRoots: [String] = [
        "Library/Caches", "Library/Logs", ".cache", ".Trash", ".android/avd",
        "Library/Android/sdk/system-images",
        "Library/Android/sdk/platforms", "Library/Android/sdk/ndk", "Library/Android/sdk/build-tools",
        ".nvm/versions/node", "Library/Application Support/fnm/node-versions", ".volta/tools/image/node",
        ".pyenv/versions", ".rbenv/versions", ".rustup/toolchains", ".sdkman/candidates", ".asdf/installs",
        "Library/Java/JavaVirtualMachines",
    ].map { home.appendingPathComponent($0).path }

    /// Never swept (permanent delete). Personal files go through the Trash instead (see TrashGuard).
    static let protectedRoots: [String] = [
        "Documents", "Downloads", "Movies", "Desktop", "Pictures", "Music",
        "Library/Mobile Documents", "Library/CloudStorage",
        ".pub-cache/bin",
    ].map { home.appendingPathComponent($0).path }

    static func isAllowed(_ url: URL, allowContainer: Bool = false) -> Bool {
        if ProtectedPaths.isBlocked(url) { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if protectedRoots.contains(where: { isInside(path, $0) }) { return false }
        if let depth = containerCacheDepth(path) { return depth > 4 || (allowContainer && depth == 4) }
        if isWebCache(path) { return true }
        if !allowContainer && containerRoots.contains(path) { return false }
        return allowedRoots.contains(where: { isInside(path, $0) })
    }

    /// ~/Library/Containers/<app>/Data/Library/Caches[/…] → number of components after Containers.
    static func containerCacheDepth(_ path: String) -> Int? {
        guard path.hasPrefix(containersRoot + "/") else { return nil }
        let rel = path.dropFirst(containersRoot.count + 1).split(separator: "/")
        guard rel.count >= 4, rel[1] == "Data", rel[2] == "Library", rel[3] == "Caches",
              !rel[0].hasPrefix("com.apple.") else { return nil }
        return rel.count
    }

    /// ~/Library/Application Support/<app>/…/<Cache|GPUCache|…> or …/Service Worker/<CacheStorage|ScriptCache>
    static func isWebCache(_ path: String) -> Bool {
        guard path.hasPrefix(appSupport + "/") else { return false }
        let rel = path.dropFirst(appSupport.count + 1).split(separator: "/").map(String.init)
        guard rel.count >= 2, !rel[0].hasPrefix("com.apple.") else { return false }
        for i in 1..<min(rel.count, 6) {
            if webCacheNames.contains(rel[i]) { return true }
            if (rel[i] == "CacheStorage" || rel[i] == "ScriptCache") && rel[i - 1] == "Service Worker" { return true }
        }
        return false
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}

/// Rules for "Move to Trash" in Disk Map and Duplicates. Recoverable, so it may reach personal
/// folders, but never the structural folders macOS or your account depend on.
enum TrashGuard {
    static let home = SafetyGuard.home.path

    /// Exact folders that may never be trashed themselves.
    static let structural: Set<String> = {
        var s: Set<String> = ["/", "/Applications", "/Users", home]
        for sub in ["Library", "Documents", "Downloads", "Desktop", "Movies", "Pictures", "Music",
                    "Public", "Applications", "Library/Application Support", "Library/Containers",
                    "Library/Group Containers", "Library/Preferences", "Library/Caches",
                    "Library/Mobile Documents", "Library/CloudStorage", ".Trash", "Library/Cookies"] {
            s.insert(home + "/" + sub)
        }
        return s
    }()

    /// Never trash anything inside these.
    static let sensitive: [String] = [
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Accounts",
        ".ssh", ".gnupg",
    ].map { home + "/" + $0 }

    static func canTrash(_ url: URL) -> Bool { reason(url) == nil }

    private static let structuralKeys = Set(structural.map { $0.lowercased() })
    private static let sensitiveKeys = sensitive.map { $0.lowercased() }

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
        let p = key(url)
        let home = Self.home.lowercased()
        if structuralKeys.contains(p) { return "System or account folder" }
        // Single Messages attachments may go (Messages then shows them as unavailable); the folders stay.
        let attachments = home + "/library/messages/attachments"
        if SafetyGuard.isInside(p, attachments) && p != attachments { return nil }
        if sensitiveKeys.contains(where: { SafetyGuard.isInside(p, $0) }) { return "Holds passwords, mail or settings" }
        if SafetyGuard.isInside(p, home) || SafetyGuard.isInside(p, "/applications") { return nil }
        return "Outside your home folder (view only)"
    }
}

/// Folders and files the user never wants touched. Checked by every guard (cache sweep, Trash,
/// admin step, Shredder, MCP). Stored in the app's defaults so the MCP server sees the same list.
enum ProtectedPaths {
    static let key = "protectedPaths"

    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func set(_ paths: [String]) {
        var seen = Set<String>()
        let clean = paths.map(normalize).filter { seen.insert($0).inserted }.sorted()
        UserDefaults.standard.set(clean, forKey: key)
    }

    static func add(_ urls: [URL]) { set(all + urls.map(\.path)) }
    static func remove(_ path: String) { set(all.filter { $0 != normalize(path) }) }

    static func normalize(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// nil if fine; otherwise why it's blocked. A path is blocked if it is protected, inside a
    /// protected folder, or contains a protected item (removing it would take the item along).
    /// Compared without regard to letter case: the Mac's disk ignores case, so ~/documents is ~/Documents.
    static func reason(_ url: URL) -> String? {
        let p = normalize(url.path).lowercased()
        for q in all.map({ $0.lowercased() }) {
            if p == q || p.hasPrefix(q + "/") { return "Protected (Settings › Protection)" }
            if q.hasPrefix(p + "/") { return "Contains a protected item" }
        }
        return nil
    }

    static func isBlocked(_ url: URL) -> Bool { reason(url) != nil }

    /// Protected itself or inside a protected folder (ignores "contains a protected item").
    static func isInsideProtected(_ url: URL) -> Bool {
        let p = normalize(url.path)
        return all.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
}
