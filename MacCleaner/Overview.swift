import AppKit
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
        let total = Scanner.totalBytes(), free = Scanner.freeBytes()
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
        if let d = try? JSONEncoder.iso.encode(b) { UserDefaults.standard.set(d, forKey: key) }
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

    func trashDownloads() async -> Int64 {
        var bytes: Int64 = 0
        for f in oldDownloads where TrashGuard.canTrash(f.url) {
            let u = f.url
            if await Task.detached(operation: { AppEngine.trash(u, size: f.size, source: "Old Downloads") }).value == nil { bytes += f.size }
        }
        HistoryStore.shared.add("Old Downloads Removed", bytes: bytes, symbol: "arrow.down.circle")
        oldDownloads = []
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

struct OverviewView: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(OverviewModel.self) private var ov
    @Binding var page: SidebarPage
    @State private var showHistory = false

    var body: some View {
        @Bindable var ov = ov
        ScrollView {
            VStack(spacing: 18) {
                StorageCard()
                HStack(alignment: .top, spacing: 18) {
                    RecommendedCard()
                    VStack(spacing: 18) {
                        QuickTools(page: $page)
                        TrashCard()
                        RecentCleanups(showAll: $showHistory)
                    }
                    .frame(width: 520)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .task {
            if ov.breakdown == nil || Date().timeIntervalSince(ov.breakdown!.date) > 3600 { await ov.measure() }
        }
        .sheet(isPresented: $showHistory) { HistorySheet() }
        .alert("Clean \(ByteText.string(cleaner.chosenBytes + (ov.downloadsSelected ? ov.oldDownloadsBytes : 0)))?",
               isPresented: $ov.confirming) {
            Button("Clean", role: .destructive) {
                Task {
                    ov.cleaning = true
                    if !cleaner.chosen.isEmpty { await cleaner.clean() }
                    if ov.downloadsSelected { _ = await ov.trashDownloads() }
                    ov.cleaning = false
                    await ov.measure()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanSummary)
        }
    }

    private var cleanSummary: String {
        var lines: [String] = []
        for g in RecGroup.allCases where g != .downloads {
            let sel = cleaner.targets.filter { g.categories.contains($0.category) && $0.selected }
            if !sel.isEmpty { lines.append("• \(g.title): \(sel.count) item(s), \(ByteText.string(sel.reduce(0) { $0 + $1.sizeBytes }))") }
        }
        let other = cleaner.chosen.filter { c in !RecGroup.allCases.contains { $0.categories.contains(c.category) } }
        if !other.isEmpty { lines.append("• Other selected: \(other.count) item(s)") }
        if ov.downloadsSelected {
            lines.append("• Old downloads → Trash: \(ov.oldDownloads.count) item(s), \(ByteText.string(ov.oldDownloadsBytes))")
            lines += ov.oldDownloads.prefix(6).map { "    \($0.url.lastPathComponent) — \(ByteText.string($0.size))" }
        }
        return lines.joined(separator: "\n")
            + "\n\nCaches and logs are deleted permanently (they rebuild). Downloads go to the Trash."
    }
}

// MARK: Storage

private struct StorageCard: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(OverviewModel.self) private var ov

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 36) {
                Donut()
                    .frame(width: 210, height: 210)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Storage Usage").font(.system(size: 15)).foregroundStyle(Palette.dim)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ByteText.string(usedBytes)).font(.system(size: 26, weight: .bold))
                        Text("Used").font(.system(size: 17)).foregroundStyle(Palette.dim)
                    }
                    .padding(.bottom, 4)
                    ForEach(rows, id: \.0) { r in
                        HStack {
                            Circle().fill(r.1).frame(width: 11, height: 11)
                            Text(r.0).font(.system(size: 15))
                            Spacer(minLength: 24)
                            Text(r.2).font(.system(size: 15)).foregroundStyle(Palette.dim).monospacedDigit()
                        }
                        .frame(width: 250)
                    }
                    if ov.measuring {
                        Label("Measuring…", systemImage: "hourglass").font(.system(size: 11)).foregroundStyle(Palette.faint)
                    }
                }
            }
            .padding(28)

            Rectangle().fill(Palette.stroke).frame(width: 1).padding(.vertical, 28)

            ScanHero()
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .panel(radius: 24)
    }

    private var usedBytes: Int64 { ov.breakdown?.used ?? (Scanner.totalBytes() - Scanner.freeBytes()) }

    private var rows: [(String, Color, String)] {
        guard let b = ov.breakdown else {
            return [("Used", Palette.apps, ByteText.string(usedBytes)),
                    ("Available", Palette.available, ByteText.string(Scanner.freeBytes()))]
        }
        return [("Apps", Palette.apps, ByteText.string(b.apps)),
                ("Documents", Palette.documents, ByteText.string(b.documents)),
                ("Library", Palette.library, ByteText.string(b.library)),
                ("System & Other", Palette.other, ByteText.string(b.other)),
                ("Available", Palette.available, ByteText.string(b.available))]
    }
}

