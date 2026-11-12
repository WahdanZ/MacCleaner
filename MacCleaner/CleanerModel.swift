import SwiftUI
import Observation

@MainActor @Observable
final class CleanerModel {
    enum Phase: Equatable { case idle, scanning, results, cleaning, done }

    struct LogLine: Identifiable {
        enum Kind { case info, found, removed, error }
        let id = UUID()
        let kind: Kind
        let category: CacheCategory?
        let text: String
        let bytes: Int64?
    }

    struct CleanResult: Equatable {
        let freed: Int64
        let count: Int
        let errors: [String]
    }

    var phase: Phase = .idle
    var targets: [CleanTarget] = []
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var progressDone = 0
    var progressTotal = 0
    var runningBytes: Int64 = 0
    var log: [LogLine] = []
    var confirming = false
    var result: CleanResult?
    var fullDiskAccess = Scanner.hasFullDiskAccess()

    // MARK: Derived

    var hasScanned: Bool { !targets.isEmpty || phase == .results || phase == .done }
    var isBusy: Bool { phase == .scanning || phase == .cleaning }
    var chosen: [CleanTarget] { targets.filter { $0.selected && $0.isCleanable } }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.sizeBytes } }
    var reclaimableBytes: Int64 { targets.reduce(0) { $0 + $1.sizeBytes } }
    var recommendedBytes: Int64 { targets.filter(\.recommended).reduce(0) { $0 + $1.sizeBytes } }
    var categories: [CacheCategory] {
        CacheCategory.allCases.filter { c in targets.contains { $0.category == c } }
    }
    var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - freeBytes) / Double(totalBytes) : 0
    }

    func items(in c: CacheCategory) -> [CleanTarget] { targets.filter { $0.category == c } }
    func bytes(in c: CacheCategory) -> Int64 { items(in: c).reduce(0) { $0 + $1.sizeBytes } }
    func selectedBytes(in c: CacheCategory) -> Int64 {
        items(in: c).filter(\.selected).reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: Actions

    func refreshDisk() {
        freeBytes = Scanner.freeBytes()
        totalBytes = Scanner.totalBytes()
    }

    func scan() async {
        guard !isBusy else { return }
        phase = .scanning
        result = nil
        runningBytes = 0
        log = []
        append(.info, nil, "Deep scan started", nil)
        refreshDisk()
        fullDiskAccess = Scanner.hasFullDiskAccess()

        let keep = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.selected) })
        let plan = await Task.detached(priority: .userInitiated) { Scanner.plan() }.value
        progressTotal = plan.count
        progressDone = 0
        append(.info, nil, "\(plan.count) locations to check", nil)

        var measured: [CleanTarget] = []
        await withTaskGroup(of: CleanTarget.self) { group in
            var queue = plan[...]
            for _ in 0..<6 {
                if let t = queue.popFirst() { group.addTask { Scanner.measure(t) } }
            }
            while let m = await group.next() {
                measured.append(m)
                progressDone += 1
                if m.isCleanable {
                    runningBytes += m.sizeBytes
                    append(.found, m.category, m.path, m.sizeBytes)
                }
                if let t = queue.popFirst() { group.addTask { Scanner.measure(t) } }
            }
        }

        targets = Scanner.finalize(measured).map { t in
            var t = t
            t.selected = keep[t.id] ?? t.recommended
            return t
        }
        refreshDisk()
        append(.info, nil, "Done · \(targets.count) items · \(ByteText.string(reclaimableBytes)) sweepable", nil)
        phase = .results
    }

    func clean() async {
        let items = chosen
        guard !items.isEmpty, !isBusy else { return }
        phase = .cleaning
        runningBytes = 0
        log = []
        append(.info, nil, "Sweeping \(items.count) items", nil)
        progressTotal = items.count
        progressDone = 0
        let before = Scanner.freeBytes()

        var errors: [String] = []
        var cleaned: Set<String> = []
        for t in items {
            let errs = await Task.detached(priority: .userInitiated) { Cleaner.run([t]) }.value
            progressDone += 1
            if errs.isEmpty {
                cleaned.insert(t.id)
                runningBytes += t.sizeBytes
                append(.removed, t.category, t.path, t.sizeBytes)
            } else {
                errors += errs
                errs.forEach { append(.error, t.category, $0, nil) }
            }
        }
        targets.removeAll { cleaned.contains($0.id) }
        refreshDisk()
        result = CleanResult(freed: max(0, freeBytes - before), count: cleaned.count, errors: errors)
        let swept = items.filter { cleaned.contains($0.id) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        HistoryStore.shared.add("Junk Files Cleaned", bytes: swept, symbol: "trash",
                                outcome: .deleted, measuredFreeChange: result?.freed)
        phase = .done
    }

    func toggle(_ id: String) {
        guard !isBusy, let i = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[i].selected.toggle()
    }

    func toggleAll(_ c: CacheCategory) {
        toggleAll(ids: Set(items(in: c).map(\.id)))
    }

    func toggleAll(ids: Set<String>) {
        guard !isBusy else { return }
        let idx = targets.indices.filter { ids.contains(targets[$0].id) }
        let allOn = idx.allSatisfy { targets[$0].selected }
        for i in idx { targets[i].selected = !allOn }
    }

    func selectRecommended() {
        for i in targets.indices { targets[i].selected = targets[i].recommended }
    }

    func selectNone() {
        for i in targets.indices { targets[i].selected = false }
    }

    private func append(_ kind: LogLine.Kind, _ c: CacheCategory?, _ text: String, _ bytes: Int64?) {
        log.append(LogLine(kind: kind, category: c, text: text, bytes: bytes))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}
