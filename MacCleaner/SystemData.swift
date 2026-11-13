import AppKit
import Observation
import SwiftUI

// Phase 4: the parts of "System Data" a user can actually do something about.

struct SysItem: Identifiable, Sendable, Hashable {
    enum Section: String, CaseIterable, Sendable {
        case snapshots = "Time Machine snapshots", backups = "iPhone & iPad backups"
        case messages = "Messages attachments", mail = "Mail"
    }
    enum Action: Sendable, Hashable { case snapshot(String), trash(URL), none }

    let id: String
    let section: Section
    let name: String
    let detail: String
    let size: Int64?
    let reveal: URL?
    let action: Action
    var review = false
    var needsPassword = false
}

struct SysReport: Sendable {
    var items: [SysItem] = []
    var needsFDA: Set<SysItem.Section> = []
    var totals: [SysItem.Section: Int64] = [:]
    var snapshotCount = 0
    var purgeable: Int64 = 0
    var swap: Int64 = 0
    var mailTotal: Int64 = 0
    var messagesTotal: Int64 = 0
}

enum SystemDataEngine {
    static let home = SafetyGuard.home
    static let backups = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
    static let messages = home.appendingPathComponent("Library/Messages/Attachments")
    static let mail = home.appendingPathComponent("Library/Mail")
    static let mailDownloads = home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
    private static let fm = FileManager.default

