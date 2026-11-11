import AppKit
import SwiftUI

struct DuplicatesView: View {
    @Environment(DupFinder.self) private var dup

    var body: some View {
        @Bindable var dup = dup
        let busy = dup.phase == .scanning || dup.phase == .trashing
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("DUPLICATES").font(.mono(11, .bold)).foregroundStyle(Palette.accent)
                Text("identical content (SHA-256), not just the same name")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                Spacer()
            }

            // Folders
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach($dup.roots) { $r in
                        Button { r.on.toggle() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: r.on ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                                Text(r.url.lastPathComponent).font(.system(size: 11.5, weight: .medium))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Palette.accent.opacity(r.on ? 0.14 : 0.03), in: Capsule())
                            .overlay(Capsule().strokeBorder(r.on ? Palette.accent.opacity(0.5) : Palette.stroke))
                            .foregroundStyle(r.on ? Palette.fg : Palette.dim)
                        }
                        .buttonStyle(.plain)
                        .help(r.url.path)
                    }
                    Button { dup.addFolder() } label: { Label("Add folder", systemImage: "plus") }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .scrollIndicators(.never)
            .disabled(busy)

            HStack(spacing: 10) {
                Text("MIN SIZE").font(.mono(10, .semibold)).foregroundStyle(Palette.faint)
                Picker("", selection: $dup.minSize) {
                    Text("100 KB").tag(Int64(100_000))
                    Text("1 MB").tag(Int64(1_000_000))
                    Text("10 MB").tag(Int64(10_000_000))
                    Text("100 MB").tag(Int64(100_000_000))
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                .disabled(busy)
                Spacer()
                if dup.phase == .scanning {
                    Button("Cancel") { dup.cancel() }.buttonStyle(GhostButtonStyle())
                } else {
                    Button { dup.start() } label: {
                        Label(dup.phase == .idle ? "Find duplicates" : "Scan again", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!dup.roots.contains(where: \.on) || busy)
                }
            }

            Rectangle().fill(Palette.stroke).frame(height: 1)

            switch dup.phase {
            case .idle: idle
            case .scanning: scanning
            case .done, .trashing: results
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var idle: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc").font(.system(size: 44, weight: .light)).foregroundStyle(Palette.accent)
            Text("Find identical files").font(.system(size: 24, weight: .bold))
            Text("Compares file contents, so renamed copies are found too. Hard links and iCloud files that are not downloaded are skipped.\nDeleting moves copies to the Trash and always keeps at least one.")
                .multilineTextAlignment(.center).foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(dup.progress.files.formatted()).font(.mono(44, .bold)).contentTransition(.numericText())
                Text("files checked").foregroundStyle(Palette.dim)
            }
            .animation(.snappy, value: dup.progress.files)
            Text("\(dup.progress.candidates.formatted()) same-size candidates · \(dup.progress.hashed.formatted()) compared")
                .font(.mono(12)).foregroundStyle(Palette.dim)
            ProgressView().progressViewStyle(.linear).tint(Palette.accent)
            Text(Scanner.tilde(URL(fileURLWithPath: dup.progress.current)))
                .font(.mono(11)).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
    }

    @ViewBuilder private var results: some View {
        if let t = dup.lastTrash {
            HStack(spacing: 8) {
                Image(systemName: t.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(t.errors.isEmpty ? Palette.accent : Palette.warn)
                Text("Moved \(t.count) file(s), \(ByteText.string(t.bytes)), to the Trash. Empty the Trash to free the space.")
                    .font(.system(size: 12))
                if !t.errors.isEmpty {
                    Text(t.errors.prefix(2).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Palette.danger)
                        .lineLimit(1)
                }
                Spacer()
                Button { dup.lastTrash = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(10)
            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        if dup.groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(Palette.accent)
                Text("No duplicates found").font(.system(size: 20, weight: .bold))
                Text("Nothing identical at or above \(ByteText.string(dup.minSize)).").foregroundStyle(Palette.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ByteText.string(dup.wasted)).font(.mono(30, .bold)).foregroundStyle(Palette.accent)
                Text("in extra copies · \(dup.groups.count) groups").foregroundStyle(Palette.dim)
                Spacer()
                Button("Keep oldest, mark the rest") { dup.markExtraCopies() }
                Button("Clear marks") { dup.marked = [] }.disabled(dup.marked.isEmpty)
                Button(dup.expanded.isEmpty ? "Expand all" : "Collapse all") {
                    dup.expanded = dup.expanded.isEmpty ? Set(dup.groups.map(\.id)) : []
                }
            }
            .buttonStyle(GhostButtonStyle())
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(dup.groups.prefix(1500)) { g in GroupRow(group: g) }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct GroupRow: View {
    @Environment(DupFinder.self) private var dup
    let group: DupGroup

    var body: some View {
        let open = dup.expanded.contains(group.id)
        let markedHere = group.files.filter { dup.marked.contains($0) }.count
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { dup.expanded.remove(group.id) } else { dup.expanded.insert(group.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Palette.dim)
                        .frame(width: 10)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: group.files[0].path))
                        .resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.files[0].lastPathComponent).font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(group.files.count) copies × \(ByteText.string(group.size))"
                             + (markedHere > 0 ? " · \(markedHere) marked" : ""))
                            .font(.system(size: 10.5)).foregroundStyle(markedHere > 0 ? Palette.danger : Palette.faint)
                    }
                    Spacer()
                    Text(ByteText.string(group.wasted)).font(.mono(12, .semibold)).foregroundStyle(Palette.accent)
                    Text("extra").font(.system(size: 10)).foregroundStyle(Palette.faint)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.files, id: \.self) { f in
                        let isMarked = dup.marked.contains(f)
                        let blocked = TrashGuard.reason(f)
                        HStack(spacing: 8) {
                            Button { dup.toggle(f, in: group) } label: {
                                if ProtectedPaths.isBlocked(f) {
                                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(Palette.accent).frame(width: 18)
                                } else {
                                    CheckSquare(on: isMarked, color: Palette.danger).opacity(blocked == nil ? 1 : 0.25)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(blocked != nil)
                            .help(blocked ?? "Mark this copy for the Trash (one copy always stays)")
                            Text(Scanner.tilde(f)).font(.mono(11))
                                .foregroundStyle(isMarked ? Palette.danger : Palette.dim)
                                .strikethrough(isMarked)
                                .lineLimit(1).truncationMode(.middle)
                                .help(f.path)
                            Spacer()
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                                .buttonStyle(GhostButtonStyle())
                        }
                        .padding(.horizontal, 12).padding(.vertical, 3)
                    }
                }
                .padding(.leading, 34).padding(.bottom, 8)
            }
        }
        .background(Palette.fg.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(markedHere > 0 ? Palette.danger.opacity(0.4) : Palette.stroke))
    }
}
