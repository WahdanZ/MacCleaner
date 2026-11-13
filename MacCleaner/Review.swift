import AppKit
import MacCleanerCore
import Observation
import SwiftUI

// One review screen for every multi-item cleanup. It lists every item (never truncated) with its path,
// size, what will happen to it and whether a safety guard blocks it. The engines re-check every guard
// again right before they act, so this list informs the decision; it is not the only check.

struct ReviewItem: Identifiable, Hashable {
    enum Action: String {
        case trash = "Move to Trash"
        case delete = "Delete permanently"
        case command = "Remove with tool"       // simctl, docker, tmutil
        case adminTrash = "Move to Trash (password)"

        var symbol: String {
            switch self {
            case .trash, .adminTrash: return "trash"
            case .delete: return "xmark.bin"
            case .command: return "terminal"
            }
        }
        var permanent: Bool { self == .delete || self == .command }
    }

    enum Risk: Int, Comparable {
        case safe, review, inUse
        static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
        var label: String { self == .safe ? "Safe" : self == .review ? "Review" : "In use" }
    }

    let id: String
    let name: String
    /// Full path (or a description for items without one, e.g. a simulator runtime).
    let location: String
    let size: Int64?
    let action: Action
    var risk: Risk = .safe
    /// Why it's risky or what comes back how ("comes back with npm install").
    var note: String? = nil
    /// Set when a safety guard refuses the item. It is shown and skipped.
    var blocked: String? = nil
    /// What the item was when the sheet opened (approved-Trash flows only). The approval covers exactly this.
    var snapshot: FileIdentity? = nil
}

struct ReviewRequest: Identifiable {
    let id = UUID()
    let title: String
    let explanation: String
    let items: [ReviewItem]
    /// Verb for the button, e.g. "Clean", "Uninstall", "Shred".
    let verb: String
    /// Runs the cleanup with the ids of the rows that were shown and not blocked. Builders map these back to the
    /// exact objects they listed (captured when the review opened), so what runs is what was reviewed, even if a
    /// rescan changes the screen's live selection while the sheet is open.
    let perform: (Set<String>) -> Void
    /// Approved-Trash flows (M01-04b): the Trash plan built when the sheet opened from the snapshots it shows.
    var trashPlan: CleanupPlan? = nil
    /// Approved-Trash flows: runs instead of `perform` with the shown, allowed ids and the approval for `trashPlan`
    /// (nil when there is nothing to move to the Trash).
    var performApproved: ((Set<String>, TrashApproval?) -> Void)? = nil

    var allowed: [ReviewItem] { items.filter { $0.blocked == nil } }
    var total: Int64 { allowed.reduce(0) { $0 + ($1.size ?? 0) } }
    var trashBytes: Int64 { allowed.filter { !$0.action.permanent }.reduce(0) { $0 + ($1.size ?? 0) } }
    var permanentBytes: Int64 { allowed.filter(\.action.permanent).reduce(0) { $0 + ($1.size ?? 0) } }
    /// Permanent removal of something marked REVIEW or IN USE needs an extra checkbox.
    var needsAcknowledgement: Bool { allowed.contains { $0.action.permanent && $0.risk > .safe } }
}

/// Shared presenter: a screen calls `review.present(...)`; the sheet lives once at the window root.
@MainActor @Observable
final class ReviewCenter {
    var request: ReviewRequest?
    func present(_ r: ReviewRequest) { request = r }
}

