import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ShredEngine {
    /// Overwrites a regular file with zeros (up to 4 GB) and syncs it to disk.
    static func overwrite(_ url: URL) {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
              v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size > 0, size <= 4_000_000_000,
              let h = try? FileHandle(forUpdating: url) else { return }
        defer { try? h.close() }
        let chunk = Data(count: 1 << 20)
        var left = size
        try? h.seek(toOffset: 0)
        while left > 0 {
            let n = min(left, chunk.count)
            try? h.write(contentsOf: chunk.prefix(n))
            left -= n
        }
        try? h.synchronize()
    }

    /// Overwrites every file (folders: recursively), then deletes permanently.
    static func shred(_ url: URL) -> String? {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        if let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           v.isDirectory == true, v.isSymbolicLink != true {
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: [], errorHandler: { _, _ in true })
            while let f = e?.nextObject() as? URL { overwrite(f) }
        } else {
            overwrite(url)
        }
        do { try FileManager.default.removeItem(at: url); return nil }
        catch { return error.localizedDescription }
    }
}

@MainActor @Observable
final class ShredderModel {
    struct Item: Identifiable { let id: String; let url: URL; let size: Int64; let blocked: String? }

    var items: [Item] = []
    var confirming = false
    var working = false
    var message: (text: String, isError: Bool)?
    var dropTargeted = false

    var ready: [Item] { items.filter { $0.blocked == nil } }
    var total: Int64 { ready.reduce(0) { $0 + $1.size } }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(where: { $0.url == u }) {
            items.append(Item(id: u.path, url: u, size: Scanner.allocatedSize(u), blocked: TrashGuard.reason(u)))
        }
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Add to Shredder"
        if p.runModal() == .OK { add(p.urls) }
    }

    func shred() async {
        let list = ready
        guard !list.isEmpty else { return }
        working = true
        var bytes: Int64 = 0, errors: [String] = []
        for i in list {
            let u = i.url
            if let e = await Task.detached(operation: { ShredEngine.shred(u) }).value {
                errors.append("\(u.lastPathComponent): \(e)")
            } else {
                bytes += i.size
                items.removeAll { $0.id == i.id }
            }
        }
        HistoryStore.shared.add("Files Shredded", bytes: bytes, symbol: "printer", outcome: .deleted)
        message = errors.isEmpty ? ("Shredded \(ByteText.string(bytes)).", false)
                                 : ("Shredded \(ByteText.string(bytes)). \(errors.count) problem(s): \(errors.prefix(2).joined(separator: "; "))", true)
        working = false
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
                            .buttonStyle(.borderedProminent)
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
                                    Text(ByteText.string(i.size)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                    Button { m.items.removeAll { $0.id == i.id } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).foregroundStyle(Palette.faint)
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
                m.add(urls)
                return !urls.isEmpty
            } isTargeted: { m.dropTargeted = $0 }

            HStack {
                Text("On SSDs, macOS may keep old copies of blocks, so overwriting can't guarantee recovery is impossible. FileVault encryption is the real protection.")
                    .font(.caption).foregroundStyle(Palette.dim).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !m.items.isEmpty {
                    Button("Add more…") { m.choose() }.buttonStyle(.bordered)
                }
                Button { review.present(ReviewBuild.shred(m.items) { Task { await m.shred() } }) } label: {
                    Label(m.ready.isEmpty ? "Shred" : "Shred \(ByteText.string(m.total))", systemImage: "flame")
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.ready.isEmpty || m.working)
            }
        }
    }
}
