import Foundation

// The rules that decide what may be deleted or moved to the Trash. Pure: every function takes paths that the
// caller has already resolved (symlinks, case) and never touches the file system, so the rules are testable with
// any home folder. The app's SafetyGuard / TrashGuard / ProtectedPaths resolve paths and call these.
//
// Precedence (strongest first): user protection → structural/sensitive folders → allow-lists.

/// Path comparisons on "/"-separated absolute paths.
public enum PathRules {
    /// `path` is `root` or inside it ("/a/bc" is not inside "/a/b").
    public static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// `home` + "/" + `relative`, as `URL.appendingPathComponent(_:).path` gives for a standardized home.
    public static func join(_ home: String, _ relative: String) -> String {
        home.hasSuffix("/") ? home + relative : home + "/" + relative
    }
}

/// Folders and files the user protected (Settings › Protection). Checked by every guard.
public struct UserProtection: Sendable, Equatable {
    /// Normalized paths (symlinks resolved, standardized), as stored.
    public let paths: [String]

    public init(paths: [String]) { self.paths = paths }

    /// The stored form of a list: duplicates removed, sorted. Paths must already be normalized.
    public static func cleaned(_ normalized: [String]) -> [String] {
        var seen = Set<String>()
        return normalized.filter { seen.insert($0).inserted }.sorted()
    }

    /// nil if fine; otherwise why it's blocked. Blocked when it is protected, inside a protected folder, or
    /// contains a protected item (removing it would take the item along). Letter case is ignored: the Mac's
    /// disk ignores it, so ~/documents is ~/Documents.
    public func refusal(normalizedPath: String) -> String? {
        let p = normalizedPath.lowercased()
        for q in paths.map({ $0.lowercased() }) {
            if PathRules.isInside(p, q) { return "Protected (Settings › Protection)" }
            if q.hasPrefix(p + "/") { return "Contains a protected item" }
        }
        return nil
    }

    /// Protected itself or inside a protected folder (not "contains a protected item"). Ignores letter case,
    /// like `refusal` (it used to compare exactly, RISK-012).
    public func covers(normalizedPath: String) -> Bool {
        let p = normalizedPath.lowercased()
        return paths.contains { PathRules.isInside(p, $0.lowercased()) }
    }
}

