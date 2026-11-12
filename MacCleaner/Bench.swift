import Foundation

/// `"Mac Cleaner" --cli bench [scan…] [--runs N] [--dump DIR] [--cache]`: times every scan through the same models the
/// window uses, on a live main run loop, and reports the longest main-thread stall during each one (the time the
/// window could not redraw). Reads only; deletes nothing. `--dump` writes one "id<TAB>bytes" file per scan so two
/// builds can be compared line by line.
@MainActor
enum Bench {
    static let all = ["junk", "storage", "duplicates", "large", "projects", "sdks", "apps", "system", "overview"]

    struct Result {
        var seconds: Double
        var stall: Double
        var summary: String
        var lines: [String]
    }

    static func run(_ argv: [String]) -> Int32 {
        var args = argv
        var runs = 1
        var dump: URL?
        if let i = args.firstIndex(of: "--runs"), i + 1 < args.count {
            runs = max(1, Int(args[i + 1]) ?? 1); args.removeSubrange(i...i + 1)
        }
        if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
            dump = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath); args.removeSubrange(i...i + 1)
        }
        // Real walks unless --cache: then later scans may reuse sizes from earlier ones, as in the app.
        if let i = args.firstIndex(of: "--cache") { args.remove(at: i) } else { SizeCache.enabled = false }
        let names = args.isEmpty ? all : args
        if names == ["sizer"] { return sizer() }
        if let bad = names.first(where: { !all.contains($0) }) {
            FileHandle.standardError.write(Data("Unknown scan “\(bad)”. Scans: \(all.joined(separator: ", "))\n".utf8))
            return 64
        }
        if let dump { try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true) }

        print("scan".padding(toLength: 12, withPad: " ", startingAt: 0) + "median s   min s   max stall s   result")
        for name in names {
            var results: [Result] = []
            for _ in 0..<runs { results.append(measure(name)) }
            let secs = results.map(\.seconds).sorted()
            let last = results[results.count - 1]
            print(name.padding(toLength: 12, withPad: " ", startingAt: 0)
                  + String(format: "%8.2f %7.2f %13.3f   ", secs[secs.count / 2], secs[0], results.map(\.stall).max() ?? 0)
                  + last.summary)
            if name == "storage" || name == "large" || name == "overview" {
                print("            most folder jobs waiting at once so far: \(WalkPool.shared.peakQueued)")
            }
            if let dump {
                let text = last.lines.sorted().joined(separator: "\n") + "\n"
                try? text.write(to: dump.appendingPathComponent(name + ".tsv"), atomically: true, encoding: .utf8)
            }
        }
        return 0
    }

    /// `bench sizer`: the fast folder sizer against the old FileManager walk on every folder in the home folder
    /// and in ~/Library. Prints only counts and totals, never paths.
    private static func sizer() -> Int32 {
        SizeCache.enabled = false
        let home = SafetyGuard.home
        let fm = FileManager.default
        let kids = { (u: URL) in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] }
        let folders = kids(home).filter { $0.lastPathComponent != "Library" } + kids(home.appendingPathComponent("Library"))
        var fastT = 0.0, slowT = 0.0, fastB: Int64 = 0, slowB: Int64 = 0, same = 0, differ: [(Int64, Int64)] = []
        for f in folders {
            var t = Date()
            let s = Scanner.allocatedSizeSlow(f); slowT += Date().timeIntervalSince(t)
            t = Date()
            let q = Scanner.allocatedSize(f); fastT += Date().timeIntervalSince(t)
            slowB += s; fastB += q
            if s == q { same += 1 } else { differ.append((s, q)) }
        }
        print("\(folders.count) folders: \(same) identical, \(differ.count) differ")
        print(String(format: "old walk %.2f s  %@\nDirSize  %.2f s  %@", slowT, mb(slowB), fastT, mb(fastB)))
        for (s, q) in differ.prefix(20) { print("  old \(s)  new \(q)  diff \(q - s)") }
        return 0
    }

    /// Runs `body` on the main actor while spinning the main run loop; returns wall time and the longest
    /// single run-loop turn (a stall the window would show as a beach ball or frozen progress).
    private static func time(_ body: @escaping @MainActor () async -> Void) -> (Double, Double) {
        var done = false
        let start = Date()
        Task { @MainActor in await body(); done = true }
        var stall = 0.0
        var turn = Date()
        while !done {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            let now = Date()
            stall = max(stall, now.timeIntervalSince(turn))
            turn = now
        }
        return (Date().timeIntervalSince(start), stall)
    }

    private static func waitUntil(_ cond: @escaping @MainActor () -> Bool) async {
        while !cond() { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private static func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1e6) }

    private static func measure(_ name: String) -> Result {
        var summary = ""
        var lines: [String] = []
        let (secs, stall) = time {
            switch name {
            case "junk":
                let m = CleanerModel()
                await m.scan()
                summary = "\(m.targets.count) items, \(mb(m.reclaimableBytes))"
                lines = m.targets.map { "\($0.id)\t\($0.sizeBytes)" }
            case "storage":
                let m = DiskMapModel()
                m.start()
                await waitUntil { m.phase != .scanning }
                let root = m.root
                summary = "\(root?.fileCount ?? 0) files, \(mb(root?.size ?? 0))"
                lines = (root?.children ?? []).flatMap { c in
                    ["\(c.id)\t\(c.size)\t\(c.fileCount)"] + c.children.map { "\($0.id)\t\($0.size)\t\($0.fileCount)" }
                }
            case "duplicates":
                let m = DupFinder()
                m.start()
                await waitUntil { m.phase != .scanning }
                summary = "\(m.groups.count) groups, \(mb(m.wasted)) wasted"
                lines = m.groups.map { "\($0.id)\t\($0.files.count)" }
            case "large":
                let m = LargeFilesModel()
                m.scan()
                await waitUntil { m.phase != .scanning }
                summary = "\(m.files.count) files, \(mb(m.files.reduce(0) { $0 + $1.size }))"
                lines = m.files.map { "\($0.id)\t\($0.size)" }
            case "projects":
                let m = ProjectsModel()
                m.scan()
                await waitUntil { m.phase != .scanning }
                summary = "\(m.projects.count) projects, \(mb(m.allBytes))"
                lines = m.projects.flatMap { p in
                    ["\(p.id)\t\(p.total)\t\(p.lastTouched?.timeIntervalSince1970 ?? 0)"] + p.artifacts.map { "\($0.id)\t\($0.size)" }
                }
            case "sdks":
                let m = SDKModel()
                await m.load()
                summary = "\(m.scan.items.count) items, \(mb(m.total(nil)))"
                lines = m.scan.items.map { "\($0.id)\t\($0.size)" }
            case "apps":
                let m = AppsModel()
                await m.scan()
                summary = "\(m.apps.count) apps, \(mb(m.apps.reduce(0) { $0 + $1.total }))"
                lines = m.apps.map { "\($0.id)\t\($0.appSize)\t\($0.dataSize)\t\($0.cacheSize)" }
            case "system":
                let m = SystemDataModel()
                await m.load()
                summary = "\(m.report.items.count) items, \(mb(m.report.items.reduce(0) { $0 + ($1.size ?? 0) }))"
                lines = m.report.items.map { "\($0.id)\t\($0.size ?? -1)" }
            case "overview":
                let m = OverviewModel()
                m.savesResult = false       // measure without replacing the saved breakdown
                await m.measure()
                let b = m.breakdown
                summary = "apps \(mb(b?.apps ?? 0)), documents \(mb(b?.documents ?? 0)), library \(mb(b?.library ?? 0))"
                lines = ["apps\t\(b?.apps ?? 0)", "documents\t\(b?.documents ?? 0)", "library\t\(b?.library ?? 0)"]
            default:
                break
            }
        }
        return Result(seconds: secs, stall: stall, summary: summary, lines: lines)
    }
}
