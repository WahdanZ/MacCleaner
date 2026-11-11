import AppKit
import SwiftUI

extension DiskNode.Kind {
    var color: Color {
        switch self {
        case .folder: return Color(hex: 0x4EA8FF)
        case .app: return Color(hex: 0x22D3EE)
        case .video: return Color(hex: 0xFB7185)
        case .image: return Color(hex: 0xFBBF24)
        case .audio: return Color(hex: 0xA3E635)
        case .archive: return Color(hex: 0xA78BFA)
        case .document: return Color(hex: 0xF472B6)
        case .code: return Color(hex: 0x3DF5A7)
        case .other: return Color(hex: 0x94A3B8)
        case .small: return Palette.fg.opacity(0.35)
        }
    }

    var label: String {
        switch self {
        case .folder: return "Folder"
        case .app: return "App"
        case .video: return "Video"
        case .image: return "Image"
        case .audio: return "Audio"
        case .archive: return "Archive / disk image"
        case .document: return "Document"
        case .code: return "Code"
        case .other: return "File"
        case .small: return "Small files"
        }
    }
}

extension DiskNode {
    private static let folderShades: [Color] = [
        Color(hex: 0x4EA8FF), Color(hex: 0x6366F1), Color(hex: 0x38BDF8), Color(hex: 0x2DD4BF),
        Color(hex: 0x818CF8), Color(hex: 0x0EA5E9), Color(hex: 0x60A5FA), Color(hex: 0x7DD3FC),
    ]

    /// Folders get one of several blue/teal shades (stable per name) so neighbours stand apart.
    var tint: Color {
        guard kind == .folder else { return kind.color }
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return Self.folderShades[h % Self.folderShades.count]
    }
}

struct DiskMapView: View {
    @Environment(DiskMapModel.self) private var map

    var body: some View {
        switch map.phase {
        case .idle: DiskIdle()
        case .scanning: DiskScanning()
        case .done, .trashing:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Breadcrumbs()
                    DiskTreemap()
                    KindLegend()
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panel()
                DiskSidePanel()
                    .frame(width: 380)
                    .frame(maxHeight: .infinity)
                    .panel()
            }
        }
    }
}

// MARK: - Idle / scanning

private struct DiskIdle: View {
    @Environment(DiskMapModel.self) private var map

    var body: some View {
        @Bindable var map = map
        VStack(spacing: 18) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Palette.accent)
            Text("Where is my space going?").font(.system(size: 30, weight: .bold))
            Text("Measures every folder and file, including Documents, Downloads, Movies and Pictures.\nDrill into any folder, see the biggest items, then reveal them or move them to the Trash.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.dim)
            Picker("", selection: $map.rootChoice) {
                ForEach(DiskMapModel.RootChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Button {
                map.start()
            } label: {
                Label("Scan \(map.rootChoice == .home ? "home folder" : "whole disk")", systemImage: "scope")
            }
            .buttonStyle(AccentButtonStyle(large: true))
            .keyboardShortcut(.defaultAction)
            Text(map.rootChoice == .disk
                 ? "Whole disk includes system folders (view only). Grant Full Disk Access for complete numbers."
                 : "macOS may ask once for access to Desktop, Documents and Downloads.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel()
    }
}

private struct DiskScanning: View {
    @Environment(DiskMapModel.self) private var map

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MAPPING \(map.rootChoice == .home ? "HOME FOLDER" : "WHOLE DISK")")
                    .font(.mono(11, .bold)).foregroundStyle(Palette.accent)
                Spacer()
                Button("Cancel") { map.cancel() }.buttonStyle(GhostButtonStyle())
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(ByteText.string(map.progress.bytes))
                    .font(.mono(46, .bold))
                    .contentTransition(.numericText())
                Text("in \(map.progress.files.formatted()) files").foregroundStyle(Palette.dim)
            }
            .animation(.snappy, value: map.progress.files)
            ProgressView().progressViewStyle(.linear).tint(Palette.accent)
            Text(Scanner.tilde(URL(fileURLWithPath: map.progress.current)))
                .font(.mono(11.5)).foregroundStyle(Palette.faint)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel()
    }
}

// MARK: - Map side

private struct Breadcrumbs: View {
    @Environment(DiskMapModel.self) private var map