/// Allow-list for permanent deletion (the cache sweep). Only regenerable caches qualify.
public struct PermanentDeleteRules: Sendable {
    public static let editorApps: [(folder: String, name: String)] = [
        ("Code", "VS Code"), ("Cursor", "Cursor"), ("Antigravity", "Antigravity"),
    ]
    public static let editorCacheFolders = ["Cache", "CachedData", "Code Cache", "CachedExtensionVSIXs", "GPUCache", "logs"]
    public static let deviceSupportOSes = ["iOS", "watchOS", "tvOS", "macOS", "visionOS"]
    /// Folder names that browsers and Electron apps use for disposable caches.
    public static let webCacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "ShaderCache", "GrShaderCache",
    ]

    public let home: String
    public let appSupport: String
    public let containersRoot: String
    /// Only paths at or inside these may be swept.
    public let allowedRoots: [String]
    /// Folders that hold many things. Their contents may go, the folder itself never.
    public let containerRoots: [String]
    /// Never swept. Personal files go through the Trash instead.
    public let protectedRoots: [String]

    /// `home`: the resolved, standardized home folder path.
    public init(home: String) {
        self.home = home
        let at = { (rel: String) in PathRules.join(home, rel) }
        appSupport = at("Library/Application Support")
        containersRoot = at("Library/Containers")
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
        r += Self.deviceSupportOSes.map { "Library/Developer/Xcode/\($0) DeviceSupport" }
        for app in Self.editorApps {
            r += Self.editorCacheFolders.map { "Library/Application Support/\(app.folder)/\($0)" }
        }
        allowedRoots = r.map(at)
        containerRoots = [
            "Library/Caches", "Library/Logs", ".cache", ".Trash", ".android/avd",
            "Library/Android/sdk/system-images",
            "Library/Android/sdk/platforms", "Library/Android/sdk/ndk", "Library/Android/sdk/build-tools",
            ".nvm/versions/node", "Library/Application Support/fnm/node-versions", ".volta/tools/image/node",
            ".pyenv/versions", ".rbenv/versions", ".rustup/toolchains", ".sdkman/candidates", ".asdf/installs",
            "Library/Java/JavaVirtualMachines",
        ].map(at)
        protectedRoots = [
            "Documents", "Downloads", "Movies", "Desktop", "Pictures", "Music",
            "Library/Mobile Documents", "Library/CloudStorage",
            ".pub-cache/bin",
        ].map(at)
    }

    /// `resolvedPath`: symlinks resolved and standardized. User protection is checked by the caller first.
    public func allows(resolvedPath path: String, allowContainer: Bool = false) -> Bool {
        if protectedRoots.contains(where: { PathRules.isInside(path, $0) }) { return false }
        if let depth = containerCacheDepth(path) { return depth > 4 || (allowContainer && depth == 4) }
        if isWebCache(path) { return true }
        if !allowContainer && containerRoots.contains(path) { return false }
        return allowedRoots.contains(where: { PathRules.isInside(path, $0) })
    }

    /// ~/Library/Containers/<app>/Data/Library/Caches[/…] → number of components after Containers.
    public func containerCacheDepth(_ path: String) -> Int? {
        guard path.hasPrefix(containersRoot + "/") else { return nil }
        let rel = path.dropFirst(containersRoot.count + 1).split(separator: "/")
        guard rel.count >= 4, rel[1] == "Data", rel[2] == "Library", rel[3] == "Caches",
              !rel[0].hasPrefix("com.apple.") else { return nil }
        return rel.count
    }

    /// ~/Library/Application Support/<app>/…/<Cache|GPUCache|…> or …/Service Worker/<CacheStorage|ScriptCache>
    public func isWebCache(_ path: String) -> Bool {
        guard path.hasPrefix(appSupport + "/") else { return false }
        let rel = path.dropFirst(appSupport.count + 1).split(separator: "/").map(String.init)
        guard rel.count >= 2, !rel[0].hasPrefix("com.apple.") else { return false }
        for i in 1..<min(rel.count, 6) {
            if Self.webCacheNames.contains(rel[i]) { return true }
            if (rel[i] == "CacheStorage" || rel[i] == "ScriptCache") && rel[i - 1] == "Service Worker" { return true }
        }
        return false
    }
}

/// Rules for "Move to Trash": recoverable, so personal folders are allowed, but never the structural folders
/// macOS or the account depend on, nor password/mail/settings stores.
public struct TrashRules: Sendable {
    public let home: String
    /// Exact folders that may never be trashed themselves.
    public let structural: Set<String>
    /// Never trash anything inside these.
    public let sensitive: [String]
    private let structuralKeys: Set<String>
    private let sensitiveKeys: [String]

    /// `home`: the resolved, standardized home folder path.
    public init(home: String) {
        self.home = home
        var s: Set<String> = ["/", "/Applications", "/Users", home]
        for sub in ["Library", "Documents", "Downloads", "Desktop", "Movies", "Pictures", "Music",
                    "Public", "Applications", "Library/Application Support", "Library/Containers",
                    "Library/Group Containers", "Library/Preferences", "Library/Caches",
                    "Library/Mobile Documents", "Library/CloudStorage", ".Trash", "Library/Cookies"] {
            s.insert(home + "/" + sub)
        }
        structural = s
        sensitive = ["Library/Keychains", "Library/Mail", "Library/Messages", "Library/Accounts", ".ssh", ".gnupg"]
            .map { home + "/" + $0 }
        structuralKeys = Set(s.map { $0.lowercased() })
        sensitiveKeys = sensitive.map { $0.lowercased() }
    }

    /// `key`: the path with symlinks in its parent folders resolved (the item itself not followed) and
    /// lower-cased. nil when allowed. User protection is checked by the caller first.
    public func refusal(key p: String) -> String? {
        let home = self.home.lowercased()
        if structuralKeys.contains(p) { return "System or account folder" }
        // Single Messages attachments may go (Messages then shows them as unavailable); the folders stay.
        let attachments = home + "/library/messages/attachments"
        if PathRules.isInside(p, attachments) && p != attachments { return nil }
        if sensitiveKeys.contains(where: { PathRules.isInside(p, $0) }) { return "Holds passwords, mail or settings" }
        if PathRules.isInside(p, home) || PathRules.isInside(p, "/applications") { return nil }
        return "Outside your home folder (view only)"
    }
}