private struct Donut: View {
    @Environment(OverviewModel.self) private var ov
    @State private var grow: Double = 0

    var body: some View {
        let b = ov.breakdown
        let total = Double(max(b?.total ?? Scanner.totalBytes(), 1))
        let parts: [(Double, Color)] = b.map {
            [(Double($0.apps), Palette.apps), (Double($0.documents), Palette.documents), (Double($0.library), Palette.library),
             (Double($0.other), Palette.other), (Double($0.available), Palette.available)]
        } ?? [(Double(Scanner.totalBytes() - Scanner.freeBytes()), Palette.apps), (Double(Scanner.freeBytes()), Palette.available)]
        let fractions = parts.map { $0.0 / total }
        let starts = fractions.indices.map { i in fractions.prefix(i).reduce(0, +) }
        ZStack {
            ForEach(parts.indices, id: \.self) { i in
                let gap = fractions[i] > 0.02 ? 0.004 : 0
                Circle()
                    .trim(from: (starts[i] + gap) * grow, to: max(starts[i] + gap, starts[i] + fractions[i] - gap) * grow)
                    .stroke(parts[i].1, style: StrokeStyle(lineWidth: 28, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(ByteText.string(Int64(total))).font(.system(size: 26, weight: .bold))
                Text("Total Storage").font(.system(size: 14)).foregroundStyle(Palette.dim)
            }
        }
        .padding(14)
        .animation(.easeInOut(duration: 0.6), value: b?.used)
        .onAppear { withAnimation(.spring(response: 1.1, dampingFraction: 0.9).delay(0.1)) { grow = 1 } }
    }
}

private struct ScanHero: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(OverviewModel.self) private var ov

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(symbol: "paintbrush.pointed.fill", color: Palette.accent, size: 54)
            Text(cleaner.hasScanned ? "\(ByteText.string(cleaner.recommendedBytes)) can be cleaned" : "Find and remove\nunnecessary files")
                .font(.system(size: 28, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(cleaner.hasScanned
                 ? "Scanned \(cleaner.progressTotal) locations. Review the recommendations below, then clean."
                 : "Scan your Mac for junk, temporary files, caches and other items you can safely clean.")
                .font(.system(size: 15)).foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            if cleaner.phase == .scanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(cleaner.progressDone), total: Double(max(cleaner.progressTotal, 1)))
                        .tint(Palette.accent)
                    Text("Scanning \(cleaner.progressDone) of \(cleaner.progressTotal) locations · \(ByteText.string(cleaner.runningBytes)) found")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                }
                .frame(maxWidth: 380)
            } else {
                Button {
                    Task {
                        async let a: Void = cleaner.scan()
                        async let b: Void = ov.scanDownloads()
                        _ = await (a, b)
                    }
                } label: {
                    Label(cleaner.hasScanned ? "Scan Again" : "Scan for Junk", systemImage: "play.fill")
                }
                .buttonStyle(AccentButtonStyle(large: true))
                .disabled(cleaner.isBusy)
            }
        }
    }
}

// MARK: Recommended

