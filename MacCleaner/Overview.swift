import AppKit
import Charts
import Observation
import SwiftUI

// MARK: - Model

@MainActor @Observable
final class OverviewModel {
    struct Breakdown: Codable {
        var apps: Int64 = 0
        var documents: Int64 = 0
        var library: Int64 = 0
        var other: Int64 = 0
        var available: Int64 = 0
        var total: Int64 = 0
        var date = Date()
        var used: Int64 { total - available }
    }

    var breakdown: Breakdown?
    var measuring = false
    var oldDownloads: [BigFile] = []
    var downloadsScanned = false
    var downloadsSelected = false
    var confirming = false
    var cleaning = false
    var lastResult: String?

    private let key = "overviewBreakdown"
    /// Off only for `bench`, which measures without replacing the saved breakdown.
    var savesResult = true

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let b = try? JSONDecoder.iso.decode(Breakdown.self, from: d) {
            breakdown = b
        }
    }

    var oldDownloadsBytes: Int64 { oldDownloads.reduce(0) { $0 + $1.size } }

    /// Apps, personal folders and ~/Library sizes; the rest of "used" is macOS and other data.
    func measure() async {
        guard !measuring else { return }
        measuring = true
        // The free-space figure can take a moment while macOS works out purgeable space: ask off the main thread.
        let (total, free) = await Task.detached(priority: .utility) { (Scanner.totalBytes(), Scanner.freeBytes()) }.value
        async let apps = Task.detached(priority: .utility) { () -> Int64 in
            let urls = AppScanner.appURLs()
            var sizes = [Int64](repeating: 0, count: urls.count)
            sizes.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: urls.count) { i in buf[i] = Scanner.allocatedSize(urls[i]) }
            }
            return sizes.reduce(0, +)
        }.value
        async let docs = Task.detached(priority: .utility) { () -> Int64 in
            let names = ["Documents", "Downloads", "Desktop", "Movies", "Pictures", "Music"]
            var sizes = [Int64](repeating: 0, count: names.count)
            sizes.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: names.count) { i in
                    buf[i] = Scanner.allocatedSize(SafetyGuard.home.appendingPathComponent(names[i]))
                }
            }
            return sizes.reduce(0, +)
        }.value
        async let lib = Task.detached(priority: .utility) {
            Scanner.allocatedSize(SafetyGuard.home.appendingPathComponent("Library"))
        }.value
        var b = Breakdown()
        b.total = total
        b.available = free
        b.apps = await apps
        b.documents = await docs
        b.library = await lib
        b.other = max(0, (total - free) - b.apps - b.documents - b.library)
        breakdown = b
        if savesResult, let d = try? JSONEncoder.iso.encode(b) { UserDefaults.standard.set(d, forKey: key) }
        measuring = false
    }

    /// Top-level Downloads items untouched for 90+ days (never pre-selected).
    func scanDownloads() async {
        let dir = SafetyGuard.home.appendingPathComponent("Downloads")
        oldDownloads = await Task.detached(priority: .utility) { () -> [BigFile] in
            let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .contentAccessDateKey, .addedToDirectoryDateKey]
            let kids = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys),
                                                                      options: [.skipsHiddenFiles])) ?? []
            return kids.compactMap { u in
                guard !ProtectedPaths.isBlocked(u) else { return nil }
                let v = try? u.resourceValues(forKeys: keys)
                let last = [v?.contentModificationDate, v?.contentAccessDate, v?.addedToDirectoryDate].compactMap { $0 }.max()
                guard (last ?? .distantPast) < cutoff else { return nil }
                let size = Scanner.allocatedSize(u)
                guard size > 0 else { return nil }
                return BigFile(id: u.path, url: u, size: size, modified: v?.contentModificationDate, lastOpened: last)
            }
            .sorted { $0.size > $1.size }
        }.value
        downloadsScanned = true
    }

    /// Moves exactly the reviewed old downloads to the Trash.
    func trashDownloads(_ files: [BigFile]) async -> Int64 {
        var bytes: Int64 = 0
        var moved: Set<String> = []
        for f in files where TrashGuard.canTrash(f.url) {
            let u = f.url
            if await Task.detached(operation: { AppEngine.trash(u, size: f.size, source: "Old Downloads") }).value == nil {
                bytes += f.size
                moved.insert(f.id)
            }
        }
        HistoryStore.shared.add("Old Downloads Moved to Trash", bytes: bytes, symbol: "arrow.down.circle", outcome: .trashed)
        oldDownloads.removeAll { moved.contains($0.id) }
        downloadsSelected = false
        return bytes
    }
}

