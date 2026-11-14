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
        if !SafetyGuard.isInside(TrashGuard.key(url), SafetyGuard.home.path.lowercased()) {
            return "Only items in your home folder can be shredded"
        }
        return nil
    }
}