private struct RecommendedCard: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(OverviewModel.self) private var ov

    var body: some View {
        let total = RecGroup.allCases.reduce(Int64(0)) { $0 + bytes($1) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recommended Cleanup").font(.system(size: 20, weight: .bold))
                Spacer()
                if cleaner.hasScanned {
                    Text("\(ByteText.string(total)) found")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Palette.fg.opacity(0.06), in: Capsule())
                }
            }
            .padding(.bottom, 12)

            ForEach(RecGroup.allCases) { g in
                Divider().opacity(0.6)
                HStack(spacing: 14) {
                    IconTile(symbol: g.symbol, color: g.color, size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.title).font(.system(size: 15, weight: .semibold))
                        Text(g.subtitle).font(.system(size: 12.5)).foregroundStyle(Palette.dim).lineLimit(1)
                    }
                    Spacer()
                    Text(scanned(g) ? ByteText.string(bytes(g)) : "—")
                        .font(.system(size: 15)).monospacedDigit().foregroundStyle(Palette.dim)
                    Button { toggle(g) } label: {
                        CheckSquare(on: isOn(g), color: Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(!scanned(g) || bytes(g) == 0 || cleaner.isBusy)
                }
                .padding(.vertical, 12)
            }

            Spacer(minLength: 16)

            if let r = cleaner.result, cleaner.phase == .done {
                Label("Freed \(ByteText.string(r.freed)) · \(r.count) item(s)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(Palette.success).padding(.bottom, 10)
            }

            Button { ov.confirming = true } label: {
                Label(cleanTitle, systemImage: "sparkles")
            }
            .buttonStyle(WideAccentButtonStyle())
            .disabled(selectedTotal == 0 || cleaner.isBusy || ov.cleaning)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 420)
        .panel(radius: 22)
    }

    private var selectedTotal: Int64 { cleaner.chosenBytes + (ov.downloadsSelected ? ov.oldDownloadsBytes : 0) }
    private var cleanTitle: String {
        if ov.cleaning || cleaner.phase == .cleaning { return "Cleaning…" }
        if !cleaner.hasScanned { return "Scan first to clean" }
        return "Clean \(ByteText.string(selectedTotal))"
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

// MARK: Quick tools + recent

private struct QuickTools: View {
    @Binding var page: SidebarPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Tools").font(.system(size: 20, weight: .bold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                tile("Projects", "hammer", Color(hex: 0x8B5CF6), .projects).appearIn(0)
                tile("SDKs", "shippingbox", Color(hex: 0x3A8DFF), .sdks).appearIn(1)
                tile("Large & Old", "laptopcomputer", Color(hex: 0x14B8C8), .large).appearIn(2)
                tile("Duplicates", "plus.square.on.square", Color(hex: 0x1A7CFF), .duplicates).appearIn(3)
                tile("Apps", "square.grid.2x2", Color(hex: 0x22A54A), .apps).appearIn(4)
                tile("System Data", "internaldrive", Color(hex: 0xF0559C), .systemData).appearIn(5)
                tile("Startup", "power", Color(hex: 0xF97316), .startup).appearIn(6)
                tile("Storage", "chart.bar.xaxis", Color(hex: 0xF7B731), .storage).appearIn(7)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 22)
    }

    private func tile(_ title: String, _ symbol: String, _ color: Color, _ target: SidebarPage) -> some View {
        QuickTile(title: title, symbol: symbol, color: color) { page = target }
    }
}

/// One Quick Tools tile: same size as its neighbours; hover tints it instead of zooming.
private struct QuickTile: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void
    @State private var hover = false
    @State private var bounce = 0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium)).foregroundStyle(color)
                    .frame(height: 26)
                    .symbolEffect(.bounce, value: bounce)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.fg).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(hover ? color.opacity(0.12) : Palette.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hover ? color.opacity(0.45) : Palette.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            if h { bounce += 1 }
        }
    }
}

private struct RecentCleanups: View {
    @Binding var showAll: Bool
    private var history: HistoryStore { HistoryStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Cleanups").font(.system(size: 20, weight: .bold))
                Spacer()
                Button("See All") { showAll = true }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).font(.system(size: 14, weight: .medium))
                    .disabled(history.records.isEmpty)
            }
            if history.records.isEmpty {
                Text("Cleanups you run show up here.").font(.system(size: 13)).foregroundStyle(Palette.dim)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(history.records.prefix(3).enumerated()), id: \.1.id) { idx, r in
                    VStack(spacing: 0) {
                        Divider().opacity(0.6)
                        HistoryRow(record: r)
                    }
                    .appearIn(idx)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: history.records.first?.id)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 22)
    }
}

struct HistoryRow: View {
    let record: CleanupRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(Palette.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.system(size: 14, weight: .medium))
                Text(record.date.formatted(Calendar.current.isDateInToday(record.date)
                                           ? .dateTime.hour().minute()
                                           : .dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 12)).foregroundStyle(Palette.dim)
            }
            Spacer()
            Text(ByteText.string(record.bytes)).font(.system(size: 14)).monospacedDigit().foregroundStyle(Palette.dim)
        }
        .padding(.vertical, 6)
    }
}

struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    private var history: HistoryStore { HistoryStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup History").font(.system(size: 22, weight: .bold))
                    Text("\(history.records.count) cleanups · \(ByteText.string(history.totalFreed)) in total")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                }
                Spacer()
                Button("Clear") { history.clear() }.buttonStyle(GhostButtonStyle()).disabled(history.records.isEmpty)
                Button("Done") { dismiss() }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(history.records) { r in
                        HistoryRow(record: r)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
        .background(AppBackground())
    }
}
