import AppKit
import MacCleanerCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

// The Shredder screen. Items are listed, measured and checked off the main thread (ShredReview); the shred itself is the
// cleanup executor's overwrite-then-delete, acting only on the plan the person approved (see
// Packages/MacCleanerKit/Sources/MacCleanerPlatform/LocalFileSystem+Shred.swift for the algorithm and its limits).

@MainActor @Observable
final class ShredderModel {
    struct Item: Identifiable {
        let id: String; let url: URL
        /// nil while it is being measured. Until a review has looked at the item this is a preview only.
        var size: Int64?
        var blocked: String?
        /// True until a review measured the item itself; a preview never feeds the plan or the sheet.
        var isPreview = true
    }

    var items: [Item] = []
    var working = false
    /// A review is being prepared (the items are being listed off the main thread).
    var preparing = false
    var message: (text: String, isError: Bool)?
    var dropTargeted = false
    private var reviewToken: UUID?
    /// The last executor report (read by the self-test).
    private(set) var lastReport: CleanupReport?

    var busy: Bool { preparing || working }
    var ready: [Item] { items.filter { $0.blocked == nil } }
    var total: Int64 { ready.reduce(0) { $0 + ($1.size ?? 0) } }

    func add(_ urls: [URL]) {
        guard !busy else { return }
        var added: [Item] = []
        for raw in urls {
            let u = raw.standardizedFileURL   // the same item by another spelling (…/dir/, …/dir/sub/..) is one row
            guard !items.contains(where: { $0.id == u.path }) && !added.contains(where: { $0.id == u.path }) else { continue }
            added.append(Item(id: u.path, url: u))
        }
        items += added
        measure(added)
    }

    /// Fills in a preview size off the main thread. It never replaces what a review measured.
    private func measure(_ list: [Item]) {
        for i in list {
            let id = i.id, u = i.url
            Task {
                let size = await Task.detached(priority: .utility) { Scanner.allocatedSize(u) }.value
                if let at = items.firstIndex(where: { $0.id == id }), items[at].isPreview { items[at].size = size }
            }
        }
    }

    func choose() {
        guard !busy else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Add to Shredder"
        if p.runModal() == .OK { add(p.urls) }
    }

    /// Lists every item once off the main thread, applies the app's rules, then hands the review to `present`.
    func prepareReview(present: @escaping (ReviewRequest) -> Void) {
        guard !busy, !items.isEmpty else { return }
        let token = UUID()
        reviewToken = token
        preparing = true
        let list = items.map { (id: $0.id, url: $0.url) }
        Task {
            let rows = await Task.detached(priority: .userInitiated) { ShredReview.snapshots(list) }.value
            guard reviewToken == token else { return }   // another review took over: drop this result
            reviewToken = nil
            preparing = false
            for r in rows {
                guard let at = items.firstIndex(where: { $0.id == r.id }) else { continue }
                items[at].blocked = r.blockedReason
                if let bytes = r.allocatedBytes { items[at].size = bytes; items[at].isPreview = false }
            }
            present(ReviewBuild.shred(rows: rows) { [weak self] rows, approval in
                guard let self else { return }
                // Busy from the moment Confirm fires, so a second approval can't start while the first is still starting.
                guard !self.working else { self.message = ("Already shredding", true); return }
                self.working = true
                Task { await self.perform(rows: rows, approval: approval) }
            })
        }
    }

    /// Shreds exactly the plan that was approved (the rows the sheet showed), through the cleanup executor.
    func shred(rows: [ShredReviewRow], approval: TrashApproval?) async {
        guard !working else { message = ("Already shredding", true); return }
        working = true
        await perform(rows: rows, approval: approval)
    }

    /// The run itself. `working` is already set by the caller and is cleared here.
    private func perform(rows: [ShredReviewRow], approval: TrashApproval?) async {
        defer { working = false }
        let approved: ApprovedTrash
        switch approval {
        case .approved(let a)?: approved = a
        case .refused(_, let reason)?:
            message = ("Nothing was shredded: \(reason)", true)
            return
        case nil:
            let why = rows.compactMap { r in r.blockedReason.map { "\(r.url.lastPathComponent): \($0)" } }
            message = ("Nothing was shredded." + (why.isEmpty ? "" : " " + why.prefix(2).joined(separator: "; ")), true)
            return
        }
        // Only a plan of shred entries for module "shredder" runs here; anything else (a Trash plan) is refused untouched.
        guard approved.plan.entries.allSatisfy({ $0.disposition == .overwriteThenDelete && $0.candidate.module == "shredder" }) else {
            message = ("Nothing was shredded: this isn't a shred plan", true)
            return
        }
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        let before = Scanner.freeBytes()
        let report: CleanupReport
        do {
            report = try await AppCleanup.executor.execute(approved.plan, approval: approved.approval)
        } catch {
            message = ("Nothing was shredded: \(AppCleanup.text(error))", true)
            return
        }
        lastReport = report
        let plan = approved.plan
        // What is at each root now is looked at off the main thread; `finish` only applies the results.
        let states = await Task.detached { Self.rootStates(report: report, plan: plan) }.value
        finish(report: report, plan: plan, rootStates: states, freeBefore: before, freeAfter: Scanner.freeBytes())
    }

