import AppKit
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case caches = "Caches"
    case disk = "Disk Map"
    case duplicates = "Duplicates"
    case apps = "Apps"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .caches: return "wind"
        case .disk: return "square.grid.3x3.square"
        case .duplicates: return "doc.on.doc"
        case .apps: return "square.grid.2x2"
        }
    }
}

/// Confirm dialogs for the cache sweep, Storage Analysis, Duplicates and Apps.
struct FeatureAlerts: ViewModifier {
    @Environment(CleanerModel.self) private var model
    @Environment(DiskMapModel.self) private var map
    @Environment(DupFinder.self) private var dup
    @Environment(AppsModel.self) private var appsModel

    func body(content: Content) -> some View {
        @Bindable var model = model
        @Bindable var map = map
        @Bindable var dup = dup
        @Bindable var appsModel = appsModel
        content
        .alert("Sweep \(model.chosen.count) item(s)?", isPresented: $model.confirming) {
            Button("Sweep \(ByteText.string(model.chosenBytes))", role: .destructive) {
                Task { await model.clean() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.chosen.prefix(14).map { "• \($0.name) — \(ByteText.string($0.sizeBytes))" }.joined(separator: "\n")
                 + (model.chosen.count > 14 ? "\n• …and \(model.chosen.count - 14) more" : "")
                 + "\n\nCaches are deleted permanently. Documents, Downloads, Desktop, Movies, Pictures, Music and iCloud Drive are not part of a sweep.")
        }
        .alert("Move \(map.markedCount) item(s) to the Trash?", isPresented: $map.confirming) {
            Button("Move \(ByteText.string(map.markedBytes)) to Trash", role: .destructive) {
                Task { await map.trashMarked() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(map.topLevelMarked.sorted { $0.size > $1.size }.prefix(14)
                    .map { "• \($0.tildePath) — \(ByteText.string($0.size))" }.joined(separator: "\n")
                 + (map.markedCount > 14 ? "\n• …and \(map.markedCount - 14) more" : "")
                 + "\n\nYou can put them back from the Trash. Space is freed when the Trash is emptied.")
        }
        .alert("Uninstall \(appsModel.selected?.name ?? "app")?", isPresented: $appsModel.confirmUninstall) {
            Button("Move to Trash", role: .destructive) { Task { await appsModel.uninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(appsModel.uninstallSummary)
        }
        .alert("Clear \(appsModel.selected?.name ?? "app") cache?", isPresented: $appsModel.confirmClear) {
            Button("Clear \(ByteText.string(appsModel.selected?.cacheSize ?? 0))", role: .destructive) {
                Task { await appsModel.clearCaches() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let a = appsModel.selected {
                Text(a.caches.prefix(12).map { "• \(Scanner.tilde($0.url)) — \(ByteText.string($0.size))" }.joined(separator: "\n")
                     + "\n\nCaches are deleted permanently; the app rebuilds them. Quit the app first for the cleanest result.")
            }
        }
        .alert("Move \(dup.marked.count) duplicate(s) to the Trash?", isPresented: $dup.confirming) {
            Button("Move \(ByteText.string(dup.markedBytes)) to Trash", role: .destructive) {
                Task { await dup.trashMarked() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dup.marked.sorted { $0.path < $1.path }.prefix(14).map { "• " + Scanner.tilde($0) }.joined(separator: "\n")
                 + (dup.marked.count > 14 ? "\n• …and \(dup.marked.count - 14) more" : "")
                 + "\n\nAt least one copy of every file stays. You can put them back from the Trash.")
        }
    }
}

struct AccessBanner: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(Palette.warn)
            Text("Limited access: without Full Disk Access some folders (Trash, Mail, other apps' data) can't be measured, so totals are low.")
                .font(.system(size: 12)).foregroundStyle(Palette.fg.opacity(0.85))
            Spacer()
            Button("Open Full Disk Access settings") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(u)
                }
            }
            .buttonStyle(GhostButtonStyle())
            Button("Check again") { model.fullDiskAccess = Scanner.hasFullDiskAccess() }
                .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.warn.opacity(0.3)))
    }
}

struct DiskStrip: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(model.totalBytes), 1)
            let junk = model.categories.map { ($0.color, Double(model.bytes(in: $0))) }
            let junkSum = junk.reduce(0) { $0 + $1.1 }
            let otherUsed = max(0, total - Double(model.freeBytes) - junkSum)
            let segs: [(Color, Double)] = [(Palette.fg.opacity(0.22), otherUsed)] + junk
                + [(Palette.fg.opacity(0.05), Double(model.freeBytes))]
            let usable = geo.size.width - CGFloat(segs.count * 2)
            HStack(spacing: 2) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                    Rectangle()
                        .fill(s.0)
                        .frame(width: s.1 > 0 ? max(3, usable * CGFloat(s.1 / total)) : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .animation(.snappy, value: model.freeBytes)
        .animation(.snappy, value: model.reclaimableBytes)
    }
}

