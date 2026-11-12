import Charts
import Foundation
import Observation
import SwiftUI

// MARK: - Free-space log

/// One reading of the disk's free space per day, kept for 90 days
/// (~/Library/Application Support/Mac Cleaner/free-space.json). Fed by the low-disk check,
/// which runs at launch and every 30 minutes. Only numbers are stored: no file names or paths.
@MainActor @Observable
final class FreeSpaceLog {
    struct Sample: Codable, Equatable {
        /// Start of the day the reading belongs to.
        let day: Date
        let free: Int64
        let total: Int64
    }

    static let shared = FreeSpaceLog()
    static let keepDays = 90

    private(set) var samples: [Sample] = []

    nonisolated static var fileURL: URL {
        HistoryStore.fileURL.deletingLastPathComponent().appendingPathComponent("free-space.json")
    }

    private init() {
        if let d = try? Data(contentsOf: Self.fileURL),
           let s = try? JSONDecoder.iso.decode([Sample].self, from: d) { samples = s }
    }

    func record(free: Int64, total: Int64, now: Date = Date()) {
        guard free > 0, total > 0 else { return }
        let next = Self.merged(samples, Sample(day: Calendar.current.startOfDay(for: now), free: free, total: total), now: now)
        guard next != samples else { return }
        samples = next
        if let d = try? JSONEncoder.iso.encode(samples) { try? d.write(to: Self.fileURL, options: .atomic) }
    }

    /// Replaces today's reading with the newest one, keeps days in order and drops days older than `keepDays`.
    nonisolated static func merged(_ list: [Sample], _ new: Sample, now: Date) -> [Sample] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: now) ?? .distantPast
        return (list.filter { $0.day != new.day && $0.day >= cutoff } + [new]).sorted { $0.day < $1.day }
    }

    /// Days until free space falls to `threshold`, from a straight-line fit of the last 30 days.
    /// nil when there's too little data (fewer than 3 days, spread over less than 2 days) or free space
    /// isn't shrinking. 0 when it is already below the threshold.
    nonisolated static func daysUntil(_ threshold: Int64, samples all: [Sample], now: Date = Date()) -> Double? {
        let from = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        let s = all.filter { $0.day >= from }
        guard s.count >= 3, let first = s.first, let last = s.last,
              last.day.timeIntervalSince(first.day) >= 2 * 86_400 else { return nil }
        if last.free <= threshold { return 0 }
        let xs = s.map { $0.day.timeIntervalSince(first.day) / 86_400 }
        let ys = s.map { Double($0.free) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard sxx > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx   // bytes per day
        guard slope < -1 else { return nil }
        return Double(last.free - threshold) / -slope
    }
}

// MARK: - Cleanup history by week

enum InsightMath {
    struct Week: Identifiable {
        let start: Date
        let deleted: Int64
        let trashed: Int64
        var id: Date { start }
    }

    /// The last `count` calendar weeks (oldest first, empty weeks included) with bytes deleted and
    /// moved to the Trash. Records saved before outcomes were tracked count as deleted.
    static func weeks(_ records: [CleanupRecord], count: Int, now: Date = Date(), calendar: Calendar = .current) -> [Week] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let starts = (0..<count).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
        var deleted: [Date: Int64] = [:], trashed: [Date: Int64] = [:]
        for r in records {
            guard let w = calendar.dateInterval(of: .weekOfYear, for: r.date)?.start, w >= starts.first ?? thisWeek else { continue }
            if r.outcome == .trashed { trashed[w, default: 0] += r.bytes } else { deleted[w, default: 0] += r.bytes }
        }
        return starts.map { Week(start: $0, deleted: deleted[$0] ?? 0, trashed: trashed[$0] ?? 0) }
    }

    /// "about 3 weeks", "about 5 days", "less than a day".
    static func durationText(days: Double) -> String {
        switch days {
        case ..<1: return "less than a day"
        case ..<14: let d = Int(days.rounded()); return "about \(d) day\(d == 1 ? "" : "s")"
        case ..<70: return "about \(Int((days / 7).rounded())) weeks"
        default: return "about \(Int((days / 30).rounded())) months"
        }
    }
}