enum RecGroup: String, CaseIterable, Identifiable {
    case junk, downloads, appCaches, logs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .junk: return "Junk Files"
        case .downloads: return "Downloads"
        case .appCaches: return "App Caches"
        case .logs: return "System Logs"
        }
    }
    var subtitle: String {
        switch self {
        case .junk: return "Developer caches, build files and temporary files"
        case .downloads: return "Downloads untouched for 90+ days, protected items skipped"
        case .appCaches: return "Temporary data from your apps and browsers"
        case .logs: return "Diagnostic and app log files"
        }
    }
    var symbol: String {
        switch self {
        case .junk: return "trash"
        case .downloads: return "arrow.down"
        case .appCaches: return "square.stack.3d.up"
        case .logs: return "doc.text"
        }
    }
    var color: Color {
        switch self {
        case .junk: return Color(hex: 0xF05A5A)
        case .downloads: return Color(hex: 0x1A7CFF)
        case .appCaches: return Color(hex: 0x8B5CF6)
        case .logs: return Color(hex: 0xF59E0B)
        }
    }
    var categories: Set<CacheCategory> {
        switch self {
        case .junk: return [.xcode, .android, .packages, .editors, .devCache]
        case .downloads: return []
        case .appCaches: return [.appCaches, .webCaches]
        case .logs: return [.logs]
        }
    }
}

// MARK: - View

/// Dashboard: storage donut + scan hero on top; recommended cleanup beside quick tools, Trash and
/// recent cleanups below. Two columns when there's room, one column in narrow windows.
struct OverviewView: View {
    @Environment(OverviewModel.self) private var ov
    @State private var showHistory = false

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width >= 860
            ScrollView {
                VStack(spacing: Space.l) {
                    if wide {
                        HStack(alignment: .top, spacing: Space.l) {
                            StorageCard().frame(maxWidth: .infinity).appearIn(0)
                            ScanHero().frame(width: min(400, g.size.width * 0.38)).appearIn(1)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: Space.l) {
                            VStack(spacing: Space.l) {
                                RecommendedCard().appearIn(2)
                                InsightsCard().appearIn(3)
                            }
                            .frame(maxWidth: .infinity)
                            VStack(spacing: Space.l) {
                                QuickTools().appearIn(3)
                                TrashCard().appearIn(4)
                                RecentCleanups(showAll: $showHistory).appearIn(5)
                            }
                            .frame(width: min(400, g.size.width * 0.38))
                        }
                    } else {
                        StorageCard().appearIn(0)
                        ScanHero().appearIn(1)
                        RecommendedCard().appearIn(2)
                        InsightsCard().appearIn(3)
                        QuickTools().appearIn(3)
                        TrashCard().appearIn(4)
                        RecentCleanups(showAll: $showHistory).appearIn(5)
                    }
                }
                .padding(.bottom, Space.l)
            }
            .scrollIndicators(.automatic)
        }
        .task {
            if ov.breakdown == nil || Date().timeIntervalSince(ov.breakdown!.date) > 3600 { await ov.measure() }
        }
        .sheet(isPresented: $showHistory) { HistorySheet() }
    }
}

/// Card title row used across the dashboard.
private struct CardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            trailing()
        }
    }
}

// MARK: Storage donut