struct CleanupReviewSheet: View {
    let request: ReviewRequest
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var sortOrder = [KeyPathComparator(\ReviewRow.sortSize, order: .reverse)]
    @State private var selection: Set<ReviewItem.ID> = []
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", trash = "To Trash", delete = "Deleted", attention = "Needs Attention"
        var id: String { rawValue }
    }

    private var rows: [ReviewRow] {
        request.items.filter { i in
            switch filter {
            case .all: return true
            case .trash: return !i.action.permanent
            case .delete: return i.action.permanent
            case .attention: return i.blocked != nil || i.risk > .safe
            }
        }
        .map(ReviewRow.init).sorted(using: sortOrder)
    }

    private var focused: ReviewItem? {
        guard let id = selection.first else { return nil }
        return request.items.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                table
                Divider()
                ReviewInspector(item: focused, request: request)
                    .frame(width: 280)
            }
            footer
        }
        .frame(width: 1040, height: 640)
        .onAppear { if let first = rows.first { selection = [first.id] } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                IconTile(symbol: request.permanentBytes > 0 ? "xmark.bin" : "trash",
                         color: request.permanentBytes > 0 ? Palette.danger : Palette.accent, size: 44)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(request.title).font(.title2.weight(.semibold))
                    Text(request.explanation).font(.callout).foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Space.s) {
                stat(value: ByteText.string(request.total), label: "\(request.allowed.count) item\(request.allowed.count == 1 ? "" : "s")",
                     symbol: "square.stack", tint: Palette.accent)
                if request.trashBytes > 0 {
                    stat(value: ByteText.string(request.trashBytes), label: "To Trash · recoverable", symbol: "trash", tint: Color(nsColor: .systemGray))
                }
                if request.permanentBytes > 0 {
                    stat(value: ByteText.string(request.permanentBytes), label: "Deleted permanently", symbol: "xmark.bin", tint: Palette.danger)
                }
                let blocked = request.items.count - request.allowed.count
                if blocked > 0 {
                    stat(value: "\(blocked)", label: "Blocked · skipped", symbol: "lock.fill", tint: Color(nsColor: .systemGray))
                }
                Spacer(minLength: Space.s)
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(Space.xl)
    }

    private func stat(value: String, label: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.headline).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(Palette.dim)
            }
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(Palette.tile, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: List

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Item", value: \.item.name) { r in
                HStack(spacing: Space.s) {
                    ItemIcon(item: r.item, size: 18)
                    Text(r.item.name).lineLimit(1).truncationMode(.middle)
                }
                .opacity(r.item.blocked != nil ? 0.5 : 1)
            }
            .width(min: 150, ideal: 200)
            TableColumn("Location", value: \.item.location) { r in
                Text(Scanner.tildeString(r.item.location)).foregroundStyle(Palette.dim)
                    .lineLimit(1).truncationMode(.middle)
                    .help(r.item.location)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Size", value: \.sortSize) { r in
                Text(r.item.size.map(ByteText.string) ?? "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 76, max: 100)
            TableColumn("Action", value: \.actionName) { r in
                Label(r.item.action.permanent ? "Delete" : "Trash",
                      systemImage: r.item.action.permanent ? "xmark.bin" : "trash")
                    .foregroundStyle(r.item.action.permanent ? Palette.danger : Palette.dim)
                    .help(r.item.action.rawValue)
            }
            .width(min: 64, ideal: 76, max: 90)
            TableColumn("Safety", value: \.statusRank) { r in SafetyBadge(item: r.item) }
                .width(min: 84, ideal: 100, max: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ReviewItem.ID.self) { ids in
            Button("Reveal in Finder") { reveal(ids) }
            Button("Copy Paths") {
                copy(request.items.filter { ids.contains($0.id) }.map(\.location).joined(separator: "\n"))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if request.needsAcknowledgement {
                Toggle(isOn: $acknowledged) {
                    Text("I understand that items marked Review or In Use will be deleted permanently and may need to be downloaded or rebuilt.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
            HStack(spacing: Space.s) {
                Button { copy(listText) } label: { Label("Copy List", systemImage: "doc.on.doc") }
                Text("Guards are checked again for every item when it is removed.")
                    .font(.caption).foregroundStyle(Palette.dim)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(role: .destructive) {
                    dismiss()
                    ReviewConfirmation.confirm(request)
                } label: {
                    Text(confirmTitle).padding(.horizontal, Space.s)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(request.permanentBytes > 0 ? Palette.danger : Palette.accent)
                .disabled(request.allowed.isEmpty || (request.needsAcknowledgement && !acknowledged))
            }
        }
        .padding(.horizontal, Space.xl).padding(.vertical, Space.l)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var confirmTitle: String {
        let n = request.allowed.count
        if request.permanentBytes > 0 && request.trashBytes > 0 { return "\(request.verb) \(n) Item\(n == 1 ? "" : "s")" }
        if request.permanentBytes > 0 { return "Delete \(ByteText.string(request.total)) Permanently" }
        return "Move \(ByteText.string(request.total)) to Trash"
    }

    private var listText: String {
        request.items.map {
            "\($0.blocked != nil ? "[blocked] " : "")\($0.action.rawValue)\t\($0.size.map(ByteText.string) ?? "—")\t\($0.location)"
        }.joined(separator: "\n")
    }

    private func reveal(_ ids: Set<ReviewItem.ID>) {
        let urls = request.items.filter { ids.contains($0.id) }.map(\.location)
            .filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Safety classification as a small tinted capsule: Safe, Review, In Use or Blocked.
struct SafetyBadge: View {
    let item: ReviewItem

    var body: some View {
        let (text, symbol, tint): (String, String, Color) = {
            if item.blocked != nil { return ("Blocked", "lock.fill", Color(nsColor: .systemGray)) }
            switch item.risk {
            case .safe: return ("Safe", "checkmark.shield.fill", Palette.success)
            case .review: return ("Review", "exclamationmark.triangle.fill", Palette.warn)
            case .inUse: return ("In Use", "exclamationmark.octagon.fill", Palette.danger)
            }
        }()
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Space.s).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .help(item.blocked ?? item.note ?? text)
            .accessibilityLabel("Safety: \(text)")
    }
}

/// File icon when the item exists on disk, otherwise the action symbol.
private struct ItemIcon: View {
    let item: ReviewItem
    let size: CGFloat

    var body: some View {
        if item.location.hasPrefix("/"), FileManager.default.fileExists(atPath: item.location) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.location)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: item.blocked != nil ? "lock.fill" : item.action.symbol)
                .foregroundStyle(Palette.dim).frame(width: size, height: size)
        }
    }
}

/// Right-hand panel: everything about the selected item, or a summary when nothing is selected.
private struct ReviewInspector: View {
    let item: ReviewItem?
    let request: ReviewRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                if let i = item {
                    ItemIcon(item: i, size: 48)
                    Text(i.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    SafetyBadge(item: i)
                    Divider()
                    field("Size", i.size.map(ByteText.string) ?? "Not measured")
                    field("What happens", i.action.permanent
                          ? (i.action == .command ? "Removed with the system tool. Can't be undone." : "Deleted permanently. Can't be undone.")
                          : (i.action == .adminTrash ? "Moved to the Trash after you enter your password. You can put it back." : "Moved to the Trash. You can put it back."))
                    field("Location", i.location, selectable: true)
                    if let n = i.note { field("Note", n) }
                    if let b = i.blocked { field("Blocked", b + ". It will be skipped.") }
                    if i.location.hasPrefix("/"), FileManager.default.fileExists(atPath: i.location) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.location)]) } label: {
                            Label("Reveal in Finder", systemImage: "magnifyingglass")
                        }
                    }
                } else {
                    Image(systemName: "sidebar.trailing").font(.largeTitle).foregroundStyle(Palette.faint)
                    Text("Select an item to see its full path, what will happen to it and why.")
                        .font(.callout).foregroundStyle(Palette.dim)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.tile.opacity(0.5))
    }

    private func field(_ title: String, _ value: String, selectable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Palette.dim)
            if selectable {
                Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Table row wrapper with sortable keys.
struct ReviewRow: Identifiable {
    let item: ReviewItem
    var id: String { item.id }
    var sortSize: Int64 { item.size ?? -1 }
    var actionName: String { item.action.rawValue }
    var statusRank: Int { item.blocked != nil ? 9 : item.risk.rawValue }
}

extension Scanner {
    /// "/Users/x/Library" → "~/Library"; anything else unchanged.
    static func tildeString(_ path: String) -> String {
        let home = SafetyGuard.home.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
