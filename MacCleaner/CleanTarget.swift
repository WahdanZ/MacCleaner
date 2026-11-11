import Foundation

/// What "cleaning" a target means.
enum CleanAction: Sendable {
    /// Delete the folder (or file) itself.
    case removeItem(URL)
    /// Delete each of these.
    case removeItems([URL])
    /// Empty the folder but keep it.
    case removeContents(URL)
    /// `xcrun simctl delete unavailable`
    case deleteUnavailableSimulators
    /// `xcrun simctl runtime delete <uuid>`
    case deleteSimRuntime(String)
    /// Placeholder: discover browser/Electron cache folders under this app folder while measuring.
    case webCachesIn(URL)
}

enum CacheCategory: String, CaseIterable, Sendable, Identifiable {
    case xcode = "Xcode"
    case android = "Android & Flutter"
    case packages = "Package managers"
    case editors = "IDEs & editors"
    case devCache = "~/.cache"
    case appCaches = "App caches"
    case webCaches = "Web & Electron caches"
    case logs = "Logs"
    case trash = "Trash"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .xcode: return "hammer.fill"
        case .android: return "iphone.gen3"
        case .packages: return "shippingbox.fill"
        case .editors: return "chevron.left.forwardslash.chevron.right"
        case .devCache: return "terminal.fill"
        case .appCaches: return "square.stack.3d.up.fill"
        case .webCaches: return "globe"
        case .logs: return "doc.plaintext.fill"
        case .trash: return "trash.fill"
        }
    }
}

struct CleanTarget: Identifiable, Sendable {
    let id: String
    let category: CacheCategory
    let name: String
    /// Display path, e.g. "~/.gradle/caches".
    let path: String
    /// One-line explanation of what it is / what happens after deleting.
    let note: String
    var action: CleanAction
    /// Safe to clear routinely (pure cache, re-downloads on its own).
    var recommended = true
    var sizeBytes: Int64 = 0
    var exists = false
    var selected = false

    var isCleanable: Bool { exists && sizeBytes > 0 }
}

extension CleanTarget {
    /// A real file URL to show in Finder, when there is one.
    var revealURL: URL? {
        switch action {
        case .removeItem(let u), .removeContents(let u), .webCachesIn(let u): return u
        case .removeItems(let us):
            guard let f = us.first else { return nil }
            return us.count == 1 ? f : f.deletingLastPathComponent()
        default: return nil
        }
    }

    /// Top-level folder this item lives in, e.g. "~/Library/Caches" or "~/.gradle".
    var folder: String {
        guard path.hasPrefix("~/") else { return "~/Library/Developer" }
        let comps = path.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true)
        guard let first = comps.first else { return "~" }
        if first == "Library", comps.count > 1 { return "~/Library/\(comps[1])" }
        return "~/\(first)"
    }
}

enum ByteText {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
