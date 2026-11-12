import AppKit
import SwiftUI

struct DevSDKView: View {
    @Environment(SDKModel.self) private var m
    @Environment(ReviewCenter.self) private var review

    var body: some View {
        @Bindable var m = m
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                // Sizes show when every chip fits; in narrower windows the chips drop their sizes
                // (still in the tooltip and VoiceOver), and only then scroll.
                ViewThatFits(in: .horizontal) {
                    chips(showSizes: true)
                    chips(showSizes: false)
                    ScrollView(.horizontal) { chips(showSizes: false) }.scrollIndicators(.never)
                }
                Spacer(minLength: Space.s)
                if m.phase == .done {
                    Button("Select unused") { m.selectUnused() }.buttonStyle(.bordered)
                    Button("None") { m.selected = [] }.buttonStyle(.bordered).disabled(m.selected.isEmpty)
                }
                Button { Task { await m.load() } } label: { Label(m.phase == .idle ? "Scan" : "Rescan", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.phase == .scanning || m.phase == .removing)
            }

            if let msg = m.message {
                MessageBar(text: msg.text, isError: msg.isError) { m.message = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                switch m.phase {
                case .idle:
                    EmptyState(symbol: "shippingbox", title: "Xcode, Android SDK and Docker",
                               text: "Simulator runtimes, device support files, Android system images, NDKs and Docker images. Items your projects or emulators still use are flagged.")
                case .scanning, .removing:
                    WorkingState(symbol: m.phase == .scanning ? "shippingbox" : "trash",
                                 title: m.phase == .scanning ? "Checking developer SDKs…" : "Removing…", detail: m.current)
                case .done:
                    if m.items.isEmpty {
                        EmptyState(symbol: "checkmark.seal", title: "Nothing here",
                                   text: m.filter == .docker ? (m.scan.dockerStatus ?? "No Docker data.") : "No SDK components found.")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                                ForEach(sections, id: \.0) { title, rows in
                                    Section {
                                        ForEach(Array(rows.enumerated()), id: \.1.id) { i, item in
                                            SDKRow(item: item).appearIn(i)
                                        }
                                    } header: {
                                        SectionHeader(title: title, bytes: rows.reduce(0) { $0 + $1.size })
                                    }
                                }
                                if m.filter != .docker, m.filter != .xcode, let note = usageNote {
                                    Text(note).font(.system(size: 11)).foregroundStyle(Palette.faint).padding(.horizontal, 12).padding(.top, 6)
                                }
                                if m.filter == nil || m.filter == .homebrew, let s = m.scan.brewStatus {
                                    Label(s, systemImage: "mug").font(.system(size: 12)).foregroundStyle(Palette.dim)
                                        .padding(.horizontal, 12).padding(.top, 10)
                                }
                                if m.filter == nil || m.filter == .docker, let s = m.scan.dockerStatus {
                                    Label(s, systemImage: "shippingbox").font(.system(size: 12)).foregroundStyle(Palette.dim)
                                        .padding(.horizontal, 12).padding(.top, 10)
                                }
                            }
                            .padding(10)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: m.phase)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()

            HStack {
                Text("Runtimes, images and SDK parts are deleted permanently: they can be downloaded again. Xcode archives go to the Trash.")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint)
                Spacer()
                Button { review.present(ReviewBuild.sdks(m) { items in Task { await m.remove(items) } }) } label: {
                    Label(m.selected.isEmpty ? "Remove" : "Remove \(ByteText.string(m.selectedBytes))", systemImage: "trash")
                        .contentTransition(.numericText())
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.selected.isEmpty || m.phase != .done)
                .animation(.snappy, value: m.selectedBytes)
            }
        }
        .animation(.snappy, value: m.message?.text)
        .task { if m.phase == .idle { await m.load() } }
    }

    private var sections: [(String, [SDKItem])] {
        var order: [String] = []
        var map: [String: [SDKItem]] = [:]
        for i in m.items {
            let key = m.filter == nil ? "\(i.group.rawValue) · \(i.kind)" : i.kind
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(i)
        }
        return order.map { ($0, map[$0]!.sorted { $0.size > $1.size }) }
    }

    private var usageNote: String? {
        let u = m.scan.usage
        guard u.filesRead > 0 || u.timedOut else { return nil }
        var s = "In-use flags come from \(u.filesRead) Gradle file(s) in your project folders"
        if let f = u.flutterCompileSdk { s += "; Flutter's defaults are API \(f)" + (u.flutterNdk.map { " and NDK \($0)" } ?? "") }
        if u.timedOut { s += ". Some folders didn't answer in time (a macOS permission prompt may be waiting)" }
        return s + "."
    }