// MARK: - Card

/// Dashboard card with three small charts: space reclaimed per week, the free-space trend with a
/// forecast, and where the junk from the last scan is.
struct InsightsCard: View {
    enum Tab: String, CaseIterable, Identifiable {
        case reclaimed = "Reclaimed", freeSpace = "Free Space", junk = "Junk"
        var id: String { rawValue }
    }

    /// Every tab keeps the same height, so switching charts doesn't move the cards below.
    static let contentHeight: CGFloat = 236

    @AppStorage("insightsTab") private var tab: Tab = .reclaimed
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Insights").font(.title3.weight(.semibold))
                Spacer()
                Picker("Chart", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Group {
                switch tab {
                case .reclaimed: ReclaimedChart()
                case .freeSpace: FreeSpaceChart()
                case .junk: JunkChart()
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.contentHeight, alignment: .top)
            .id(tab)
            .transition(.opacity)
        }
        .animation(Motion.quick(reduce), value: tab)
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// Bars grow from zero once when a chart appears (skipped under Reduce Motion).
private struct Grow: ViewModifier {
    @Binding var progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.onAppear {
            if reduce { progress = 1 } else { withAnimation(.easeOut(duration: 0.7).delay(0.05)) { progress = 1 } }
        }
    }
}

private struct ChartSummary: View {
    let text: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(text).font(.callout.weight(.medium)).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(Palette.dim) }
        }
    }
}

private struct ChartEmpty<Action: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Palette.faint).accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(Palette.dim).multilineTextAlignment(.center)
            action().padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, minHeight: InsightsCard.contentHeight)
    }
}

extension ChartEmpty where Action == EmptyView {
    init(symbol: String, text: String) { self.init(symbol: symbol, text: text) { EmptyView() } }
}

private func bytesAxis() -> some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
        AxisGridLine()
        AxisValueLabel { if let d = v.as(Double.self) { Text(d == 0 ? "0" : ByteText.string(Int64(d))) } }
    }
}

// MARK: Reclaimed per week

private struct ReclaimedChart: View {
    @State private var grow: Double = 0
    private var weeks: [InsightMath.Week] { InsightMath.weeks(HistoryStore.shared.records, count: 8) }

    var body: some View {
        let w = weeks
        let deleted = w.reduce(Int64(0)) { $0 + $1.deleted }, trashed = w.reduce(Int64(0)) { $0 + $1.trashed }
        if deleted + trashed == 0 {
            ChartEmpty(symbol: "chart.bar", text: "Space you reclaim shows up here, week by week.")
        } else {
            VStack(alignment: .leading, spacing: Space.m) {
                ChartSummary(text: "\(ByteText.string(deleted)) deleted · \(ByteText.string(trashed)) moved to Trash",
                             detail: "Last 8 weeks. Space in the Trash is freed when you empty it.")
                Chart {
                    ForEach(w) { week in
                        BarMark(x: .value("Week", week.start, unit: .weekOfYear),
                                y: .value("Size", Double(week.deleted) * grow))
                            .foregroundStyle(by: .value("Outcome", "Deleted"))
                            .cornerRadius(3)
                        BarMark(x: .value("Week", week.start, unit: .weekOfYear),
                                y: .value("Size", Double(week.trashed) * grow))
                            .foregroundStyle(by: .value("Outcome", "Moved to Trash"))
                            .cornerRadius(3)
                    }
                }
                .chartForegroundStyleScale(["Deleted": Palette.success, "Moved to Trash": Palette.warn])
                .chartYAxis { bytesAxis() }
                .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                    AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 170)
                .modifier(Grow(progress: $grow))
                .accessibilityLabel("Space reclaimed per week")
            }
        }
    }
}

// MARK: Free space trend

private struct FreeSpaceChart: View {
    @State private var grow: Double = 0
    private var log: FreeSpaceLog { FreeSpaceLog.shared }

