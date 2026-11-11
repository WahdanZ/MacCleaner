import AppKit
import SwiftUI

enum SidebarPage: String, CaseIterable, Identifiable {
    case overview, junk, projects, sdks, large, duplicates, apps, extensions, startup, systemData, storage, shredder
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .junk: return "Junk Files"
        case .projects: return "Projects"
        case .sdks: return "Developer SDKs"
        case .systemData: return "System Data"
        case .large: return "Large & Old Files"
        case .duplicates: return "Duplicates"
        case .apps: return "Apps"
        case .extensions: return "Extensions"
        case .startup: return "Startup Items"
        case .storage: return "Storage Analysis"
        case .shredder: return "Shredder"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "house"
        case .junk: return "trash"
        case .projects: return "hammer"
        case .sdks: return "shippingbox"
        case .systemData: return "internaldrive"
        case .large: return "folder"
        case .duplicates: return "plus.square.on.square"
        case .apps: return "square.grid.2x2"
        case .extensions: return "puzzlepiece.extension"
        case .startup: return "power"
        case .storage: return "chart.bar.xaxis"
        case .shredder: return "printer"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Keep your Mac clean, fast, and running at its best."
        case .junk: return "Developer caches, app caches, logs and temporary files across 340+ locations."
        case .projects: return "Build files and packages in your code projects: they come back when you build."
        case .sdks: return "Simulator runtimes, Android SDK parts and Docker data, with what your projects still use."
        case .systemData: return "Time Machine snapshots, device backups, Mail and Messages: the big parts of System Data."
        case .large: return "Big files and files you haven't opened in a long time."
        case .duplicates: return "Identical files, compared by content."
        case .apps: return "App sizes, caches and complete uninstall with leftovers."
        case .extensions: return "Plug-ins, preference panes, Quick Look add-ons and drivers."
        case .startup: return "What starts automatically with your Mac."
        case .storage: return "See exactly where your space goes, folder by folder."
        case .shredder: return "Permanently delete files, skipping the Trash."
        }
    }

    var isTool: Bool { self == .storage || self == .shredder || self == .systemData }
}