struct Legend: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.categories) { c in
                    let any = model.selectedBytes(in: c) > 0
                    Button { model.toggleAll(c) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(c.color).frame(width: 7, height: 7)
                            Text(c.rawValue).font(.system(size: 11.5, weight: .medium))
                            Text(ByteText.string(model.bytes(in: c)))
                                .font(.mono(10.5)).foregroundStyle(Palette.dim)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(c.color.opacity(any ? 0.16 : 0.04), in: Capsule())
                        .overlay(Capsule().strokeBorder(c.color.opacity(any ? 0.5 : 0.2)))
                    }
                    .buttonStyle(.plain)
                    .help("Include or exclude everything in \(c.rawValue)")
                }
            }
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Stage (left panel)

struct Stage: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle:
            IdleView()
        case .scanning, .cleaning:
            ConsoleView()
        case .results:
            if model.targets.isEmpty { EmptyResults() } else { MapPanel() }
        case .done:
            DoneView()
        }
    }
}

private struct IdleView: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("~/deep-scan").font(.mono(13, .semibold)).foregroundStyle(Palette.accent)
                    Text("Find what your\ndev tools left behind.")
                        .font(.system(size: 36, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Checks 40+ places: Xcode, simulators, Gradle, emulators, Flutter, npm · yarn · pnpm · bun, Homebrew, CocoaPods, editors, app caches, logs and Trash.")
                        .foregroundStyle(Palette.dim)
                        .frame(maxWidth: 440, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await model.scan() }
                    } label: {
                        Label("Start deep scan", systemImage: "scope")
                    }
                    .buttonStyle(AccentButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
                DecorMap()
                    .frame(width: 260, height: 260)
                    .opacity(0.85)
                    .rotationEffect(.degrees(-4))
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Palette.accent)
                Text("SWEEP NEVER TOUCHES").font(.mono(10, .semibold)).foregroundStyle(Palette.faint)
                ForEach(["Documents", "Downloads", "Desktop", "Movies", "Pictures", "Music", "iCloud Drive"], id: \.self) {
                    Text($0).font(.mono(10.5))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Palette.fg.opacity(0.06), in: Capsule())
                }
            }
        }
        .padding(32)
    }
}

private struct ConsoleView: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        let scanning = model.phase == .scanning
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(scanning ? "SCANNING" : "SWEEPING")
                    .font(.mono(11, .bold)).foregroundStyle(Palette.accent)
                Spacer()
                Text("\(model.progressDone) / \(model.progressTotal)")
                    .font(.mono(11)).foregroundStyle(Palette.dim)
            }
            ProgressBar(fraction: model.progressTotal > 0
                        ? Double(model.progressDone) / Double(model.progressTotal) : 0)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ByteText.string(model.runningBytes))
                    .font(.mono(46, .bold))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.runningBytes)
                Text(scanning ? "found so far" : "swept so far").foregroundStyle(Palette.dim)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.log) { line in
                            LogRow(line: line).id(line.id)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Palette.fg.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: model.log.count) {
                    if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(22)
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fg.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Palette.accent, Palette.accent2], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
                    .shadow(color: Palette.accent.opacity(0.5), radius: 6)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}

private struct LogRow: View {
    let line: CleanerModel.LogLine

    var body: some View {
        HStack(spacing: 10) {
            Text(prefix).foregroundStyle(prefixColor).frame(width: 12, alignment: .leading)
            if let b = line.bytes {
                Text(ByteText.string(b))
                    .foregroundStyle(Palette.fg)
                    .frame(width: 78, alignment: .trailing)
            }
            Text(line.text)
                .foregroundStyle(line.kind == .error ? Palette.danger : line.kind == .info ? Palette.accent : Palette.dim)
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.mono(11.5))
    }