    static func scan(largestAttachments: Int = 60) -> SysReport {
        var r = SysReport()

        // Time Machine local snapshots
        let snaps = snapshotDates()
        r.snapshotCount = snaps.count
        for d in snaps {
            r.items.append(SysItem(id: "snap.\(d)", section: .snapshots, name: "Snapshot \(prettySnapshot(d))",
                                   detail: "Local Time Machine snapshot. macOS removes these by itself when space runs low.",
                                   size: nil, reveal: nil, action: .snapshot(d), needsPassword: true))
        }

        // iPhone / iPad backups
        do {
            let kids = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            for b in kids where !b.lastPathComponent.hasPrefix(".") {
                let info = NSDictionary(contentsOf: b.appendingPathComponent("Info.plist"))
                let device = info?["Device Name"] as? String ?? info?["Display Name"] as? String ?? "Unknown device"
                let product = info?["Product Name"] as? String ?? info?["Product Type"] as? String ?? ""
                let os = info?["Product Version"] as? String
                let date = info?["Last Backup Date"] as? Date
                let size = Scanner.allocatedSize(b)
                r.totals[.backups, default: 0] += size
                r.items.append(SysItem(id: b.path, section: .backups, name: device,
                                       detail: [product, os.map { "iOS \($0)" }, date.map { "backed up " + $0.formatted(date: .abbreviated, time: .omitted) }]
                                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                       size: size, reveal: b, action: .trash(b), review: true))
            }
        } catch {
            if fm.fileExists(atPath: backups.deletingLastPathComponent().path) || isPermission(error) { r.needsFDA.insert(.backups) }
        }

        // Messages attachments: total + the largest files
        if let e = fm.enumerator(at: messages, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey],
                                 options: [], errorHandler: { _, err in if isPermission(err) { r.needsFDA.insert(.messages) }; return true }) {
            var files: [(URL, Int64, Date?)] = []
            for case let u as URL in e {
                guard let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]),
                      v.isRegularFile == true else { continue }
                let s = Int64(v.totalFileAllocatedSize ?? 0)
                r.messagesTotal += s
                files.append((u, s, v.contentModificationDate))
            }
            for (u, s, d) in files.sorted(by: { $0.1 > $1.1 }).prefix(largestAttachments) where s > 0 {
                r.items.append(SysItem(id: u.path, section: .messages, name: u.lastPathComponent,
                                       detail: (d.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "") + " · Messages will show it as unavailable",
                                       size: s, reveal: u, action: .trash(u), review: true))
            }
            r.totals[.messages] = files.prefix(largestAttachments).reduce(0) { $0 + $1.1 }
        }
        if !fm.isReadableFile(atPath: messages.path), fm.fileExists(atPath: messages.deletingLastPathComponent().path) {
            r.needsFDA.insert(.messages)
        }

        // Mail: total (view only) + opened attachments (safe to remove)
        if (try? fm.contentsOfDirectory(atPath: mail.path)) != nil {
            r.mailTotal = Scanner.allocatedSize(mail)
            r.items.append(SysItem(id: mail.path, section: .mail, name: "Mail mailboxes",
                                   detail: "Your email and its attachments. Remove big attachments in Mail: select a message › Message › Remove Attachments.",
                                   size: r.mailTotal, reveal: mail, action: .none))
        } else if fm.fileExists(atPath: mail.path) {
            r.needsFDA.insert(.mail)
        }
        for d in (try? fm.contentsOfDirectory(at: mailDownloads, includingPropertiesForKeys: nil)) ?? [] where !d.lastPathComponent.hasPrefix(".") {
            let s = Scanner.allocatedSize(d)
            guard s > 0 else { continue }
            let first = (try? fm.contentsOfDirectory(atPath: d.path))?.first { !$0.hasPrefix(".") }
            r.items.append(SysItem(id: d.path, section: .mail, name: first ?? d.lastPathComponent,
                                   detail: "Attachment you opened from Mail (a copy; the email keeps the original)",
                                   size: s, reveal: d, action: .trash(d)))
        }
        r.totals[.mail] = r.items.filter { $0.section == .mail }.reduce(0) { $0 + ($1.size ?? 0) }

        // Purgeable space and swap (information only)
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let a = v.volumeAvailableCapacity, let imp = v.volumeAvailableCapacityForImportantUsage {
            r.purgeable = max(0, imp - Int64(a))
        }
        if let out = Shell.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"], timeout: 5).output,
           let used = out.range(of: #"used = ([\d.]+)M"#, options: .regularExpression) {
            let n = out[used].replacingOccurrences(of: "used = ", with: "").replacingOccurrences(of: "M", with: "")
            r.swap = Int64((Double(n) ?? 0) * 1_048_576)
        }
        return r
    }

    static func isPermission(_ e: Error) -> Bool {
        let ns = e as NSError
        return ns.code == NSFileReadNoPermissionError || (ns.underlyingErrors.first as NSError?)?.code == Int(EPERM)
            || ns.code == Int(EPERM) || ns.code == Int(EACCES)
    }

    /// "2026-11-10-101530" for each com.apple.TimeMachine.<date>.local snapshot.
    static func snapshotDates() -> [String] {
        let out = Shell.run("/usr/bin/tmutil", ["listlocalsnapshotdates", "/"], timeout: 15).output ?? ""
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) != nil }
    }

    static func prettySnapshot(_ d: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: d)?.formatted(date: .abbreviated, time: .shortened) ?? d
    }

    static func reason(_ i: SysItem) -> String? {
        switch i.action {
        case .none: return "View only"
        case .snapshot(let d): return d.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#, options: .regularExpression) == nil ? "Bad snapshot date" : nil
        case .trash(let u): return TrashGuard.reason(u)
        }
    }

    /// Snapshots need one password prompt (tmutil runs as admin); everything else goes to the Trash.
    /// `bytes` = total; `freed` = the free-space change after deleting snapshots (they have no size up front).
    /// Trash items move only through `trash`, the approval given at the review sheet or the MCP/CLI confirm for
    /// exactly the items it showed (never made here); without it they stay and say so.
    static func remove(_ items: [SysItem], trash: TrashApproval? = nil, trashSource: String = "System Data")
        -> (bytes: Int64, freed: Int64, errors: [String], cancelled: Bool) {
        SizeCache.clear(); defer { SizeCache.clear() }   // sizes measured before this are out of date
        var bytes: Int64 = 0, freed: Int64 = 0, errors: [String] = [], cancelled = false
        let snaps = items.compactMap { i -> String? in if case .snapshot(let d) = i.action, reason(i) == nil { return d }; return nil }
        if !snaps.isEmpty {
            let before = Scanner.freeBytes()
            let script = snaps.map { "/usr/bin/tmutil deletelocalsnapshots \($0)" }.joined(separator: "; ")
            let r = Shell.run("/usr/bin/osascript", ["-e", "do shell script \"\(script)\" with administrator privileges"], timeout: 900)
            if r.status != 0 {
                let out = r.output ?? ""
                if out.contains("-128") { cancelled = true } else { errors.append("Snapshots: \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
            } else {
                freed = max(0, Scanner.freeBytes() - before)
                bytes += freed
            }
        }
        let trashItems = items.filter { if case .trash = $0.action { return true }; return false }
        let t = AppCleanup.engineTrash(trashItems.map { ($0.id, $0.name) }, trash, source: trashSource)
        for i in trashItems where t.moved[i.id] != nil { bytes += i.size ?? 0 }
        errors += t.errors
        return (bytes, freed, errors, cancelled)
    }
}

@MainActor @Observable
final class SystemDataModel {
    var report = SysReport()
    var loaded = false
    var busy = false
    var selected: Set<String> = []
    var confirming = false
    var message: (text: String, isError: Bool)?

    var chosen: [SysItem] { report.items.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { chosen.reduce(0) { $0 + ($1.size ?? 0) } }

    func load() async {
        busy = true
        report = await Task.detached(priority: .userInitiated) { SystemDataEngine.scan() }.value
        selected = selected.filter { id in report.items.contains { $0.id == id } }
        loaded = true
        busy = false
    }

    func toggle(_ i: SysItem) {
        guard SystemDataEngine.reason(i) == nil else { return }
        if selected.contains(i.id) { selected.remove(i.id) } else { selected.insert(i.id) }
    }

    /// Removes exactly the reviewed items.
    func remove(_ list: [SysItem], _ trash: TrashApproval?) async {
        guard !list.isEmpty else { return }
        busy = true
        let r = await Task.detached { SystemDataEngine.remove(list, trash: trash) }.value
        HistoryStore.shared.add("Snapshots Deleted", bytes: r.freed, symbol: "clock.arrow.circlepath",
                                outcome: .deleted, measuredFreeChange: r.freed)
        HistoryStore.shared.add("System Data Moved to Trash", bytes: r.bytes - r.freed, symbol: "internaldrive", outcome: .trashed)
        if r.cancelled && r.errors.isEmpty { message = ("Snapshots kept (password prompt cancelled). Other items: \(ByteText.string(r.bytes)) to the Trash.", false) }
        else if r.errors.isEmpty { message = ("Done: \(ByteText.string(r.bytes)). Items moved to the Trash can be put back until you empty it.", false) }
        else { message = ("\(ByteText.string(r.bytes)) done. \(r.errors.count) problem(s): \(r.errors.prefix(2).joined(separator: "; "))", true) }
        selected = []
        await load()
    }
}

// MARK: - View

struct SystemDataView: View {
    @Environment(SystemDataModel.self) private var m
    @Environment(ReviewCenter.self) private var review
    @State private var open: Set<SysItem.Section> = Set(SysItem.Section.allCases)

    var body: some View {
        @Bindable var m = m
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                SummaryCard(symbol: "clock.arrow.circlepath", color: Color(hex: 0x14B8C8), title: "Snapshots",
                            value: m.report.snapshotCount == 0 ? "None" : "\(m.report.snapshotCount)",
                            sub: "local Time Machine").appearIn(0)
                SummaryCard(symbol: "iphone", color: Palette.accent, title: "Device backups",
                            value: m.report.needsFDA.contains(.backups) ? "Locked" : ByteText.string(m.report.totals[.backups] ?? 0),
                            sub: m.report.needsFDA.contains(.backups) ? "needs Full Disk Access" : "iPhone & iPad").appearIn(1)
                SummaryCard(symbol: "message", color: Palette.success, title: "Messages",
                            value: m.report.needsFDA.contains(.messages) ? "Locked" : ByteText.string(m.report.messagesTotal),
                            sub: m.report.needsFDA.contains(.messages) ? "needs Full Disk Access" : "attachments").appearIn(2)
                SummaryCard(symbol: "envelope", color: Color(hex: 0xF0559C), title: "Mail",
                            value: m.report.needsFDA.contains(.mail) ? "Locked" : ByteText.string(m.report.mailTotal),
                            sub: m.report.needsFDA.contains(.mail) ? "needs Full Disk Access" : "mailboxes").appearIn(3)
                SummaryCard(symbol: "sparkles", color: Palette.other, title: "Purgeable",
                            value: ByteText.string(m.report.purgeable), sub: "macOS frees it by itself").appearIn(4)
            }
            .redacted(reason: m.loaded ? [] : .placeholder)

            if let msg = m.message { MessageBar(text: msg.text, isError: msg.isError) { m.message = nil }.transition(.opacity) }

            Group {
                if !m.loaded {
                    WorkingState(symbol: "internaldrive", title: "Looking inside System Data…", detail: "snapshots, backups, Mail, Messages")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(SysItem.Section.allCases, id: \.self) { s in
                                sectionView(s)
                            }
                            Text("Also in System Data: swap \(ByteText.string(m.report.swap)) (memory overflow, freed on restart), caches and logs (see Junk Files) and developer data (see Developer SDKs).")
                                .font(.system(size: 11)).foregroundStyle(Palette.faint).padding(.horizontal, 12).padding(.top, 10)
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()

            HStack {
                Text("Backups and attachments go to the Trash (REVIEW: they can't be rebuilt). Snapshots ask for your password.")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint)
                Spacer()
                Button { Task { await m.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).disabled(m.busy)
                Button { review.present(ReviewBuild.systemData(m) { items, trash in Task { await m.remove(items, trash) } }) } label: {
                    Label(m.selected.isEmpty ? "Remove" : "Remove \(ByteText.string(m.selectedBytes))", systemImage: "trash")
                        .contentTransition(.numericText())
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.selected.isEmpty || m.busy)
                .animation(.snappy, value: m.selectedBytes)
            }
        }
        .animation(.snappy, value: m.loaded)
        .task { if !m.loaded { await m.load() } }
    }

    @ViewBuilder private func sectionView(_ s: SysItem.Section) -> some View {
        let rows = m.report.items.filter { $0.section == s }
        let isOpen = open.contains(s)
        Button {
            withAnimation(.snappy) { if isOpen { open.remove(s) } else { open.insert(s) } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(Palette.dim)
                Text(s.rawValue.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
                Spacer()
                if let t = m.report.totals[s], t > 0 {
                    Text(ByteText.string(t)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if isOpen {
            if m.report.needsFDA.contains(s) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield").foregroundStyle(Palette.warn)
                    Text("macOS only lets apps with Full Disk Access look here. Grant it in System Settings › Privacy & Security, then reopen Mac Cleaner.")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                    Spacer()
                    Button("Open settings") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .transition(.opacity)
            } else if rows.isEmpty {
                Text(empty(s)).font(.system(size: 12)).foregroundStyle(Palette.faint).padding(.horizontal, 36).padding(.bottom, 6)
            } else {
                ForEach(Array(rows.enumerated()), id: \.1.id) { i, item in
                    SysRow(item: item).appearIn(i)
                }
            }
        }
    }

    private func empty(_ s: SysItem.Section) -> String {
        switch s {
        case .snapshots: return "No local snapshots right now."
        case .backups: return "No iPhone or iPad backups on this Mac."
        case .messages: return "No Messages attachments."
        case .mail: return "Mail isn't set up, or has no downloads."
        }
    }

    private var summary: String {
        let list = m.chosen
        var lines = list.prefix(14).map { "• \($0.name)" + ($0.size.map { ": \(ByteText.string($0))" } ?? "") }
        if list.count > 14 { lines.append("• …and \(list.count - 14) more") }
        var tail = ""
        if list.contains(where: { $0.section == .backups }) { tail += "\n\nDevice backups can't be recreated without the device. They go to the Trash." }
        if list.contains(where: { $0.section == .messages }) { tail += "\nMessages will show removed attachments as unavailable." }
        if list.contains(where: { $0.needsPassword }) { tail += "\nSnapshots are deleted permanently; macOS asks for your password." }
        return lines.joined(separator: "\n") + tail
    }
}

private struct SummaryCard: View {
    let symbol: String
    let color: Color
    let title: String
    let value: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IconTile(symbol: symbol, color: color, size: 34)
            Text(value).font(.system(size: 20, weight: .bold)).monospacedDigit()
                .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(sub).font(.system(size: 11)).foregroundStyle(Palette.faint).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 16)
        .hoverLift()
    }
}

private struct SysRow: View {
    @Environment(SystemDataModel.self) private var m
    let item: SysItem
    @State private var hover = false

    var body: some View {
        let ok = SystemDataEngine.reason(item) == nil
        let on = m.selected.contains(item.id)
        HStack(spacing: 12) {
            if ok { CheckSquare(on: on, color: Palette.accent) }
            else { Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(Palette.faint).frame(width: 18) }
            Group {
                if let r = item.reveal, item.section != .snapshots {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: r.path)).resizable().frame(width: 30, height: 30)
                } else {
                    IconTile(symbol: "clock.arrow.circlepath", color: Color(hex: 0x14B8C8), size: 30)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if item.review { ReviewTag() }
                    if item.needsPassword { Tag(text: "PASSWORD", color: Palette.warn) }
                }
                Text(item.detail).font(.system(size: 11)).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(item.size.map(ByteText.string) ?? "size not shown").font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(item.size == nil ? Palette.faint : Palette.dim)
            if let r = item.reveal {
                Button { NSWorkspace.shared.activateFileViewerSelecting([r]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .padding(.leading, 14)
        .background(on ? Palette.selection.opacity(0.5) : hover ? Palette.fg.opacity(0.04) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { m.toggle(item) } }
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(ok ? (on ? "Selected" : "Not selected") : "View only")
        .accessibilityAction { m.toggle(item) }
        .help(SystemDataEngine.reason(item) ?? item.reveal?.path ?? "")
    }
}