struct ContentView: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(TrashModel.self) private var trash
    @AppStorage("sidebarPage") private var page: SidebarPage = .overview
    @AppStorage("appearance") private var appearance = "system"
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var showIntro = false
    @AppStorage("introSeen") private var introSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scheme: ColorScheme? {
        appearance == "light" ? .light : appearance == "dark" ? .dark : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page)
                .frame(width: 280)
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    PageHeader(title: page.title, subtitle: page.subtitle)
                    Spacer()
                    Button { showHelp.toggle() } label: { Image(systemName: "questionmark") }
                        .buttonStyle(CircleIconButtonStyle())
                        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                            HelpView { showHelp = false; showIntro = true }
                        }
                        .help("Help")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(CircleIconButtonStyle())
                        .help("Settings")
                }
                if [.junk, .storage, .large, .duplicates, .systemData].contains(page), !cleaner.fullDiskAccess {
                    AccessBanner()
                }
                content
                    .id(page)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.99, anchor: .top)),
                        removal: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.86), value: page)
            .padding(.horizontal, 34)
            .padding(.top, 34)
            .padding(.bottom, 22)
        }
        .background(AppBackground())
        .foregroundStyle(Palette.fg)
        .preferredColorScheme(scheme)
        .modifier(FeatureAlerts())
        .modifier(TrashAlerts())
        .overlay { CelebrationOverlay() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showIntro) { IntroView() }
        .task {
            if !introSeen {
                try? await Task.sleep(for: .milliseconds(600))
                showIntro = true
            }
        }
        .onAppear { cleaner.refreshDisk() }
        .task { await trash.refresh() }
        // Every cleanup is recorded in history; refresh the Trash size after each one.
        .onChange(of: HistoryStore.shared.records.count) { Task { await trash.refresh() } }
        .onChange(of: page) { Task { await trash.refresh() } }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .overview:
            OverviewView(page: $page)
        case .junk:
            VStack(spacing: 12) {
                if !cleaner.categories.isEmpty { Legend() }
                HStack(alignment: .top, spacing: 16) {
                    Stage().frame(maxWidth: .infinity, maxHeight: .infinity).panel()
                    Inspector().frame(width: 370).frame(maxHeight: .infinity).panel()
                }
                BottomBar(tab: .caches)
            }
        case .projects:
            ProjectsView()
        case .sdks:
            DevSDKView()
        case .systemData:
            SystemDataView()
        case .large:
            LargeFilesView()
        case .duplicates:
            VStack(spacing: 12) {
                DuplicatesView().frame(maxWidth: .infinity, maxHeight: .infinity).panel()
                BottomBar(tab: .duplicates)
            }
        case .apps:
            AppsView()
        case .extensions:
            ExtensionsView()
        case .startup:
            StartupView()
        case .storage:
            VStack(spacing: 12) {
                DiskMapView()
                BottomBar(tab: .disk)
            }
        case .shredder:
            ShredderView()
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(CleanerModel.self) private var cleaner
    @Binding var page: SidebarPage
    @Namespace private var pill

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac Cleaner").font(.system(size: 20, weight: .bold))
                    Text("Clean · Optimize · Protect").font(.system(size: 13)).foregroundStyle(Palette.dim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 22)

            ForEach(SidebarPage.allCases.filter { !$0.isTool }) { p in
                SidebarRow(page: p, selected: page == p, badge: badge(p), pill: pill) { page = p }
            }

            Rectangle().fill(Palette.stroke).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 12)
            Text("Tools").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.dim)
                .padding(.horizontal, 12).padding(.bottom, 4)
            ForEach(SidebarPage.allCases.filter(\.isTool)) { p in
                SidebarRow(page: p, selected: page == p, badge: nil, pill: pill) { page = p }
            }

            Spacer()
            DiskCard()
        }
        .padding(.horizontal, 14)
        .padding(.top, 50)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .background(Palette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.stroke).frame(width: 1) }
    }

    private func badge(_ p: SidebarPage) -> String? {
        guard p == .junk, cleaner.hasScanned, cleaner.recommendedBytes > 0 else { return nil }
        return ByteText.string(cleaner.recommendedBytes)
    }
}

private struct SidebarRow: View {
    let page: SidebarPage
    let selected: Bool
    let badge: String?
    let pill: Namespace.ID
    let action: () -> Void
    @State private var hover = false
    @State private var bounce = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: page.symbol)
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 26)
                    .foregroundStyle(selected ? Palette.accent : Palette.fg.opacity(0.75))
                    .symbolEffect(.bounce, value: bounce)
                Text(page.title).font(.system(size: 16))
                Spacer()
                if let badge {
                    Text(badge).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Palette.fg.opacity(0.07), in: Capsule())
                        .foregroundStyle(Palette.dim)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.selection)
                        .matchedGeometryEffect(id: "pill", in: pill)
                } else if hover {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fg.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .simultaneousGesture(TapGesture().onEnded { bounce += 1 })
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selected)
    }
}

private struct DiskCard: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(TrashModel.self) private var trash

    var body: some View {
        let used = cleaner.totalBytes - cleaner.freeBytes
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: "/")).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Macintosh HD").font(.system(size: 14, weight: .semibold))
                    Text("\(ByteText.string(used)) of \(ByteText.string(cleaner.totalBytes)) used")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                }
            }
            HStack(spacing: 10) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.fg.opacity(0.1))
                        Capsule().fill(LinearGradient(colors: [Palette.accent2, barColor], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * (filled ? cleaner.usedFraction : 0))
                            .animation(.spring(response: 1.0, dampingFraction: 0.85), value: filled)
                            .animation(.spring(response: 0.6), value: cleaner.usedFraction)
                    }
                }
                .frame(height: 7)
                Text("\(Int((cleaner.usedFraction * 100).rounded()))%").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText(value: cleaner.usedFraction))
                    .animation(.snappy, value: cleaner.usedFraction)
            }
            if trash.displayBytes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Palette.dim)
                    Text("Trash \(trash.isExact ? "" : "≥ ")\(ByteText.string(trash.displayBytes))")
                        .font(.system(size: 12)).foregroundStyle(Palette.dim)
                    Spacer()
                    Button("Empty") { trash.confirmingEmpty = true }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                        .disabled(trash.busy)
                }
            }
        }
        .padding(14)
        .panel(radius: 18)
        .onAppear { cleaner.refreshDisk(); filled = true }
    }

    @State private var filled = false
    @Environment(AutomationModel.self) private var auto

    private var barColor: Color {
        switch auto.level { case .ok: Palette.accent; case .low: Palette.warn; case .critical: Palette.danger }
    }
}

