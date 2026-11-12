import AppKit
import SwiftUI

// MARK: - Navigation model

/// Sidebar destinations. Related tools share one destination with a segmented switch in the toolbar
/// (Projects + SDKs → Developer Tools; Startup Items + Extensions → Startup & Extensions).
enum SidebarPage: String, CaseIterable, Identifiable {
    case overview, junk, developer, large, duplicates, apps, storage, systemData, startup, shredder
    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case home = "", cleanUp = "Clean Up", manage = "Manage", utilities = "Utilities"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .overview: return .home
        case .junk, .developer, .large, .duplicates: return .cleanUp
        case .apps, .storage, .systemData: return .manage
        case .startup, .shredder: return .utilities
        }
    }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .junk: return "Junk Files"
        case .developer: return "Developer Tools"
        case .large: return "Large & Old Files"
        case .duplicates: return "Duplicates"
        case .apps: return "Applications"
        case .storage: return "Storage Map"
        case .systemData: return "System Data"
        case .startup: return "Startup & Extensions"
        case .shredder: return "Shredder"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .junk: return "trash"
        case .developer: return "hammer"
        case .large: return "doc.text.magnifyingglass"
        case .duplicates: return "plus.square.on.square"
        case .apps: return "square.grid.2x2"
        case .storage: return "chart.bar.xaxis"
        case .systemData: return "internaldrive"
        case .startup: return "power"
        case .shredder: return "flame"
        }
    }

    /// Short toolbar subtitle.
    var subtitle: String {
        switch self {
        case .overview: return "Storage and recommended cleanup"
        case .junk: return "Caches, logs and temporary files"
        case .developer: return "Build files and SDK downloads"
        case .large: return "Big and forgotten files"
        case .duplicates: return "Identical files, by content"
        case .apps: return "Caches and complete uninstall"
        case .storage: return "Where your space goes"
        case .systemData: return "Snapshots, backups, Mail, Messages"
        case .startup: return "What starts with your Mac"
        case .shredder: return "Delete without the Trash"
        }
    }

    /// Pages whose numbers are low without Full Disk Access.
    var needsFullDiskAccess: Bool { [.junk, .storage, .large, .duplicates, .systemData].contains(self) }
}

// MARK: - Window

/// Light / Dark / System, applied through AppKit (NSApp.appearance). Changing it this way redraws every
/// window in place; SwiftUI's preferredColorScheme rebuilt the window and left the sidebar list empty.
enum AppearanceSetting {
    @MainActor static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

struct ContentView: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(TrashModel.self) private var trash
    @Environment(ReviewCenter.self) private var review
    @AppStorage("sidebarPage") private var page: SidebarPage = .overview
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("introSeen") private var introSeen = false
    @State private var showIntro = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var review = review
        NavigationSplitView {
            SidebarList(selection: Binding(get: { page }, set: { if let p = $0 { page = p } }))
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        } detail: {
            VStack(alignment: .leading, spacing: Space.m) {
                if page.needsFullDiskAccess, !cleaner.fullDiskAccess { AccessBanner() }
                PageContent(page: page)
                    .id(page)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 10)),
                        removal: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(Space.xl)
            .navigationTitle(page.title)
            .navigationSubtitle(page.subtitle)
            .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9), value: page)
        }
        .modifier(TrashAlerts())
        .onAppear { AppearanceSetting.apply(appearance) }
        .onChange(of: appearance) { _, v in AppearanceSetting.apply(v) }
        .overlay(alignment: .bottom) { CompletionToast() }
        .sheet(item: $review.request) { CleanupReviewSheet(request: $0) }
        .sheet(isPresented: $showIntro) { IntroView() }
        .task {
            if !introSeen {
                try? await Task.sleep(for: .milliseconds(600))
                showIntro = true
            }
        }
        .onChange(of: introSeen) { _, seen in if !seen { showIntro = true } }
        .onAppear { cleaner.refreshDisk() }
        .task { await trash.refresh() }
        // Every cleanup is recorded in history; refresh the Trash size after each one.
        .onChange(of: HistoryStore.shared.records.count) { Task { await trash.refresh() } }
    }
}

/// The page for a sidebar destination.
struct PageContent: View {
    let page: SidebarPage
    @Environment(CleanerModel.self) private var cleaner