    var body: some View {
        let _ = map.revision
        HStack(spacing: 6) {
            Button { map.up() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(GhostButtonStyle())
                .disabled(map.current?.parent == nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Up one folder (⌘↑)")
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(map.breadcrumb) { n in
                        Button { map.open(n) } label: {
                            Text(n.name).font(.mono(11.5, n === map.current ? .bold : .regular))
                                .foregroundStyle(n === map.current ? Palette.fg : Palette.dim)
                        }
                        .buttonStyle(.plain)
                        if n !== map.current {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Palette.faint)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 8)
            if let c = map.current {
                Text(ByteText.string(c.size)).font(.mono(13, .bold))
                Text("· \(c.fileCount.formatted()) files").font(.mono(11)).foregroundStyle(Palette.faint)
            }
            Button { map.start() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(GhostButtonStyle())
                .help("Rescan")
        }
    }
}

private struct DiskTreemap: View {
    @Environment(DiskMapModel.self) private var map
    @State private var hovered: String?

    var body: some View {
        let _ = map.revision
        GeometryReader { geo in
            let all = (map.current?.children ?? []).filter { $0.size > 0 }
            let total = all.reduce(Int64(0)) { $0 + $1.size }
            // Blocks for items ≥ 0.4% of this folder (max 120); everything smaller becomes one grey block.
            let shown = Array(all.prefix { Double($0.size) >= Double(total) * 0.004 }.prefix(120))
            let rest = all.dropFirst(shown.count)
            let restBytes = rest.reduce(Int64(0)) { $0 + $1.size }
            let values = shown.map { Double($0.size) } + (restBytes > 0 ? [Double(restBytes)] : [])
            let order = values.indices.sorted { values[$0] > values[$1] }
            let sortedRects = Treemap.layout(order.map { values[$0] }, in: CGRect(origin: .zero, size: geo.size))
            let rects = Dictionary(uniqueKeysWithValues: zip(order, sortedRects))
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, n in
                    let r = Treemap.inset(rects[i] ?? .zero, 2)
                    DiskBlock(node: n, size: r.size, hovered: hovered == n.id,
                              selected: map.selected === n, marked: map.marked[n.id] != nil)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .onTapGesture(count: 2) { map.open(n) }
                        .onTapGesture { map.selected = n }
                        .onHover { inside in
                            if inside { hovered = n.id } else if hovered == n.id { hovered = nil }
                        }
                        .help("\(n.name) — \(ByteText.string(n.size))\n\(n.tildePath)\n\(n.canOpen ? "Double-click to open" : "")")
                }
                if restBytes > 0, let rr = rects[shown.count] {
                    let r = Treemap.inset(rr, 2)
                    RestBlock(count: rest.count, bytes: restBytes, size: r.size)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .help("\(rest.count) smaller items, \(ByteText.string(restBytes)) in total. They are all in the list on the right.")
                }
            }
        }
        .overlay {
            if map.current?.children.isEmpty ?? true {
                Text(map.current?.unreadable == true ? "No permission to read this folder" : "Empty folder")
                    .foregroundStyle(Palette.faint)
            }
        }
    }
}

private struct RestBlock: View {
    let count: Int
    let bytes: Int64
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.fg.opacity(0.07))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.fg.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if size.width > 70 && size.height > 34 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) smaller items").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(ByteText.string(bytes)).font(.mono(10, .medium)).opacity(0.8)
                }
                .foregroundStyle(Palette.dim)
                .padding(8)
            }
        }
    }
}

private struct DiskBlock: View {
    let node: DiskNode
    let size: CGSize
    let hovered: Bool
    let selected: Bool
    let marked: Bool

    var body: some View {
        let c = node.tint
        let big = size.width > 150 && size.height > 60
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [c.opacity(hovered ? 0.95 : 0.8), c.opacity(hovered ? 0.7 : 0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(marked ? Palette.danger : selected ? Palette.fg : Palette.fg.opacity(0.1),
                              style: StrokeStyle(lineWidth: marked || selected ? 2.5 : 1, dash: marked ? [5, 3] : []))
            if size.width > 56 && size.height > 32 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if node.isDirectory && !node.isAggregate {
                            Image(systemName: "folder.fill").font(.system(size: big ? 11 : 9))
                        }
                        Text(node.name).font(.system(size: big ? 13 : 11, weight: .semibold)).lineLimit(1)
                    }
                    Text(ByteText.string(node.size)).font(.mono(big ? 12 : 10, .medium)).opacity(0.85)
                }
                .foregroundStyle(Color.black.opacity(0.8))
                .padding(8)
            }
            if marked && size.width > 30 && size.height > 30 {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.danger, .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(5)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct KindLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([DiskNode.Kind.folder, .app, .video, .image, .audio, .archive, .document, .code, .other, .small],
                    id: \.self) { k in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(k.color).frame(width: 9, height: 9)
                    Text(k.label).font(.system(size: 10.5)).foregroundStyle(Palette.dim)
                }
            }
            Spacer()
            Text("click = details · double-click = open folder").font(.mono(10)).foregroundStyle(Palette.faint)
        }
    }
}

// MARK: - Side panel: details + outline

private struct DiskSidePanel: View {
    @Environment(DiskMapModel.self) private var map
    @AppStorage("diskSort") private var sortByName = false

    private struct Row: Identifiable {
        let node: DiskNode
        let depth: Int
        var id: String { node.id }
    }