private struct StorageCard: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(OverviewModel.self) private var ov
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 0 → 1 when the card appears: the ring sweeps around once.
    @State private var sweep: Double = 0

    struct Slice: Identifiable { let id: String; let color: Color; let bytes: Int64 }

    /// Slices scaled by the sweep, plus an invisible remainder so the drawn part grows clockwise.
    private var drawn: [(Slice, Double)] {
        let all = slices.map { ($0, Double(max($0.bytes, 0))) }
        let total = max(all.reduce(0) { $0 + $1.1 }, 1)
        return all.map { ($0.0, $0.1 * sweep) } + [(Slice(id: "_rest", color: .clear, bytes: 0), total * (1 - sweep))]
    }

    private var slices: [Slice] {
        if let b = ov.breakdown {
            return [Slice(id: "Apps", color: Palette.apps, bytes: b.apps),
                    Slice(id: "Documents & Media", color: Palette.documents, bytes: b.documents),
                    Slice(id: "Library", color: Palette.library, bytes: b.library),
                    Slice(id: "macOS & Other", color: Palette.other, bytes: b.other),
                    Slice(id: "Available", color: Palette.available, bytes: b.available)]
        }
        return [Slice(id: "Used", color: Palette.apps, bytes: max(0, cleaner.totalBytes - cleaner.freeBytes)),
                Slice(id: "Available", color: Palette.available, bytes: cleaner.freeBytes)]
    }

    var body: some View {
        let used = max(0, cleaner.totalBytes - cleaner.freeBytes)
        HStack(alignment: .center, spacing: Space.xxl) {
            Chart(drawn, id: \.0.id) { s, value in
                SectorMark(angle: .value("Size", value),
                           innerRadius: .ratio(0.66), angularInset: s.id == "_rest" ? 0 : 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(s.color)
            }
            .chartLegend(.hidden)
            .overlay {
                VStack(spacing: Space.xxs) {
                    Text(ByteText.string(cleaner.totalBytes)).font(.title2.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Total Storage").font(.caption).foregroundStyle(Palette.dim)
                }
            }
            .frame(width: 190, height: 190)
            .onAppear {
                if reduce { sweep = 1 } else { withAnimation(.easeOut(duration: 0.9).delay(0.1)) { sweep = 1 } }
            }
            .animation(Motion.standard(reduce), value: ov.breakdown?.used)
            .accessibilityElement()
            .accessibilityLabel("Storage")
            .accessibilityValue(slices.map { "\($0.id) \(ByteText.string($0.bytes))" }.joined(separator: ", "))

            VStack(alignment: .leading, spacing: Space.s) {
                CardHeader(title: "Storage") {
                    if ov.measuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { cleaner.refreshDisk(); await ov.measure() } } label: {
                            Label("Measure Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless).labelStyle(.iconOnly).help("Measure storage again")
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(ByteText.string(used)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(used)))
                        .animation(Motion.standard(reduce), value: used)
                    Text("used").font(.title3).foregroundStyle(Palette.dim)
                }
                .padding(.bottom, Space.xs)
                ForEach(slices) { s in
                    HStack(spacing: Space.s) {
                        Circle().fill(s.color).frame(width: 9, height: 9)
                        Text(s.id).font(.callout)
                        Spacer(minLength: Space.m)
                        Text(ByteText.string(s.bytes)).font(.callout).foregroundStyle(Palette.dim).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                if ov.breakdown == nil {
                    Text(ov.measuring ? "Measuring folders…" : "Measuring apps, documents and Library takes a moment.")
                        .font(.caption).foregroundStyle(Palette.faint)
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .panel()
    }
}

// MARK: Scan hero

private struct ScanHero: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(OverviewModel.self) private var ov
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            RoundedRectangle(cornerRadius: 52 * 0.24, style: .continuous)
                .fill(Palette.accent.opacity(0.14))
                .overlay(
                    Image(systemName: cleaner.phase == .scanning ? "magnifyingglass" : "wand.and.sparkles")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, options: .repeating, isActive: cleaner.phase == .scanning && !reduce)
                )
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
            Text(cleaner.hasScanned && cleaner.phase != .scanning
                 ? "\(ByteText.string(cleaner.recommendedBytes)) can be cleaned"
                 : "Find and remove unnecessary files")
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
                .animation(Motion.standard(reduce), value: cleaner.recommendedBytes)
            Text(cleaner.hasScanned
                 ? "Review the recommendations, then clean. Nothing is removed until you confirm."
                 : "Scan for caches, logs, leftovers and old downloads you can safely remove.")
                .font(.callout).foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            if cleaner.phase == .scanning {
                VStack(alignment: .leading, spacing: Space.s) {
                    ProgressView(value: Double(cleaner.progressDone), total: Double(max(cleaner.progressTotal, 1)))
                    Text("\(cleaner.progressDone) of \(cleaner.progressTotal) locations · \(ByteText.string(cleaner.runningBytes)) found")
                        .font(.caption).foregroundStyle(Palette.dim).monospacedDigit()
                }
            } else {
                Button { scan() } label: {
                    Label(cleaner.hasScanned ? "Scan Again" : "Scan for Junk", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .disabled(cleaner.isBusy || ov.cleaning)
                .keyboardShortcut("r", modifiers: .command)
                Text("Scanning only reads your disk.").font(.caption).foregroundStyle(Palette.faint)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel()
    }

    private func scan() {
        Task {
            async let a: Void = cleaner.scan()
            async let b: Void = ov.scanDownloads()
            _ = await (a, b)
        }
    }
}

// MARK: Recommended

private struct RecommendedCard: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(OverviewModel.self) private var ov
    @Environment(ReviewCenter.self) private var review

    var body: some View {
        let total = RecGroup.allCases.reduce(Int64(0)) { $0 + bytes($1) }
        VStack(alignment: .leading, spacing: Space.m) {
            CardHeader(title: "Recommended Cleanup") {
                if cleaner.hasScanned {
                    Text("\(ByteText.string(total)) found")
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(total)))
                        .animation(.snappy, value: total)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                        .background(Palette.tile, in: Capsule())
                }
            }
            VStack(spacing: 0) {
                ForEach(RecGroup.allCases) { g in
                    if g != RecGroup.allCases.first { Divider().padding(.leading, 52) }
                    row(g)
                }
            }

            Spacer(minLength: 0)

            if let r = cleaner.result, cleaner.phase == .done {
                Label("Last cleanup deleted \(r.count) item(s). Free space went up by \(ByteText.string(r.freed)).",
                      systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(Palette.success)
            }
            Label("Documents, Desktop, media, iCloud Drive and protected folders are never included.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(Palette.dim)

            VStack(spacing: Space.xs) {
                Button { presentReview() } label: {
                    Text(buttonTitle).frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: selectedTotal)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .disabled(selectedTotal == 0 || cleaner.isBusy || ov.cleaning)
                .keyboardShortcut(.return, modifiers: .command)
                if selectedTotal > 0 {
                    Text(selectionText).font(.caption).foregroundStyle(Palette.dim).monospacedDigit()
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, minHeight: 380, alignment: .topLeading)
        .panel()
    }

    private func row(_ g: RecGroup) -> some View {
        let enabled = scanned(g) && bytes(g) > 0 && !cleaner.isBusy
        return HStack(spacing: Space.m) {
            IconTile(symbol: g.symbol, color: g.color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.title).font(.body.weight(.semibold))
                Text(g.subtitle).font(.callout).foregroundStyle(Palette.dim).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            VStack(alignment: .trailing, spacing: 1) {
                Text(scanned(g) ? ByteText.string(bytes(g)) : "—").font(.body).monospacedDigit()
                Text(g == .downloads ? "to Trash" : "deleted").font(.caption2).foregroundStyle(Palette.faint)
            }
            Toggle(isOn: Binding(get: { isOn(g) }, set: { _ in toggle(g) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!enabled)
                .accessibilityLabel(g.title)
        }
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { toggle(g) } }
    }

    private var buttonTitle: String {
        if ov.cleaning || cleaner.phase == .cleaning { return "Cleaning…" }
        if !cleaner.hasScanned { return "Scan First to Clean" }
        return selectedTotal > 0 ? "Review & Clean \(ByteText.string(selectedTotal))…" : "Select Items to Clean"
    }

    private var selectedTotal: Int64 { cleaner.chosenBytes + (ov.downloadsSelected ? ov.oldDownloadsBytes : 0) }
    private var selectionText: String {
        var parts: [String] = []
        if cleaner.chosenBytes > 0 { parts.append("\(ByteText.string(cleaner.chosenBytes)) deleted") }
        if ov.downloadsSelected && ov.oldDownloadsBytes > 0 { parts.append("\(ByteText.string(ov.oldDownloadsBytes)) to Trash") }
        return parts.joined(separator: " · ") + " · you'll see every item first"
    }

    private func presentReview() {
        let downloads = ov.downloadsSelected ? ov.oldDownloads : []
        review.present(ReviewBuild.overview(cleaner, downloads: downloads) { targets, files in
            Task {
                ov.cleaning = true
                if !targets.isEmpty { await cleaner.clean(targets) }
                if !files.isEmpty { _ = await ov.trashDownloads(files) }
                ov.cleaning = false
                await ov.measure()
            }
        })
    }

    private func items(_ g: RecGroup) -> [CleanTarget] {
        cleaner.targets.filter { g.categories.contains($0.category) && $0.recommended }
    }
    private func scanned(_ g: RecGroup) -> Bool { g == .downloads ? ov.downloadsScanned : cleaner.hasScanned }
    private func bytes(_ g: RecGroup) -> Int64 {
        g == .downloads ? ov.oldDownloadsBytes : items(g).reduce(0) { $0 + $1.sizeBytes }
    }
    private func isOn(_ g: RecGroup) -> Bool {
        if g == .downloads { return ov.downloadsSelected }
        let i = items(g)
        return !i.isEmpty && i.allSatisfy(\.selected)
    }
    private func toggle(_ g: RecGroup) {
        if g == .downloads { ov.downloadsSelected.toggle(); return }
        cleaner.toggleAll(ids: Set(items(g).map(\.id)))
    }
}

// MARK: Quick tools

private struct QuickTools: View {
    @AppStorage("sidebarPage") private var page: SidebarPage = .overview

    private let tools: [(String, String, Color, SidebarPage)] = [
        ("Developer", "hammer", Color(nsColor: .systemPurple), .developer),
        ("Large & Old", "doc.text.magnifyingglass", Color(nsColor: .systemTeal), .large),
        ("Duplicates", "plus.square.on.square", Color(nsColor: .systemBlue), .duplicates),
        ("Apps", "square.grid.2x2", Color(nsColor: .systemGreen), .apps),
        ("Storage Map", "chart.bar.xaxis", Color(nsColor: .systemYellow), .storage),
        ("System Data", "internaldrive", Color(nsColor: .systemPink), .systemData),
        ("Startup", "power", Color(nsColor: .systemOrange), .startup),
        ("Shredder", "flame", Color(nsColor: .systemRed), .shredder),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            CardHeader(title: "Quick Tools") { EmptyView() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s), count: 4), spacing: Space.s) {
                ForEach(tools, id: \.0) { t in
                    QuickTile(title: t.0, symbol: t.1, color: t.2) { page = t.3 }
                }
            }
        }
        .padding(Radius.cardPadding)
        .panel()
    }
}

private struct QuickTile: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void
    @State private var hover = false
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs + 2) {
                Image(systemName: symbol).font(.title2).foregroundStyle(color).frame(height: 26)
                    .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(Palette.fg).lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(hover ? color.opacity(0.14) : Palette.tile,
                        in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hover = h }
            if h && !reduce { bounce += 1 }
        }
        .help("Open \(title)")
        .accessibilityLabel("Open \(title)")
    }
}

// MARK: Recent activity

private struct RecentCleanups: View {
    @Binding var showAll: Bool
    private var history: HistoryStore { HistoryStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Recent Cleanups").font(.title3.weight(.semibold))
                Spacer()
                Button("Show All") { showAll = true }
                    .buttonStyle(.link)
                    .disabled(history.records.isEmpty)
            }
            if history.records.isEmpty {
                Text("Cleanups you run show up here, with what was deleted and what went to the Trash.")
                    .font(.callout).foregroundStyle(Palette.dim)
                    .padding(.vertical, Space.s)
            } else {
                ForEach(history.records.prefix(3)) { r in
                    Divider()
                    HistoryRow(record: r)
                }
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct HistoryRow: View {
    let record: CleanupRecord

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: record.outcome == .trashed ? "trash" : "checkmark.circle")
                .foregroundStyle(record.outcome == .trashed ? Palette.dim : Palette.success)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title).font(.rowTitle)
                Text(record.date.formatted(Calendar.current.isDateInToday(record.date)
                                           ? .dateTime.hour().minute()
                                           : .dateTime.month(.abbreviated).day().year()))
                    .font(.caption).foregroundStyle(Palette.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(record.resultText).font(.callout).monospacedDigit()
                if record.outcome == .trashed {
                    Text("not freed until the Trash is emptied").font(.caption).foregroundStyle(Palette.faint)
                } else if let m = record.measuredFreeChange {
                    Text("free space +\(ByteText.string(m))").font(.caption).foregroundStyle(Palette.faint)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }
}

struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    private var history: HistoryStore { HistoryStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("Cleanup History").font(.title2.bold())
                    Text("\(ByteText.string(history.totalDeleted)) deleted · \(ByteText.string(history.totalTrashed)) moved to Trash"
                         + (history.totalUnclassified > 0 ? " · \(ByteText.string(history.totalUnclassified)) earlier (not classified)" : "")
                         + " · \(history.records.count) cleanups")
                        .font(.callout).foregroundStyle(Palette.dim)
                }
                Spacer()
                Button("Clear History", role: .destructive) { history.clear() }.disabled(history.records.isEmpty)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            List(history.records) { r in HistoryRow(record: r) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(Space.xl)
        .frame(width: 600, height: 540)
    }
}