    var body: some View {
        switch page {
        case .overview:
            OverviewView()
        case .junk:
            JunkFilesView()
        case .developer:
            DeveloperToolsView()
        case .large:
            LargeFilesView()
        case .duplicates:
            VStack(spacing: Space.m) {
                DuplicatesView().frame(maxWidth: .infinity, maxHeight: .infinity).panel()
                BottomBar(tab: .duplicates)
            }
        case .apps:
            AppsView()
        case .storage:
            VStack(spacing: Space.m) {
                DiskMapView()
                BottomBar(tab: .disk)
            }
        case .systemData:
            SystemDataView()
        case .startup:
            StartupAndExtensionsView()
        case .shredder:
            ShredderView()
        }
    }
}

/// Junk Files: space map and item list side by side; the list can be hidden from the toolbar.
struct JunkFilesView: View {
    @Environment(CleanerModel.self) private var cleaner
    @AppStorage("junkInspector") private var showList = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.m) {
            if !cleaner.categories.isEmpty { Legend() }
            // The list takes about a third of the width (300–440 pt), so small windows keep a usable map.
            GeometryReader { g in
                HStack(spacing: Space.m) {
                    Stage().frame(maxWidth: .infinity, maxHeight: .infinity).panel()
                    if showList {
                        Inspector()
                            .frame(width: min(440, max(300, g.size.width * 0.34)))
                            .frame(maxHeight: .infinity)
                            .panel()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .animation(Motion.standard(reduceMotion), value: showList)
            BottomBar(tab: .caches)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showList.toggle() } label: { Label("Item List", systemImage: "sidebar.trailing") }
                    .help(showList ? "Hide the item list" : "Show the item list")
            }
        }
    }
}

/// Projects and SDKs: two tools for one job (developer storage), switched in the toolbar.
struct DeveloperToolsView: View {
    enum Tab: String, CaseIterable, Identifiable { case projects = "Projects", sdks = "SDKs"; var id: String { rawValue } }
    @AppStorage("developerTab") private var tab: Tab = .projects

    var body: some View {
        Group {
            switch tab {
            case .projects: ProjectsView()
            case .sdks: DevSDKView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Developer Tools", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Build files in your projects, or SDKs and simulators")
            }
        }
    }
}

struct StartupAndExtensionsView: View {
    enum Tab: String, CaseIterable, Identifiable { case startup = "Startup Items", extensions = "Extensions"; var id: String { rawValue } }
    @AppStorage("startupTab") private var tab: Tab = .startup

