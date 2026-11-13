import AppKit
import MacCleanerCore
import Observation
import SwiftUI

// MARK: - Extensions (plug-ins, panes, drivers…)

struct ExtItem: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let kind: String
    let symbol: String
    let allUsers: Bool
    let size: Int64
    /// What the scan found, captured when it found it; the alert approves exactly this item.
    var identity: FileIdentity? = nil
}

enum ExtensionScanner {
    static let locations: [(String, String, String)] = [
        ("PreferencePanes", "Preference pane", "gearshape"),
        ("QuickLook", "Quick Look plug-in", "eye"),
        ("Spotlight", "Spotlight importer", "magnifyingglass"),
        ("Internet Plug-Ins", "Internet plug-in", "globe"),
        ("Screen Savers", "Screen saver", "sparkles.tv"),
        ("Audio/Plug-Ins/HAL", "Audio driver", "speaker.wave.2"),
        ("Audio/Plug-Ins/Components", "Audio unit", "waveform"),
        ("Input Methods", "Input method", "keyboard"),
        ("Services", "Service", "gearshape.2"),
    ]

    static func scan() -> [ExtItem] {
        var out: [ExtItem] = []
        let fm = FileManager.default
        for (base, allUsers) in [(SafetyGuard.home.appendingPathComponent("Library"), false),
                                 (URL(fileURLWithPath: "/Library"), true)] {
            for (folder, kind, symbol) in locations {
                let dir = base.appendingPathComponent(folder)
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    guard !name.hasPrefix("."), !name.hasPrefix("com.apple") else { continue }
                    let u = dir.appendingPathComponent(name)
                    let display = Bundle(url: u)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? u.deletingPathExtension().lastPathComponent
                    out.append(ExtItem(id: u.path, url: u, name: display, kind: kind, symbol: symbol,
                                       allUsers: allUsers, size: Scanner.allocatedSize(u), identity: AppCleanup.snapshot(u)))
                }
            }
        }
        return out.sorted { $0.size > $1.size }
    }
}

@MainActor @Observable
final class ExtensionsModel {
    var items: [ExtItem] = []
    var loaded = false
    var busy = false
    var pending: ExtItem?
    /// What the alert for `pending` showed: the scan's identity if the same item was still there (`ask`).
    private(set) var pendingShown: (identity: FileIdentity?, refusal: String?) = (nil, nil)

    /// Shows the Remove alert for `x`, capturing what it describes now.
    func ask(_ x: ExtItem) {
        pendingShown = AppCleanup.scannedSnapshot(x.url, scanned: x.identity)
        pending = x
    }
    var message: (text: String, isError: Bool)?

    func load() async {
        busy = true
        items = await Task.detached { ExtensionScanner.scan() }.value
        loaded = true
        busy = false
    }

    /// Removes the item the alert named: in your Library through `trash` (the alert's approval); installed for all
    /// users through the password step, which checks its scanned identity at the privileged move.
    /// `refusal` is what the alert found when it was shown (stale, replaced, missing or unidentified): then nothing
    /// happens, no password prompt either. `adminStep` is passed only by the self-test.
    func remove(_ x: ExtItem, trash: TrashApproval?, refusal: String?,
                adminStep: @escaping AppEngine.AdminStepRunner = AppEngine.defaultAdminStep) async {
        busy = true
        var movedToTrash = false   // from the outcome itself, never from the original being gone
        if let refusal {
            message = ("\(x.name): \(refusal)", true)
        } else if x.allUsers {
            var item = AppLeftover(id: x.id, url: x.url, label: x.kind, size: x.size, include: true, note: nil, needsAdmin: true)
            item.identity = x.identity
            let r = await Task.detached { AppEngine.removeSystemItems([item], adminStep: adminStep) }.value
            movedToTrash = r.removed.contains(x.url) && r.inTrash
            if r.cancelled { message = ("Kept \(x.name) (password prompt cancelled).", false) }
            else if r.errors.isEmpty { message = ("\(x.name) moved to the Trash.", false) }
            else { message = ("\(x.name): \(r.errors.joined(separator: "; "))", true) }
            if x.url.path.hasPrefix("/Library/Audio/Plug-Ins/HAL/") && r.errors.isEmpty && !r.cancelled {
                message = ("\(x.name) moved to the Trash. Audio restarted.", false)
            }
        } else if let trash {
            let run = await AppCleanup.moveToTrash(trash, source: "Extensions")
            movedToTrash = run.moved[x.id] != nil
            if run.moved[x.id] != nil && run.problems.isEmpty { message = ("\(x.name) moved to the Trash.", false) }
            else { message = ("\(x.name): \(run.problems.first?.message ?? "not moved")", true) }
        } else {
            message = ("\(x.name): it wasn't approved, so nothing was moved", true)
        }
        if movedToTrash {
            HistoryStore.shared.add("\(x.name) Moved to Trash", bytes: x.size, symbol: "puzzlepiece.extension", outcome: .trashed)
        }
        await load()
    }
}