// MARK: - Settings & help

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CleanerModel.self) private var cleaner
    @AppStorage("appearance") private var appearance = "system"
    @State private var showAI = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings").font(.system(size: 22, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }

            section("Appearance") {
                Picker("", selection: $appearance) {
                    Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                    Label("Light", systemImage: "sun.max").tag("light")
                    Label("Dark", systemImage: "moon").tag("dark")
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            section("Full Disk Access") {
                HStack {
                    Label(cleaner.fullDiskAccess ? "Granted: scans see everything" : "Not granted: some folders can't be measured",
                          systemImage: cleaner.fullDiskAccess ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundStyle(cleaner.fullDiskAccess ? Palette.success : Palette.warn)
                        .font(.system(size: 13))
                    Spacer()
                    Button("Open settings") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button("Check") { cleaner.fullDiskAccess = Scanner.hasFullDiskAccess() }.buttonStyle(GhostButtonStyle())
                }
            }

            section("Automation") {
                AutomationSettings()
            }

            section("Protected") {
                ProtectedList()
            }

            section("Command line") {
                CLISettingsRow()
            }

            section("AI assistants") {
                HStack {
                    Text("Let Claude, Cursor, Codex and other AI apps use Mac Cleaner (MCP server + skill).")
                        .font(.system(size: 13)).foregroundStyle(Palette.dim)
                    Spacer()
                    Button { showAI = true } label: { Label("Connect AI…", systemImage: "sparkles") }
                        .buttonStyle(GhostButtonStyle())
                }
            }

            section("History") {
                HStack {
                    Text("\(HistoryStore.shared.records.count) cleanups · \(ByteText.string(HistoryStore.shared.totalFreed)) freed in total")
                        .font(.system(size: 13)).foregroundStyle(Palette.dim)
                    Spacer()
                    Button("Clear history") { HistoryStore.shared.clear() }.buttonStyle(GhostButtonStyle())
                }
            }

            Text("Mac Cleaner \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Caches are deleted permanently; everything else goes to the Trash.")
                .font(.system(size: 11)).foregroundStyle(Palette.faint)
        }
        .padding(26)
        }
        .scrollIndicators(.never)
        .frame(width: 640, height: 760)
        .background(AppBackground())
        .sheet(isPresented: $showAI) { IntegrationsView() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(radius: 14)
        }
    }
}