    private func rows() -> [Row] {
        var out: [Row] = []
        func walk(_ n: DiskNode, _ depth: Int) {
            var kids = n.children.filter { $0.size > 0 }
            if sortByName { kids.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
            for k in kids.prefix(300) {
                out.append(Row(node: k, depth: depth))
                if map.expanded.contains(k.id) && k.isDirectory && !k.isAggregate { walk(k, depth + 1) }
            }
        }
        if let c = map.current { walk(c, 0) }
        return out
    }

    var body: some View {
        let _ = map.revision
        VStack(alignment: .leading, spacing: 0) {
            DetailCard(node: map.selected ?? map.current)
                .padding(14)
            Rectangle().fill(Palette.stroke).frame(height: 1)
            HStack(spacing: 8) {
                Text("CONTENTS").font(.mono(10, .semibold)).foregroundStyle(Palette.faint)
                Spacer()
                Picker("", selection: $sortByName) {
                    Text("Size").tag(false)
                    Text("Name").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                Button {
                    if map.expanded.isEmpty {
                        map.expanded = Set((map.current?.children ?? []).filter(\.isDirectory).map(\.id))
                    } else {
                        map.expanded = []
                    }
                } label: {
                    Image(systemName: map.expanded.isEmpty ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .buttonStyle(GhostButtonStyle())
                .help(map.expanded.isEmpty ? "Expand all" : "Collapse all")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows()) { r in OutlineRow(node: r.node, depth: r.depth) }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct DetailCard: View {
    @Environment(DiskMapModel.self) private var map
    let node: DiskNode?

    var body: some View {
        if let n = node {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: n.url.path))
                        .resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        Text(n.tildePath).font(.mono(10.5)).foregroundStyle(Palette.faint)
                            .lineLimit(1).truncationMode(.middle).help(n.url.path)
                    }
                }
                HStack(spacing: 18) {
                    stat("SIZE", ByteText.string(n.size))
                    stat("FILES", n.fileCount.formatted())
                    stat("KIND", n.kind.label)
                    if let m = n.modified { stat("MODIFIED", m.formatted(date: .abbreviated, time: .omitted)) }
                }
                HStack(spacing: 6) {
                    Button { map.reveal(n) } label: { Label("Reveal", systemImage: "magnifyingglass") }
                    if n.canOpen && n !== map.current {
                        Button { map.open(n) } label: { Label("Open", systemImage: "arrow.down.right.square") }
                    }
                    if !n.isAggregate && n !== map.root && !TrashGuard.structural.contains(n.url.standardizedFileURL.path) {
                        let isProtected = ProtectedPaths.all.contains(ProtectedPaths.normalize(n.url.path))
                        Button {
                            if isProtected { ProtectedPaths.remove(n.url.path) } else {
                                ProtectedPaths.add([n.url])
                                map.marked[n.id] = nil
                            }
                            map.revision += 1
                        } label: {
                            Label(isProtected ? "Unprotect" : "Protect", systemImage: isProtected ? "lock.open" : "lock")
                        }
                        .help(isProtected ? "Allow cleaning this again" : "Never clean, trash or shred this")
                    }
                    if !n.isAggregate && n !== map.root {
                        let blocked = TrashGuard.reason(n.url)
                        Button { map.toggleMark(n) } label: {
                            Label(map.marked[n.id] != nil ? "Unmark" : "Mark for Trash", systemImage: "trash")
                        }
                        .disabled(blocked != nil)
                        .help(blocked ?? "Add to the Move to Trash list")
                    }
                }
                .buttonStyle(GhostButtonStyle())
                if let why = TrashGuard.reason(n.url), !n.isAggregate, n !== map.root {
                    Label(why, systemImage: "lock.fill").font(.system(size: 10.5)).foregroundStyle(Palette.faint)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.mono(9, .semibold)).foregroundStyle(Palette.faint)
            Text(value).font(.mono(12, .semibold))
        }
    }
}

private struct OutlineRow: View {
    @Environment(DiskMapModel.self) private var map
    let node: DiskNode
    let depth: Int
    @State private var hover = false

    var body: some View {
        let parentSize = max(node.parent?.size ?? 1, 1)
        let canTrash = !node.isAggregate && TrashGuard.canTrash(node.url)
        let isMarked = map.marked[node.id] != nil
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            if node.isDirectory && !node.isAggregate {
                Button { map.toggleExpanded(node) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(map.expanded.contains(node.id) ? 90 : 0))
                        .foregroundStyle(Palette.dim)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Button { map.toggleMark(node) } label: {
                CheckSquare(on: isMarked, color: Palette.danger)
                    .opacity(canTrash ? 1 : 0.25)
            }
            .buttonStyle(.plain)
            .disabled(!canTrash)
            .help(canTrash ? "Mark for Trash" : (TrashGuard.reason(node.url) ?? "Can't trash"))
            RoundedRectangle(cornerRadius: 2).fill(node.tint).frame(width: 8, height: 8)
            Text(node.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            GeometryReader { g in
                Capsule().fill(Palette.fg.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(node.tint.opacity(0.8))
                            .frame(width: g.size.width * CGFloat(Double(node.size) / Double(parentSize)))
                    }
            }
            .frame(width: 44, height: 4)
            Text(ByteText.string(node.size)).font(.mono(11, .medium))
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background((map.selected === node ? Palette.fg.opacity(0.1) : hover ? Palette.fg.opacity(0.05) : .clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { map.open(node) }
        .onTapGesture { map.selected = node }
        .onHover { hover = $0 }
        .help(node.tildePath)
    }
}