    private var prefix: String {
        switch line.kind {
        case .info: return "›"
        case .found: return "●"
        case .removed: return "✓"
        case .error: return "✕"
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .info: return Palette.accent
        case .error: return Palette.danger
        default: return line.category?.color ?? Palette.fg
        }
    }
}

private struct MapPanel: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("SPACE MAP").font(.mono(11, .bold)).foregroundStyle(Palette.accent)
                Text("block size = disk space · click to include or exclude")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                Spacer()
                Text("\(model.targets.count) items").font(.mono(11)).foregroundStyle(Palette.dim)
            }
            TreemapView()
        }
        .padding(14)
    }
}

private struct EmptyResults: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Palette.accent)
            Text("Nothing to sweep").font(.system(size: 26, weight: .bold))
            Text("Every cache location is already empty.").foregroundStyle(Palette.dim)
            Button("Scan again") { Task { await model.scan() } }.buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DoneView: View {
    @Environment(CleanerModel.self) private var model

    var body: some View {
        let r = model.result ?? .init(freed: 0, count: 0, errors: [])
        VStack(spacing: 12) {
            Spacer()
            Text("SWEPT").font(.mono(12, .bold)).foregroundStyle(Palette.accent)
            Text("−\(ByteText.string(r.freed))")
                .font(.mono(64, .bold))
                .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.accent2],
                                                startPoint: .leading, endPoint: .trailing))
            Text("\(r.count) item(s) removed · \(ByteText.string(model.freeBytes)) free now")
                .foregroundStyle(Palette.dim)
            if !r.errors.isEmpty {
                Text(r.errors.prefix(3).joined(separator: "\n"))
                    .font(.mono(11)).foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            HStack(spacing: 10) {
                if !model.targets.isEmpty {
                    Button("Back to space map") { model.phase = .results }.buttonStyle(GhostButtonStyle())
                }
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Scan again", systemImage: "scope")
                }
                .buttonStyle(AccentButtonStyle())
            }
            .padding(.top, 10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - Inspector (right panel)

enum SortMode: String, CaseIterable, Identifiable {
    case size = "Size"
    case category = "Category"
    case folder = "Folder"
    case name = "Name"
    var id: String { rawValue }
    var grouped: Bool { self == .category || self == .folder }
}

private struct ListSection: Identifiable {
    let id: String
    let title: String
    let color: Color
    let symbol: String
    let items: [CleanTarget]
}

struct Inspector: View {
    @Environment(CleanerModel.self) private var model
    @AppStorage("sortMode") private var sort: SortMode = .size
    @State private var collapsed: Set<String> = []

    private var flatItems: [CleanTarget] {
        switch sort {
        case .name: return model.targets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        default: return model.targets.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    private var sections: [ListSection] {
        if sort == .folder {
            return Dictionary(grouping: model.targets, by: \.folder)
                .map { key, items in
                    ListSection(id: "f:" + key, title: key, color: Palette.fg.opacity(0.75), symbol: "folder.fill",
                                items: items.sorted { $0.sizeBytes > $1.sizeBytes })
                }
                .sorted { a, b in a.items.reduce(0) { $0 + $1.sizeBytes } > b.items.reduce(0) { $0 + $1.sizeBytes } }
        }
        return model.categories.map {
            ListSection(id: "c:" + $0.rawValue, title: $0.rawValue.uppercased(), color: $0.color,
                        symbol: $0.symbol, items: model.items(in: $0).sorted { $0.sizeBytes > $1.sizeBytes })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SELECTED").font(.mono(10, .semibold)).foregroundStyle(Palette.faint)
                Text(ByteText.string(model.chosenBytes))
                    .font(.mono(30, .bold))
                    .foregroundStyle(model.chosenBytes > 0 ? Palette.accent : Palette.fg)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.chosenBytes)
                Text(model.targets.isEmpty ? "Run a scan to see items"
                     : "\(model.chosen.count) of \(model.targets.count) items")
                    .font(.system(size: 12)).foregroundStyle(Palette.dim)
                HStack(spacing: 6) {
                    Button("Recommended") { model.selectRecommended() }
                    Button("None") { model.selectNone() }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.targets.isEmpty || model.isBusy)
                .padding(.top, 8)
            }
            .padding(16)

            Rectangle().fill(Palette.stroke).frame(height: 1)

            if !model.targets.isEmpty {
                HStack(spacing: 8) {
                    Picker("Sort", selection: $sort) {
                        ForEach(SortMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if sort.grouped {
                        let all = Set(sections.map(\.id))
                        let allCollapsed = !all.isEmpty && all.isSubset(of: collapsed)
                        Button {
                            collapsed = allCollapsed ? [] : all
                        } label: {
                            Image(systemName: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        }
                        .buttonStyle(GhostButtonStyle())
                        .help(allCollapsed ? "Expand all" : "Collapse all")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            if model.targets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 26)).foregroundStyle(Palette.faint)
                    Text(model.isBusy ? "Measuring…" : "Items appear here after a scan.")
                        .font(.system(size: 12)).foregroundStyle(Palette.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if sort.grouped {
                        LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { sec in
                                Section {
                                    if !collapsed.contains(sec.id) {
                                        ForEach(sec.items) { t in
                                            InspectorRow(target: t, showCategory: sort == .folder)
                                        }
                                    }
                                } header: {
                                    SectionHeaderRow(section: sec, collapsed: collapsed.contains(sec.id)) {
                                        if collapsed.contains(sec.id) { collapsed.remove(sec.id) } else { collapsed.insert(sec.id) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(flatItems.enumerated()), id: \.element.id) { i, t in
                                InspectorRow(target: t, rank: sort == .size ? i + 1 : nil, showCategory: true)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct SectionHeaderRow: View {
    @Environment(CleanerModel.self) private var model
    let section: ListSection
    let collapsed: Bool
    let onCollapse: () -> Void

    var body: some View {
        let ids = Set(section.items.map(\.id))
        let selected = section.items.filter(\.selected)
        let total = section.items.reduce(0) { $0 + $1.sizeBytes }
        let sel = selected.reduce(0) { $0 + $1.sizeBytes }
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(Palette.dim)
                .frame(width: 10)
            Image(systemName: section.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(section.color)
                .frame(width: 14)
            Text(section.title).font(.system(size: 10.5, weight: .bold)).tracking(0.4)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Text("\(section.items.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.faint)
            Spacer(minLength: 4)
            Group {
                if sel == 0 || sel == total {
                    Text(ByteText.string(total)).foregroundStyle(sel == 0 ? Palette.faint : Palette.dim)
                } else {
                    Text(ByteText.string(sel)).foregroundStyle(Palette.dim)
                    + Text(" of \(ByteText.string(total))").foregroundStyle(Palette.faint)
                }
            }
            .font(.system(size: 10.5, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize()
            .help("\(ByteText.string(sel)) selected of \(ByteText.string(total))")
            Button { model.toggleAll(ids: ids) } label: {
                CheckSquare(on: selected.count == section.items.count, color: section.color,
                            mixed: !selected.isEmpty && selected.count < section.items.count)
            }
            .buttonStyle(.plain)
            .help("Include or exclude everything here")
        }
        .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 6)
        .background(Palette.bgBottom.opacity(0.97))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCollapse)
        .help(collapsed ? "Expand" : "Collapse")
    }
}

private struct InspectorRow: View {
    @Environment(CleanerModel.self) private var model
    let target: CleanTarget
    var rank: Int? = nil
    var showCategory = false
    @State private var hover = false

    var body: some View {
        Button { model.toggle(target.id) } label: {
            HStack(spacing: 10) {
                if let rank {
                    Text("\(rank)")
                        .font(.mono(10, .medium)).foregroundStyle(Palette.faint)
                        .frame(width: 18, alignment: .trailing)
                }
                CheckSquare(on: target.selected, color: target.category.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 5) {
                        if !target.recommended { ReviewTag() }
                        if showCategory {
                            Circle().fill(target.category.color).frame(width: 5, height: 5)
                            Text(target.category.rawValue)
                        } else {
                            Text(target.note)
                        }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(Palette.faint).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(ByteText.string(target.sizeBytes))
                    .font(.mono(11.5, .medium))
                    .foregroundStyle(target.selected ? Palette.fg : Palette.dim)
                    .fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Palette.fg.opacity(hover ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(target.path)\n\(target.note)")
        .contextMenu {
            if let u = target.revealURL {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.revealURL?.path ?? target.path, forType: .string)
            }
        }
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @Environment(CleanerModel.self) private var model
    @Environment(DiskMapModel.self) private var map
    @Environment(DupFinder.self) private var dup
    @Environment(AppsModel.self) private var appsModel
    let tab: AppTab

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(busy ? Palette.warn : Palette.accent).frame(width: 7, height: 7)
                .shadow(color: (busy ? Palette.warn : Palette.accent).opacity(0.8), radius: 4)
            Text(status).font(.mono(11.5)).foregroundStyle(Palette.dim).lineLimit(1)
            Spacer()
            switch tab {
            case .caches:
                if model.phase != .idle {
                    Button {
                        Task { await model.scan() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
                }
                Button {
                    model.confirming = true
                } label: {
                    Label(model.chosen.isEmpty ? "Sweep" : "Sweep \(ByteText.string(model.chosenBytes))",
                          systemImage: "wind")
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.chosen.isEmpty || model.isBusy || model.phase == .idle)
            case .disk:
                if map.markedCount > 0 {
                    Button("Clear marks") { map.marked = [:] }.buttonStyle(GhostButtonStyle())
                }
                Button {
                    map.confirming = true
                } label: {
                    Label(map.markedCount == 0 ? "Move to Trash" : "Move \(ByteText.string(map.markedBytes)) to Trash",
                          systemImage: "trash")
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(map.markedCount == 0 || map.phase != .done)
            case .duplicates:
                Button {
                    dup.confirming = true
                } label: {
                    Label(dup.marked.isEmpty ? "Move to Trash" : "Move \(ByteText.string(dup.markedBytes)) to Trash",
                          systemImage: "trash")
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(dup.marked.isEmpty || dup.phase != .done)
            case .apps:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var busy: Bool {
        switch tab {
        case .caches: return model.isBusy
        case .disk: return map.phase == .scanning || map.phase == .trashing
        case .duplicates: return dup.phase == .scanning || dup.phase == .trashing
        case .apps: return appsModel.phase == .scanning || appsModel.phase == .working
        }
    }

    private var status: String {
        switch tab {
        case .caches:
            switch model.phase {
            case .idle: return "Ready · nothing scanned yet"
            case .scanning: return "Scanning \(model.progressDone) of \(model.progressTotal) locations…"
            case .cleaning: return "Sweeping \(model.progressDone) of \(model.progressTotal)…"
            case .results, .done:
                return "\(model.targets.count) items · \(ByteText.string(model.reclaimableBytes)) sweepable · ⌘↩ to sweep"
            }
        case .disk:
            switch map.phase {
            case .idle: return "Map your home folder or the whole disk"
            case .scanning: return "Mapping… \(map.progress.files.formatted()) files · \(ByteText.string(map.progress.bytes))"
            case .trashing: return "Moving to Trash…"
            case .done:
                if let t = map.lastTrash {
                    return "Moved \(t.count) item(s), \(ByteText.string(t.bytes)), to Trash · empty the Trash to free it"
                        + (t.errors.isEmpty ? "" : " · \(t.errors.count) failed")
                }
                return "\(map.markedCount) marked · \(ByteText.string(map.markedBytes)) · double-click a folder to open it"
            }
        case .duplicates:
            switch dup.phase {
            case .idle: return "Pick folders, then Find duplicates"
            case .scanning: return "Comparing… \(dup.progress.files.formatted()) files"
            case .trashing: return "Moving to Trash…"
            case .done: return "\(dup.groups.count) groups · \(dup.marked.count) marked · \(ByteText.string(dup.markedBytes))"
            }
        case .apps:
            switch appsModel.phase {
            case .idle: return "Scan apps to see sizes, caches and leftovers"
            case .scanning: return "Measuring \(appsModel.progressDone) of \(appsModel.progressTotal) apps…"
            case .working: return "Working…"
            case .done:
                return "\(appsModel.apps.count) apps · \(ByteText.string(appsModel.apps.reduce(0) { $0 + $1.total })) · caches \(ByteText.string(appsModel.totalCaches))"
            }
        }
    }
}