struct ExtensionsView: View {
    @Environment(ExtensionsModel.self) private var m

    var body: some View {
        @Bindable var m = m
        VStack(spacing: 14) {
            if let msg = m.message { MessageBar(text: msg.text, isError: msg.isError) { m.message = nil } }
            Group {
                if !m.loaded {
                    WorkingState(symbol: "puzzlepiece.extension", title: "Looking for extensions…", detail: "plug-ins, panes, drivers")
                } else if m.items.isEmpty {
                    EmptyState(symbol: "puzzlepiece.extension", title: "No third-party extensions",
                               text: "No plug-ins, preference panes, drivers or Quick Look add-ons from other developers are installed.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(m.items.enumerated()), id: \.1.id) { i, x in
                                SystemRow(symbol: x.symbol, title: x.name,
                                          subtitle: "\(x.kind) · \(x.allUsers ? "All users" : "You") · \(Scanner.tilde(x.url))",
                                          trailing: ByteText.string(x.size), needsPassword: x.allUsers,
                                          reveal: x.url, actionTitle: "Remove", busy: m.busy) { m.ask(x) }
                                    .appearIn(i)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
            Text("App extensions (Share, Finder, Safari…) live inside their apps; remove the app in Apps to remove them.")
                .font(.system(size: 11)).foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if !m.loaded { await m.load() } }
        .alert("Remove \(m.pending?.name ?? "")?", isPresented: Binding(get: { m.pending != nil }, set: { if !$0 { m.pending = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let x = m.pending {
                    if x.allUsers {   // the password step authorizes it, unless the alert found the item stale
                        let refusal = m.pendingShown.refusal
                        Task { await m.remove(x, trash: nil, refusal: refusal) }
                    } else {
                        AlertConfirmation.confirm(id: x.id, name: x.name, shown: m.pendingShown, module: "extensions") { trash, refusal in
                            Task { await m.remove(x, trash: trash, refusal: refusal) }
                        }
                    }
                }
                m.pending = nil
            }
            Button("Cancel", role: .cancel) { m.pending = nil }
        } message: {
            if let x = m.pending {
                Text("\(x.kind)\n\(x.url.path)\n\n" + (x.allUsers ? "Installed for all users: macOS will ask for your password." : "You can put it back from the Trash."))
            }
        }
    }
}

// MARK: - Startup items (launch agents and daemons)

struct StartupItem: Identifiable, Sendable {
    enum Scope: String, Sendable { case user = "You", allUsers = "All users", system = "Background (system)" }
    let id: String
    let url: URL
    let label: String
    let program: String
    let owner: String
    let scope: Scope
    var running: Bool
    var runAtLoad: Bool
    /// What the scan found, captured when it found it; the alert approves exactly this item.
    var identity: FileIdentity? = nil
}

enum StartupScanner {
    static func scan() -> [StartupItem] {
        let uid = getuid()
        var out: [StartupItem] = []
        let dirs: [(URL, StartupItem.Scope)] = [
            (SafetyGuard.home.appendingPathComponent("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .allUsers),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .system),
        ]
        for (dir, scope) in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".plist") {
                guard !f.hasPrefix("com.apple.") else { continue }
                let u = dir.appendingPathComponent(f)
                let p = NSDictionary(contentsOf: u)
                let label = p?["Label"] as? String ?? String(f.dropLast(6))
                let program = (p?["Program"] as? String) ?? ((p?["ProgramArguments"] as? [String])?.first) ?? ""
                let domain = scope == .system ? "system" : "gui/\(uid)"
                let running = Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 10).status == 0
                out.append(StartupItem(id: u.path, url: u, label: label, program: program, owner: owner(of: program, label: label),
                                       scope: scope, running: running, runAtLoad: (p?["RunAtLoad"] as? Bool) ?? false,
                                       identity: AppCleanup.snapshot(u)))
            }
        }
        return out.sorted { ($0.scope.rawValue, $0.owner) < ($1.scope.rawValue, $1.owner) }
    }

    /// "…/Docker.app/Contents/…" → "Docker"; otherwise the program or label name.
    static func owner(of program: String, label: String) -> String {
        if let r = program.range(of: ".app/") {
            let appPath = String(program[..<r.lowerBound]) + ".app"
            return FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        }
        if !program.isEmpty { return URL(fileURLWithPath: program).lastPathComponent }
        return label
    }
}

@MainActor @Observable
final class StartupModel {
    var items: [StartupItem] = []
    var loaded = false
    var busy = false
    var pending: StartupItem?
    /// What the alert for `pending` showed: the scan's identity if the same item was still there (`ask`).
    private(set) var pendingShown: (identity: FileIdentity?, refusal: String?) = (nil, nil)

    /// Shows the Remove alert for `s`, capturing what it describes now.
    func ask(_ s: StartupItem) {
        pendingShown = AppCleanup.scannedSnapshot(s.url, scanned: s.identity)
        pending = s
    }
    var message: (text: String, isError: Bool)?

    func load() async {
        busy = true
        items = await Task.detached { StartupScanner.scan() }.value
        loaded = true
        busy = false
    }

    /// Stop or start one of your own launch agents (no password needed).
    func toggleRunning(_ s: StartupItem) async {
        guard s.scope == .user else { return }
        busy = true
        let uid = getuid(), path = s.url.path, label = s.label
        let r = await Task.detached {
            s.running ? Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"], timeout: 15)
                      : Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", path], timeout: 15)
        }.value
        if r.status != 0 { message = ("\(s.owner): \(r.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "launchctl failed")", true) }
        else { message = (s.running ? "Stopped \(s.owner) until next login." : "Started \(s.owner).", false) }
        await load()
    }

    /// Removes the item the alert named: yours is stopped, then moved through `trash` (the alert's approval); others
    /// go through the password step, which checks the scanned identity at the privileged move.
    /// `refusal` is what the alert found when it was shown: then nothing happens (no launchctl, no password prompt).
    /// Yours: its file goes to the Trash through `trash`, and only once it has moved is its job stopped, so a refused
    /// approval or a changed file never stops anything. Others: the password step, which stops the job only after
    /// verifying and moving its file. `adminStep` and `stopJob` are passed only by the self-test.
    func remove(_ s: StartupItem, trash: TrashApproval?, refusal: String?,
                adminStep: @escaping AppEngine.AdminStepRunner = AppEngine.defaultAdminStep,
                stopJob: @escaping @Sendable (String) -> Void = AppEngine.defaultStopUserJob) async {
        busy = true
        if let refusal {
            message = ("\(s.owner): \(refusal)", true)
        } else if s.scope == .user, case .refused(_, let reason)? = trash {
            message = ("\(s.owner): \(reason)", true)
        } else if s.scope == .user, let trash {
            let run = await AppCleanup.moveToTrash(trash, source: "Startup items")
            if run.moved[s.id] != nil {
                let label = s.label
                await Task.detached { stopJob(label) }.value
            }
            message = run.moved[s.id] != nil && run.problems.isEmpty
                ? ("\(s.owner) removed from startup (moved to Trash).", false)
                : ("\(s.owner): \(run.problems.first?.message ?? "not moved")", true)
        } else if s.scope == .user {
            message = ("\(s.owner): it wasn't approved, so nothing was changed", true)
        } else {
            var item = AppLeftover(id: s.id, url: s.url, label: "Startup item", size: 0, include: true, note: nil, needsAdmin: true)
            item.identity = s.identity
            item.launchLabel = s.label
            item.launchSystem = s.scope == .system
            let r = await Task.detached { AppEngine.removeSystemItems([item], adminStep: adminStep) }.value
            message = r.cancelled ? ("Kept \(s.owner) (password prompt cancelled).", false)
                : r.errors.isEmpty ? ("\(s.owner) removed from startup (moved to Trash).", false)
                : ("\(s.owner): \(r.errors.joined(separator: "; "))", true)
        }
        await load()
    }
}

struct StartupView: View {
    @Environment(StartupModel.self) private var m

    var body: some View {
        @Bindable var m = m
        VStack(spacing: 14) {
            if let msg = m.message { MessageBar(text: msg.text, isError: msg.isError) { m.message = nil } }
            Group {
                if !m.loaded {
                    WorkingState(symbol: "power", title: "Reading startup items…", detail: "launch agents and daemons")
                } else if m.items.isEmpty {
                    EmptyState(symbol: "power", title: "No third-party startup items",
                               text: "Nothing from other developers starts with your Mac.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(m.items.enumerated()), id: \.1.id) { i, s in
                                SystemRow(symbol: s.scope == .system ? "gearshape.2" : "power",
                                          title: s.owner,
                                          subtitle: "\(s.scope.rawValue) · \(s.label)\(s.runAtLoad ? " · starts at login" : "")",
                                          trailing: s.running ? "Running" : "Stopped",
                                          trailingColor: s.running ? Palette.success : Palette.faint,
                                          needsPassword: s.scope != .user, reveal: s.url,
                                          actionTitle: "Remove", busy: m.busy,
                                          secondaryTitle: s.scope == .user ? (s.running ? "Stop" : "Start") : nil,
                                          secondary: { Task { await m.toggleRunning(s) } }) { m.ask(s) }
                                    .appearIn(i)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel()
            HStack {
                Text("Login items you added in System Settings are managed there.")
                    .font(.system(size: 11)).foregroundStyle(Palette.faint)
                Spacer()
                Button("Open Login Items settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .buttonStyle(.bordered)
                Button { Task { await m.load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Scan again")
                    .buttonStyle(.bordered)
            }
        }
        .task { if !m.loaded { await m.load() } }
        .alert("Remove \(m.pending?.owner ?? "") from startup?", isPresented: Binding(get: { m.pending != nil }, set: { if !$0 { m.pending = nil } })) {
            Button("Remove", role: .destructive) {
                if let s = m.pending {
                    if s.scope == .user {
                        AlertConfirmation.confirm(id: s.id, name: s.owner, shown: m.pendingShown, module: "startup") { trash, refusal in
                            Task { await m.remove(s, trash: trash, refusal: refusal) }
                        }
                    } else {   // the password step authorizes it, unless the alert found the item stale
                        let refusal = m.pendingShown.refusal
                        Task { await m.remove(s, trash: nil, refusal: refusal) }
                    }
                }
                m.pending = nil
            }
            Button("Cancel", role: .cancel) { m.pending = nil }
        } message: {
            if let s = m.pending {
                Text("\(s.label)\n\(s.url.path)\n\nIt is stopped and its file moved to the Trash. The app itself stays installed but may need it to work fully."
                     + (s.scope != .user ? "\n\nmacOS will ask for your password." : ""))
            }
        }
    }
}

// MARK: - Shared row + message

struct SystemRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let trailing: String
    var trailingColor: Color = Palette.dim
    let needsPassword: Bool
    let reveal: URL
    let actionTitle: String
    let busy: Bool
    var secondaryTitle: String? = nil
    var secondary: () -> Void = {}
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, color: Palette.accent, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if needsPassword { Tag(text: "PASSWORD", color: Palette.warn) }
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(trailing).font(.system(size: 12, weight: .medium)).foregroundStyle(trailingColor)
            Button { NSWorkspace.shared.activateFileViewerSelecting([reveal]) } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Show in Finder")
                .buttonStyle(.plain).foregroundStyle(Palette.dim).help("Reveal in Finder")
            if let secondaryTitle {
                Button(secondaryTitle, action: secondary).buttonStyle(.bordered).disabled(busy)
            }
            Button(actionTitle, action: action).buttonStyle(.bordered).disabled(busy)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hover ? Palette.fg.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
        .help(reveal.path)
    }
}

struct MessageBar: View {
    let text: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Palette.warn : Palette.success)
            Text(text).font(.callout).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.accessibilityLabel("Close").buttonStyle(.plain).foregroundStyle(Palette.dim)
        }
        .padding(10)
        .background((isError ? Palette.warn : Palette.success).opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