private struct HelpView: View {
    var onTour: () -> Void = {}
    private let items: [(String, String, String)] = [
        ("house", "Overview", "Storage at a glance. Scan for Junk, review the recommendations, then Clean."),
        ("trash", "Junk Files", "Every cache location in detail, with a space map. Caches are deleted permanently and rebuild."),
        ("hammer", "Projects", "node_modules, build, .dart_tool, Pods… in your code projects. Regenerated by your build tools."),
        ("shippingbox", "Developer SDKs", "Simulator runtimes, Android SDK parts and Docker data. In-use items are flagged."),
        ("folder", "Large & Old Files", "Big and forgotten files in your home folder → Trash."),
        ("plus.square.on.square", "Duplicates", "Identical files by content; one copy always stays."),
        ("square.grid.2x2", "Apps", "Clear an app's cache, or uninstall it with all leftovers."),
        ("puzzlepiece.extension", "Extensions", "Plug-ins, panes and drivers from other developers."),
        ("power", "Startup Items", "Launch agents and daemons: stop, start or remove."),
        ("internaldrive", "System Data", "Snapshots, iPhone backups, Mail and Messages attachments."),
        ("chart.bar.xaxis", "Storage Analysis", "Browse every folder by size."),
        ("printer", "Shredder", "Delete files permanently, skipping the Trash."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How Mac Cleaner works").font(.system(size: 15, weight: .bold))
            ForEach(items, id: \.1) { i in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: i.0).frame(width: 20).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.1).font(.system(size: 12.5, weight: .semibold))
                        Text(i.2).font(.system(size: 11.5)).foregroundStyle(Palette.dim)
                    }
                }
            }
            Text("Nothing is removed without a confirmation that lists every item.")
                .font(.system(size: 11)).foregroundStyle(Palette.faint).padding(.top, 4)
            Button(action: onTour) { Label("Take the tour", systemImage: "play.circle") }
                .buttonStyle(AccentButtonStyle())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 360)
    }
}


/// Settings › Protected: folders and files no feature (or AI tool) may clean, trash or shred.
struct ProtectedList: View {
    @State private var paths = ProtectedPaths.all

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Never cleaned, trashed, shredded or uninstalled, from any section or AI tool. Folders protect everything inside them.")
                .font(.system(size: 12)).foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            if paths.isEmpty {
                Text("Nothing protected yet.").font(.system(size: 12)).foregroundStyle(Palette.faint)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(paths, id: \.self) { p in
                            HStack(spacing: 10) {
                                Image(systemName: "lock.fill").foregroundStyle(Palette.accent).font(.system(size: 11))
                                Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 18, height: 18)
                                Text(Scanner.tilde(URL(fileURLWithPath: p))).font(.system(size: 12))
                                    .lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(FileManager.default.fileExists(atPath: p) ? Palette.fg : Palette.faint)
                                Spacer()
                                Button {
                                    ProtectedPaths.remove(p); paths = ProtectedPaths.all
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(Palette.faint).help("Stop protecting")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.prompt = "Protect"
                if panel.runModal() == .OK { ProtectedPaths.add(panel.urls); paths = ProtectedPaths.all }
            } label: { Label("Add folder or file…", systemImage: "lock.badge.plus") }
                .buttonStyle(GhostButtonStyle())
        }
        .onAppear { paths = ProtectedPaths.all }
    }
}


/// Settings › Command line: install or remove the `mac-cleaner` command.
struct CLISettingsRow: View {
    @State private var installed = CLIInstaller.installedAt
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(installed.map { "Installed: \(Scanner.tilde($0))" } ?? "Use Mac Cleaner from Terminal: mac-cleaner status, scan, clean…")
                        .font(.system(size: 13)).foregroundStyle(installed == nil ? Palette.dim : Palette.success)
                    Text("Same engine and safety rules as the app: deletes always show a preview and ask you to type yes.")
                        .font(.system(size: 11)).foregroundStyle(Palette.faint)
                }
                Spacer()
                if installed != nil {
                    Button("Copy example") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("mac-cleaner help", forType: .string)
                        message = "Copied “mac-cleaner help”. Paste it in Terminal."
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button("Remove") { CLIInstaller.uninstall(); installed = CLIInstaller.installedAt; message = nil }
                        .buttonStyle(GhostButtonStyle())
                } else {
                    Button { install() } label: { Label("Install command", systemImage: "terminal") }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(Palette.dim).textSelection(.enabled) }
        }
    }

    private func install() {
        switch CLIInstaller.install() {
        case .success(let u):
            installed = u
            message = u.path.contains("/.local/bin")
                ? "Installed in ~/.local/bin. If Terminal says “command not found”, add it to your PATH: echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"
                : "Open a new Terminal window and run: mac-cleaner help"
        case .failure(let e):
            message = e.localizedDescription
        }
    }
}