    private var summary: String {
        let list = m.chosen
        var lines = list.prefix(14).map { "• \($0.name): \(ByteText.string($0.size))" + ($0.inUse.map { "  ⚠︎ \($0)" } ?? "") }
        if list.count > 14 { lines.append("• …and \(list.count - 14) more") }
        let used = list.filter { $0.inUse != nil }.count
        let review = list.filter(\.review).count
        var tail = "\n\nThey can be downloaded again (SDK Manager, Xcode › Components, docker pull)."
        if used > 0 { tail += "\n\(used) item(s) are still in use: the project or emulator will download or need them again." }
        if review > 0 { tail += "\n\(review) item(s) are marked REVIEW (archives, volumes or stopped containers hold data that can't be rebuilt)." }
        return lines.joined(separator: "\n") + tail
    }
}

extension DevSDKView {
    func chips(showSizes: Bool) -> some View {
        HStack(spacing: Space.s) {
            ForEach([nil] + SDKItem.Group.allCases.map(Optional.some), id: \.self) { g in
                GroupChip(group: g, bytes: m.total(g), selected: m.filter == g, showSize: showSizes) {
                    withAnimation(.snappy) { m.filter = g }
                }
                .accessibilityAddTraits(m.filter == g ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

private struct GroupChip: View {
    let group: SDKItem.Group?
    let bytes: Int64
    let selected: Bool
    var showSize = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(group?.rawValue ?? "All").font(.system(size: 13, weight: .semibold))
                if showSize {
                    RollingBytes(bytes: bytes, size: 12, weight: .medium).foregroundStyle(selected ? Color.white.opacity(0.85) : Palette.dim)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Palette.fg)
            .background(selected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Palette.fg.opacity(0.06)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(ByteText.string(bytes))
        .accessibilityValue(ByteText.string(bytes))
    }

    private var symbol: String {
        switch group {
        case .xcode: return "hammer"
        case .android: return "iphone.gen3"
        case .docker: return "shippingbox"
        case .languages: return "chevron.left.forwardslash.chevron.right"
        case .homebrew: return "mug"
        case nil: return "square.stack.3d.up"
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let bytes: Int64
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
            Spacer()
            Text(ByteText.string(bytes)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

private struct SDKRow: View {
    @Environment(SDKModel.self) private var m
    let item: SDKItem
    @State private var hover = false

    var body: some View {
        let on = m.selected.contains(item.id)
        HStack(spacing: 12) {
            if item.isProtected {
                Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(Palette.accent).frame(width: 18)
            } else {
                CheckSquare(on: on, color: Palette.accent)
            }
            IconTile(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let u = item.inUse { Tag(text: "IN USE", color: Palette.success).help(u) }
                    if let n = item.note { Tag(text: n.uppercased(), color: Palette.accent) }
                    if item.review { ReviewTag() }
                }
                Text([item.inUse, item.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("comes back with \(item.regen)").font(.system(size: 10.5)).foregroundStyle(Palette.faint).lineLimit(1)
                .frame(maxWidth: 260, alignment: .trailing)
            Text(ByteText.string(item.size)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            if let r = item.reveal {
                Button { NSWorkspace.shared.activateFileViewerSelecting([r]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).help("Reveal in Finder")
            } else {
                Color.clear.frame(width: 14)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(on ? Palette.selection.opacity(0.5) : hover ? Palette.fg.opacity(0.04) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { m.toggle(item) } }
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(item.isProtected ? "Protected" : on ? "Selected" : "Not selected")
        .accessibilityAction { m.toggle(item) }
        .help(SDKEngine.reason(item) ?? item.reveal?.path ?? item.name)
    }

    private var symbol: String {
        switch item.kind {
        case "Simulator runtimes": return "iphone"
        case "Device support": return "cable.connector"
        case "Archives": return "archivebox"
        case "System images": return "opticaldisc"
        case "Platforms": return "square.stack.3d.up"
        case "NDK": return "cpu"
        case "Build tools": return "wrench.and.screwdriver"
        case "Emulators": return "iphone.gen3"
        case "Homebrew formulae": return "terminal"
        case "Homebrew apps (casks)": return "app.badge"
        case "Homebrew cleanup": return "clock.arrow.circlepath"
        case "Java JDKs": return "cup.and.saucer"
        default: return item.group == .languages ? "chevron.left.forwardslash.chevron.right" : "shippingbox"
        }
    }

    private var color: Color {
        switch item.group {
        case .xcode: return Color(hex: 0x3A8DFF)
        case .android: return Color(hex: 0x7DC42F)
        case .docker: return Color(hex: 0x1D9BF0)
        case .languages: return Color(nsColor: .systemPurple)
        case .homebrew: return Color(nsColor: .systemOrange)
        }
    }
}