    var body: some View {
        Group {
            switch tab {
            case .startup: StartupView()
            case .extensions: ExtensionsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Startup & Extensions", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarList: View {
    @Binding var selection: SidebarPage?
    @Environment(CleanerModel.self) private var cleaner

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarPage.Group.allCases) { g in
                let pages = SidebarPage.allCases.filter { $0.group == g }
                if g == .home {
                    ForEach(pages) { row($0) }
                } else {
                    Section(g.rawValue) { ForEach(pages) { row($0) } }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarStorage().padding(Space.m) }
    }

    private func row(_ p: SidebarPage) -> some View {
        Label(p.title, systemImage: p.symbol)
            .badge(badge(p))
            .tag(p)
    }

    private func badge(_ p: SidebarPage) -> Text? {
        guard p == .junk, cleaner.hasScanned, cleaner.recommendedBytes > 0 else { return nil }
        return Text(ByteText.string(cleaner.recommendedBytes))
    }
}

/// Startup disk usage and Trash size, pinned to the bottom of the sidebar.
private struct SidebarStorage: View {
    @Environment(CleanerModel.self) private var cleaner
    @Environment(TrashModel.self) private var trash
    @Environment(AutomationModel.self) private var auto

    var body: some View {
        let used = max(0, cleaner.totalBytes - cleaner.freeBytes)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "internaldrive").foregroundStyle(Palette.dim)
                Text("Macintosh HD").font(.callout.weight(.medium))
                Spacer()
            }
            ProgressView(value: Double(used), total: Double(max(cleaner.totalBytes, 1)))
                .progressViewStyle(.linear)
                .tint(levelColor)
            Text("\(ByteText.string(cleaner.freeBytes)) available of \(ByteText.string(cleaner.totalBytes))")
                .font(.caption).foregroundStyle(Palette.dim).monospacedDigit()
            if trash.displayBytes > 0 {
                HStack(spacing: Space.xs) {
                    Image(systemName: "trash").font(.caption).foregroundStyle(Palette.dim)
                    Text("Trash \(trash.isExact ? "" : "≥ ")\(ByteText.string(trash.displayBytes))")
                        .font(.caption).foregroundStyle(Palette.dim)
                    Spacer()
                    Button("Empty…") { trash.confirmingEmpty = true }
                        .buttonStyle(.link).font(.caption)
                        .disabled(trash.busy)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Startup disk: \(ByteText.string(cleaner.freeBytes)) available of \(ByteText.string(cleaner.totalBytes))")
        .onAppear { cleaner.refreshDisk() }
    }

    private var levelColor: Color {
        switch auto.level { case .ok: Palette.accent; case .low: Palette.warn; case .critical: Palette.danger }
    }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            Form { Section { ProtectedList() } header: { Text("Protected folders and files") } }
                .formStyle(.grouped)
                .tabItem { Label("Protection", systemImage: "lock.shield") }
            Form { Section { AutomationSettings() } header: { Text("Low disk and weekly clean") } }
                .formStyle(.grouped)
                .tabItem { Label("Automation", systemImage: "clock.arrow.2.circlepath") }
            PermissionsSettings().tabItem { Label("Permissions", systemImage: "hand.raised") }
            Form {
                Section("AI assistants (MCP)") { IntegrationsView(embedded: true) }
                Section("Command line") { CLISettingsRow() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Integrations", systemImage: "terminal") }
        }
        .frame(width: 640, height: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("introSeen") private var introSeen = true
    @AppStorage(Updater.autoKey) private var autoUpdate = true
    @Environment(AutomationModel.self) private var auto
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Open at login (menu bar only, so disk checks keep running)", isOn: Binding(
                    get: { auto.loginEnabled }, set: { auto.setLogin($0) }))
                if auto.loginNeedsApproval {
                    Text("Approve it in System Settings › General › Login Items.").font(.caption).foregroundStyle(Palette.warn)
                }
            }
            Section("History") {
                LabeledContent("Deleted permanently", value: ByteText.string(HistoryStore.shared.totalDeleted))
                LabeledContent("Moved to Trash", value: ByteText.string(HistoryStore.shared.totalTrashed))
                if HistoryStore.shared.totalUnclassified > 0 {
                    LabeledContent("Earlier cleanups (not classified)", value: ByteText.string(HistoryStore.shared.totalUnclassified))
                }
                LabeledContent("Cleanups", value: "\(HistoryStore.shared.records.count)")
                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .disabled(HistoryStore.shared.records.isEmpty)
                    .confirmationDialog("Clear the cleanup history?", isPresented: $confirmClear) {
                        Button("Clear History", role: .destructive) { HistoryStore.shared.clear() }
                    } message: {
                        Text("This removes the list of past cleanups. It doesn't change any files.")
                    }
            }
            Section("Updates") {
                LabeledContent("Version", value: Updater.currentVersion)
                Toggle("Check for updates automatically (once a day, from GitHub)", isOn: $autoUpdate)
                HStack {
                    Button(Updater.shared.updateAvailable ? "Show Update…" : "Check Now") {
                        if Updater.shared.updateAvailable { Updater.shared.show() }
                        else { Task { await Updater.shared.check(userInitiated: true) } }
                    }
                    if let last = Updater.shared.lastCheck {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(Palette.dim)
                    }
                }
            }
            Section {
                Button("Show the Welcome Tour") { introSeen = false }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsSettings: View {
    @Environment(CleanerModel.self) private var cleaner

    var body: some View {
        Form {
            Section {
                LabeledContent("Full Disk Access") {
                    Label(cleaner.fullDiskAccess ? "Allowed" : "Not allowed",
                          systemImage: cleaner.fullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(cleaner.fullDiskAccess ? Palette.success : Palette.warn)
                }
                Text("Without it, macOS hides the Trash, Mail, Messages and other apps' data, so totals come out low. Nothing is cleaned without your review either way.")
                    .font(.callout).foregroundStyle(Palette.dim)
                HStack {
                    Button("Open Privacy & Security…") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                    Button("Check Again") { cleaner.fullDiskAccess = Scanner.hasFullDiskAccess() }
                }
            }
            Section("Also asked when needed") {
                LabeledContent("Finder automation", value: "to measure and empty the Trash")
                LabeledContent("Administrator password", value: "for items outside your home folder")
                LabeledContent("Notifications", value: "for low-disk alerts")
            }
        }
        .formStyle(.grouped)
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
                .buttonStyle(.bordered)
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
                    .buttonStyle(.bordered)
                    Button("Remove") { CLIInstaller.uninstall(); installed = CLIInstaller.installedAt; message = nil }
                        .buttonStyle(.bordered)
                } else {
                    Button { install() } label: { Label("Install command", systemImage: "terminal") }
                        .buttonStyle(.bordered)
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