    var body: some View {
        let s = log.samples
        let limit = AutomationModel.thresholdBytes
        if s.count < 2 {
            ChartEmpty(symbol: "chart.line.uptrend.xyaxis",
                       text: "Mac Cleaner notes your free space once a day. The trend appears after a few days.")
        } else {
            let last = s[s.count - 1]
            let days = FreeSpaceLog.daysUntil(limit, samples: s)
            VStack(alignment: .leading, spacing: Space.m) {
                ChartSummary(text: "\(ByteText.string(last.free)) free now", detail: forecast(days, limit: limit, count: s.count))
                Chart {
                    ForEach(s, id: \.day) { p in
                        AreaMark(x: .value("Day", p.day, unit: .day), y: .value("Free", Double(p.free) * grow))
                            .foregroundStyle(Palette.accent.opacity(0.12))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", p.day, unit: .day), y: .value("Free", Double(p.free) * grow))
                            .foregroundStyle(Palette.accent)
                            .interpolationMethod(.monotone)
                    }
                    RuleMark(y: .value("Alert", Double(limit)))
                        .foregroundStyle(Palette.warn.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Alert at \(ByteText.string(limit))").font(.caption2).foregroundStyle(Palette.warn)
                        }
                }
                .chartYScale(domain: 0...Double(max(s.map(\.free).max() ?? 0, limit)) * 1.15)
                .chartYAxis { bytesAxis() }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                } }
                .frame(height: 170)
                .modifier(Grow(progress: $grow))
                .accessibilityLabel("Free space over time")
            }
        }
    }

    private func forecast(_ days: Double?, limit: Int64, count: Int) -> String {
        guard let days else {
            return count < 3 ? "A forecast appears after a few more days." : "Free space is steady or growing."
        }
        if days == 0 { return "Below your \(ByteText.string(limit)) alert. Review the recommended cleanup." }
        return "At this rate, free space reaches your \(ByteText.string(limit)) alert in \(InsightMath.durationText(days: days))."
    }
}

// MARK: Junk by category

private struct JunkChart: View {
    @Environment(CleanerModel.self) private var cleaner
    @State private var grow: Double = 0

    struct Row: Identifiable { let category: CacheCategory; let bytes: Int64; var id: String { category.rawValue } }

    var body: some View {
        let rows = cleaner.categories.map { Row(category: $0, bytes: cleaner.bytes(in: $0)) }
            .filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        if rows.isEmpty && cleaner.phase == .scanning {
            ChartEmpty(symbol: "chart.bar.xaxis",
                       text: "Scanning \(cleaner.progressDone) of \(cleaner.progressTotal) locations…") {
                ProgressView(value: Double(cleaner.progressDone), total: Double(max(cleaner.progressTotal, 1)))
                    .frame(width: 220)
            }
        } else if rows.isEmpty {
            ChartEmpty(symbol: "chart.bar.xaxis", text: "Scan to see which kinds of junk take the most space.") {
                Button { Task { await cleaner.scan() } } label: { Label("Scan for Junk", systemImage: "magnifyingglass") }
                    .buttonStyle(.bordered).disabled(cleaner.isBusy)
            }
        } else {
            let top = Array(rows.prefix(6))
            VStack(alignment: .leading, spacing: Space.m) {
                ChartSummary(text: "\(ByteText.string(cleaner.reclaimableBytes)) of junk in \(rows.count) categor\(rows.count == 1 ? "y" : "ies")",
                             detail: "\(ByteText.string(cleaner.recommendedBytes)) of it is recommended to clean. From the last scan, biggest first.")
                Chart(top) { r in
                    BarMark(x: .value("Size", Double(r.bytes) * grow), y: .value("Category", r.category.rawValue),
                            height: .fixed(14))
                        .foregroundStyle(r.category.color)
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text(ByteText.string(r.bytes)).font(.caption).foregroundStyle(Palette.dim).monospacedDigit()
                        }
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.caption) } }
                .chartXScale(domain: 0...Double(top.first?.bytes ?? 1) * 1.25)
                .frame(height: CGFloat(top.count) * 30 + 8)
                .modifier(Grow(progress: $grow))
                .accessibilityLabel("Junk by category")
            }
        }
    }
}