    /// What is at each planned root now, by candidate id. Reads the disk: not for the main thread.
    nonisolated static func rootStates(report: CleanupReport, plan: CleanupPlan) -> [String: ShredReview.RootState] {
        let planned = Dictionary(plan.candidates.compactMap { c in c.targets.first.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        var out: [String: ShredReview.RootState] = [:]
        for o in report.outcomes {
            if case .tree(_, let root, _) = planned[o.candidateID] ?? o.target { out[o.candidateID] = ShredReview.rootState(root) }
        }
        return out
    }

    /// Tells the list, History and the message what a finished run did (also fed synthetic reports by the self-test).
    func finish(report: CleanupReport, plan: CleanupPlan, rootStates: [String: ShredReview.RootState],
                freeBefore before: Int64, freeAfter after: Int64) {
        let planned = Dictionary(plan.candidates.compactMap { c in c.targets.first.map { (c.id, $0) } },
                                 uniquingKeysWith: { a, _ in a })
        var bytes: Int64 = 0, problems: [String] = [], partial = 0, removedAny = false
        var remeasure: [String] = []
        for o in report.outcomes {
            let target = planned[o.candidateID] ?? o.target
            let state = rootStates[o.candidateID] ?? .unknown
            let r = ShredReview.classify(outcome: o, planned: target, rootState: state)
            bytes += r.countedBytes
            removedAny = removedAny || r.removedAnything
            if r.isPartial { partial += 1 }
            if r.isProblem { problems.append(r.message) }
            problems += r.warnings
            switch r.disposition {
            case .remove: items.removeAll { $0.id == o.candidateID }
            case .keep:
                if let at = items.firstIndex(where: { $0.id == o.candidateID }) { items[at].size = nil; items[at].isPreview = true }
                remeasure.append(o.candidateID)
            case .block(let why):
                if let at = items.firstIndex(where: { $0.id == o.candidateID }) { items[at].blocked = why; items[at].size = nil; items[at].isPreview = true }
                remeasure.append(o.candidateID)
            }
        }
        measure(items.filter { remeasure.contains($0.id) })
        if removedAny {
            HistoryStore.shared.add("Files Shredded", bytes: bytes, symbol: "printer", outcome: .deleted,
                                    measuredFreeChange: max(0, after - before))
        }
        let done = !removedAny ? "Nothing was shredded."
            : partial == 0 ? "Overwrote and deleted about \(ByteText.string(bytes))."
            : "Overwrote and deleted about \(ByteText.string(bytes)); \(partial) item(s) only partly."
        message = problems.isEmpty ? (done, false)
                                   : (done + " \(problems.count) problem(s): \(problems.prefix(2).joined(separator: "; "))", true)
    }
}

struct ShredderView: View {
    @Environment(ShredderModel.self) private var m
    @Environment(ReviewCenter.self) private var review

    var body: some View {
        @Bindable var m = m
        VStack(spacing: 14) {
            if let msg = m.message { MessageBar(text: msg.text, isError: msg.isError) { m.message = nil } }
            VStack(spacing: 0) {
                if m.items.isEmpty {
                    VStack(spacing: 14) {
                        IconTile(symbol: "printer", color: Palette.accent, size: 70)
                        Text("Drop files or folders here").font(.system(size: 20, weight: .semibold))
                        Text("Shredded items skip the Trash and can't be put back.")
                            .font(.system(size: 13)).foregroundStyle(Palette.dim)
                        Button { m.choose() } label: { Label("Choose files…", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).disabled(m.busy)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(m.items) { i in
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: i.url.path)).resizable().frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(i.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(i.blocked ?? Scanner.tilde(i.url.deletingLastPathComponent()))
                                            .font(.system(size: 11))
                                            .foregroundStyle(i.blocked == nil ? Palette.faint : Palette.danger)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(i.size.map { i.isPreview ? "about \(ByteText.string($0)) (preview)" : ByteText.string($0) } ?? "Measuring…")
                                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                    Button { m.items.removeAll { $0.id == i.id } } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove from list")
                                        .buttonStyle(.plain).foregroundStyle(Palette.faint).disabled(m.busy)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .opacity(m.dropTargeted ? 1 : 0)
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard !m.busy else { return false }
                m.add(urls)
                return !urls.isEmpty
            } isTargeted: { m.dropTargeted = $0 }

            HStack {
                Text("On SSDs, macOS may keep old copies of blocks, so overwriting can't guarantee recovery is impossible. FileVault encryption is the real protection.")
                    .font(.caption).foregroundStyle(Palette.dim).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !m.items.isEmpty {
                    Button("Add more…") { m.choose() }.buttonStyle(.bordered).disabled(m.busy)
                }
                Button { m.prepareReview { review.present($0) } } label: {
                    Label(m.total == 0 ? "Shred" : "Shred about \(ByteText.string(m.total))", systemImage: "flame")
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.items.isEmpty || m.busy)
            }
        }
    }
}
