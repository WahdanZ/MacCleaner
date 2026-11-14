import Foundation
import MacCleanerCore

/// The app's protection rules for the executor, read as they are when asked.
struct AppProtection: ProtectionChecking {
    func refusal(path: String, disposition: Disposition) -> String? {
        let url = URL(fileURLWithPath: path)
        switch disposition {
        case .trash:
            return TrashGuard.reason(url)
        case .permanentDelete:
            if let why = ProtectedPaths.reason(url) { return why }
            return SafetyGuard.isAllowed(url, allowContainer: true) ? nil : "Outside the folders Mac Cleaner may delete"
        case .overwriteThenDelete:
            return Self.shredReason(url)
        case .quarantine, .command:
            return "Not handled by the cleanup executor yet"
        }
    }

    /// The Shredder's rule, in one place: the Trash rules, and inside the home folder only (the Trash rules alone
    /// would allow /Applications).
    static func shredReason(_ url: URL) -> String? {
        if let why = TrashGuard.reason(url) { return why }
        if !isInsideHome(exactKey(url), home: SafetyGuard.home.path) {
            return "Only items in your home folder can be shredded"
        }
        return nil
    }

    /// "Inside the home folder" is an allow condition, so it compares letter case exactly (SAFETY_MODEL §2a: allow
    /// rules are exact, deny rules are case-folded). On a case-sensitive volume `/Users/Me` and `/Users/me` are
    /// different folders; a case-folded comparison would let the second pass as home. On the usual
    /// case-insensitive disk a differently spelled path is refused, never allowed.
    static func isInsideHome(_ key: String, home: String) -> Bool { PathRules.isInside(key, home) }

    /// Like `TrashGuard.key` (parent folders' links resolved, the item itself not followed), without lower-casing.
    static func exactKey(_ url: URL) -> String {
        let std = url.standardizedFileURL
        guard std.path != "/" else { return "/" }
        let parent = std.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(std.lastPathComponent).standardizedFileURL.path
    }
}
